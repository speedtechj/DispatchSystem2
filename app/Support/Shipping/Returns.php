<?php

namespace App\Support\Shipping;

use App\Models\Boxissue;
use App\Models\Invoiceissue;
use App\Models\Shipping\ReturnShipment;
use App\Models\Shipping\WrongHubBox;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\Boxes\Sections;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Return shipments: the partner hub puts boxes on one (RET-0001), sends it, and the warehouse
 * scans each box in. Only then is the box back in the pool, in its section.
 */
class Returns
{
    public static function ready(): bool
    {
        return Schema::hasTable('return_shipments');
    }

    /** The return shipment the hub is filling now (made when needed). */
    public static function openFor(int $hubId): ReturnShipment
    {
        return ReturnShipment::where('logistichub_id', $hubId)->where('status', 'preparing')->latest('id')->first()
            ?? ReturnShipment::create(['code' => static::newCode(), 'logistichub_id' => $hubId, 'status' => 'preparing',
                'status_log' => [['status' => 'preparing', 'at' => now()->toIso8601String(), 'by' => Auth::id()]], 'created_by' => Auth::id()]);
    }

    public static function newCode(): string
    {
        $n = ReturnShipment::count() + 1;
        do {
            $code = 'RET-'.str_pad((string) $n++, 4, '0', STR_PAD_LEFT);
        } while (ReturnShipment::where('code', $code)->exists());

        return $code;
    }

    public static function add(WrongHubBox $w): ReturnShipment
    {
        $rs = static::openFor((int) $w->logistichub_id);
        $w->update(['status' => 'returning', 'return_shipment_id' => $rs->id, 'done_by' => Auth::id(), 'done_at' => now()]);

        return $rs;
    }

    public static function remove(WrongHubBox $w): bool
    {
        if ($w->status !== 'returning' || $w->returnShipment?->status !== 'preparing') {
            return false;
        }
        $w->update(['status' => 'waiting', 'return_shipment_id' => null, 'done_by' => null, 'done_at' => null]);

        return true;
    }

    public static function send(ReturnShipment $rs): bool
    {
        if ($rs->status !== 'preparing' || ! $rs->boxes()->exists()) {
            return false;
        }
        $log = (array) $rs->status_log;
        $log[] = ['status' => 'sent', 'at' => now()->toIso8601String(), 'by' => Auth::id()];
        $rs->update(['status' => 'sent', 'status_log' => $log]);

        return true;
    }

    /**
     * The warehouse scans a box in: off its trip, back in the pool (returned), into its section.
     *
     * @return array{status: string, message: string, box: ?WrongHubBox}
     */
    /** @param  int|null  $pin  the box (invoice id) picked in Which one? (board 58) */
    public static function receive(ReturnShipment $rs, string $code, ?int $warehouseId, ?int $pin = null): array
    {
        $all = WrongHubBox::with('invoice')->where('return_shipment_id', $rs->id)->whereHas('invoice', fn ($q) => $q->where('invoice', $code))->orderBy('id')->get();
        $open = $all->where('status', '!=', 'back')->values();
        if (! $pin && $open->count() > 1) {
            return ['status' => 'which', 'message' => $open->count()." boxes have number {$code}. Which one?", 'box' => null, 'boxes' => $open->pluck('invoice')->filter()->values()];
        }
        $w = ($pin ? $all->firstWhere('invoice_id', $pin) : null) ?? $open->first() ?? $all->first();
        if (! $w) {
            return ['status' => 'danger', 'message' => "{$code} is not on return shipment {$rs->code}.", 'box' => null];
        }
        if ($w->status === 'back') {
            return ['status' => 'warning', 'message' => "{$code} was already received. Not counted again.", 'box' => $w];
        }
        DB::transaction(function () use ($w, $warehouseId) {
            $row = $w->tripinvoice ?? Tripinvoice::where('invoice_id', $w->invoice_id)->latest('id')->first();
            if ($row) {
                if ($row->hub_assigned) {
                    app(TripAssignment::class)->removeFromHubTrip($row);
                }
                $row = $row->fresh();
                \App\Models\Invoice::whereKey($row->invoice_id)->update(['is_assigned' => false, 'is_returned' => true]);
                $row->delete(); // the box is back: no longer on the trip (even a locked one)
            }
            $inv = $w->invoice->fresh();
            $section = Sections::forInvoice($inv, $warehouseId);
            $inv->forceFill(['warehouse_id' => $warehouseId ?? $inv->warehouse_id, 'wh_section_id' => $section?->id, 'sectioned_at' => $section ? now() : null, 'is_verified' => true])->save();
            $w->update(['status' => 'back', 'tripinvoice_id' => null, 'received_by' => Auth::id(), 'received_at' => now()]);
        });

        return ['status' => 'success', 'message' => "{$code} is back at the warehouse.", 'box' => $w->fresh('invoice.whSection')];
    }

    /** Finish receiving: boxes not scanned in get an Invoice Issue each. */
    public static function finish(ReturnShipment $rs): int
    {
        $type = Boxissue::firstOrCreate(['issue_type' => 'Missing box']);
        $made = 0;
        foreach (WrongHubBox::with('invoice')->where('return_shipment_id', $rs->id)->where('status', 'returning')->get() as $w) {
            Invoiceissue::create(['invoice' => $w->invoice?->invoice, 'invoice_id' => $w->invoice_id, 'container_id' => $w->invoice?->container_id, 'boxissue_id' => $type->id,
                'remarks' => "Not in return shipment {$rs->code} from {$rs->hub?->hub_name} when it arrived.", 'user_id' => Auth::id()]);
            $made++;
        }
        $log = (array) $rs->status_log;
        $log[] = ['status' => 'received', 'at' => now()->toIso8601String(), 'by' => Auth::id()];
        $rs->update(['status' => 'received', 'status_log' => $log, 'warehouse_id' => $rs->warehouse_id ?? Auth::user()?->warehouse_id]);

        return $made;
    }

    /** @return array{total: int, back: int} */
    public static function counts(ReturnShipment $rs): array
    {
        $b = WrongHubBox::where('return_shipment_id', $rs->id)->get(['status']);

        return ['total' => $b->count(), 'back' => $b->where('status', 'back')->count()];
    }
}
