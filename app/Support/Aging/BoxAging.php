<?php

namespace App\Support\Aging;

use App\Models\Ai\AgingLimit;
use App\Models\Container;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Box aging: how long each box that is not delivered yet has been at its current stage,
 * and in total since its container was unloaded. Plain counting on your own data.
 */
class BoxAging
{
    public const STAGES = [
        'container' => 'In container, not unloaded',
        'waiting' => 'In warehouse, waiting for a trip',
        'transfer' => 'Warehouse transfer (on the way)',
        'hub' => 'At partner hub, waiting for its trip',
        'truck' => 'On a truck, not delivered',
        'failed' => 'Tried and failed, waiting',
    ];

    public const TOTAL = 'total';

    /** Used until you save your own (or the AI's) limits. [warn, late] */
    public const DEFAULTS = [
        'container' => ['all' => [2, 4]],
        'waiting' => ['all' => [4, 7], 'mindanao' => [7, 11]],
        'transfer' => ['all' => [2, 4]],
        'hub' => ['all' => [3, 6]],
        'truck' => ['all' => [2, 4]],
        'failed' => ['all' => [3, 7]],
        'total' => ['metro_manila' => [7, 9], 'luzon' => [9, 12], 'visayas' => [10, 14], 'mindanao' => [14, 18], 'all' => [10, 14]],
    ];

    public const BUCKETS = [[0, 3, '0–3 days'], [4, 7, '4–7 days'], [8, 14, '8–14 days'], [15, 9999, '15+ days']];

    /** Only boxes from containers made in the last … days are followed. */
    public const WINDOW_DAYS = 150;

    /** @return array<string, array<string, array{0: int, 1: int}>> */
    protected static ?array $limitMemo = null;

    public static function limits(): array
    {
        return static::$limitMemo ??= Cache::remember('ai.aging.limits', 600, function () {
            $limits = self::DEFAULTS;
            foreach (AgingLimit::all() as $l) {
                $limits[$l->stage][$l->region] = [(int) $l->warn_days, (int) $l->late_days];
            }

            return $limits;
        });
    }

    public static function forgetLimits(): void
    {
        static::$limitMemo = null;
        Cache::forget('ai.aging.limits');
    }

    /** @return array{0: int, 1: int} */
    public static function limitFor(string $stage, string $region): array
    {
        $l = static::limits()[$stage] ?? [];

        return $l[$region] ?? $l['all'] ?? [5, 10];
    }

    public static function status(int $days, array $limit): string
    {
        return $days >= $limit[1] ? 'late' : ($days >= $limit[0] ? 'warn' : 'ok');
    }

    /**
     * One row per box that is not delivered yet.
     *
     * @return Collection<int, array<string, mixed>>
     */
    public static function rows(?int $hubId = null, ?int $warehouseId = null, bool $fresh = false): Collection
    {
        $key = 'ai.aging.rows.'.($hubId ?? 'x').'.'.($warehouseId ?? 'x');
        $store = Cache::store('file');
        if ($fresh) {
            $store->forget($key);
        }

        return $store->remember($key, 900, function () use ($hubId, $warehouseId) {
            $rows = static::compute($hubId, $warehouseId);
            Cache::store('file')->put(static::badgeKey($hubId, $warehouseId), $rows->where('status', 'late')->count(), 3600);

            return $rows;
        });
    }

    /** Big warehouses can have many thousands of boxes open: give this count enough memory. */
    public static function roomToWork(): void
    {
        $limit = ini_get('memory_limit');
        $bytes = $limit === '-1' ? PHP_INT_MAX : (int) $limit * (str_ends_with(strtoupper((string) $limit), 'G') ? 1024 ** 3 : (str_ends_with(strtoupper((string) $limit), 'M') ? 1024 ** 2 : 1));
        if ($bytes < 512 * 1024 ** 2) {
            @ini_set('memory_limit', '512M');
        }
        if (PHP_SAPI !== 'cli' && (int) ini_get('max_execution_time') < 120) {
            @set_time_limit(120);
        }
    }

    public static function badgeKey(?int $hubId, ?int $warehouseId): string
    {
        return 'ai.aging.badge.'.($hubId ?? 'x').'.'.($warehouseId ?? 'x');
    }

    /** The number of late boxes from the last count, without counting again (for the menu badge). */
    public static function lateCountCached(?int $hubId, ?int $warehouseId): ?int
    {
        $n = Cache::store('file')->get(static::badgeKey($hubId, $warehouseId));

        return $n === null ? null : (int) $n;
    }

