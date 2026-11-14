<?php

namespace App\Support\Ai;

use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\User;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;

/** Insights: boxes expected in the next weeks, and a weekly report per partner hub. Numbers are counted; the AI writes the words. */
class Insights
{
    public const WEEKS_AHEAD = 8;

    /**
     * Boxes per week (by container unload date): the last 8 weeks, and a forecast for the next 8
     * from the same weeks last year, scaled by how this year compares.
     *
     * @return array{past: list<array{label: string, n: int}>, next: list<array{label: string, n: int, last_year: int}>, growth: float, has_history: bool}
     */
    public static function forecast(?int $warehouseId = null): array
    {
        $weekOf = fn (Carbon $d) => $d->copy()->startOfWeek();
        $count = function (Carbon $from, Carbon $to) use ($warehouseId): int {
            return Invoice::whereIn('container_id', Container::whereBetween('unloaded_at', [$from, $to])
                ->when($warehouseId, fn ($q) => $q->where('warehouse_id', $warehouseId))->select('id'))->count();
        };

        $thisWeek = $weekOf(now());
        $past = [];
        $sumNow = $sumLast = 0;
        for ($i = 8; $i >= 1; $i--) {
            $from = $thisWeek->copy()->subWeeks($i);
            $n = $count($from, $from->copy()->endOfWeek());
            $ly = $count($from->copy()->subYear(), $from->copy()->subYear()->endOfWeek());
            $sumNow += $n;
            $sumLast += $ly;
            $past[] = ['label' => $from->format('M j'), 'n' => $n];
        }
        $growth = $sumLast > 0 ? $sumNow / $sumLast : 1.0;
        $avg = (int) round($sumNow / 8);

        $next = [];
        $hasHistory = $sumLast > 0;
        for ($i = 0; $i < self::WEEKS_AHEAD; $i++) {
            $from = $thisWeek->copy()->addWeeks($i);
            $ly = $count($from->copy()->subYear(), $from->copy()->subYear()->endOfWeek());
            $next[] = ['label' => $from->format('M j'), 'n' => $hasHistory ? (int) round($ly * $growth) : $avg, 'last_year' => $ly];
        }

        return ['past' => $past, 'next' => $next, 'growth' => round($growth, 2), 'has_history' => $hasHistory];
    }

    /** Advice in a few sentences from the forecast numbers (cached for a day). */
    public static function forecastAdvice(?int $warehouseId = null, bool $fresh = false): string
    {
        $key = 'ai.insights.forecast.'.($warehouseId ?? 'all').'.'.now()->toDateString();
        if ($fresh) {
            Cache::forget($key);
        }

        return Cache::remember($key, now()->addDay(), function () use ($warehouseId) {
            $f = static::forecast($warehouseId);
            $staff = User::whereNotNull('warehouse_id')->where('is_active', true)->when($warehouseId, fn ($q) => $q->where('warehouse_id', $warehouseId))->count();

            return Ai::text('insights',
                'You advise the operations manager of a Philippine balikbayan box cargo company. Write 2 to 4 short sentences, plain English, no headings. '
                .'Say when the busy weeks are and by how much boxes go up or down compared with the last weeks, and suggest practical steps (extra loaders, trucks, drivers, overtime). '
                .'If there is no history from last year, say the forecast is just the recent average. Do not invent numbers that are not given.',
                'Last 8 weeks (boxes per week): '.json_encode($f['past'])."\nNext 8 weeks forecast: ".json_encode($f['next'])
                ."\nThis year vs last year ratio: {$f['growth']}\nHas last-year history: ".($f['has_history'] ? 'yes' : 'no')
                ."\nActive warehouse staff accounts: {$staff}",
                'smart', 400);
        });
    }

    /** The numbers behind a hub's weekly report. */
    public static function hubStats(Logistichub $hub, ?Carbon $weekStart = null): array
    {
        $from = ($weekStart ?? now()->subWeek()->startOfWeek())->copy();
        $to = $from->copy()->endOfWeek();
        $delivered = Tripinvoice::where('logistichub_id', $hub->id)->where('is_delivered', true)->whereBetween('delivered_at', [$from, $to])->get();
        $attempts = DeliveryAttempt::whereBetween('created_at', [$from, $to])
            ->whereIn('tripinvoice_id', Tripinvoice::where('logistichub_id', $hub->id)->select('id'))->with(['user', 'invoice'])->get();
        $waiting = Tripinvoice::where('logistichub_id', $hub->id)->where('is_delivered', false)
            ->where('created_at', '<=', now()->subDays(5))->count();

        $firstTry = $delivered->filter(fn ($t) => ! DeliveryAttempt::where('tripinvoice_id', $t->id)->exists())->count();

        return [
            'hub' => $hub->hub_name,
            'week' => $from->format('M j').' – '.$to->format('M j'),
            'delivered' => $delivered->count(),
            'delivered_first_try' => $firstTry,
            'failed_attempts' => $attempts->count(),
            'failed_by_reason' => $attempts->groupBy(fn ($a) => $a->reason?->getLabel() ?? 'Other')->map->count()->sortDesc(),
            'failed_by_barangay' => $attempts->groupBy(fn ($a) => Str::title((string) $a->invoice?->receiver_barangay))->map->count()->sortDesc()->take(3),
            'failed_by_driver' => $attempts->groupBy(fn ($a) => $a->user?->full_name ?? '—')->map->count()->sortDesc()->take(3),
            'delivered_by_driver' => $delivered->groupBy('delivered_by')->map->count()->sortDesc()->take(5)
                ->mapWithKeys(fn ($n, $id) => [User::find($id)?->full_name ?? '—' => $n]),
            'boxes_waiting_over_5_days' => $waiting,
        ];
    }

    public static function hubReport(Logistichub $hub, bool $fresh = false): string
    {
        $key = 'ai.insights.hub.'.$hub->id.'.'.now()->format('oW');
        if ($fresh) {
            Cache::forget($key);
        }

        return Cache::remember($key, now()->addDays(7), function () use ($hub) {
            $s = static::hubStats($hub);

            return Ai::text('insights',
                'You write a short weekly report (3 to 5 sentences, plain English, no headings, no bullet points) for a partner hub of a Philippine '
                .'balikbayan box delivery company. Say how many boxes were delivered and how many on the first try, the main reasons for failed deliveries, '
                .'where and with which driver problems happened, and one or two practical things to improve. Be fair and factual; only use the numbers given.',
                json_encode($s, JSON_UNESCAPED_UNICODE), 'smart', 400);
        });
    }
}
