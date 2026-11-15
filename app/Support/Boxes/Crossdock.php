<?php

namespace App\Support\Boxes;

use App\Models\Boxes\WhSection;
use App\Models\Invoice;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Throwable;

/**
 * A truck waiting at the warehouse (for example a 10-wheeler to the Tarlac warehouse).
 * The office switches "The truck is here now" on in the transfer trip. While it is on, every
 * box scanned off any container at this warehouse whose section goes to that warehouse is put
 * straight on the truck: one scan verifies the box and loads it. Nothing to pick on the phone.
 * It turns off by itself when the trip is locked or closed.
 */
class Crossdock
{
    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Schema::hasColumn('whdeliverylogs', 'truck_here');
    }

    /** Trucks here now at this warehouse, loading while containers are unloaded. */
    public static function here(?int $warehouseId): Collection
    {
        if (! $warehouseId || ! static::ready() || ! Sections::ready()) {
            return collect();
        }

        return Whdeliverylog::with('warehouse:id,name', 'truck:id,plate_no')->where('user_whid', $warehouseId)
            ->where('truck_here', true)->where('is_active', true)
            ->where(fn ($q) => $q->where('is_lock', false)->orWhereNull('is_lock'))
            ->orderBy('truck_here_at')->get();
    }

    /** The truck here for the warehouse this section goes to. */
    public static function tripFor(?int $warehouseId, ?WhSection $section): ?Whdeliverylog
    {
        if (! $section || ! $section->to_warehouse_id) {
            return null;
        }

        return static::here($warehouseId)->first(fn ($t) => (int) $t->warehouse_id === (int) $section->to_warehouse_id);
    }

    /** Can this trip be switched on: open, from a warehouse, with a section that goes to its warehouse. */
    public static function sectionFor(Whdeliverylog $trip): ?WhSection
    {
        return Sections::forWarehouse($trip->user_whid, (int) $trip->warehouse_id);
    }

    public static function switchOn(Whdeliverylog $trip): void
    {
        $trip->forceFill(['truck_here' => true, 'truck_here_at' => now(), 'truck_here_by' => Auth::id()])->save();
    }

    public static function switchOff(Whdeliverylog $trip): void
    {
        $trip->forceFill(['truck_here' => false])->save();
    }

    /**
     * Load the box onto the truck here when its section goes to the truck's warehouse.
     * Returns the trip it was loaded on, or null (then it goes to its section as usual).
     */
    public static function load(Invoice $invoice, ?int $warehouseId, ?WhSection $section): ?Whdeliverylog
    {
        $trip = static::tripFor($warehouseId, $section);
        if (! $trip) {
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

    /** The truck here that this box was just put on, if any. */
    public static function tripOf(Invoice $invoice, ?int $warehouseId): ?Whdeliverylog
    {
        $ids = static::here($warehouseId)->pluck('id');

        return $ids->isEmpty() ? null : static::here($warehouseId)->firstWhere('id', Whtripinvoice::whereIn('whdeliverylog_id', $ids)->where('invoice_id', $invoice->id)->where('is_unloaded', false)->value('whdeliverylog_id'));
    }

    /** "Put in section instead": take the box off the truck again. */
    public static function unload(Invoice $invoice, Whdeliverylog $trip): bool
    {
        $row = Whtripinvoice::where('whdeliverylog_id', $trip->id)->where('invoice_id', $invoice->id)->where('is_unloaded', false)->first();
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
     * The trucks here, for the bar in the Scan app.
     *
     * @return array<int, array{id: int, trip: string, to: string, plate: ?string, onTruck: int}>
     */
    public static function status(?int $warehouseId): array
    {
        return static::here($warehouseId)->map(fn ($t) => [
            'id' => $t->id, 'trip' => (string) $t->trip_number, 'to' => (string) ($t->warehouse?->name ?? 'the other warehouse'),
            'plate' => $t->truck?->plate_no, 'onTruck' => Whtripinvoice::where('whdeliverylog_id', $t->id)->where('is_loaded', true)->count(),
        ])->values()->all();
    }
}
