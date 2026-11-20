<?php

namespace App\Support\Trips;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\TripPlanner;
use App\Support\Hubs\HubAreas;
use App\Support\Maps\Barangays;
use App\Support\Rentals;
use App\Support\TripFlow;
use App\Support\TruckSpace;
use App\Support\Warehouses\Coverage;
use Filament\Facades\Filament;
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

    /** $atHub: a partner hub plans its own trips (boxes that arrived at the hub; added at Create). */
    public function __construct(public readonly User $user, public readonly bool $atHub = false) {}

    public static function ready(): bool
    {
        static $ready = null;

        return $ready ??= Schema::hasTable('trip_cities');
    }

    public static function isCityTrip(?Deliverylog $trip): bool
    {
        return $trip && static::ready() && TripCity::where('deliverylog_id', $trip->id)->exists();
    }

    /** Kept for this request: Plan trips asks for the same lists many times in one click. */
    protected ?TripPlanner $plannerMemo = null;

    protected ?Collection $placesMemo = null;

    protected ?array $coveredMemo = null;

    protected ?Collection $trucksMemo = null;

    protected function planner(): TripPlanner
    {
        return $this->plannerMemo ??= new TripPlanner($this->user, $this->atHub ? 'hub' : 'delivery');
    }

    /**
     * Waiting boxes by city: [key, province, city, boxes, space, receivers, biggest, days, prio, retry].
     */
    public function places(): Collection
    {
        return $this->placesMemo ??= $this->freshPlaces();
    }

    /** How these trips are made (Delivery trips › Made by): ['ai' => bool, 'instruction' => what was typed, 'reason' => why the plan was changed]. */
    public array $made = [];

    /** made_by / made_note of one planned trip. */
    protected function madeFields(array $t, string $default = 'plan'): array
    {
        if (! Schema::hasColumn('deliverylogs', 'made_by')) {
            return [];
        }
        if (! empty($t['changed'])) {
            return ['made_by' => 'changed', 'made_note' => Str::limit(trim(($t['changedNote'] ?? 'changed').(! empty($this->made['reason']) ? '. Reason: '.$this->made['reason'] : '')), 295, '')];
        }
        if (! empty($this->made['ai']) && filled($this->made['instruction'] ?? null)) {
            return ['made_by' => 'ai', 'made_note' => Str::limit((string) $this->made['instruction'], 295, '')];
        }

        return ['made_by' => $default, 'made_note' => null];
    }

    /** Cities of a hub's area delivered direct instead (keys "hubId|province|city"), set by Plan trips. */
    public array $direct = [];

    protected function isDirect(array $u): bool
    {
        if ($this->atHub) {
            // at a hub: only the boxes of its own area (a box of another hub came by mistake)
            return ! $u['hub'] || (int) $u['hub'] === (int) $this->user->logistichub_id;
        }

        return ! $u['hub'] || in_array($u['hub'].'|'.Str::lower($u['province']).'|'.Barangays::cityKey($u['city']), $this->direct, true);
    }

    /** Days a box has waited, per box id. */
    protected ?Collection $sinceMemo = null;

    protected function daysOf(array $u): int
    {
        if (! $this->sinceMemo) {
            $ids = $this->planner()->units()->flatMap(fn ($x) => $x['ids']);
            $this->sinceMemo = $ids->isEmpty() ? collect() : ($this->atHub
                ? Tripinvoice::whereIn('id', $ids)->get(['id', 'created_at'])->mapWithKeys(fn ($t) => [$t->id => $t->created_at])
                : Invoice::whereIn('id', $ids)->get(['id', 'verified_at', 'created_at'])->mapWithKeys(fn ($i) => [$i->id => $i->verified_at ?? $i->created_at]));
        }

        return (int) (collect($u['ids'])->map(fn ($id) => $this->sinceMemo[$id] ?? null)->filter()->map(fn ($d) => (int) floor(Carbon::parse($d)->diffInHours(now()) / 24))->max() ?? 0);
    }

    protected function freshPlaces(): Collection
    {
        // only the boxes the warehouse delivers direct; a hub's boxes are planned in "To hubs"
        $units = $this->planner()->units()->map(fn ($u) => $u + ['hub' => null])->filter(fn ($u) => $this->isDirect($u));
        $days = fn ($u) => $this->daysOf($u);

        return $units->groupBy(fn ($u) => Str::lower($u['province']).'|'.Barangays::cityKey($u['city']))->map(fn ($g, $k) => [
            'key' => $k, 'province' => $g->first()['province'], 'city' => $g->first()['city'],
            'boxes' => $g->sum('n'), 'space' => (int) ceil($g->sum('space')), 'receivers' => $g->count(), 'biggest' => (int) ceil($g->max('space')),
            'days' => (int) $g->map($days)->max(), 'prio' => $g->sum('prio'), 'retry' => $g->sum('retry'),
            'unclear' => $g->first()['city'] === 'No city',
            'via' => $this->atHub ? [] : $g->pluck('hub')->filter()->unique()->values()->all(),
        ])->values();
    }

    /**
     * Boxes a partner hub delivers, by hub and city.
     *
     * @return Collection<int, array{hub: int, name: string, boxes: int, space: int, days: int, prio: int, cities: Collection}>
     */
    public function hubPlaces(): Collection
    {
        if ($this->atHub) {
            return collect();
        }
        $units = $this->planner()->units()->map(fn ($u) => $u + ['hub' => null])->reject(fn ($u) => $this->isDirect($u));
        $names = Logistichub::whereIn('id', $units->pluck('hub')->unique())->pluck('hub_name', 'id');

        return $units->groupBy('hub')->map(function ($g, $hub) use ($names) {
            $cities = $g->groupBy(fn ($u) => Str::lower($u['province']).'|'.Barangays::cityKey($u['city']))->map(fn ($c, $k) => [
                'key' => $k, 'province' => $c->first()['province'], 'city' => $c->first()['city'], 'boxes' => $c->sum('n'),
                'space' => (int) ceil($c->sum('space')), 'days' => (int) $c->map(fn ($u) => $this->daysOf($u))->max(), 'prio' => $c->sum('prio') + $c->sum('retry'),
            ])->sortBy(fn ($c) => [-$c['prio'], -$c['days'], -$c['boxes']])->values();

            return ['hub' => (int) $hub, 'name' => (string) ($names[$hub] ?? 'Hub #'.$hub), 'boxes' => $cities->sum('boxes'), 'space' => $cities->sum('space'),
                'days' => (int) $cities->max('days'), 'prio' => $cities->sum('prio'), 'cities' => $cities];
        })->sortBy(fn ($h) => [-$h['prio'], -$h['days'], -$h['boxes']])->values();
    }

    /** Boxes for a hub still on the way (in containers not unloaded yet), for "wait for the next container". */
    public function comingFor(int $hubId): int
    {
        $map = HubAreas::map();
        if (! in_array($hubId, $map, true)) {
            return 0;
        }

        return Invoice::query()->where('is_verified', false)->where('is_delivered', false)->where('created_at', '>=', now()->subDays(60))->limit(3000)->get()
            ->filter(fn ($i) => HubAreas::hubOf($i, $map) === $hubId)->count();
    }

    /**
     * Trips to the hubs: one trip per hub, or more when the boxes do not fit one truck.
     * Whole cities go together (a city bigger than a truck goes on two trips: the truck-full check stops each truck).
     *
     * @param  array<int>  $usedTrucks  trucks already in the direct plan
     * @return list<array>
     */
    public function planHubs(array $usedTrucks = []): array
    {
        $trucks = $this->trucks();
        $free = $trucks->where('state', 'free')->reject(fn ($t) => in_array($t['id'], $usedTrucks, true))->values();
        $busy = $trucks->where('state', 'busy')->values();
        $fi = 0;
        $out = [];
        $open = $this->hubTripsOpen();
        foreach ($this->hubPlaces() as $h) {
            if (isset($open[$h['hub']])) {
                // a trip to this hub is open: its boxes join it when scanned
                $out[] = $h + ['trips' => [], 'coming' => 0, 'tip' => 'On '.implode(', ', $open[$h['hub']]).': boxes join when scanned onto the truck.', 'wait' => false, 'open' => $open[$h['hub']]];

                continue;
            }
            $slot = $free[$fi] ?? null;
            $cap = $slot['capacity'] ?? self::DEFAULT_CAPACITY;
            // first fit: each city (most urgent first) goes on the first trip with room, so trucks fill up;
            // a city bigger than a truck goes on more trips (the truck-full check stops each truck)
            $parts = [];
            foreach ($h['cities'] as $c) {
                $left = $c['space'];
                while ($left > 0) {
                    $fit = null;
                    foreach ($parts as $pi => $pt) {
                        if ($cap - $pt['load'] >= min($left, $cap)) {
                            $fit = $pi;
                            break;
                        }
                    }
                    if ($fit === null) {
                        $parts[] = ['cities' => [], 'load' => 0];
                        $fit = array_key_last($parts);
                    }
                    $take = min($left, $cap - $parts[$fit]['load']);
                    $parts[$fit]['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'province' => $c['province'],
                        'boxes' => $take === $c['space'] ? $c['boxes'] : (int) round($c['boxes'] * $take / max(1, $c['space'])), 'space' => $take];
                    $parts[$fit]['load'] += $take;
                    $left -= $take;
                }
            }
            $trips = [];
            foreach ($parts as $n => $pt) {
                $t = $free[$fi] ?? null;
                if ($t) {
                    $fi++;
                }
                $trips[] = ['cities' => $pt['cities'], 'load' => $pt['load'], 'cap' => $t['capacity'] ?? $cap, 'truck_id' => $t['id'] ?? null, 'plate' => $t['plate'] ?? null,
                    'when' => $t ? 'now' : 'later'];
            }
            $coming = $this->comingFor($h['hub']);
            $small = $h['space'] < $cap * 0.3;
            $tip = match (true) {
                $small && $coming > 0 && $h['prio'] === 0 => 'Wait: only '.$h['boxes'].' boxes; '.$coming.' more are on the way. One trip instead of two.',
                $small && $h['prio'] === 0 && $h['days'] < 3 => 'Small: only '.$h['boxes'].' boxes. Wait for more, or send if the hub needs them.',
                count($trips) > 1 && collect($trips)->contains('when', 'later') => 'Not enough free trucks: Trip 1 now with the priority and oldest boxes, the rest '.($coming ? 'with the next container' : 'when a truck is free').'.',
                count($trips) > 1 => count($trips).' trips: '.$h['boxes'].' boxes do not fit one truck. Priority and oldest on Trip 1.',
                $h['prio'] > 0 => 'Send today: '.$h['prio'].' priority or tried-before '.Str::plural('box', $h['prio']).', oldest '.$h['days'].' '.Str::plural('day', $h['days']).'.',
                default => 'Send: '.$h['boxes'].' boxes, oldest '.$h['days'].' '.Str::plural('day', $h['days']).'.',
            };
            if (! $free->count() && $busy->isNotEmpty()) {
                $tip .= ' No free truck now: '.$busy->first()['plate'].' comes back'.($busy->first()['on'] ? ' from '.$busy->first()['on'] : '').'.';
            }
            $out[] = $h + ['trips' => $trips, 'coming' => $coming, 'tip' => $tip, 'wait' => $small && $h['prio'] === 0, 'open' => []];
        }

        return $out;
    }

    /**
     * Make trips to a hub. Boxes join when scanned onto the truck (only boxes of this hub's cities).
     *
     * @return list<array{id: int, number: string, truck: ?string}>
     */
    public function createHub(int $hubId, array $trips, Carbon $date, ?string $why = null): array
    {
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['cities'])) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date, $hubId, $why) {
                $truck = ! empty($t['truck_id']) ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $hubId, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) $why, 295), 'plan_space' => (int) $t['load'],
                ] + $this->madeFields([]));
                foreach (collect($t['cities'])->unique('key') as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $c['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'),
                        'planned_boxes' => (int) $c['boxes'], 'hub_id' => $hubId]);
                }
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }

        return $made;
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
            $invIds = $this->atHub ? Tripinvoice::whereIn('id', $u['ids'])->pluck('invoice_id') : $u['ids'];
            $setKeys = Invoice::whereIn('id', $invIds)->pluck('set_key')->filter()->unique();
            $missing = $setKeys->isEmpty() ? 0 : Invoice::whereIn('set_key', $setKeys)->where('is_verified', false)->where('is_delivered', false)->count();
            $out[] = ['name' => $u['name'], 'city' => $u['city'], 'n' => $u['n'], 'missing' => $missing];
        }

        return collect($out)->sortBy(fn ($x) => [$x['missing'] ? 0 : 1, -$x['n']])->take(4)->values()->all();
    }

    /** Cities already on an open trip (planned or loading, not locked): city key => trip number. */
    public function covered(): array
    {
        return $this->coveredMemo ??= $this->freshCovered();
    }

    /** At a hub: boxes of another hub's area that came here by mistake. */
    public function notMine(): int
    {
        return $this->atHub ? $this->planner()->units()->filter(fn ($u) => ($u['hub'] ?? null) && (int) $u['hub'] !== (int) $this->user->logistichub_id)->sum('n') : 0;
    }

    protected function freshCovered(): array
    {
        if (! static::ready() || $this->atHub) {
            return [];
        }

        return TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->where('d.logistichub_id', $this->user->logistichub_id)
            ->when(Schema::hasColumn('trip_cities', 'hub_id'), fn ($q) => $q->whereNull('trip_cities.hub_id'))
            ->get(['trip_cities.province', 'trip_cities.city_key', 'd.trip_number'])
            ->mapWithKeys(fn ($r) => [Str::lower((string) $r->province).'|'.$r->city_key => $r->trip_number])->all();
    }

    /**
     * Open trips to each hub (not locked yet): hub id => trip numbers.
     *
     * @return array<int, list<string>>
     */
    public function hubTripsOpen(): array
    {
        if (! static::ready() || ! Schema::hasColumn('trip_cities', 'hub_id')) {
            return [];
        }

        return TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->where('d.logistichub_id', $this->user->logistichub_id)->whereNotNull('trip_cities.hub_id')->whereColumn('d.assigned_to', 'trip_cities.hub_id')
            ->get(['trip_cities.hub_id', 'd.trip_number'])->groupBy('hub_id')->map(fn ($g) => $g->pluck('trip_number')->unique()->values()->all())->all();
    }

    /** Trucks of the hub: free, out on a trip, kept, or off. */
    public function trucks(): Collection
    {
        return $this->trucksMemo ??= $this->freshTrucks();
    }

    protected function freshTrucks(): Collection
    {
        $all = Truck::where('logistichub_id', $this->user->logistichub_id)->orderBy('plate_no')->get();
        $usable = Rentals::usable(Truck::where('logistichub_id', $this->user->logistichub_id)->where('is_active', true))->pluck('id')->flip();
        // speed: every truck's crew in one query
        $crews = Truckcrew::with('member')->whereIn('truck_id', $all->pluck('id'))->get()->groupBy('truck_id');

        return $all->map(function (Truck $t) use ($usable, $crews) {
            $on = $t->is_assigned ? TripFlow::runningOn($t->id) : null;
            $state = match (true) {
                ! $t->is_active => 'off',
                ! isset($usable[$t->id]) => 'off',
                $on !== null => 'busy',
                (bool) $t->is_assigned => 'busy',
                default => 'free',
            };
            $sub = match ($state) {
                'free' => collect($crews->get($t->id, []))->map(fn ($c) => $c->member?->first_name)->filter()->join(' · ') ?: 'No crew yet',
                'busy' => $on ? 'On '.$on->trip_number.' · '.TripFlow::label($on) : 'On a trip',
                default => $t->is_active ? 'Rental, not booked today' : 'Inactive',
            };

            $stage = $on ? TripFlow::stage($on) : null;

            return ['id' => $t->id, 'plate' => $t->plate_no, 'state' => $state, 'sub' => $sub,
                'label' => match (true) {
                    $state === 'free' => 'Free now', $state === 'off' => 'Off', $stage === 'road' => 'Out', $stage === 'back' => 'Coming back', default => 'On a trip'
                }, 'on' => $on?->trip_number, 'onId' => $on?->id,
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
            $p['urgent'] > 0 ? 0 : 1, -$p['days'], -$p['boxes'],
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
                        $trip['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space'], 'via' => $c['via'] ?? []];
                        $trip['load'] = $cap;
                        $trip['left'][] = $c['city'].' has '.$c['boxes'].' boxes: about '.max(0, $c['space'] - $cap).' wait for the next '.$prov['province'].' trip';
                        $trip['days'] = max($trip['days'], $c['days']);

                        continue;
                    }
                    if ($cap >= $trip['load'] + $c['space']) {
                        $trip['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space'], 'via' => $c['via'] ?? []];
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
        if ($this->atHub) {
            return $this->createAtHub($trips, $date);
        }
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
                ] + (Schema::hasColumn('deliverylogs', 'no_sms') ? ['no_sms' => array_key_exists('sms', $t) && ! $t['sms']] : []) + $this->madeFields($t));
                foreach ($t['cities'] as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => (int) $c['boxes']]);
                    // a hub's boxes of this city delivered direct instead
                    foreach ($c['via'] ?? [] as $hub) {
                        TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => 0, 'hub_id' => (int) $hub]);
                    }
                }
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }

        return $made;
    }

    /** A hub's own trips: the boxes of the trip's cities that are at the hub go on it now. */
    protected function createAtHub(array $trips, Carbon $date): array
    {
        $units = $this->planner()->units()->filter(fn ($u) => $this->isDirect($u));
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['on']) || empty($t['cities'])) {
                continue;
            }
            $keys = collect($t['cities'])->pluck('key')->flip();
            $ids = $units->filter(fn ($u) => isset($keys[Str::lower($u['province']).'|'.Barangays::cityKey($u['city'])]))->flatMap(fn ($u) => $u['ids'])->values();
            if ($ids->isEmpty()) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date, $ids) {
                $truck = $t['truck_id'] ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $this->user->logistichub_id, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) ($t['why'] ?? ''), 295), 'plan_space' => (int) $t['load'],
                ] + (Schema::hasColumn('deliverylogs', 'no_sms') ? ['no_sms' => array_key_exists('sms', $t) && ! $t['sms']] : []) + $this->madeFields($t));
                foreach ($t['cities'] as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => (int) $c['boxes']]);
                }
                app(TripAssignment::class)->addToHubTrip($trip, Tripinvoice::whereKey($ids)->get());
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }
        $this->plannerMemo = null;
        $this->placesMemo = null;

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
    public static function join(Deliverylog $trip, string $code, bool $force = false, bool $forceHub = false): array
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
        // same city name in two provinces: the province must match too (a city saved without a province takes only boxes without one)
        $sameCity = $cities->filter(fn ($c) => $c->city_key === $key && Str::lower(Str::squish((string) $c->province)) === Str::lower(Str::squish((string) $inv->receiver_province)));
        $hasHub = Schema::hasColumn('trip_cities', 'hub_id');
        $boxHub = $hasHub ? HubAreas::hubOf($inv) : null;
        $match = $hasHub ? $sameCity->first(fn ($c) => (int) $c->hub_id === (int) $boxHub) : $sameCity->first();
        if (! $match && $hasHub && ! $forceHub) {
            $toHubTrip = $cities->every(fn ($c) => $c->hub_id && $trip->assigned_to && (int) $trip->assigned_to !== (int) $trip->logistichub_id);
            // a hub's box on our own trip, our box on a trip to a hub, or a box of another hub
            if ($sameCity->isNotEmpty() || $boxHub || $toHubTrip) {
                return [null, 'hub:'.(int) $boxHub];
            }
        }
        if (! $match && ! $force && ! $forceHub) {
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
        if ($this->atHub) {
            return ['container' => null, 'rows' => []];
        }
        $wh = $this->user->warehouse_id;
        $rows = Invoice::where('is_assigned', false)->where('is_delivered', false)->where('verified_at', '>=', today())
            ->when($wh && Filament::getCurrentPanel()?->getId() === 'warehouse', fn ($q) => $q->where('warehouse_id', $wh))
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
            $to = $here ? Coverage::transferTo($g->first(), $here) : null;
            $out[] = [$prov.' · '.$g->count().' '.Str::plural('box', $g->count()), $to ? 'Transfer → '.Coverage::name($to) : ($plate ? $plate.' is here → straight on' : 'Sections'), (bool) $plate];
        }
        if ($byProv->count() > 2) {
            $n = $byProv->slice(2)->sum(fn ($g) => $g->count());
            $out[] = ['Others · '.$n.' '.Str::plural('box', $n), 'Sections', false];
        }

        return ['container' => $rows->sortByDesc('id')->first()->container?->container_no, 'rows' => $out];
    }
}
