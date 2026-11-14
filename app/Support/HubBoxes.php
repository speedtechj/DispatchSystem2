<?php

namespace App\Support;

use App\Models\Logistichub;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;

/**
 * Box counts per hub, worked out in one query for all hubs (columns are added to each hub row):
 *
 *  - boxes_waiting  Partner hubs only: loaded on a main truck to this hub, not on a hub trip yet.
 *  - boxes_loading  On one of this hub's trips, not loaded yet.
 *  - boxes_out      On one of this hub's trips, loaded, not delivered.
 *  - boxes_today    Delivered today (by this hub, or handed to it and delivered).
 *  - boxes_month    Delivered this month.
 *  - failed_today   Failed delivery attempts today on this hub's trips.
 *
 * "This hub's trips" are the trips it created. For a partner hub the boxes sit on
 * tripinvoices.deliveryloghub_id; for a main hub on deliverylog_id, except the
 * boxes it handed to a partner hub (those count for the partner hub).
 */
class HubBoxes
{
    /** More boxes than this waiting at a partner hub shows in red on the Logistic Hubs list. */
    public const BUSY_WAITING = 250;

    /** @return Builder<Logistichub> every hub with the six counts */
    public static function query(): Builder
    {
        $today = today()->toDateString();
        $month = today()->startOfMonth()->toDateTimeString();

        $trips = '(select d.id from deliverylogs d where d.logistichub_id = logistichubs.id)';
        $mine = "(t.deliveryloghub_id in {$trips} or (t.deliverylog_id in {$trips} and (t.logistichub_id is null or t.logistichub_id = logistichubs.id)))";
        $loaded = "(case when t.deliveryloghub_id in {$trips} then coalesce(t.is_loaded_hub, 0) else coalesce(t.is_loaded, 0) end)";
        $notDelivered = 'coalesce(t.is_delivered, 0) = 0';
        $deliveredOn = 'coalesce(t.delivered_at, t.updated_at)';
        $ours = "(t.logistichub_id = logistichubs.id or {$mine})";

        $count = fn (string $where) => "(select count(*) from tripinvoices t where {$where})";

        return Logistichub::query()
            ->select('logistichubs.*')
            ->selectRaw("case when logistichubs.is_company = 1 then {$count("t.logistichub_id = logistichubs.id and coalesce(t.is_loaded, 0) = 1 and coalesce(t.hub_assigned, 0) = 0 and {$notDelivered}")} else 0 end as boxes_waiting")
            ->selectRaw($count("{$mine} and {$notDelivered} and {$loaded} = 0").' as boxes_loading')
            ->selectRaw($count("{$mine} and {$notDelivered} and {$loaded} = 1").' as boxes_out')
            ->selectRaw($count("{$ours} and t.is_delivered = 1 and date({$deliveredOn}) = ?").' as boxes_today', [$today])
            ->selectRaw($count("{$ours} and t.is_delivered = 1 and {$deliveredOn} >= ?").' as boxes_month', [$month])
            ->selectRaw("(select count(*) from delivery_attempts a where a.deliverylog_id in {$trips} and date(a.created_at) = ?) as failed_today", [$today]);
    }

    /** One hub, with the counts (fast, always fresh). */
    public static function forHub(int $hubId): ?Logistichub
    {
        $hub = Logistichub::find($hubId);

        return $hub ? static::fill($hub, static::counts(true)[$hubId] ?? []) : null;
    }

    /** Every active hub with the counts, for the dashboard (fast; kept 60 seconds). */
    public static function hubs(bool $activeOnly = true): Collection
    {
        $counts = static::counts();

        return Logistichub::query()->when($activeOnly, fn ($q) => $q->where('is_active', true))->get()
            ->each(fn (Logistichub $h) => static::fill($h, $counts[$h->id] ?? []));
    }

    protected static function fill(Logistichub $hub, array $c): Logistichub
    {
        foreach (['boxes_waiting', 'boxes_loading', 'boxes_out', 'boxes_today', 'boxes_month', 'failed_today'] as $k) {
            $hub->{$k} = (int) ($c[$k] ?? 0);
        }
        if (! $hub->is_company) {
            $hub->boxes_waiting = 0;
        }

        return $hub;
    }

