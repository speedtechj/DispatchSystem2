<?php

namespace App\Support\Tracking;

use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Maps\TripStop;
use App\Models\Tracking\TruckAlert;
use App\Models\Tracking\TruckPosition;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Support\Maps\MapSettings;
use App\Support\Maps\RoutePlanner;
use App\Support\Maps\TripSorter;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Str;

/**
 * Truck tracking: where each truck on a trip is, what it is doing, and what it did.
 * Locations come only during trips (Driver app or GPS tracker).
 */
class Tracker
{
    /** null = every hub, int = only this hub, false = nothing. */
    public static function hubFor(?User $user, ?string $panel): int|false|null
    {
        if (! $user) {
            return false;
        }
        if ($panel === 'admin' && ($user->hasRole('super_admin') || $user->is_admin)) {
            return null;
        }

        return $user->logistichub_id ? (int) $user->logistichub_id : false;
    }

    public static function canSeeTruck(int|false|null $hub, Truck $truck): bool
    {
        return $hub === null || ($hub !== false && (int) $truck->logistichub_id === $hub);
    }

    public static function km(array $a, array $b): float
    {
        return RoutePlanner::km($a, $b);
    }

    /** Trips on the road now (active, with a truck), newest first. */
    public static function activeTrips(int|false|null $hub): Collection
    {
        if ($hub === false) {
            return collect();
        }

        return Deliverylog::with('truck')->where('is_active', true)->whereNotNull('truck_id')
            ->when($hub, fn ($q) => $q->where('logistichub_id', $hub))
            ->latest('id')->get()->unique('truck_id')->values();
    }

    /** @return array{driver: ?User, helpers: Collection} */
    public static function crew(int $truckId): array
    {
        $users = User::with('workposition', 'panelcategory')->whereIn('id', Truckcrew::where('truck_id', $truckId)->pluck('crew'))->get();
        $driver = $users->first(fn ($u) => Str::contains(Str::lower((string) $u->workposition?->position_description), 'driver'))
            ?? $users->first(fn ($u) => $u->panelcategory?->code === 'drv') ?? $users->first();

        return ['driver' => $driver, 'helpers' => $users->reject(fn ($u) => $u->is($driver))->values()];
    }

    /**
     * What the truck is doing now.
     *
     * @return array{kind: string, label: string, lat: ?float, lng: ?float, speed: ?float, seen: ?Carbon, stoppedMin: int, atStop: ?int}
     */
    public static function now(Truck $truck, ?Deliverylog $trip = null): array
    {
        $pos = TruckPosition::where('truck_id', $truck->id)->where('recorded_at', '>=', now()->subHours(12))
            ->orderByDesc('recorded_at')->limit(400)->get();
        $last = $pos->first();
        if (! $last) {
            return ['kind' => 'bad', 'label' => 'Waiting for location', 'lat' => null, 'lng' => null, 'speed' => null, 'seen' => null, 'stoppedMin' => 0, 'atStop' => null];
        }
        $age = (int) $last->recorded_at->diffInMinutes(now());
        $base = ['lat' => $last->lat, 'lng' => $last->lng, 'seen' => $last->recorded_at];

        // how long it has been standing within 150 m of where it is now
        $since = $last->recorded_at;
        foreach ($pos as $p) {
            if (static::km([$last->lat, $last->lng], [$p->lat, $p->lng]) > 0.15) {
                break;
            }
            $since = $p->recorded_at;
        }
        $stopped = (int) $since->diffInMinutes($last->recorded_at) + $age;
        $speed = $last->speed;
        if ($speed === null && ($prev = $pos->get(1))) {
            $h = max(1, $prev->recorded_at->diffInSeconds($last->recorded_at)) / 3600;
            $speed = round(static::km([$prev->lat, $prev->lng], [$last->lat, $last->lng]) / $h, 1);
        }
        $atStop = $trip ? static::stopNear($trip, $last->lat, $last->lng) : null;

        if ($age >= TrackSettings::int('no_signal')) {
            return $base + ['kind' => 'bad', 'label' => 'No signal '.static::dur($age), 'speed' => null, 'stoppedMin' => $stopped, 'atStop' => $atStop];
        }
        if ($stopped >= 3 && ($speed ?? 0) < 5) {
            if ($atStop) {
                return $base + ['kind' => 'ok', 'label' => "At stop {$atStop} · ".static::dur($stopped), 'speed' => 0.0, 'stoppedMin' => $stopped, 'atStop' => $atStop];
            }

            return $base + ['kind' => $stopped >= TrackSettings::int('stopped') ? 'warn' : 'ok', 'label' => 'Stopped '.static::dur($stopped), 'speed' => 0.0, 'stoppedMin' => $stopped, 'atStop' => null];
        }

        return $base + ['kind' => 'ok', 'label' => 'Moving'.($speed ? ' · '.round($speed).' km/h' : ''), 'speed' => $speed, 'stoppedMin' => 0, 'atStop' => $atStop];
    }

