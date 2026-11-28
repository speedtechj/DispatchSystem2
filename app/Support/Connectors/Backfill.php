<?php

namespace App\Support\Connectors;

use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\TruckReceiptScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whtripinvoice;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;

/**
 * Part 47b · Backfill (board 79, C): send the history of boxes already on the way, once,
 * when a connector is new, so their tracking has no gaps. Statuses are made from what
 * Dispatch System already knows, with their real dates, oldest first, and sent slowly
 * (200 a minute, after everything else). The connector skips what their staff already
 * typed the same day, and anything older than a status Dispatch System sent before.
 */
class Backfill
{
    /** Lowest priority: live statuses always go first. */
    public const PRIORITY = 9;

    public const PER_MINUTE = 200;

    public const MAX_BOXES = 20000;

    /**
     * The boxes: on the way (not delivered), one container, or a date range (boxes unloaded then).
     *
     * @return Collection<int, int>
     */
    public static function boxes(ConnectorLink $link, string $mode, ?string $container, ?string $from, ?string $to, bool $delivered): Collection
    {
        $code = (string) $link->consolidator?->code;
        $q = Invoice::query()->where('location_code', $code);
        match ($mode) {
            'container' => $q->whereIn('container_id', Container::query()->whereRaw("REPLACE(container_no, ' ', '') like ?", ['%'.preg_replace('/\s+/', '', (string) $container).'%'])->select('id')),
            'dates' => $q->whereBetween('verified_at', [Carbon::parse($from ?: now()->subMonth())->startOfDay(), Carbon::parse($to ?: now())->endOfDay()]),
            default => $q->where('is_verified', true),
        };
        if (! $delivered) {
            $q->where('is_delivered', false);
        }

        return $q->orderBy('id')->limit(static::MAX_BOXES)->pluck('id');
    }

    /**
     * What Dispatch System knows about one box, oldest first.
     *
     * @return list<array{code: string, place: ?string, at: Carbon, user: ?int, trip: ?string, location: ?string, key: string}>
     */
    public static function history(Invoice $i, bool $delivered): array
    {
        $out = [];
        $add = function (string $code, ?string $place, $at, ?int $user, ?string $trip, ?string $location, string $key) use (&$out) {
            if ($at) {
                $out[] = ['code' => $code, 'place' => $place, 'at' => Carbon::parse($at), 'user' => $user, 'trip' => $trip, 'location' => $location ?? $place, 'key' => $key];
            }
        };

        if ($i->is_verified && $i->verified_at) {
            $wh = $i->warehouse_id ? Warehouse::query()->whereKey($i->warehouse_id)->value('name') : null;
            $add('ds.unloaded', $wh, $i->verified_at, $i->verified_by ? (int) $i->verified_by : null, null, $wh, 'u');
        }
        foreach (Whtripinvoice::query()->where('invoice_id', $i->id)->where('is_unloaded', true)->with('whdeliverylog')->get() as $w) {
            $name = Warehouse::query()->whereKey($w->whdeliverylog?->warehouse_id ?? $w->warehouse_id)->value('name');
            $add('ds.transfer', $name, $w->updated_at, $w->user_id ? (int) $w->user_id : null, $w->whdeliverylog?->trip_number, $name, 'w'.$w->id);
        }
        if (class_exists(TruckReceiptScan::class)) {
            foreach (TruckReceiptScan::query()->where('invoice_id', $i->id)->get() as $s) {
                $hub = Logistichub::query()->find($s->logistichub_id);
                if ($hub) {
                    $add($hub->is_company ? 'ds.partner_hub' : 'ds.transfer', $hub->hub_name, $s->created_at, $s->user_id ? (int) $s->user_id : null, null, $hub->hub_name, 'h'.$s->id);
                }
            }
        }
        $rows = Tripinvoice::query()->where('invoice_id', $i->id)->orderBy('id')->get();
        if (class_exists(SeaShipment::class)) {
            foreach (SeaShipment::query()->whereIn('deliverylog_id', $rows->pluck('deliverylog_id'))->get() as $s) {
                $island = $s->logistichub_id ? Logistichub::query()->whereKey($s->logistichub_id)->value('island') : null;
                foreach ((array) $s->status_log as $n => $log) {
                    $code = ['at_port' => 'ds.to_port', 'sailed' => 'ds.sailing', 'arrived' => 'ds.arrived_port'][$log['status'] ?? ''] ?? null;
                    if ($code) {
                        $add($code, $island ? Str::title($island) : null, $log['at'] ?? null, isset($log['by']) ? (int) $log['by'] : null, $s->code, $s->port_to, 's'.$s->id.'.'.$n);
                    }
                }
            }
        }
        $attempts = DeliveryAttempt::query()->where('invoice_id', $i->id)->orderBy('created_at')->get();
        foreach ($rows as $t) {
            foreach (array_filter([$t->deliverylog_id => $t->is_loaded, $t->deliveryloghub_id => $t->is_loaded_hub]) as $tripId => $loaded) {
                $trip = $tripId ? Deliverylog::query()->find($tripId) : null;
                if (! $trip?->taken_at) {
                    continue;
                }
                $try = min(3, $attempts->where('created_at', '<', $trip->taken_at)->count() + 1);
                $hub = $trip->logistichub_id ? Logistichub::query()->whereKey($trip->logistichub_id)->value('hub_name') : null;
                $add('ds.load.'.$try, null, $trip->taken_at, $trip->taken_by ? (int) $trip->taken_by : null, $trip->trip_number, $hub, 'l'.$t->id.'.'.$tripId);
            }
            if ($delivered && $t->is_delivered && $t->delivered_at) {
                $add(Hooks::isDamaged($t->id) ? 'ds.delivered_damaged' : 'ds.delivered', null, $t->delivered_at, $t->delivered_by ? (int) $t->delivered_by : null, null, null, 'd'.$t->id);
            }
        }
        foreach ($attempts as $n => $a) {
            $add('ds.back_to_hub.'.max(2, min(3, $n + 2)), null, $a->created_at, (int) $a->user_id, null, null, 'a'.$a->id);
        }

        usort($out, fn ($a, $b) => $a['at'] <=> $b['at']);

        return $out;
    }