    /**
     * The same six counts as query(), worked out from three grouped queries that
     * only read open boxes and boxes delivered this month (no per-hub scans).
     *
     * @return array<int, array<string, int>> hub id => counts
     */
    public static function counts(bool $fresh = false): array
    {
        $key = 'hubboxes.counts.'.today()->toDateString();
        if (! $fresh && ($hit = cache()->store('file')->get($key)) !== null) {
            return $hit;
        }

        $tripHub = DB::table('deliverylogs')->pluck('logistichub_id', 'id')->map(fn ($v) => (int) $v)->all();
        $todayStart = today()->toDateTimeString();
        $tomorrow = today()->addDay()->toDateTimeString();
        $month = today()->startOfMonth()->toDateTimeString();
        $out = [];
        $add = function (int $hub, string $k, int $n) use (&$out) {
            $out[$hub][$k] = ($out[$hub][$k] ?? 0) + $n;
        };

        /** The hubs that count a box as "theirs" (mine), and whether it is on that hub's own hub trip. */
        $mine = function ($r) use ($tripHub): array {
            $hubs = [];
            if ($r->deliveryloghub_id && isset($tripHub[$r->deliveryloghub_id])) {
                $hubs[$tripHub[$r->deliveryloghub_id]] = true; // on this hub's hub trip
            }
            if ($r->deliverylog_id && isset($tripHub[$r->deliverylog_id])) {
                $h = $tripHub[$r->deliverylog_id];
                if (! $r->logistichub_id || (int) $r->logistichub_id === $h) {
                    $hubs[$h] ??= false;
                }
            }

            return $hubs;
        };

        // 1. boxes not delivered yet
        DB::table('tripinvoices')
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->selectRaw('deliverylog_id, deliveryloghub_id, logistichub_id, coalesce(is_loaded, 0) as l, coalesce(is_loaded_hub, 0) as lh, coalesce(hub_assigned, 0) as ha, count(*) as n')
            ->groupBy('deliverylog_id', 'deliveryloghub_id', 'logistichub_id', 'is_loaded', 'is_loaded_hub', 'hub_assigned')
            ->get()
            ->each(function ($r) use ($add, $mine) {
                $n = (int) $r->n;
                if ($r->logistichub_id && $r->l && ! $r->ha) {
                    $add((int) $r->logistichub_id, 'boxes_waiting', $n);
                }
                foreach ($mine($r) as $hub => $onHubTrip) {
                    $loaded = $onHubTrip ? $r->lh : $r->l;
                    $add($hub, $loaded ? 'boxes_out' : 'boxes_loading', $n);
                }
            });

        // 2. boxes delivered this month (today counted too)
        DB::table('tripinvoices')
            ->where('is_delivered', true)
            ->where(fn ($q) => $q->where('delivered_at', '>=', $month)->orWhere(fn ($q) => $q->whereNull('delivered_at')->where('updated_at', '>=', $month)))
            ->selectRaw('deliverylog_id, deliveryloghub_id, logistichub_id, case when coalesce(delivered_at, updated_at) >= ? and coalesce(delivered_at, updated_at) < ? then 1 else 0 end as is_today, count(*) as n', [$todayStart, $tomorrow])
            ->groupBy('deliverylog_id', 'deliveryloghub_id', 'logistichub_id', 'is_today')
            ->get()
            ->each(function ($r) use ($add, $mine) {
                $hubs = array_keys($mine($r));
                if ($r->logistichub_id) {
                    $hubs[] = (int) $r->logistichub_id;
                }
                foreach (array_unique($hubs) as $hub) {
                    $add($hub, 'boxes_month', (int) $r->n);
                    if ($r->is_today) {
                        $add($hub, 'boxes_today', (int) $r->n);
                    }
                }
            });

        // 3. failed delivery attempts today
        DB::table('delivery_attempts')->where('created_at', '>=', $todayStart)->where('created_at', '<', $tomorrow)
            ->selectRaw('deliverylog_id, count(*) as n')->groupBy('deliverylog_id')->get()
            ->each(function ($r) use ($add, $tripHub) {
                if ($r->deliverylog_id && isset($tripHub[$r->deliverylog_id])) {
                    $add($tripHub[$r->deliverylog_id], 'failed_today', (int) $r->n);
                }
            });

        cache()->store('file')->put($key, $out, 60);

        return $out;
    }

    /** One count of one hub, from the fast counts (for list columns). */
    public static function count(int $hubId, string $key): int
    {
        return (int) (static::counts()[$hubId][$key] ?? 0);
    }

    /** "order by" a count: SQL that turns hub ids into their counts (hubs are few). */
    public static function orderSql(string|array $keys, string $direction): string
    {
        $cases = [];
        foreach (static::counts() as $id => $c) {
            $n = array_sum(array_map(fn ($k) => (int) ($c[$k] ?? 0), (array) $keys));
            $cases[] = 'when '.(int) $id.' then '.$n;
        }

        return ($cases ? 'case logistichubs.id '.implode(' ', $cases).' else 0 end' : '0').' '.($direction === 'desc' ? 'desc' : 'asc');
    }

    /** Forget the kept counts (after a scan, so the dashboard is right at once). */
    protected static bool $forgotten = false;

    public static function forget(): void
    {
        if (static::$forgotten && ! app()->runningUnitTests()) {
            return; // once per request is enough
        }
        static::$forgotten = true;
        cache()->store('file')->forget('hubboxes.counts.'.today()->toDateString());
    }

    /** Boxes waiting at a partner hub whose main trip was due 2+ days ago, and the oldest one. */
    public static function waitingTooLong(int $hubId, int $days = 2): array
    {
        $base = DB::table('tripinvoices as t')
            ->join('deliverylogs as d', 'd.id', '=', 't.deliverylog_id')
            ->where('t.logistichub_id', $hubId)
            ->where('t.is_loaded', true)
            ->where(fn ($q) => $q->where('t.hub_assigned', false)->orWhereNull('t.hub_assigned'))
            ->where(fn ($q) => $q->where('t.is_delivered', false)->orWhereNull('t.is_delivered'))
            ->whereDate('d.eta', '<=', today()->subDays($days));

        $oldest = (clone $base)->orderBy('d.eta')->first(['t.invoice', 'd.eta']);

        return ['count' => (clone $base)->count(), 'oldest' => $oldest?->invoice, 'since' => $oldest?->eta];
    }
}