    public static function dur(int $min): string
    {
        return $min >= 60 ? intdiv($min, 60).' h '.($min % 60).' min' : $min.' min';
    }

    /** The stop number within 150 m of this spot, if any. */
    public static function stopNear(Deliverylog $trip, float $lat, float $lng): ?int
    {
        foreach (TripSorter::stops($trip) as $s) {
            if ($s->hasPin() && static::km([$lat, $lng], [$s->lat, $s->lng]) <= 0.15) {
                return $s->stop_no;
            }
        }

        return null;
    }

    /** Stops with boxes still to deliver, in order. */
    public static function stopsLeft(Deliverylog $trip): Collection
    {
        $done = TripSorter::boxes($trip)->where('is_delivered', true)->pluck('id')->flip();

        return TripSorter::stops($trip)->filter(fn (TripStop $s) => collect($s->box_ids)->contains(fn ($id) => ! isset($done[$id])))->values();
    }

    /** One row of the tracking page. */
    public static function card(Deliverylog $trip): array
    {
        $truck = $trip->truck;
        TripSorter::ensure($trip, 0);
        $now = static::now($truck, $trip);
        $crew = static::crew($truck->id);
        $boxes = TripSorter::boxes($trip);
        $total = (clone $boxes)->count();
        $delivered = (clone $boxes)->where('is_delivered', true)->count();
        $left = static::stopsLeft($trip);
        $next = $left->first();
        $nextKm = $next?->hasPin() && $now['lat'] !== null ? round(static::km([$now['lat'], $now['lng']], [$next->lat, $next->lng]) * 1.3, 1) : null;
        $near = $now['lat'] !== null ? static::nearPlace($trip, $now['lat'], $now['lng']) : null;
        $alert = TruckAlert::where('truck_id', $truck->id)->whereNull('ended_at')->latest('started_at')->first();

        return [
            'id' => $truck->id, 'trip_id' => $trip->id, 'plate' => (string) $truck->plate_no, 'trip' => (string) $trip->trip_number,
            'kind' => $now['kind'], 'state' => $now['label'], 'lat' => $now['lat'], 'lng' => $now['lng'],
            'seen' => $now['seen'] ? ($now['seen']->diffInSeconds(now()) < 45 ? 'just now' : $now['seen']->diffForHumans()) : 'never',
            'speed' => $now['speed'] !== null ? round($now['speed']).' km/h' : '—',
            'driver' => $crew['driver']?->full_name ?? '—', 'phone' => $crew['driver']?->mobile_number ?? null,
            'helpers' => $crew['helpers']->pluck('full_name')->join(', '),
            'delivered' => $delivered, 'total' => $total,
            'next' => $next ? 'Stop '.$next->stop_no.' · '.$next->name.($nextKm !== null ? ', '.$nextKm.' km · ~'.max(1, (int) round($nextKm / 25 * 60)).' min' : '') : ($total && $delivered === $total ? 'All delivered · back to the warehouse' : '—'),
            'near' => $near,
            'alert' => $alert ? $alert->title.($alert->text ? '. '.$alert->text : '') : null,
            'source' => TrackSettings::SOURCES[TrackSettings::source($truck->id)][0],
        ];
    }

    /** "Tipolo, Mandaue City" from the nearest stop, so no map key is needed. */
    public static function nearPlace(Deliverylog $trip, float $lat, float $lng): ?string
    {
        $best = null;
        $bestKm = INF;
        foreach (TripSorter::stops($trip) as $s) {
            if ($s->hasPin() && ($d = static::km([$lat, $lng], [$s->lat, $s->lng])) < $bestKm) {
                [$best, $bestKm] = [$s, $d];
            }
        }

        return $best && $bestKm < 5 ? trim(($best->barangay ? $best->barangay.', ' : '').$best->city, ', ').($bestKm > 0.3 ? ' area' : '') : null;
    }

