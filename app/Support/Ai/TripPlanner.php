<?php

namespace App\Support\Ai;

use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Services\TripAssignment;
use App\Support\BoxSizes;
use Filament\Facades\Filament;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * AI trip helper. The AI only decides which places go together on which truck;
 * the rules are kept here in code:
 *  - boxes for the same receiver are never split,
 *  - priority and tried-before boxes go first,
 *  - a truck is never filled over its capacity (in space: Settings → Box sizes; a big box takes more),
 *  - only free trucks of your own hub, only boxes that are not on a trip yet.
 * Trip numbers are given by the system when the trips are created, as always.
 */
class TripPlanner
{
    /** Used when a truck has no capacity set. */
    public const DEFAULT_CAPACITY = 50;

    public const MODES = [
        'delivery' => 'Delivery trips',
        'transfer' => 'Warehouse transfer',
        'hub' => 'Hub trips',
    ];

    public function __construct(public readonly User $user, public readonly string $mode) {}

    /** Which kinds of trips this person can make in the panel they are in. */
    public static function modesFor(User $user, ?string $panel = null): array
    {
        $panel ??= Filament::getCurrentPanel()?->getId();
        $hub = AiScope::hubId($user);
        if ($hub === false || ! $user->logistichub_id) {
            return [];
        }

        return match (true) {
            $panel === 'company' || (bool) $hub => Logistichub::whereKey($user->logistichub_id)->value('is_company') ? ['hub'] : [],
            $panel === 'warehouse' => $user->warehouse_id ? ['delivery', 'transfer'] : [],
            default => ['delivery'],
        };
    }

    /** In the warehouse panel only that warehouse's boxes are used. */
    protected function warehouseOnly(): ?int
    {
        return Filament::getCurrentPanel()?->getId() === 'warehouse' || $this->mode === 'transfer'
            ? ($this->user->warehouse_id ?: -1)
            : null;
    }

    /**
     * Ready boxes, grouped per receiver (one "unit" = all boxes of one receiver).
     *
     * @return Collection<string, array{key: string, name: string, province: string, city: string, barangay: string, ids: list<int>, n: int, prio: int, retry: int}>
     */
    public function units(): Collection
    {
        if ($this->mode === 'hub') {
            $rows = Tripinvoice::query()->with('invdata')
                ->where('logistichub_id', $this->user->logistichub_id)
                ->where('is_loaded', true)->where('hub_assigned', false)->where('is_delivered', false)
                ->limit(3000)->get();
            $boxes = $rows->filter(fn ($t) => $t->invdata)->map(fn ($t) => ['id' => $t->id, 'inv' => $t->invdata]);
        } else {
            $q = Invoice::query()->where('is_verified', true)->where('is_delivered', false)->where('is_assigned', false);
            if ($this->mode === 'transfer') {
                $q->where('wh_is_assigned', false);
            }
            if ($wh = $this->warehouseOnly()) {
                $q->where('warehouse_id', $wh);
            }
            $boxes = $q->limit(3000)->get()->map(fn ($i) => ['id' => $i->id, 'inv' => $i]);
        }

        $tried = DeliveryAttempt::whereIn('invoice_id', $boxes->map(fn ($b) => $b['inv']->id))->distinct()->pluck('invoice_id')->flip();
        $clean = fn ($v) => Str::of((string) $v)->squish()->title()->toString();

        return $boxes->groupBy(fn ($b) => static::receiverKey($b['inv']))->map(function (Collection $g, string $key) use ($tried, $clean) {
            $first = $g->first()['inv'];

            return [
                'key' => $key,
                'name' => $clean($first->receiver_name),
                'province' => $clean($first->receiver_province) ?: 'No province',
                'city' => $clean($first->receiver_city) ?: 'No city',
                'barangay' => $clean($first->receiver_barangay) ?: 'No barangay',
                'ids' => $g->pluck('id')->values()->all(),
                'n' => $g->count(),
                'space' => BoxSizes::half($g->sum(fn ($b) => BoxSizes::spaceOf($b['inv']->boxtype))),
                'mix' => $g->countBy(fn ($b) => BoxSizes::nameOfType($b['inv']->boxtype))->all(),
                'prio' => $g->filter(fn ($b) => $b['inv']->is_priority)->count(),
                'retry' => $g->filter(fn ($b) => isset($tried[$b['inv']->id]))->count(),
            ];
        });
    }

