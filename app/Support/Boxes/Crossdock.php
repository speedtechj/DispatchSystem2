<?php

namespace App\Support\Boxes;

use App\Models\Boxes\WhCrossdock;
use App\Models\Container;
use App\Models\Invoice;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Throwable;

/**
 * A truck waiting at a container unload (for example a 10-wheeler to the Tarlac warehouse).
 * Boxes for that warehouse go straight from the container onto the truck: one scan
 * verifies the box and loads it. The crew can put a box in its section instead, or pause the truck.
 */
class Crossdock
{
    public static function active(?int $containerId): ?WhCrossdock
    {
        if (! $containerId || ! Sections::ready()) {
            return null;
        }

        return WhCrossdock::with('trip.warehouse:id,name')->where('container_id', $containerId)->whereNull('ended_at')->latest('id')->first();
    }

    /** Warehouse trips leaving this warehouse that can take boxes. */
    public static function trips(?int $warehouseId): Collection
    {
        if (! $warehouseId) {
            return collect();
        }

        return Whdeliverylog::with('warehouse:id,name', 'truck:id,plate_no')->where('user_whid', $warehouseId)
            ->where('is_active', true)->where(fn ($q) => $q->where('is_lock', false)->orWhereNull('is_lock'))
            ->latest('id')->limit(20)->get();
    }

    public static function start(Container $container, int $tripId): ?WhCrossdock
    {
        $trip = static::trips(Auth::user()?->warehouse_id)->firstWhere('id', $tripId);
        if (! $trip) {
            return null;
        }
        WhCrossdock::where('container_id', $container->id)->whereNull('ended_at')->update(['ended_at' => now()]);

        return WhCrossdock::create(['container_id' => $container->id, 'whdeliverylog_id' => $trip->id, 'started_by' => Auth::id()]);
    }

    /**
     * Load the box onto the waiting truck when its section is for the truck's warehouse.
     * Returns the trip it was loaded on, or null (then it goes to its section as usual).
     */
    public static function load(Invoice $invoice, ?WhCrossdock $dock, ?\App\Models\Boxes\WhSection $section): ?Whdeliverylog
    {
        $trip = $dock?->trip;
        if (! $dock || $dock->paused || ! $trip || ! $section || ! $section->to_warehouse_id || (int) $section->to_warehouse_id !== (int) $trip->warehouse_id) {
            return null;
        }
        try {
            DB::transaction(function () use ($invoice, $trip): void {
                app(TripAssignment::class)->addToWarehouseTrip($trip, [$invoice]);
                Whtripinvoice::where('whdeliverylog_id', $trip->id)->where('invoice_id', $invoice->id)
                    ->update(['is_loaded' => true, 'loaded_by' => Auth::id(), 'loaded_at' => now()]);
            });
        } catch (Throwable $e) {
            report($e);

            return null;
        }

        return Whtripinvoice::where('whdeliverylog_id', $trip->id)->where('invoice_id', $invoice->id)->exists() ? $trip : null;
    }

    /** "Put in section instead": take the box off the waiting truck again. */
    public static function unload(Invoice $invoice, WhCrossdock $dock): bool
    {
        $row = Whtripinvoice::where('whdeliverylog_id', $dock->whdeliverylog_id)->where('invoice_id', $invoice->id)->where('is_unloaded', false)->first();
        if (! $row) {
            return false;
        }
        DB::transaction(function () use ($row, $invoice): void {
            $row->delete();
            $invoice->update(['wh_is_assigned' => false]);
        });

        return true;
    }

    /**
     * The truck's boxes from this container: on the truck, in the section, still in the container.
     *
     * @return array{trip: string, to: string, onTruck: int, inSection: int, inContainer: int, paused: bool, section: ?string}
     */
    public static function counts(WhCrossdock $dock): array
    {
        $trip = $dock->trip;
        $section = Sections::forWarehouse($trip?->user_whid, (int) $trip?->warehouse_id);
        $forTruck = Invoice::where('container_id', $dock->container_id)->get()
            ->filter(fn ($b) => (int) Sections::forInvoice($b, $trip?->user_whid)?->to_warehouse_id === (int) $trip?->warehouse_id);
        $ids = $forTruck->pluck('id');
        $onTruck = Whtripinvoice::where('whdeliverylog_id', $dock->whdeliverylog_id)->whereIn('invoice_id', $ids)->count();

        return [
            'trip' => (string) $trip?->trip_number, 'to' => (string) ($trip?->warehouse?->name ?? 'the other warehouse'),
            'onTruck' => $onTruck,
            'inSection' => $forTruck->filter(fn ($b) => $b->is_verified)->count() - $onTruck,
            'inContainer' => $forTruck->filter(fn ($b) => ! $b->is_verified)->count(),
            'paused' => (bool) $dock->paused, 'section' => $section?->code,
        ];
    }
}