    /** @return array{boxes: int, statuses: int, already: int, minutes: int} */
    public static function preview(ConnectorLink $link, string $mode, ?string $container, ?string $from, ?string $to, bool $delivered): array
    {
        $ids = static::boxes($link, $mode, $container, $from, $to, $delivered);
        $statuses = 0;
        $already = 0;
        foreach ($ids->chunk(300) as $chunk) {
            $sent = ConnectorEvent::query()->where('connector_link_id', $link->id)->whereIn('invoice_id', $chunk)->whereNotIn('state', ['cancelled'])
                ->get(['invoice_id', 'code', 'source'])->groupBy('invoice_id');
            foreach (Invoice::query()->whereIn('id', $chunk)->get() as $inv) {
                $have = $sent->get($inv->id, collect());
                foreach (static::history($inv, $delivered) as $h) {
                    $done = $have->contains(fn ($e) => $e->source === static::source($inv->id, $h['key']) || $e->code === $h['code']);
                    $done ? $already++ : $statuses++;
                }
            }
        }

        return ['boxes' => $ids->count(), 'statuses' => $statuses, 'already' => $already, 'minutes' => (int) ceil($statuses / static::PER_MINUTE)];
    }

    /** Put the history in the Outbox (lowest priority). Returns how many statuses. */
    public static function start(ConnectorLink $link, string $mode, ?string $container, ?string $from, ?string $to, bool $delivered, ?User $by = null): int
    {
        $by ??= Auth::user();
        $ids = static::boxes($link, $mode, $container, $from, $to, $delivered);
        $n = 0;
        foreach ($ids->chunk(300) as $chunk) {
            $sent = ConnectorEvent::query()->where('connector_link_id', $link->id)->whereIn('invoice_id', $chunk)->whereNotIn('state', ['cancelled'])
                ->get(['invoice_id', 'code', 'source'])->groupBy('invoice_id');
            foreach (Invoice::query()->whereIn('id', $chunk)->get() as $inv) {
                $have = $sent->get($inv->id, collect());
                foreach (static::history($inv, $delivered) as $h) {
                    if ($have->contains(fn ($e) => $e->source === static::source($inv->id, $h['key']) || $e->code === $h['code'])) {
                        continue; // sent before (live or an earlier backfill)
                    }
                    $ev = Recorder::record($inv, $h['code'], $h['place'], [
                        'link_id' => $link->id, 'at' => $h['at'], 'user' => $h['user'] ?? null, 'trip' => $h['trip'],
                        'location' => $h['location'], 'source' => static::source($inv->id, $h['key']), 'state' => 'ready',
                    ]);
                    if ($ev) {
                        $ev->forceFill(['priority' => static::PRIORITY])->save();
                        $n++;
                    }
                }
            }
        }

        return $n;
    }

    public static function source(int $invoiceId, string $key): string
    {
        return Str::limit('bf:'.$invoiceId.':'.$key, 40, '');
    }

    /** Backfill statuses still waiting for this connector. */
    public static function waiting(ConnectorLink $link): int
    {
        return ConnectorEvent::query()->where('connector_link_id', $link->id)->where('priority', static::PRIORITY)
            ->whereIn('state', ['ready', 'retry', 'busy'])->count();
    }

    /** "Send backfill only at night (10 PM – 5 AM)": is it allowed now? */
    public static function allowedNow(): bool
    {
        if (! Rules::on('night')) {
            return true;
        }
        $h = (int) now()->setTimezone((string) config('connectors.night_timezone', 'America/Edmonton'))->format('G');

        return $h >= 22 || $h < 5;
    }
}