    /** The positions of a trip, thinned for the map. @return list<array{0: float, 1: float, 2: string}> */
    public static function path(int $truckId, ?int $tripId = null, ?Carbon $day = null, int $max = 1500): array
    {
        $q = TruckPosition::where('truck_id', $truckId)->orderBy('recorded_at');
        $tripId ? $q->where('deliverylog_id', $tripId) : $q->whereBetween('recorded_at', [($day ?? today())->copy()->startOfDay(), ($day ?? today())->copy()->endOfDay()]);
        $rows = $q->get(['lat', 'lng', 'recorded_at']);
        $step = max(1, (int) ceil($rows->count() / $max));

        return $rows->values()->filter(fn ($r, $i) => $i % $step === 0 || $i === $rows->count() - 1)
            ->map(fn ($r) => [$r->lat, $r->lng, $r->recorded_at->format('g:i A')])->values()->all();
    }

    /** km, moving and stopped time from a list of positions. */
    public static function stats(Collection $pos): array
    {
        $km = 0.0;
        $moving = 0;
        $prev = null;
        foreach ($pos as $p) {
            if ($prev) {
                $d = static::km([$prev->lat, $prev->lng], [$p->lat, $p->lng]);
                $sec = max(1, $prev->recorded_at->diffInSeconds($p->recorded_at));
                if ($d < 3 && ($p->accuracy ?? 0) <= 150) {
                    $km += $d;
                    if ($sec <= 600 && $d / ($sec / 3600) >= 5) {
                        $moving += $sec;
                    }
                }
            }
            $prev = $p;
        }
        $span = $pos->count() > 1 ? $pos->first()->recorded_at->diffInSeconds($pos->last()->recorded_at) : 0;

        return ['km' => round($km, 1), 'moving' => (int) round($moving / 60), 'span' => (int) round($span / 60), 'stopped' => (int) round(max(0, $span - $moving) / 60)];
    }

    /** The "Today" tab of one truck. */
    public static function day(Truck $truck, ?Deliverylog $trip): array
    {
        $pos = TruckPosition::where('truck_id', $truck->id)->whereDate('recorded_at', today())->orderBy('recorded_at')->get();
        $st = static::stats($pos);
        $alertMin = TruckAlert::where('truck_id', $truck->id)->where('kind', 'stopped')->whereDate('started_at', today())->get()->sum(fn ($a) => $a->minutes());
        $stops = $trip ? TripSorter::stops($trip) : collect();
        $left = $trip ? static::stopsLeft($trip) : collect();
        $done = $stops->count() - $left->count();
        $deliveredAt = $trip ? TripSorter::boxes($trip)->where('is_delivered', true)->whereNotNull('delivered_at')->pluck('delivered_at')->map(fn ($d) => Carbon::parse($d)) : collect();
        $first = $pos->first()?->recorded_at;
        $perStop = $done && $first && $deliveredAt->isNotEmpty() ? max(1, (int) round($first->diffInMinutes($deliveredAt->max()) / $done)) : null;
        $back = $perStop && $left->isNotEmpty() ? now()->addMinutes($perStop * $left->count() + 20)->format('g:i A') : null;

        return [
            ['Driven today', $st['km'].' km', $first ? 'since '.$first->format('g:i A') : 'no location yet'],
            ['Driving', static::dur($st['moving']), 'moving time'],
            ['Stopped', static::dur($st['stopped']), $alertMin ? static::dur($alertMin).' not at a stop' : 'at stops and lights'],
            ['Stops done', $done.' of '.$stops->count(), ($trip ? TripSorter::boxes($trip)->where('is_delivered', true)->count() : 0).' boxes delivered'],
            ['Per stop', $perStop ? $perStop.' min' : '—', 'average'],
            ['Back at WH', $back ?? '—', $back ? 'estimate' : ($left->isEmpty() && $stops->isNotEmpty() ? 'all stops done' : '')],
        ];
    }