    /** Lean: plain rows from the database in chunks, no models, so big warehouses don't run out of memory. */
    protected static function compute(?int $hubId, ?int $warehouseId): Collection
    {
        static::roomToWork();
        $now = now();
        $days = fn ($since) => $since ? max(0, (int) floor(Carbon::parse($since)->diffInHours($now) / 24)) : 0;
        $hubs = DB::table('logistichubs')->get(['id', 'hub_name', 'is_company'])->keyBy('id');
        $out = [];

        $base = DB::table('invoices as i')
            ->join('containers as c', 'c.id', '=', 'i.container_id')
            ->leftJoin('consolidators as k', 'k.id', '=', 'c.consolidator_id')
            ->where('i.is_delivered', false)
            ->where('c.created_at', '>=', $now->copy()->subDays(self::WINDOW_DAYS))
            ->when($warehouseId, fn ($q) => $q->where('i.warehouse_id', $warehouseId))
            ->when($hubId, fn ($q) => $q->whereExists(fn ($e) => $e->from('tripinvoices as h')->whereColumn('h.invoice_id', 'i.id')->where('h.logistichub_id', $hubId)))
            ->select(['i.id', 'i.invoice', 'i.receiver_name', 'i.receiver_barangay', 'i.receiver_city', 'i.receiver_province', 'i.warehouse_id',
                'c.container_no', 'c.created_at as c_created', 'c.unloaded_at', 'c.is_unloaded', 'c.updated_at as c_updated', 'k.company_name']);

        $base->orderBy('i.id')->chunk(2000, function ($chunk) use (&$out, $hubs, $days) {
            $ids = $chunk->pluck('id')->all();
            $trips = DB::table('tripinvoices as t')->join('deliverylogs as d', 'd.id', '=', 't.deliverylog_id')
                ->leftJoin('deliverylogs as hd', 'hd.id', '=', 't.deliveryloghub_id')
                ->whereIn('t.invoice_id', $ids)->orderBy('t.id')
                ->get(['t.invoice_id', 't.logistichub_id', 't.is_loaded', 't.hub_assigned', 't.created_at', 't.updated_at',
                    'd.trip_number', 'd.departure_date', 'hd.trip_number as h_trip', 'hd.departure_date as h_departure'])
                ->keyBy('invoice_id'); // last one wins
            $transfers = DB::table('whtripinvoices as w')->join('whdeliverylogs as wd', 'wd.id', '=', 'w.whdeliverylog_id')
                ->whereIn('w.invoice_id', $ids)->where('w.is_unloaded', false)->orderBy('w.id')
                ->get(['w.invoice_id', 'w.created_at', 'wd.trip_number', 'wd.departure_date'])->keyBy('invoice_id');
            $attempts = DB::table('delivery_attempts')->whereIn('invoice_id', $ids)
                ->selectRaw('invoice_id, max(created_at) as at')->groupBy('invoice_id')->pluck('at', 'invoice_id');

            foreach ($chunk as $i) {
                $unloaded = $i->unloaded_at ?? ($i->is_unloaded ? $i->c_updated : null);
                $t = $trips[$i->id] ?? null;
                $w = $transfers[$i->id] ?? null;
                $a = $attempts[$i->id] ?? null;
                $hub = $t ? ($hubs[$t->logistichub_id] ?? null) : null;

                if (! $unloaded) {
                    [$stage, $since, $where] = ['container', $i->c_created, $i->container_no];
                } elseif ($w) {
                    [$stage, $since, $where] = ['transfer', $w->departure_date ?? $w->created_at, 'Transfer '.$w->trip_number];
                } elseif ($t && $a && Carbon::parse($a)->gte(Carbon::parse($t->created_at))) {
                    [$stage, $since, $where] = ['failed', $a, 'Trip '.($t->h_trip ?? $t->trip_number)];
                } elseif ($t && $hub?->is_company && ! $t->hub_assigned && $t->is_loaded) {
                    [$stage, $since, $where] = ['hub', $t->updated_at, $hub->hub_name];
                } elseif ($t && ($t->is_loaded || $t->hub_assigned)) {
                    $hubTrip = $t->hub_assigned && $t->h_trip;
                    [$stage, $since, $where] = ['truck', ($hubTrip ? $t->h_departure : $t->departure_date) ?? $t->updated_at, 'Trip '.($hubTrip ? $t->h_trip : $t->trip_number)];
                } else {
                    [$stage, $since, $where] = ['waiting', $unloaded, $t ? 'On trip '.$t->trip_number.' (not loaded)' : 'Warehouse'];
                }

                $region = Regions::of($i->receiver_province, $i->receiver_city);
                $d = $days($since);
                $total = $unloaded ? $days($unloaded) : 0;
                $stageLimit = static::limitFor($stage, $region);
                $totalLimit = static::limitFor(self::TOTAL, $region);
                $st = static::status($d, $stageLimit);
                $tt = $unloaded ? static::status($total, $totalLimit) : 'ok';
                $worst = ($st === 'late' || $tt === 'late') ? 'late' : (($st === 'warn' || $tt === 'warn') ? 'warn' : 'ok');

                $out[] = [
                    'invoice_id' => $i->id, 'invoice' => $i->invoice,
                    'name' => Str::title((string) $i->receiver_name),
                    'place' => Str::title(trim($i->receiver_barangay.', '.$i->receiver_city, ', ')),
                    'province' => Str::title((string) $i->receiver_province), 'region' => $region,
                    'stage' => $stage, 'where' => $where,
                    'days' => $d, 'total' => $total, 'stageStatus' => $st, 'status' => $worst,
                    'tomorrow' => $worst !== 'late' && ($d + 1 >= $stageLimit[1] || ($unloaded && $total + 1 >= $totalLimit[1])),
                    'warehouse_id' => $i->warehouse_id, 'hub_id' => $t?->logistichub_id, 'hub' => $hub?->hub_name,
                    'container' => $i->container_no, 'consolidator' => $i->company_name, 'tried' => (bool) $a,
                ];
            }
        });

        return collect($out);
    }

