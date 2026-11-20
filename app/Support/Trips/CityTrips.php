<?php

namespace App\Support\Trips;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use App\Support\Maps\Barangays;
use App\Support\Rentals;
use App\Support\TripFlow;
use App\Support\TruckSpace;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Trips by city: nearby cities of one province fill one truck. A trip keeps its cities;
 * waiting boxes of those cities join when they are scanned onto the truck.
 */
class CityTrips
{
    public const DEFAULT_CAPACITY = 50;

    public function __construct(public readonly User $user) {}

    public static function ready(): bool
    {
        return Schema::hasTable('trip_cities');
    }

    public static function isCityTrip(?Deliverylog $trip): bool
    {
        return $trip && static::ready() && TripCity::where('deliverylog_id', $trip->id)->exists();
    }

    protected function planner(): TripPlanner
    {
        return new TripPlanner($this->user, 'delivery');
    }

    /**
     * Waiting boxes by city: [key, province, city, boxes, space, receivers, biggest, days, prio, retry].
     */
    public function places(): Collection
    {
        $units = $this->planner()->units();
        $ids = $units->flatMap(fn ($u) => $u['ids']);
        $since = $ids->isEmpty() ? collect() : Invoice::whereIn('id', $ids)->get(['id', 'verified_at', 'created_at'])
            ->mapWithKeys(fn ($i) => [$i->id => $i->verified_at ?? $i->created_at]);
        $days = fn ($u) => collect($u['ids'])->map(fn ($id) => $since[$id] ?? null)->filter()->map(fn ($d) => (int) floor(Carbon::parse($d)->diffInHours(now()) / 24))->max() ?? 0;

        return $units->groupBy(fn ($u) => Str::lower($u['province']).'|'.Barangays::cityKey($u['city']))->map(fn ($g, $k) => [
            'key' => $k, 'province' => $g->first()['province'], 'city' => $g->first()['city'],
            'boxes' => $g->sum('n'), 'space' => (int) ceil($g->sum('space')), 'receivers' => $g->count(), 'biggest' => (int) ceil($g->max('space')),
            'days' => (int) $g->map($days)->max(), 'prio' => $g->sum('prio'), 'retry' => $g->sum('retry'),
            'unclear' => $g->first()['city'] === 'No city',
        ])->values();
    }

    /**
     * Customers with 2+ boxes in these cities: kept together on the trip.
     *
     * @return list<array{name: string, city: string, n: int, missing: int}>
     */
    public function sets(array $cityKeys): array
    {
        $keys = array_flip($cityKeys);
        $units = $this->planner()->units()->filter(fn ($u) => isset($keys[Str::lower($u['province']).'|'.Barangays::cityKey($u['city'])]) && $u['n'] >= 2);
        $out = [];
        foreach ($units as $u) {
            $setKeys = Invoice::whereIn('id', $u['ids'])->pluck('set_key')->filter()->unique();
            $missing = $setKeys->isEmpty() ? 0 : Invoice::whereIn('set_key', $setKeys)->where('is_verified', false)->where('is_delivered', false)->count();
            $out[] = ['name' => $u['name'], 'city' => $u['city'], 'n' => $u['n'], 'missing' => $missing];
        }

        return collect($out)->sortBy(fn ($x) => [$x['missing'] ? 0 : 1, -$x['n']])->take(4)->values()->all();
    }

    /** Cities already on an open trip (planned or loading, not locked): city key => trip number. */
    public function covered(): array
    {
        if (! static::ready()) {
            return [];
        }

        return TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->where('d.logistichub_id', $this->user->logistichub_id)
            ->get(['trip_cities.province', 'trip_cities.city_key', 'd.trip_number'])
            ->mapWithKeys(fn ($r) => [Str::lower((string) $r->province).'|'.$r->city_key => $r->trip_number])->all();
    }

