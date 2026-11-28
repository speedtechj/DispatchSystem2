<?php

namespace App\Support\Connectors;

use App\Models\DeliveryAttempt;
use App\Models\DeliveryReversal;
use App\Models\DeliverySignature;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\TruckReceiptScan;
use App\Models\Tripinvoice;
use App\Models\Warehouse;
use App\Models\Whtripinvoice;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Throwable;

/**
 * Part 47: what happens in Dispatch System becomes a status in the Outbox.
 * A hook never stops a scan: any error is only reported.
 */
class Hooks
{
    public static function register(): void
    {
        Invoice::saved(fn (Invoice $i) => static::safe(fn () => static::invoiceSaved($i)));
        Whtripinvoice::saved(fn (Whtripinvoice $w) => static::safe(fn () => static::transferSaved($w)));
        Tripinvoice::saved(fn (Tripinvoice $t) => static::safe(fn () => static::tripBoxSaved($t)));
        Tripinvoice::deleted(fn (Tripinvoice $t) => static::safe(fn () => Recorder::cancelWaiting('load:'.$t->id)));
        DeliveryAttempt::created(fn (DeliveryAttempt $a) => static::safe(fn () => static::notDelivered($a)));
        DeliveryReversal::created(fn (DeliveryReversal $r) => static::safe(fn () => static::undoDelivery($r)));
        Deliverylog::updated(function (Deliverylog $trip): void {
            if ($trip->taken_at && $trip->wasChanged('taken_at') && ! $trip->getOriginal('taken_at')) {
                static::safe(fn () => Recorder::tripLeft($trip));
            }
        });
        if (class_exists(SeaShipment::class)) {
            SeaShipment::updated(fn (SeaShipment $s) => static::safe(fn () => static::seaShipment($s)));
        }
        if (class_exists(TruckReceiptScan::class)) {
            TruckReceiptScan::created(fn (TruckReceiptScan $s) => static::safe(fn () => static::hubReceived($s)));
        }
    }

    protected static function safe(callable $fn): void
    {
        try {
            if (Recorder::ready() && Recorder::links()) {
                $fn();
            }
        } catch (Throwable $e) {
            report($e);
        }
    }

    /** Unload: the box was scanned out of the container. */
    protected static function invoiceSaved(Invoice $i): void
    {
        if (! $i->wasChanged('is_verified') || ! Recorder::linkIdFor($i->location_code)) {
            return;
        }
        if ($i->is_verified && $i->verified_at) {
            $wh = $i->warehouse_id ? Warehouse::query()->whereKey($i->warehouse_id)->value('name') : null;
            $wh ??= $i->container?->warehouse_id ? Warehouse::query()->whereKey($i->container->warehouse_id)->value('name') : null;
            Recorder::record($i, 'ds.unloaded', $wh, [
                'at' => $i->verified_at, 'user' => $i->verified_by ? (int) $i->verified_by : null,
                'source' => 'unload:'.$i->id, 'location' => $wh,
            ]);
        } elseif (! $i->is_verified) {
            Recorder::cancelWaiting('unload:'.$i->id) || Recorder::undoLatest($i->id, ['ds.unloaded'], Auth::user(), 'Unload scan taken back');
        }
    }

    /** Warehouse transfer: the box was unloaded at the other warehouse. */
    protected static function transferSaved(Whtripinvoice $w): void
    {
        if (! $w->wasChanged('is_unloaded') || ! $w->is_unloaded) {
            return;
        }
        $inv = Invoice::query()->find($w->invoice_id);
        if (! $inv || ! Recorder::linkIdFor($inv->location_code)) {
            return;
        }
        $whId = $w->whdeliverylog?->warehouse_id ?? $w->warehouse_id;
        $name = $whId ? Warehouse::query()->whereKey($whId)->value('name') : null;
        Recorder::record($inv, 'ds.transfer', $name, [
            'user' => $w->user_id ? (int) $w->user_id : null, 'source' => 'transfer:'.$w->id,
            'trip' => $w->whdeliverylog?->trip_number, 'location' => $name,
        ]);
    }