    /** Same receiver = same name and address, or same phone number. */
    public static function receiverKey(Invoice $i): string
    {
        $phone = substr(preg_replace('/\D+/', '', (string) $i->receiver_mobile_no), -10);
        if (strlen($phone) >= 9) {
            return 'p'.$phone;
        }

        return 'n'.md5(Str::lower(Str::squish($i->receiver_name.'|'.$i->receiver_address.'|'.$i->receiver_barangay.'|'.$i->receiver_city)));
    }

    public static function placeKey(array $u): string
    {
        return $u['province'].' › '.$u['city'].' › '.$u['barangay'];
    }

    /** Free trucks of this hub (only trucks; drivers are not assigned). */
    public function trucks(): Collection
    {
        return Truck::where('is_active', true)->where('is_assigned', false)
            ->where('logistichub_id', $this->user->logistichub_id)->orderBy('plate_no')->get()
            ->map(fn (Truck $t) => ['id' => $t->id, 'plate' => $t->plate_no, 'capacity' => \App\Support\TruckSpace::usable($t, self::DEFAULT_CAPACITY), 'set' => (bool) ($t->capacity ?: \App\Support\TruckSpace::fit($t)), 'kind' => $t->description ?: $t->category]);
    }

    /** Where a trip can go: hubs for delivery trips, other warehouses for transfers. */
    public function destinations(): Collection
    {
        return match ($this->mode) {
            'transfer' => Warehouse::where('id', '!=', $this->user->warehouse_id)->orderBy('name')->get()
                ->map(fn ($w) => ['id' => $w->id, 'name' => $w->name, 'place' => trim($w->city.', '.$w->province, ', ')]),
            'delivery' => Logistichub::where('is_active', true)->orderBy('hub_name')->get()
                ->map(fn ($h) => ['id' => $h->id, 'name' => $h->hub_name, 'place' => $h->hub_code]),
            default => collect(),
        };
    }

    /**
     * Make a draft. Returns trips with places (each place = a barangay with its receiver groups) and what was left out.
     *
     * @return array{trips: list<array>, left: list<string>, note: string, ai: bool}
     */
    public function suggest(string $instruction = ''): array
    {
        $units = $this->units();
        $trucks = $this->trucks();
        if ($units->isEmpty()) {
            return ['trips' => [], 'left' => [], 'note' => 'No boxes are waiting for a trip.', 'ai' => false];
        }
        if ($trucks->isEmpty()) {
            return ['trips' => [], 'left' => [], 'note' => 'No free trucks. Release a truck from a finished trip first.', 'ai' => false];
        }

        $places = $units->groupBy(fn ($u) => static::placeKey($u))->map(fn ($g, $k) => [
            'place' => $k, 'boxes' => $g->sum('n'), 'space' => $g->sum('space'), 'receivers' => $g->count(), 'biggest_receiver' => $g->max('space'),
            'priority' => $g->sum('prio'), 'tried_before' => $g->sum('retry'),
        ])->sortBy('place')->values();

        $ai = false;
        $note = '';
        $plan = null;
        if (Ai::enabled('trips')) {
            try {
                $out = Ai::json('trips',
                    'You plan delivery trips for a Philippine balikbayan box cargo company. Group places that are close together '
                    .'(same province first, then same or neighbouring city/municipality, then barangays) onto the free trucks. '
                    .(BoxSizes::on()
                        ? 'Each truck has a capacity in space (a normal box is 1, bigger boxes take more): the total "space" of the places on a truck must not go over its capacity. '
                        : 'Each truck has a capacity in boxes: do not plan more boxes than the capacity. ')
                    .'Places with priority or tried-before boxes must be planned first. '
                    .'You may leave places out when there is no room (they wait for the next day). Use each truck at most once. '
                    .($this->mode === 'transfer' ? 'These are transfers to other warehouses: also pick the destination warehouse id closest to the places. ' : '')
                    .'Return {"trips": [{"truck_id": id, '.($this->mode === 'transfer' ? '"warehouse_id": id, ' : '').'"places": ["exact place text", ...], "why": "one short reason"}], "note": "one or two short sentences: what was planned and what was left for later"}.',
                    json_encode([
                        'instruction_from_staff' => $instruction ?: 'Plan trips for the ready boxes.',
                        'places' => $places, 'trucks' => $trucks->map(fn ($t) => ['truck_id' => $t['id'], 'plate' => $t['plate'], 'capacity' => $t['capacity']]),
                        'warehouses' => $this->mode === 'transfer' ? $this->destinations() : null,
                    ], JSON_UNESCAPED_UNICODE),
                    'smart', 2500);
                $plan = collect($out['trips'] ?? [])->map(fn ($t) => [
                    'truck_id' => (int) ($t['truck_id'] ?? 0), 'dest' => isset($t['warehouse_id']) ? (int) $t['warehouse_id'] : null,
                    'places' => array_values(array_filter((array) ($t['places'] ?? []), 'is_string')), 'why' => (string) ($t['why'] ?? ''),
                ])->all();
                $note = (string) ($out['note'] ?? '');
                $ai = true;
            } catch (AiUnavailable $e) {
                $note = 'Made without AI ('.$e->getMessage().') by grouping province, city and barangay in order.';
            }
        } else {
            $note = 'Made without AI by grouping province, city and barangay in order. '.Ai::whyOff('trips');
        }

        $plan ??= $this->simplePlan($places, $trucks);

        return $this->fill($plan, $units, $trucks, $note, $ai);
    }