    /** Trucks of the hub: free, out on a trip, kept, or off. */
    public function trucks(): Collection
    {
        $all = Truck::where('logistichub_id', $this->user->logistichub_id)->orderBy('plate_no')->get();
        $usable = Rentals::usable(Truck::where('logistichub_id', $this->user->logistichub_id)->where('is_active', true))->pluck('id')->flip();

        return $all->map(function (Truck $t) use ($usable) {
            $on = $t->is_assigned ? TripFlow::runningOn($t->id) : null;
            $state = match (true) {
                ! $t->is_active => 'off',
                ! isset($usable[$t->id]) => 'off',
                $on !== null => 'busy',
                (bool) $t->is_assigned => 'busy',
                default => 'free',
            };
            $sub = match ($state) {
                'free' => collect(\App\Models\Truckcrew::with('member')->where('truck_id', $t->id)->get())->map(fn ($c) => $c->member?->first_name)->filter()->join(' · ') ?: 'No crew yet',
                'busy' => $on ? 'On '.$on->trip_number.' · '.TripFlow::label($on) : 'On a trip',
                default => $t->is_active ? 'Rental, not booked today' : 'Inactive',
            };

            $stage = $on ? TripFlow::stage($on) : null;

            return ['id' => $t->id, 'plate' => $t->plate_no, 'state' => $state, 'sub' => $sub,
                'label' => match (true) { $state === 'free' => 'Free now', $state === 'off' => 'Off', $stage === 'road' => 'Out', $stage === 'back' => 'Coming back', default => 'On a trip' }, 'on' => $on?->trip_number, 'onId' => $on?->id,
                'capacity' => TruckSpace::usable($t, self::DEFAULT_CAPACITY), 'rental' => $t->isRental()];
        })->sortBy(fn ($t) => [['free' => 0, 'busy' => 1, 'off' => 2][$t['state']], $t['rental'] ? 1 : 0, $t['plate']])->values();
    }

