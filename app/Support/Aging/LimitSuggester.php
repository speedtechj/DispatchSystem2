<?php

namespace App\Support\Aging;

use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Tripinvoice;
use App\Models\Whtripinvoice;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Suggests aging limits from your own history: warning = slower than 3 out of 4 boxes,
 * late = slower than 9 out of 10. Far regions get their own total limit.
 */
class LimitSuggester
{
    public const MIN_SAMPLES = 20;

    public const MONTHS = 6;

    /** @return list<array{stage: string, region: string, warn: int, late: int, usual: string, n: int, reason: string}> */
    public static function suggest(bool $withAi = true): array
    {
        BoxAging::roomToWork();
        $from = now()->subMonths(self::MONTHS);
        $d = fn ($a, $b) => ($a && $b) ? max(0, Carbon::parse($a)->diffInHours(Carbon::parse($b)) / 24) : null;
        $out = [];

        // in container: made → unloaded
        $out[] = static::row('container', 'all', Container::whereNotNull('unloaded_at')->where('unloaded_at', '>=', $from)->get()
            ->map(fn ($c) => $d($c->created_at, $c->unloaded_at)));

        // delivered boxes with their container and trips (plain rows, not models: there can be many)
        $delivered = DB::table('tripinvoices as t')
            ->join('invoices as i', 'i.id', '=', 't.invoice_id')->join('containers as c', 'c.id', '=', 'i.container_id')
            ->join('deliverylogs as d', 'd.id', '=', 't.deliverylog_id')->leftJoin('deliverylogs as hd', 'hd.id', '=', 't.deliveryloghub_id')
            ->where('t.is_delivered', true)->where('t.delivered_at', '>=', $from)->limit(60000)
            ->get(['t.invoice_id', 't.delivered_at', 'c.unloaded_at', 'i.receiver_province as prov', 'i.receiver_city as city',
                'd.departure_date as dep', 'hd.created_at as hub_made', 'hd.departure_date as hub_dep', 't.deliveryloghub_id as hub_trip'])
            ->map(function ($r) {
                $r->region = Regions::of($r->prov, $r->city);

                return $r;
            });
        $ids = $delivered->pluck('invoice_id')->unique()->values();
        $firstTrip = collect();
        $lastTry = collect();
        foreach ($ids->chunk(5000) as $part) {
            $firstTrip = $firstTrip->union(Tripinvoice::whereIn('invoice_id', $part)->selectRaw('invoice_id, min(created_at) as at')->groupBy('invoice_id')->pluck('at', 'invoice_id'));
            $lastTry = $lastTry->union(DeliveryAttempt::whereIn('invoice_id', $part)->selectRaw('invoice_id, max(created_at) as at')->groupBy('invoice_id')->pluck('at', 'invoice_id'));
        }

        // waiting for a trip: unloaded → first put on a trip (Mindanao on its own)
        $waits = $delivered->map(fn ($t) => ['r' => $t->region, 'd' => $d($t->unloaded_at, $firstTrip[$t->invoice_id] ?? null)])->filter(fn ($x) => $x['d'] !== null);
        $out[] = static::row('waiting', 'all', $waits->where('r', '!=', 'mindanao')->pluck('d'));
        $out[] = static::row('waiting', 'mindanao', $waits->where('r', 'mindanao')->pluck('d'));

        // warehouse transfer: put on → unloaded
        $out[] = static::row('transfer', 'all', Whtripinvoice::where('is_unloaded', true)->where('updated_at', '>=', $from)->limit(60000)->get(['created_at', 'updated_at'])
            ->map(fn ($w) => $d($w->created_at, $w->updated_at)));

        // at partner hub: handed to the hub → put on the hub's own trip
        $out[] = static::row('hub', 'all', $delivered->filter(fn ($t) => $t->hub_trip)->map(fn ($t) => $d($t->dep, $t->hub_made)));

        // on a truck: trip left → delivered
        $out[] = static::row('truck', 'all', $delivered->map(fn ($t) => $d($t->hub_trip ? $t->hub_dep : $t->dep, $t->delivered_at)));

        // tried and failed: last failed try → delivered
        $out[] = static::row('failed', 'all', $delivered->filter(fn ($t) => isset($lastTry[$t->invoice_id]))->map(fn ($t) => $d($lastTry[$t->invoice_id], $t->delivered_at)));

        // total per region: unloaded → delivered
        foreach (array_keys(Regions::LABELS) as $region) {
            $out[] = static::row('total', $region, $delivered->where('region', $region)->map(fn ($t) => $d($t->unloaded_at, $t->delivered_at)));
        }

        if ($withAi && Ai::enabled('aging')) {
            try {
                $notes = Ai::json('aging',
                    'You explain delivery time limits to the manager of a Philippine balikbayan box cargo company, in plain short English. '
                    .'For each row, write one sentence (max 20 words) explaining the suggested warning and late days from the numbers. '
                    .'Return {"reasons": ["...", ...]} in the same order. Do not change any number.',
                    json_encode(array_map(fn ($r) => array_intersect_key($r, array_flip(['stage', 'region', 'warn', 'late', 'usual', 'n'])), $out)), 'fast', 900);
                foreach ($out as $i => &$r) {
                    if (! empty($notes['reasons'][$i]) && $r['n'] >= self::MIN_SAMPLES) {
                        $r['reason'] = (string) $notes['reasons'][$i];
                    }
                }
            } catch (AiUnavailable) {
                // keep the plain reasons
            }
        }

        return $out;
    }

    protected static function row(string $stage, string $region, Collection $values): array
    {
        $v = $values->filter(fn ($x) => $x !== null)->map(fn ($x) => (float) $x)->sort()->values();
        $default = BoxAging::DEFAULTS[$stage][$region] ?? BoxAging::DEFAULTS[$stage]['all'] ?? [5, 10];
        if ($v->count() < self::MIN_SAMPLES) {
            return ['stage' => $stage, 'region' => $region, 'warn' => $default[0], 'late' => $default[1], 'usual' => '—', 'n' => $v->count(),
                'reason' => 'Not enough history yet ('.$v->count().' '.($stage === 'container' ? Str::plural('container', $v->count()) : Str::plural('box', $v->count())).'), so the standard limit is used.'];
        }
        $p = fn (float $q) => $v[(int) min($v->count() - 1, floor($q * ($v->count() - 1)))];
        $warn = max(1, (int) ceil($p(0.75)));
        $late = max($warn + 1, (int) ceil($p(0.9)));
        $mid = (int) round($p(0.5));
        $usual = $mid === (int) ceil($p(0.75)) ? $mid.' '.($mid === 1 ? 'day' : 'days') : $mid.'–'.(int) ceil($p(0.75)).' days';

        return ['stage' => $stage, 'region' => $region, 'warn' => $warn, 'late' => $late, 'usual' => $usual, 'n' => $v->count(),
            'reason' => "3 out of 4 boxes take {$warn} days or less; 9 out of 10 take {$late} or less ({$v->count()} boxes)."];
    }
}
