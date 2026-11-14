<?php

namespace App\Support\Tracking;

use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Maps\TripStop;
use App\Models\Tracking\TruckAlert;
use App\Models\Tracking\TruckDaySummary;
use App\Models\Tracking\TruckPosition;
use App\Models\Truck;
use App\Support\Ai\Ai;
use App\Support\Maps\TripSorter;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;
use Throwable;

/** End of day: each truck's numbers and grade, and (with the AI) the day in short and a summary per truck. */
class DaySummary
{
    public static function get(Carbon $day, int|false|null $hub): ?TruckDaySummary
    {
        return $hub === false ? null : TruckDaySummary::whereDate('day', $day)->where('hub_id', (int) $hub)->first();
    }

    public static function build(Carbon $day, int|false|null $hub): ?TruckDaySummary
    {
        if ($hub === false) {
            return null;
        }
        $trips = Deliverylog::with('truck')->whereNotNull('truck_id')
            ->when($hub, fn ($q) => $q->where('logistichub_id', $hub))
            ->where(fn ($q) => $q->whereDate('departure_date', $day)
                ->orWhereIn('id', TruckPosition::whereBetween('recorded_at', [$day->copy()->startOfDay(), $day->copy()->endOfDay()])->distinct()->select('deliverylog_id')))
            ->get()->groupBy('truck_id');

        $trucks = [];
        foreach ($trips as $truckId => $list) {
            $truck = $list->first()->truck;
            $pos = TruckPosition::where('truck_id', $truckId)->whereBetween('recorded_at', [$day->copy()->startOfDay(), $day->copy()->endOfDay()])->orderBy('recorded_at')->get();
            $st = Tracker::stats($pos);
            $total = $delivered = $failed = $stops = 0;
            foreach ($list as $t) {
                $b = TripSorter::boxes($t);
                $total += (clone $b)->count();
                $delivered += (clone $b)->where('is_delivered', true)->count();
                $failed += DeliveryAttempt::where('deliverylog_id', $t->id)->whereDate('created_at', $day)->count();
                $stops += TripStop::where('deliverylog_id', $t->id)->count();
            }
            $alerts = TruckAlert::where('truck_id', $truckId)->whereDate('started_at', $day)->get();
            $serious = $alerts->filter(fn ($a) => $a->ai_level === 'high' || in_array($a->kind, ['off_route', 'back_with_boxes'], true))->count();
            $pct = $total ? $delivered / $total : 0;
            $grade = $pct >= 0.98 && $serious === 0 && $alerts->count() <= 1 ? 'A' : ($pct >= 0.9 && $serious <= 1 ? 'B' : 'C');
            $driver = Tracker::crew((int) $truckId)['driver'];
            $trucks[] = [
                'truck_id' => (int) $truckId, 'plate' => (string) $truck?->plate_no, 'driver' => (string) ($driver?->full_name ?? '—'),
                'trips' => $list->pluck('trip_number')->join(', '),
                'km' => $st['km'], 'driving' => Tracker::dur($st['moving']), 'delivered' => $delivered, 'total' => $total, 'failed' => $failed,
                'per_stop' => $stops && $st['span'] ? max(1, (int) round($st['span'] / max(1, $stops))) : null,
                'started' => $pos->first()?->recorded_at?->format('g:i A'), 'back' => $pos->last()?->recorded_at?->format('g:i A'),
                'alerts' => $alerts->map(fn ($a) => $a->title.($a->note ? ' (office: '.$a->note.')' : ''))->values()->all(),
                'grade' => $grade,
                'summary' => null, 'good' => null, 'bad' => null,
            ];
        }
        usort($trucks, fn ($a, $b) => strcmp($a['grade'], $b['grade']) ?: $b['delivered'] <=> $a['delivered']);

        $day_text = null;
        if ($trucks && Ai::enabled('day_summary')) {
            try {
                $out = Ai::json('day_summary',
                    'You write the end-of-day report for the office of a delivery company in the Philippines. Use only the numbers given. '
                    .'Write "day": 2 or 3 plain sentences about the whole day (boxes delivered, best truck, the main problem, what is left for tomorrow). '
                    .'For each truck write "summary" (1–2 sentences), "good" (one short phrase) and "bad" (one short phrase, or "Nothing to look at"). '
                    .'Answer as {"day":"...","trucks":[{"plate":"...","summary":"...","good":"...","bad":"..."}]}',
                    json_encode(['day' => $day->format('D M j'), 'trucks' => array_map(fn ($t) => array_diff_key($t, ['truck_id' => 1, 'summary' => 1, 'good' => 1, 'bad' => 1]), $trucks)], JSON_UNESCAPED_UNICODE),
                    'smart', 2000);
                $day_text = Str::limit(Str::squish((string) ($out['day'] ?? '')), 900, '') ?: null;
                $by = collect($out['trucks'] ?? [])->keyBy(fn ($t) => (string) ($t['plate'] ?? ''));
                foreach ($trucks as &$t) {
                    if ($ai = $by[$t['plate']] ?? null) {
                        $t['summary'] = Str::limit(Str::squish((string) ($ai['summary'] ?? '')), 600, '');
                        $t['good'] = Str::limit(Str::squish((string) ($ai['good'] ?? '')), 160, '');
                        $t['bad'] = Str::limit(Str::squish((string) ($ai['bad'] ?? '')), 160, '');
                    }
                }
                unset($t);
            } catch (Throwable $e) {
                report($e);
            }
        }
        $all = array_sum(array_column($trucks, 'total'));
        $done = array_sum(array_column($trucks, 'delivered'));

        $row = TruckDaySummary::whereDate('day', $day)->where('hub_id', (int) $hub)->first() ?? new TruckDaySummary(['day' => $day->toDateString(), 'hub_id' => (int) $hub]);
        $row->fill(['data' => [
            'day' => $day_text,
            'plain' => $trucks ? count($trucks).' '.str('truck')->plural(count($trucks)).' delivered '.$done.' of '.$all.' boxes'.($all ? ' ('.round($done / $all * 100).'%)' : '').'.' : 'No truck was on a trip this day.',
            'trucks' => $trucks, 'made_at' => now()->toDateTimeString(),
        ]])->save();

        return $row;
    }
}
