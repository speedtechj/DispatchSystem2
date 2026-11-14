<?php

namespace App\Support\Maps;

use App\Models\Deliverylog;
use App\Models\Maps\TripStop;
use App\Models\Tripinvoice;

/**
 * Loading the truck in the right order: last stops first (FRONT, next to the cab),
 * the first stops last (BACK, at the door). Used by Load truck in the Scan app
 * and the scan pages.
 */
class LoadOrder
{
    /**
     * What to load next: the stop with the highest number that still has boxes to load.
     *
     * @return array{stop: int, zone: string, name: string, place: string, boxes: list<string>, total: int, stops: list<array{no: int, zone: string, done: bool, now: bool}>}|null
     */
    public static function next(Deliverylog $trip, bool $atHub = false): ?array
    {
        $route = TripSorter::ensure($trip);
        if (! $route) {
            return null;
        }
        $stops = TripSorter::stops($trip);
        if ($stops->count() < 2) {
            return null;
        }
        $loaded = static::loaded($trip, $atHub);
        $open = $stops->filter(fn (TripStop $s) => collect($s->box_ids)->contains(fn ($id) => ! ($loaded[$id] ?? true)));
        $now = $open->sortByDesc('stop_no')->first();

        return [
            'stop' => $now?->stop_no ?? 0,
            'zone' => $now?->zone ?? '',
            'name' => (string) $now?->name,
            'place' => trim(($now?->barangay ? $now->barangay.', ' : '').$now?->city, ', '),
            'boxes' => $now ? Tripinvoice::whereIn('id', $now->box_ids)->where($atHub ? 'is_loaded_hub' : 'is_loaded', false)->pluck('invoice')->all() : [],
            'total' => $stops->count(),
            'stops' => $stops->sortByDesc('stop_no')->map(fn (TripStop $s) => [
                'no' => $s->stop_no, 'zone' => $s->zone, 'done' => ! $open->contains('id', $s->id), 'now' => $now && $s->id === $now->id,
            ])->values()->all(),
        ];
    }

    /**
     * Null when the box may go in now; otherwise why it is too early
     * (its spot is nearer the door than the stop being loaded now).
     *
     * @return array{code: string, stop: int, zone: string, name: string, place: string, nextStop: int, nextZone: string}|null
     */
    public static function tooEarly(Deliverylog $trip, Tripinvoice $box, bool $atHub = false): ?array
    {
        if (! MapSettings::warnEarly()) {
            return null;
        }
        $next = static::next($trip, $atHub);
        if (! $next || ! $next['stop']) {
            return null;
        }
        $mine = TripSorter::zoneMap($trip)[$box->id] ?? null;
        if (! $mine || (TripStop::RANK[$mine['zone']] ?? 1) <= (TripStop::RANK[$next['zone']] ?? 1)) {
            return null;
        }
        $stop = TripStop::where('deliverylog_id', $trip->id)->where('stop_no', $mine['stop'])->first();

        return [
            'code' => (string) $box->invoice, 'stop' => $mine['stop'], 'zone' => $mine['zone'],
            'name' => (string) $stop?->name, 'place' => (string) ($stop?->barangay ?: $stop?->city),
            'nextStop' => $next['stop'], 'nextZone' => $next['zone'],
        ];
    }

    /** tripinvoice id => loaded? */
    protected static function loaded(Deliverylog $trip, bool $atHub): array
    {
        return TripSorter::boxes($trip)->pluck($atHub ? 'is_loaded_hub' : 'is_loaded', 'id')->map(fn ($v) => (bool) $v)->all();
    }
}
