<?php

namespace App\Support\Shipping;

use App\Models\Boxissue;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\TruckReceipt;
use App\Models\Shipping\TruckReceiptScan;
use App\Models\Shipping\WrongHubBox;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Boxes\BoxSets;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Partner hub by truck (Baguio and other Luzon hubs): scan the boxes in when the truck from
 * Manila arrives, then Finish receiving. Boxes not scanned get a Missing box issue the same day.
 * Sea shipments are received with Receive container instead, so a box is never scanned in twice.
 */
class TruckReceive
{
    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Schema::hasTable('truck_receipts');
    }

    /** Trips that went to the port as a sea shipment (received with Receive container). */
    public static function seaTripIds(): \Illuminate\Database\Query\Builder|array
    {
        return Shipments::allTripIds();
    }

    /** Boxes of this trip for this hub, scanned onto the truck in Manila. */
    public static function rows(int $tripId, int $hubId): Builder
    {
        return Tripinvoice::query()->where('deliverylog_id', $tripId)->where('logistichub_id', $hubId)->where('is_loaded', true);
    }

    /** Trucks arriving at this hub, not received yet. */
    public static function trips(?int $hubId): Collection
    {
        if (! $hubId || ! static::ready()) {
            return collect();
        }
        $done = TruckReceipt::where('logistichub_id', $hubId)->whereNotNull('finished_at')->pluck('deliverylog_id');

        return Deliverylog::with('truck:id,plate_no')
            ->whereIn('id', Tripinvoice::where('logistichub_id', $hubId)->where('is_loaded', true)
                ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->select('deliverylog_id'))
            ->whereNotIn('id', static::seaTripIds())
            ->whereNotIn('id', $done)
            ->where('created_at', '>=', now()->subDays(60))
            ->latest('id')->limit(40)->get();
    }

    /** @return array{got: int, of: int, missing: Collection} */
    public static function counts(int $tripId, int $hubId): array
    {
        $rows = static::rows($tripId, $hubId)->get(['invoice_id', 'invoice', 'loaded_by', 'loaded_at']);
        $got = TruckReceiptScan::where('deliverylog_id', $tripId)->whereIn('invoice_id', $rows->pluck('invoice_id'))->pluck('invoice_id')->all();

        return ['got' => count($got), 'of' => $rows->count(), 'missing' => $rows->reject(fn ($r) => in_array($r->invoice_id, $got, true))->values()];
    }

    public static function receipt(int $tripId, int $hubId): ?TruckReceipt
    {
        return TruckReceipt::where('deliverylog_id', $tripId)->where('logistichub_id', $hubId)->first();
    }

    /** Scan one box in. Returns the scan, or null when it was already scanned. */
    public static function scan(int $tripId, int $hubId, Tripinvoice $row): ?TruckReceiptScan
    {
        $scan = TruckReceiptScan::firstOrCreate(['deliverylog_id' => $tripId, 'invoice_id' => $row->invoice_id],
            ['logistichub_id' => $hubId, 'user_id' => Auth::id(), 'created_at' => now()]);
        TruckReceipt::firstOrCreate(['deliverylog_id' => $tripId, 'logistichub_id' => $hubId]);

        return $scan->wasRecentlyCreated ? $scan : null;
    }

    /** The box's section is for another partner hub: put it on the Wrong hub & returns list. */
    public static function checkWrongHub(int $hubId, Tripinvoice $row): ?WrongHubBox
    {
        $section = $row->invdata?->whSection;
        if (! $section?->logistichub_id || (int) $section->logistichub_id === $hubId) {
            return null;
        }

        return WrongHubBox::firstOrCreate(['invoice_id' => $row->invoice_id, 'logistichub_id' => $hubId, 'status' => 'waiting'], [
            'tripinvoice_id' => $row->id, 'correct_hub_id' => $section->logistichub_id, 'reason' => 'wrong_hub', 'created_by' => Auth::id(),
        ]);
    }

    /** Finish receiving: every box not scanned gets a Missing box issue. Returns how many. */
    public static function finish(Deliverylog $trip, int $hubId, ?User $by = null): int
    {
        $by ??= Auth::user();
        $c = static::counts($trip->id, $hubId);
        $hub = \App\Models\Logistichub::find($hubId);
        $type = Boxissue::firstOrCreate(['issue_type' => 'Missing box']);
        $made = 0;
        DB::transaction(function () use ($c, $trip, $hubId, $hub, $type, $by, &$made) {
            foreach ($c['missing'] as $row) {
                $exists = Invoiceissue::where('invoice_id', $row->invoice_id)->where('boxissue_id', $type->id)->where('remarks', 'like', '%trip '.$trip->trip_number.'%')->exists();
                if (! $exists) {
                    Invoiceissue::create(['invoice' => $row->invoice, 'invoice_id' => $row->invoice_id, 'container_id' => Invoice::whereKey($row->invoice_id)->value('container_id'),
                        'boxissue_id' => $type->id, 'remarks' => 'Not on trip '.$trip->trip_number.' when '.($hub?->hub_name ?? 'the hub').' received the truck.', 'user_id' => $by?->id]);
                    $made++;
                }
            }
            TruckReceipt::updateOrCreate(['deliverylog_id' => $trip->id, 'logistichub_id' => $hubId],
                ['finished_at' => now(), 'finished_by' => $by?->id, 'missing' => $c['missing']->count()]);
        });
        // The hub has its boxes: the trip may be done now (the truck releases itself).
        \App\Support\TripFlow::maybeClose($trip->fresh());

        return $made;
    }

    /** The customer's boxes at the hub: "1 of 2 received · 1 more on this truck". */
    public static function setAtHub(int $tripId, int $hubId, Invoice $invoice): ?array
    {
        $all = BoxSets::members($invoice);
        if ($all->count() < 2) {
            return null;
        }
        $ids = $all->pluck('id');
        $onTruck = static::rows($tripId, $hubId)->whereIn('invoice_id', $ids)->pluck('invoice_id')->all();
        $got = TruckReceiptScan::where('deliverylog_id', $tripId)->whereIn('invoice_id', $ids)->count();
        $toScan = count($onTruck) - $got;
        $notHere = $all->reject(fn ($b) => in_array($b->id, $onTruck, true))->count();
        $parts = [];
        if ($toScan > 0) {
            $parts[] = $toScan.' more on this truck';
        }
        if ($notHere > 0) {
            $parts[] = $notHere.' not on this truck (still in Manila or on another trip)';
        }

        return ['n' => $got, 'of' => $all->count(), 'name' => Str::title((string) $invoice->receiver_name),
            'text' => $parts ? implode(' · ', $parts) : '✓ All '.$all->count().' boxes at your hub', 'kind' => $notHere ? 'split' : ($toScan ? 'wait' : 'done')];
    }
}