    /** Without AI: one province per truck, places with priority first, then city and barangay in order. */
    protected function simplePlan(Collection $places, Collection $trucks): array
    {
        $prov = fn ($p) => Str::before($p['place'], ' › ');
        $urgentProv = $places->filter(fn ($p) => $p['priority'] + $p['tried_before'] > 0)->map($prov)->unique()->flip();
        $order = $places->sortBy(fn ($p) => [isset($urgentProv[$prov($p)]) ? 0 : 1, $prov($p), ($p['priority'] + $p['tried_before']) > 0 ? 0 : 1, $p['place']])->values();
        $plan = [];
        $ti = -1;
        $load = 0;
        $current = null;
        foreach ($order as $p) {
            $needNew = $ti < 0 || $prov($p) !== $current || $load + $p['biggest_receiver'] > $trucks[$ti]['capacity'];
            if ($needNew) {
                $ti++;
                $load = 0;
                $current = $prov($p);
            }
            if ($ti >= $trucks->count()) {
                break;
            }
            $plan[$ti] ??= ['truck_id' => $trucks[$ti]['id'], 'dest' => null, 'places' => [], 'why' => 'Places in '.$current.', next to each other in the list.'];
            $plan[$ti]['places'][] = $p['place'];
            $load += min($p['space'], $trucks[$ti]['capacity'] - $load);
        }

        return array_values($plan);
    }

    /** Put the receiver groups into the planned trips, keeping every rule. */
    public function fill(array $plan, Collection $units, Collection $trucks, string $note, bool $ai): array
    {
        $byPlace = $units->groupBy(fn ($u) => static::placeKey($u));
        $index = $byPlace->keys()->mapWithKeys(fn ($k) => [mb_strtolower($k) => $k]);
        $resolve = fn (string $name) => $index[mb_strtolower(trim($name))]
            ?? $byPlace->keys()->first(fn ($k) => str_ends_with(mb_strtolower($k), mb_strtolower(trim(Str::afterLast($name, '›')))));
        $usedTrucks = [];
        $usedUnits = [];
        $trips = [];
        $dests = $this->destinations()->keyBy('id');

        foreach ($plan as $p) {
            $truck = $trucks->firstWhere('id', $p['truck_id']);
            if (! $truck || isset($usedTrucks[$truck['id']])) {
                continue;
            }
            $usedTrucks[$truck['id']] = true;
            $trip = ['truck_id' => $truck['id'], 'dest' => $p['dest'] && $dests->has($p['dest']) ? $p['dest'] : $this->defaultDest(), 'why' => $p['why'], 'places' => []];
            $load = 0;
            // priority and tried-before receivers first, then the biggest groups
            foreach ($p['places'] as $asked) {
                $placeName = $resolve((string) $asked);
                if (! $placeName) {
                    continue;
                }
                $group = ($byPlace[$placeName] ?? collect())->reject(fn ($u) => isset($usedUnits[$u['key']]))
                    ->sortBy(fn ($u) => [-($u['prio'] + $u['retry']), -$u['space']]);
                $keys = [];
                foreach ($group as $u) {
                    if ($load + $u['space'] > $truck['capacity']) {
                        continue; // the whole receiver waits; never split
                    }
                    $keys[] = $u['key'];
                    $usedUnits[$u['key']] = true;
                    $load += $u['space'];
                }
                if ($keys) {
                    $trip['places'][] = ['place' => $placeName, 'units' => $keys];
                }
            }
            if ($trip['places']) {
                $trip['load'] = $load;
                $trip['capacity'] = $truck['capacity'];
                $trips[] = $trip;
            }
        }

        // boxes that were not planned: put them on a trip with room in the same province (priority and tried-before first)
        $waiting = $units->reject(fn ($u) => isset($usedUnits[$u['key']]))->sortBy(fn ($u) => [-($u['prio'] + $u['retry']), -$u['space']]);
        foreach ($waiting as $u) {
            $place = static::placeKey($u);
            $sameProvince = collect($trips)->keys()->filter(fn ($i) => collect($trips[$i]['places'])->contains(fn ($pl) => str_starts_with($pl['place'], $u['province'].' ›')));
            // a place already on a trip goes there first
            $order = $sameProvince->sortBy(fn ($i) => collect($trips[$i]['places'])->contains('place', $place) ? 0 : 1);
            foreach ($order as $i) {
                if ($trips[$i]['load'] + $u['space'] <= $trips[$i]['capacity']) {
                    $slot = collect($trips[$i]['places'])->search(fn ($pl) => $pl['place'] === $place);
                    if ($slot === false) {
                        $trips[$i]['places'][] = ['place' => $place, 'units' => [$u['key']]];
                    } else {
                        $trips[$i]['places'][$slot]['units'][] = $u['key'];
                    }
                    $trips[$i]['load'] += $u['space'];
                    $usedUnits[$u['key']] = true;
                    break;
                }
            }
        }

        $left = $units->reject(fn ($u) => isset($usedUnits[$u['key']]));

        return [
            'trips' => $trips,
            'left' => $left->groupBy(fn ($u) => static::placeKey($u))->map(fn ($g, $k) => $k.' ('.$g->sum('n').(BoxSizes::on() && $g->sum('space') != $g->sum('n') ? ' · '.BoxSizes::fmt($g->sum('space')).' space' : '').')')->values()->all(),
            'leftPrio' => $left->sum('prio'),
            'note' => $note,
            'ai' => $ai,
        ];
    }