    /** Today, step by step. @return list<array{t: string, at: Carbon, text: string, kind: string}> */
    public static function events(Truck $truck, ?Deliverylog $trip): array
    {
        $ev = [];
        $pos = TruckPosition::where('truck_id', $truck->id)->whereDate('recorded_at', today())->orderBy('recorded_at')->get(['recorded_at']);
        if ($first = $pos->first()) {
            $start = $trip ? MapSettings::startFor($trip->user?->warehouse_id, $trip->logistichub_id) : null;
            $ev[] = [$first->recorded_at, 'Left '.($start['name'] ?? 'the warehouse').($trip ? ' · '.TripSorter::boxes($trip)->count().' boxes loaded' : ''), 'start'];
        }
        $prev = null;
        foreach ($pos as $p) {
            if ($prev && ($gap = (int) $prev->recorded_at->diffInMinutes($p->recorded_at)) >= 10) {
                $ev[] = [$prev->recorded_at, "No location for {$gap} min", 'gap'];
            }
            $prev = $p;
        }
        if ($trip) {
            $map = TripSorter::zoneMap($trip);
            $stops = TripSorter::stops($trip)->keyBy('stop_no');
            TripSorter::boxes($trip)->where('is_delivered', true)->whereNotNull('delivered_at')->get(['id', 'delivered_at'])
                ->groupBy(fn ($b) => $map[$b->id]['stop'] ?? 0)
                ->each(function ($g, $no) use (&$ev, $stops) {
                    $s = $stops[$no] ?? null;
                    $ev[] = [Carbon::parse($g->min('delivered_at')), 'Delivered '.($s ? 'stop '.$no.' · '.$s->name : 'a box').' ('.$g->count().' '.str('box')->plural($g->count()).')', 'ok'];
                });
            DeliveryAttempt::with('invoice')->whereIn('invoice_id', TripSorter::boxes($trip)->pluck('invoice_id'))->whereDate('created_at', today())->get()
                ->each(function ($a) use (&$ev) {
                    $ev[] = [$a->created_at, 'Not delivered: '.Str::title((string) $a->invoice?->receiver_name).($a->reason ? ' · '.Str::lower($a->reason->getLabel()) : ''), 'bad'];
                });
        }
        TruckAlert::where('truck_id', $truck->id)->whereDate('started_at', today())->get()
            ->each(function (TruckAlert $a) use (&$ev) {
                $ev[] = [$a->started_at, $a->title.($a->text ? ' · '.$a->text : '').' · alert sent', 'warn'];
            });
        if ($trip && ($next = static::stopsLeft($trip)->first()) && $pos->isNotEmpty()) {
            $ev[] = [now(), 'On the way to stop '.$next->stop_no.' · '.$next->name, 'now'];
        }
        usort($ev, fn ($a, $b) => $a[0] <=> $b[0]);

        return array_map(fn ($e) => ['t' => $e[0]->format('g:i'), 'text' => $e[1], 'kind' => $e[2]], $ev);
    }

    /** Trips of a truck (last 30 days) for "Trip history". */
    public static function history(Truck $truck, int $days = 30): Collection
    {
        return Deliverylog::where('truck_id', $truck->id)->where('created_at', '>=', now()->subDays($days))->latest('id')->limit(60)->get()
            ->map(function (Deliverylog $t) {
                $pos = TruckPosition::where('deliverylog_id', $t->id)->orderBy('recorded_at')->get();
                $st = static::stats($pos);
                $boxes = TripSorter::boxes($t);
                $total = (clone $boxes)->count();
                $del = (clone $boxes)->where('is_delivered', true)->count();
                $driverId = (clone $boxes)->whereNotNull('delivered_by')->groupBy('delivered_by')->orderByRaw('count(*) desc')->value('delivered_by');
                $tries = DeliveryAttempt::whereIn('invoice_id', (clone $boxes)->pluck('invoice_id'))->count();
                $alerts = TruckAlert::where('deliverylog_id', $t->id)->count();

                return [
                    'id' => $t->id, 'date' => ($t->departure_date ?? $t->created_at)?->format('M j'), 'today' => $t->is_active,
                    'trip' => (string) $t->trip_number, 'driver' => $driverId ? (User::find($driverId)?->full_name ?? '—') : '—',
                    'km' => $pos->isNotEmpty() ? $st['km'] : null, 'hours' => $pos->isNotEmpty() ? static::dur($st['span']) : '—',
                    'delivered' => $del, 'total' => $total, 'points' => $pos->count(),
                    'note' => collect([$tries ? $tries.' not delivered' : null, $alerts ? $alerts.' '.str('alert')->plural($alerts) : null, $t->is_active ? 'on the road' : null])->filter()->join(' · '),
                    'firstTry' => $del - min($del, $tries),
                ];
            });
    }
}
