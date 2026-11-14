<?php

namespace App\Support\Tracking;

use App\Models\Tracking\TruckAlert;
use App\Models\Tracking\TruckPosition;
use App\Support\Ai\Ai;
use App\Support\Maps\TripSorter;
use Illuminate\Support\Str;
use Throwable;

/** AI note on a truck alert: what probably happened, how worried to be, and what to do. */
class AlertExplainer
{
    public static function explain(TruckAlert $alert): void
    {
        if (! Ai::enabled('alert_explain') || $alert->ai_note) {
            return;
        }
        $trip = $alert->trip;
        $truck = $alert->truck;
        $ctx = [
            'alert' => ['kind' => $alert->kind, 'title' => $alert->title, 'text' => $alert->text, 'time' => $alert->started_at->format('D g:i A')],
            'truck' => $truck?->plate_no,
        ];
        if ($trip) {
            $boxes = TripSorter::boxes($trip);
            $left = Tracker::stopsLeft($trip);
            $ctx['trip'] = ['delivered' => (clone $boxes)->where('is_delivered', true)->count(), 'total' => (clone $boxes)->count(),
                'stops_left' => $left->count(), 'next_stop' => $left->first()?->only(['stop_no', 'name', 'barangay', 'city'])];
            if ($alert->lat !== null && ($next = $left->first(fn ($s) => $s->hasPin()))) {
                $ctx['trip']['km_to_next_stop'] = round(Tracker::km([$alert->lat, $alert->lng], [$next->lat, $next->lng]), 1);
            }
            if ($alert->lat !== null) {
                $ctx['near'] = Tracker::nearPlace($trip, $alert->lat, $alert->lng);
            }
        }
        if ($alert->lat !== null) {
            $ctx['same_place_before'] = TruckAlert::where('truck_id', $alert->truck_id)->where('id', '!=', $alert->id)
                ->where('started_at', '>=', now()->subDays(21))->whereNotNull('lat')->get()
                ->filter(fn ($a) => Tracker::km([$a->lat, $a->lng], [$alert->lat, $alert->lng]) < 0.4)
                ->map(fn ($a) => $a->started_at->format('D M j g:i A').' · '.$a->title.($a->note ? ' · office note: '.$a->note : ''))->values()->take(6)->all();
        }
        $gap = TruckPosition::where('truck_id', $alert->truck_id)->where('recorded_at', '<=', $alert->started_at)->latest('recorded_at')->value('source');
        $ctx['location_from'] = $gap ?: 'app';

        try {
            $out = Ai::json('alert_explain',
                'You help the office of a delivery company in the Philippines understand an alert about one of its trucks. '
                .'Say in one or two short, plain sentences what probably happened, using only the facts given (time of day, place, past alerts, trip progress). '
                .'Say "probably" when you are guessing. Then rate the concern low, medium or high, and suggest up to 3 short actions (2–5 words each). '
                .'Answer as {"note":"...","level":"low|medium|high","actions":["..."]}',
                json_encode($ctx, JSON_UNESCAPED_UNICODE), 'fast', 400);
            $level = in_array($out['level'] ?? '', ['low', 'medium', 'high'], true) ? $out['level'] : null;
            $alert->update([
                'ai_note' => Str::limit(Str::squish((string) ($out['note'] ?? '')), 480, '') ?: null,
                'ai_level' => $level,
                'ai_actions' => collect($out['actions'] ?? [])->map(fn ($a) => Str::limit(Str::squish((string) $a), 40, ''))->filter()->take(3)->values()->all(),
            ]);
        } catch (Throwable $e) {
            report($e);
        }
    }
}