    /** Load on truck (sent when the trip leaves) and Delivered. */
    protected static function tripBoxSaved(Tripinvoice $t): void
    {
        $inv = null;
        $get = function () use ($t, &$inv) {
            return $inv ??= Invoice::query()->find($t->invoice_id);
        };

        foreach (['is_loaded' => 'deliverylog_id', 'is_loaded_hub' => 'deliveryloghub_id'] as $col => $tripCol) {
            if (! $t->wasChanged($col)) {
                continue;
            }
            if (! $t->{$col}) {
                Recorder::cancelWaiting('load:'.$t->id);

                continue;
            }
            $i = $get();
            if (! $i || ! Recorder::linkIdFor($i->location_code)) {
                return;
            }
            $trip = $t->{$tripCol} ? Deliverylog::query()->find($t->{$tripCol}) : null;
            $try = min(3, DeliveryAttempt::query()->where('invoice_id', $t->invoice_id)->count() + 1);
            $hub = $trip?->logistichub_id ? Logistichub::query()->whereKey($trip->logistichub_id)->value('hub_name') : null;
            $ev = Recorder::record($i, 'ds.load.'.$try, null, [
                'source' => 'load:'.$t->id, 'trip' => $trip?->trip_number, 'location' => $hub,
            ]);
            if ($ev && $ev->state === 'trip' && $trip?->taken_at) {
                Recorder::tripLeft($trip); // the trip already left (box added on the road)
            }
        }

        if ($t->wasChanged('is_delivered') && $t->is_delivered) {
            $i = $get();
            if (! $i || ! Recorder::linkIdFor($i->location_code)) {
                return;
            }
            $trip = Deliverylog::query()->find($t->deliveryloghub_id ?: $t->deliverylog_id);
            Recorder::record($i, 'ds.delivered', null, [
                'at' => $t->delivered_at, 'user' => $t->delivered_by ? (int) $t->delivered_by : null,
                'source' => 'deliver:'.$t->id, 'trip' => $trip?->trip_number,
                'location' => $trip?->logistichub_id ? Logistichub::query()->whereKey($trip->logistichub_id)->value('hub_name') : null,
            ]);
        }
    }

    protected static function notDelivered(DeliveryAttempt $a): void
    {
        $i = Invoice::query()->find($a->invoice_id);
        if (! $i || ! Recorder::linkIdFor($i->location_code)) {
            return;
        }
        $next = min(3, DeliveryAttempt::query()->where('invoice_id', $a->invoice_id)->count() + 1);
        $trip = $a->deliverylog_id ? Deliverylog::query()->find($a->deliverylog_id) : null;
        Recorder::record($i, 'ds.back_to_hub.'.max(2, $next), null, [
            'at' => $a->created_at, 'user' => (int) $a->user_id, 'source' => 'attempt:'.$a->id,
            'trip' => $trip?->trip_number, 'reason' => $a->reason?->getLabel(),
            'location' => $trip?->logistichub_id ? Logistichub::query()->whereKey($trip->logistichub_id)->value('hub_name') : null,
        ]);
    }

    protected static function undoDelivery(DeliveryReversal $r): void
    {
        $why = is_object($r->reason) && method_exists($r->reason, 'getLabel') ? $r->reason->getLabel() : (string) $r->reason;
        $src = $r->tripinvoice_id ? 'deliver:'.$r->tripinvoice_id : null;
        if ($src && Recorder::cancelWaiting($src)) {
            return; // still in the 10-minute hold: never sent
        }
        Recorder::undoLatest((int) $r->invoice_id, ['ds.delivered', 'ds.delivered_damaged'], $r->user, Str::limit('Undo delivery: '.$why, 200, ''));
    }

    protected static function seaShipment(SeaShipment $s): void
    {
        if (! $s->wasChanged('status')) {
            return;
        }
        $code = ['at_port' => 'ds.to_port', 'sailed' => 'ds.sailing', 'arrived' => 'ds.arrived_port'][$s->status] ?? null;
        if (! $code) {
            return;
        }
        $island = $s->logistichub_id ? Logistichub::query()->whereKey($s->logistichub_id)->value('island') : null;
        $place = $island ? Str::title((string) $island) : null;
        $ids = Tripinvoice::query()->where('deliverylog_id', $s->deliverylog_id)->pluck('invoice_id');
        foreach (Invoice::query()->whereKey($ids)->get() as $i) {
            if (Recorder::linkIdFor($i->location_code)) {
                Recorder::record($i, $code, $place, ['source' => 'sea:'.$s->id.':'.$i->id, 'trip' => $s->code, 'location' => $s->port_to ?: $place]);
            }
        }
    }

    protected static function hubReceived(TruckReceiptScan $s): void
    {
        $i = Invoice::query()->find($s->invoice_id);
        if (! $i || ! Recorder::linkIdFor($i->location_code)) {
            return;
        }
        $hub = Logistichub::query()->find($s->logistichub_id);
        if (! $hub) {
            return;
        }
        $trip = Deliverylog::query()->find($s->deliverylog_id);
        Recorder::record($i, $hub->is_company ? 'ds.partner_hub' : 'ds.transfer', $hub->hub_name, [
            'user' => $s->user_id ? (int) $s->user_id : null, 'source' => 'hub:'.$s->id,
            'trip' => $trip?->trip_number, 'location' => $hub->hub_name,
        ]);
    }

    /** Delivered with a "damaged" signature: sent as Delivered · damaged. */
    public static function isDamaged(?int $tripinvoiceId): bool
    {
        return $tripinvoiceId && class_exists(DeliverySignature::class)
            && DeliverySignature::query()->where('tripinvoice_id', $tripinvoiceId)->where('why', 'damaged')->exists();
    }
}