    public function defaultDest(): ?int
    {
        return match ($this->mode) {
            'delivery' => $this->user->logistichub_id,
            'transfer' => $this->destinations()->first()['id'] ?? null,
            default => null,
        };
    }

    /**
     * Create the trips of the draft. Trip numbers come from the system as usual.
     *
     * @return list<array{number: string, truck: string, boxes: int, skipped: int}>
     */
    public function create(array $trips, Carbon $date): array
    {
        $units = $this->units()->keyBy('key');
        $service = app(TripAssignment::class);
        $made = [];

        foreach ($trips as $t) {
            $ids = collect($t['places'])->flatMap(fn ($p) => $p['units'])->flatMap(fn ($k) => $units[$k]['ids'] ?? [])->unique()->values();
            if ($ids->isEmpty()) {
                continue;
            }

            $made[] = DB::transaction(function () use ($t, $ids, $date, $service) {
                $truck = Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)
                    ->where('is_active', true)->lockForUpdate()->first();
                if (! $truck || ($this->mode !== 'transfer' && $truck->is_assigned)) {
                    throw new \DomainException('Truck '.($truck?->plate_no ?? '#'.$t['truck_id']).' is no longer free. Suggest again.');
                }

                if ($this->mode === 'transfer') {
                    $trip = Whdeliverylog::create([
                        'truck_id' => $truck->id, 'warehouse_id' => $t['dest'] ?: $this->defaultDest(),
                        'departure_date' => $date->toDateString(), 'delivery_date' => $date->toDateString(),
                        'user_id' => $this->user->id, 'user_whid' => $this->user->warehouse_id,
                    ]);
                    $added = $service->addToWarehouseTrip($trip, Invoice::whereKey($ids)->get());
                } else {
                    $trip = Deliverylog::create([
                        'truck_id' => $truck->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                        'logistichub_id' => $this->user->logistichub_id,
                        'assigned_to' => $this->mode === 'hub' ? $this->user->logistichub_id : ($t['dest'] ?: $this->user->logistichub_id),
                        'user_id' => $this->user->id,
                    ]);
                    $truck->update(['is_assigned' => true]);
                    $added = $this->mode === 'hub'
                        ? $service->addToHubTrip($trip, Tripinvoice::whereKey($ids)->get())
                        : $service->addToDeliveryTrip($trip, Invoice::whereKey($ids)->get());
                }

                return ['number' => (string) $trip->trip_number, 'truck' => (string) $truck->plate_no, 'boxes' => $added, 'skipped' => $ids->count() - $added,
                    'places' => collect($t['places'])->map(fn ($p) => Str::afterLast($p['place'], ' › '))->join(', ')];
            });
        }

        return $made;
    }
}