    /** Numbers for the top of the page and the morning summary. */
    public static function summary(Collection $rows): array
    {
        $key = 'ai.aging.ontime';
        [$onTime, $count] = Cache::store('file')->remember($key, 1800, function () {
            $ok = 0;
            $n = 0;
            DB::table('tripinvoices as t')->join('invoices as i', 'i.id', '=', 't.invoice_id')->join('containers as c', 'c.id', '=', 'i.container_id')
                ->where('t.is_delivered', true)->where('t.delivered_at', '>=', now()->subDays(30))
                ->select(['t.id', 't.delivered_at', 'c.unloaded_at', 'i.receiver_province', 'i.receiver_city'])->orderBy('t.id')
                ->chunk(3000, function ($chunk) use (&$ok, &$n) {
                    foreach ($chunk as $r) {
                        $n++;
                        if (! $r->unloaded_at || ! $r->delivered_at) {
                            $ok++;

                            continue;
                        }
                        $limit = static::limitFor(self::TOTAL, Regions::of($r->receiver_province, $r->receiver_city));
                        $ok += Carbon::parse($r->unloaded_at)->diffInDays(Carbon::parse($r->delivered_at)) < $limit[1] ? 1 : 0;
                    }
                });

            return [$ok, $n];
        });

        return [
            'open' => $rows->count(),
            'late' => $rows->where('status', 'late')->count(),
            'warn' => $rows->where('status', 'warn')->count(),
            'tomorrow' => $rows->where('tomorrow', true)->count(),
            'onTime' => $count ? (int) round($onTime / $count * 100) : null,
            'oldest' => $rows->sortByDesc('total')->first(),
        ];
    }

    public const PHRASE = [
        'container' => 'still in the container', 'waiting' => 'waiting in the warehouse for a trip', 'transfer' => 'on a warehouse transfer',
        'hub' => 'waiting at the partner hub', 'truck' => 'on a truck, not delivered', 'failed' => 'waiting after a failed try',
    ];

    /** Plain reasons and next steps for late boxes (used when the AI is not available). */
    public static function reasons(Collection $rows): array
    {
        $action = [
            'container' => 'Unload the container', 'waiting' => 'Plan the trips (Plan trips)', 'transfer' => 'Check the transfer trip',
            'hub' => 'Plan hub trips', 'truck' => 'Call the driver of the trip', 'failed' => 'Text the receivers (Risky deliveries)',
        ];
        $items = $rows->where('stageStatus', 'late')
            ->groupBy(fn ($r) => $r['stage'].'|'.($r['stage'] === 'waiting' ? ($r['container'] ?? '') : ($r['where'] ?? '')))
            ->sortByDesc(fn ($g) => $g->count())->take(3)
            ->map(function ($g) use ($action) {
                $r = $g->first();
                $limit = static::limitFor($r['stage'], $r['region']);
                $ref = $r['stage'] === 'waiting' ? ($r['container'] ? 'container '.$r['container'] : null) : $r['where'];

                return [
                    't' => sprintf('%d %s %s%s for %d+ days.', $g->count(), Str::plural('box', $g->count()), self::PHRASE[$r['stage']], $ref ? ' ('.$ref.')' : '', $limit[1]),
                    'act' => $action[$r['stage']],
                ];
            })->values()->all();

        $totalOnly = $rows->where('status', 'late')->where('stageStatus', '!=', 'late');
        if ($totalOnly->isNotEmpty() && count($items) < 4) {
            $items[] = [
                't' => sprintf('%d %s on time at the current stage but past the total limit since unload (oldest %d days).', $totalOnly->count(), Str::plural('box', $totalOnly->count()), $totalOnly->max('total')),
                'act' => 'Deliver these first',
            ];
        }

        return $items;
    }
}