    /**
     * The draft: trips by province and city.
     *
     * @param  array{order?: string, first?: ?string, keep?: bool, full?: bool, instruction?: string}  $opt
     * @return array{trips: list<array>, kept: ?int, note: string, ai: bool}
     */
    public function plan(array $opt = []): array
    {
        $covered = $this->covered();
        $places = $this->places()->reject(fn ($p) => $p['unclear'] || isset($covered[$p['key']]));
        $trucks = $this->trucks();
        $free = $trucks->where('state', 'free')->values();
        $kept = ! empty($opt['keep']) && $free->count() > 1 ? $free->last()['id'] : null;
        $slots = $free->reject(fn ($t) => $t['id'] === $kept)->values()
            ->merge($trucks->where('state', 'busy')->values())
            ->push(null)->push(null)->values();

        $note = '';
        $ai = false;
        $why = [];
        $provinceOrder = null;
        if (filled($opt['instruction'] ?? null) && Ai::enabled('trips')) {
            try {
                $out = Ai::json('trips',
                    'You help plan delivery trips by city for a Philippine balikbayan box company. Read what the staff asked and answer the order of provinces to plan first, '
                    .'which truck ids to keep free, and one short reason per province. Answer as {"order":["Province",...],"keep_truck_ids":[id,...],"why":{"Province":"..."},"note":"one short sentence"}.',
                    json_encode(['asked' => $opt['instruction'], 'provinces' => $places->groupBy('province')->map(fn ($g, $p) => ['province' => $p, 'boxes' => $g->sum('boxes'), 'oldest_days' => $g->max('days'), 'cities' => $g->pluck('city')])->values(),
                        'trucks' => $trucks->where('state', '!=', 'off')->map(fn ($t) => ['id' => $t['id'], 'plate' => $t['plate'], 'state' => $t['state']])->values()], JSON_UNESCAPED_UNICODE),
                    'fast', 1200);
                $provinceOrder = array_values(array_filter((array) ($out['order'] ?? []), 'is_string'));
                $keepIds = array_map('intval', (array) ($out['keep_truck_ids'] ?? []));
                if ($keepIds) {
                    $slots = $slots->reject(fn ($t) => $t && in_array($t['id'], $keepIds, true))->values();
                    $kept = $keepIds[0];
                }
                $why = array_change_key_case((array) ($out['why'] ?? []));
                $note = Str::limit((string) ($out['note'] ?? ''), 200);
                $ai = true;
            } catch (AiUnavailable $e) {
                $note = 'Planned without AI ('.$e->getMessage().').';
            }
        }

        // provinces: oldest boxes first (or the one asked first), then the most boxes
        $byProv = $places->groupBy('province')->map(fn ($g, $p) => ['province' => $p, 'days' => $g->max('days'), 'boxes' => $g->sum('boxes'), 'urgent' => $g->sum('prio') + $g->sum('retry'), 'cities' => $g]);
        $rank = fn ($p) => [
            $provinceOrder ? (array_search(Str::lower($p['province']), array_map('strtolower', $provinceOrder), true) === false ? 99 : array_search(Str::lower($p['province']), array_map('strtolower', $provinceOrder), true)) : 0,
            ! empty($opt['first']) && Str::lower($p['province']) === Str::lower($opt['first']) ? 0 : 1,
            -$p['urgent'] > 0 ? 0 : 1, -$p['days'], -$p['boxes'],
        ];
        $provs = $byProv->sortBy($rank)->values();

        $trips = [];
        $si = 0;
        foreach ($provs as $prov) {
            $cities = $prov['cities']->sortBy(fn ($c) => [-($c['prio'] + $c['retry']), -$c['days'], -$c['boxes']])->values();
            while ($cities->isNotEmpty() && $si < $slots->count()) {
                $slot = $slots[$si];
                $cap = $slot['capacity'] ?? self::DEFAULT_CAPACITY;
                $trip = ['province' => $prov['province'], 'cities' => [], 'load' => 0, 'cap' => $cap, 'days' => 0, 'truck_id' => $slot['id'] ?? null, 'on' => true, 'left' => []];
                $rest = collect();
                foreach ($cities as $c) {
                    if (! $trip['cities'] && $c['space'] > $cap) {
                        $trip['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space']];
                        $trip['load'] = $cap;
                        $trip['left'][] = $c['city'].' has '.$c['boxes'].' boxes: about '.max(0, $c['space'] - $cap).' wait for the next '.$prov['province'].' trip';
                        $trip['days'] = max($trip['days'], $c['days']);

                        continue;
                    }
                    if ($trip['load'] + $c['space'] <= $cap) {
                        $trip['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space']];
                        $trip['load'] += $c['space'];
                        $trip['days'] = max($trip['days'], $c['days']);
                    } else {
                        $rest->push($c);
                    }
                }
                if (! $trip['cities']) {
                    break;
                }
                $trip['why'] = $this->why($trip, $prov, $rest, $slot, $why[Str::lower($prov['province'])] ?? null);
                $trips[] = $trip;
                $si++;
                $cities = $rest->values();
                // a city left over goes on the next trip of the same province only if it would be a real truckload
                if ($cities->sum('space') < ($slots[$si]['capacity'] ?? self::DEFAULT_CAPACITY) * 0.5) {
                    break;
                }
            }
        }

        foreach ($trips as &$t) {
            if (! empty($opt['full'])) {
                $t['on'] = $t['load'] >= $t['cap'] * 0.9;
            } elseif ($t['load'] < $t['cap'] * 0.3 && $t['days'] < 3) {
                // a small trip waits for more boxes (switch it on to send it anyway)
                $t['on'] = false;
                $t['why'] = 'Small trip: waits for more boxes. Switch it on to send it anyway. '.$t['why'];
            }
        }
        unset($t);
        if ($note === '') {
            $planned = collect($trips)->flatMap(fn ($t) => collect($t['cities'])->pluck('key'))->flip();
            $waitCities = $places->reject(fn ($p) => isset($planned[$p['key']]))->count();
            $note = $places->isEmpty() ? 'No boxes are waiting for a trip.' : count($trips).' '.Str::plural('trip', count($trips)).' · '.($waitCities ? $waitCities.' '.Str::plural('city', $waitCities).' wait' : 'every city planned');
        }

        return ['trips' => $trips, 'kept' => $kept, 'note' => $note, 'ai' => $ai];
    }

    protected function why(array $trip, array $prov, Collection $rest, ?array $slot, ?string $ai): string
    {
        $parts = [];
        if ($ai) {
            $parts[] = Str::finish(Str::limit($ai, 140), '.');
        } else {
            $urgent = collect($prov['cities'])->whereIn('key', collect($trip['cities'])->pluck('key'))->sum(fn ($c) => $c['prio'] + $c['retry']);
            $parts[] = ($trip['days'] >= 3 ? 'Oldest boxes ('.$trip['days'].' days)' : ($trip['days'] ? 'Boxes '.$trip['days'].' '.Str::plural('day', $trip['days']).' old' : 'New today'))
                .($urgent ? ', '.$urgent.' priority or tried before' : '').'.';
        }
        if ($rest->isNotEmpty()) {
            $parts[] = ($trip['load'] >= $trip['cap'] * 0.85 ? 'Full truck: ' : 'No room: ').$rest->map(fn ($c) => $c['city'].' ('.$c['boxes'].')')->join(', ').' '.($rest->count() > 1 ? 'wait' : 'waits').' for the next '.$prov['province'].' trip.';
        }
        $parts = array_merge($parts, $trip['left']);
        if ($slot && $slot['state'] === 'busy') {
            $parts[] = 'Waits for '.$slot['plate'].($slot['on'] ? ' ('.$slot['on'].')' : '').' to come back.';
        } elseif (! $slot) {
            $parts[] = 'No truck yet: give it to the next free truck.';
        }

        return implode(' ', $parts);
    }

    /**
     * Make the trips. Trip numbers come now; boxes join when scanned onto the truck.
     *
     * @return list<array{id: int, number: string, truck: ?string}>
     */
    public function create(array $trips, Carbon $date): array
    {
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['on']) || empty($t['cities'])) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date) {
                $truck = $t['truck_id'] ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $this->user->logistichub_id, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) ($t['why'] ?? ''), 295), 'plan_space' => (int) $t['load'],
                ]);
                foreach ($t['cities'] as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => (int) $c['boxes']]);
                }
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }

        return $made;
    }

    /** City trips that still wait for a truck, most urgent first. */
    public function waitingForTruck(): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $places = $this->places()->keyBy('key');

        return Deliverylog::with('cities')->whereNull('truck_id')->where('is_active', true)->where('logistichub_id', $this->user->logistichub_id)
            ->whereHas('cities')->get()
            ->map(fn ($trip) => ['trip' => $trip, 'province' => $trip->cities->first()?->province, 'cities' => $trip->cities->pluck('city')->join(', '),
                'days' => (int) $trip->cities->map(fn ($c) => $places[Str::lower((string) $c->province).'|'.$c->city_key]['days'] ?? 0)->max()])
            ->sortByDesc('days')->values();
    }

    /** "Give": a free truck takes a trip that waits for a truck. */
    public function give(Deliverylog $trip, int $truckId): Truck
    {
        return DB::transaction(function () use ($trip, $truckId) {
            $truck = Truck::whereKey($truckId)->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->where('is_assigned', false)->lockForUpdate()->firstOrFail();
            $trip->update(['truck_id' => $truck->id]);
            $truck->update(['is_assigned' => true]);
            TripFlow::copyCrew($trip->fresh());

            return $truck;
        });
    }

    /**
     * Load truck: a waiting box of one of the trip's cities joins the trip.
     *
     * @return array{0: ?Tripinvoice, 1: ?string} the box on the trip now, or why not
     */
    public static function join(Deliverylog $trip, string $code, bool $force = false): array
    {
        if (! static::ready()) {
            return [null, null];
        }
        $cities = TripCity::where('deliverylog_id', $trip->id)->get();
        if ($cities->isEmpty()) {
            return [null, null];
        }
        $inv = Invoice::where('invoice', $code)->where('is_delivered', false)->latest('id')->first();
        if (! $inv) {
            return [null, null];
        }
        if ($inv->is_assigned || Tripinvoice::where('invoice_id', $inv->id)->where('is_delivered', false)->whereHas('deliverylog', fn ($q) => $q->where('is_active', true))->exists()) {
            return [null, null];
        }
        if ($trip->is_lock) {
            return [null, 'Trip '.$trip->trip_number.' is locked: no more boxes join. Unlock it to add '.$code.'.'];
        }
        if (! $inv->is_verified) {
            return [null, $code.' is not unloaded yet (not scanned at Unload container).'];
        }
        $key = Barangays::cityKey($inv->receiver_city);
        $match = $cities->first(fn ($c) => $c->city_key === $key && (! $c->province || Str::lower(Str::squish($c->province)) === Str::lower(Str::squish((string) $inv->receiver_province))));
        if (! $match && ! $force) {
            return [null, 'other-city'];
        }
        $added = app(TripAssignment::class)->addToDeliveryTrip($trip, collect([$inv]));
        if (! $added) {
            return [null, $code.' could not be added to '.$trip->trip_number.'.'];
        }

        return [Tripinvoice::with('invdata')->where('deliverylog_id', $trip->id)->where('invoice_id', $inv->id)->latest('id')->first(), null];
    }

    /** Unloading now: today's unloaded boxes by province, and where they go. */
    public function unloadingNow(): array
    {
        $wh = $this->user->warehouse_id;
        $rows = Invoice::where('is_assigned', false)->where('is_delivered', false)->where('verified_at', '>=', today())
            ->when($wh && \Filament\Facades\Filament::getCurrentPanel()?->getId() === 'warehouse', fn ($q) => $q->where('warehouse_id', $wh))
            ->with('container:id,container_no')->get(['id', 'container_id', 'receiver_province', 'receiver_city', 'wh_section_id', 'warehouse_id']);
        if ($rows->isEmpty()) {
            return ['container' => null, 'rows' => []];
        }
        $loading = static::ready() ? TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->whereNotNull('d.truck_id')->whereNull('d.waits_for')->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->leftJoin('trucks as t', 't.id', '=', 'd.truck_id')->get(['trip_cities.province', 'trip_cities.city_key', 't.plate_no'])
            ->mapWithKeys(fn ($r) => [Str::lower((string) $r->province).'|'.$r->city_key => $r->plate_no]) : collect();
        $byProv = $rows->groupBy(fn ($r) => Str::title(Str::squish((string) $r->receiver_province)) ?: 'No province')->sortByDesc(fn ($g) => $g->count());
        $out = [];
        $here = $this->user->warehouse_id;
        foreach ($byProv->take(2) as $prov => $g) {
            $plate = $g->map(fn ($r) => $loading[Str::lower(Str::squish((string) $r->receiver_province)).'|'.Barangays::cityKey($r->receiver_city)] ?? null)->filter()->first();
            $to = $here ? \App\Support\Warehouses\Coverage::transferTo($g->first(), $here) : null;
            $out[] = [$prov.' · '.$g->count().' '.Str::plural('box', $g->count()), $to ? 'Transfer → '.\App\Support\Warehouses\Coverage::name($to) : ($plate ? $plate.' is here → straight on' : 'Sections'), (bool) $plate];
        }
        if ($byProv->count() > 2) {
            $n = $byProv->slice(2)->sum(fn ($g) => $g->count());
            $out[] = ['Others · '.$n.' '.Str::plural('box', $n), 'Sections', false];
        }

        return ['container' => $rows->sortByDesc('id')->first()->container?->container_no, 'rows' => $out];
    }
}
