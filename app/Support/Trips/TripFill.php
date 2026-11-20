<?php

namespace App\Support\Trips;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use App\Support\Maps\Barangays;
use App\Support\TruckSpace;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Boxes onto trips (boards 45, 45b, 45d).
 *
 * - Combos: one receiver's boxes, and the boxes of one set, always go together (never split).
 * - pick(): fills the room of a trip, urgent first, combos before single boxes, first fit.
 * - newBoxes(): waiting boxes of cities that already have a trip: add to a trip with room,
 *   full → new trip or Add anyway (space is an estimate), locked or on the road → new trip.
 * - placeAtHub(): a partner hub's unload scan puts each box on the hub's open trip of its city.
 */
class TripFill
{
    public const RULE = 'truck_full';

    public static function cityKey(?string $province, ?string $city): string
    {
        return Str::lower(Str::squish((string) $province)).'|'.Barangays::cityKey((string) $city);
    }

    /** The space a trip can take: the truck's usable space, else the default. */
    public static function cap(Deliverylog $trip): int
    {
        $truck = $trip->truck;

        return $truck ? TruckSpace::usable($truck, CityTrips::DEFAULT_CAPACITY) : CityTrips::DEFAULT_CAPACITY;
    }

    /** Space of every box on the trip (loaded or not). A partner hub's own trip counts deliveryloghub_id. */
    public static function used(Deliverylog $trip): float
    {
        $hubOwn = (int) $trip->assigned_to === (int) $trip->logistichub_id && Tripinvoice::where('deliveryloghub_id', $trip->id)->exists();
        $rows = Tripinvoice::with('invdata:id,boxtype')->where($hubOwn ? 'deliveryloghub_id' : 'deliverylog_id', $trip->id)->get();

        return (float) $rows->sum(fn ($r) => BoxSizes::spaceOf($r->invdata?->boxtype));
    }

    /**
     * Combos from planner units (one unit = one receiver): units that share a set are merged.
     *
     * @return Collection<int, array{key: string, ids: list<int>, n: int, space: float, prio: int, retry: int, name: string, province: string, city: string, city_key: string, kind: string, codes: list<string>}>
     */
    public static function combos(Collection $units, bool $hubRows = false): Collection
    {
        $units = $units->values();
        if ($units->isEmpty()) {
            return collect();
        }
        $allIds = $units->flatMap(fn ($u) => $u['ids'])->values();
        $invIds = $hubRows ? Tripinvoice::whereIn('id', $allIds)->pluck('invoice_id', 'id') : null;
        $inv = Invoice::whereIn('id', $hubRows ? $invIds->values() : $allIds)->get(['id', 'invoice', 'set_key'])->keyBy('id');
        $invOf = fn ($id) => $inv[$hubRows ? ($invIds[$id] ?? 0) : $id] ?? null;

        // union units that share a set key
        $parent = range(0, $units->count() - 1);
        $find = function ($i) use (&$parent, &$find) {
            return $parent[$i] === $i ? $i : ($parent[$i] = $find($parent[$i]));
        };
        $bySet = [];
        foreach ($units as $i => $u) {
            foreach ($u['ids'] as $id) {
                $sk = $invOf($id)?->set_key;
                if ($sk) {
                    if (isset($bySet[$sk])) {
                        $parent[$find($i)] = $find($bySet[$sk]);
                    } else {
                        $bySet[$sk] = $i;
                    }
                }
            }
        }
        $groups = [];
        foreach ($units as $i => $u) {
            $groups[$find($i)][] = $i;
        }

        return collect($groups)->map(function ($members) use ($units, $invOf) {
            $us = collect($members)->map(fn ($i) => $units[$i]);
            $first = $us->first();
            $ids = $us->flatMap(fn ($u) => $u['ids'])->values()->all();
            $n = count($ids);
            // a set: the same receiver name, phone and city (one set key); else boxes of one receiver
            $set = $n >= 2 && collect($ids)->map(fn ($id) => $invOf($id)?->set_key)->filter()->unique()->count() === 1;

            return [
                'key' => 'c'.md5(implode(',', $ids)), 'ids' => $ids, 'n' => $n, 'space' => (float) $us->sum('space'),
                'prio' => (int) $us->sum('prio'), 'retry' => (int) $us->sum('retry'), 'name' => (string) $first['name'],
                'province' => (string) $first['province'], 'city' => (string) $first['city'], 'city_key' => static::cityKey($first['province'], $first['city']),
                'barangay' => (string) ($first['barangay'] ?? ''), 'hub' => $first['hub'] ?? null,
                'kind' => $n < 2 ? 'single' : ($set ? 'set' : 'receiver'),
                'codes' => collect($ids)->map(fn ($id) => $invOf($id)?->invoice)->filter()->values()->all(),
            ];
        })->values();
    }

    /** Urgent first, combos before single boxes, bigger combos first. */
    public static function order(Collection $combos): Collection
    {
        return $combos->sortBy(fn ($c) => [-($c['prio'] + $c['retry']), $c['n'] >= 2 ? 0 : 1, -$c['n'], $c['barangay'] ?? '', $c['name']])->values();
    }

    /**
     * Fill $room: first fit, a combo is taken whole or not at all.
     *
     * @return array{0: Collection, 1: Collection} [picked, rest]
     */
    public static function pick(Collection $combos, float $room): array
    {
        $picked = collect();
        $rest = collect();
        $left = $room;
        foreach (static::order($combos) as $c) {
            if ($c['space'] <= $left + 0.001) {
                $picked->push($c);
                $left -= $c['space'];
            } else {
                $rest->push($c);
            }
        }

        return [$picked, $rest];
    }

    /** Put these combos (invoice ids) on a delivery trip. Returns boxes added. */
    public static function addInvoices(Deliverylog $trip, Collection $combos): int
    {
        $ids = $combos->flatMap(fn ($c) => $c['ids'])->unique()->values();
        if ($ids->isEmpty()) {
            return 0;
        }
        $added = app(TripAssignment::class)->addToDeliveryTrip($trip, Invoice::whereIn('id', $ids)->where('is_assigned', false)->get());
        static::countCities($trip);

        return $added;
    }

    /** Planned boxes per city = boxes now on the trip (Delivery trips, the trip page). */
    public static function countCities(Deliverylog $trip, bool $hubOwn = false): void
    {
        if (! CityTrips::ready() || ! Schema::hasColumn('trip_cities', 'planned_boxes')) {
            return;
        }
        $rows = DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
            ->where('tripinvoices.'.($hubOwn ? 'deliveryloghub_id' : 'deliverylog_id'), $trip->id)
            ->get(['invoices.receiver_province as p', 'invoices.receiver_city as c'])
            ->countBy(fn ($r) => static::cityKey($r->p, $r->c));
        foreach (TripCity::where('deliverylog_id', $trip->id)->get() as $tc) {
            if ($tc->hub_id && (int) $tc->hub_id !== (int) $trip->assigned_to) {
                continue;
            }
            $tc->update(['planned_boxes' => (int) ($rows[static::cityKey($tc->province, $tc->city)] ?? 0)]);
        }
    }

    // ------------------------------------------------------------------ new boxes (Admin and Warehouse)

    /** Open trips of the hub (not locked, not left) and today's closed-to-new-boxes trips, per city key. */
    protected static function tripsByCity(User $user): array
    {
        if (! CityTrips::ready()) {
            return [[], []];
        }
        $taken = Schema::hasColumn('deliverylogs', 'taken_at');
        $rows = TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where('d.logistichub_id', $user->logistichub_id)
            ->when(Schema::hasColumn('trip_cities', 'hub_id'), fn ($q) => $q->whereNull('trip_cities.hub_id'))
            ->get(['trip_cities.province', 'trip_cities.city', 'd.id', 'd.is_lock', $taken ? 'd.taken_at' : DB::raw('null as taken_at')]);
        $open = [];
        $closed = [];
        foreach ($rows as $r) {
            $k = static::cityKey($r->province, $r->city);
            if ($r->is_lock || $r->taken_at) {
                $closed[$k][$r->id] = $r->id;
            } else {
                $open[$k][$r->id] = $r->id;
            }
        }

        return [$open, $closed];
    }

    /**
     * Waiting boxes of cities that already have a trip.
     *
     * @return list<array{key: string, city: string, province: string, n: int, combos: list<array>, kind: string, trip: ?array, fit: list<string>, newN: int}>
     */
    public static function newBoxes(User $user): array
    {
        $ct = new CityTrips($user);
        [$open, $closed] = static::tripsByCity($user);
        if (! $open && ! $closed) {
            return [];
        }
        $units = $ct->waitingUnits()->filter(fn ($u) => isset($open[static::cityKey($u['province'], $u['city'])]) || isset($closed[static::cityKey($u['province'], $u['city'])]));
        if ($units->isEmpty()) {
            return [];
        }
        $trips = Deliverylog::with('truck')->whereIn('id', collect($open)->flatten()->merge(collect($closed)->flatten())->unique())->get()->keyBy('id');
        $usedOf = [];
        $out = [];
        foreach (static::combos($units)->groupBy('city_key') as $key => $combos) {
            $best = null;
            foreach ($open[$key] ?? [] as $id) {
                $t = $trips[$id] ?? null;
                if (! $t) {
                    continue;
                }
                $used = $usedOf[$id] ??= static::used($t);
                $room = static::cap($t) - $used;
                if (! $best || $room > $best['room']) {
                    $best = ['id' => $t->id, 'number' => (string) $t->trip_number, 'used' => $used, 'cap' => static::cap($t), 'room' => $room];
                }
            }
            $kind = $best ? ($best['room'] >= min($combos->min('space'), 1) ? 'open' : 'full') : 'closed';
            [$fit] = $best ? static::pick($combos, max(0, $best['room'])) : [collect()];
            $first = $combos->first();
            if (! $best && ($cl = collect($closed[$key] ?? [])->map(fn ($id) => $trips[$id] ?? null)->filter()->first())) {
                $best = ['id' => $cl->id, 'number' => (string) $cl->trip_number, 'used' => 0, 'cap' => static::cap($cl), 'room' => 0, 'locked' => true,
                    'state' => $cl->is_lock ? 'Locked' : 'On the road'];
            }
            $out[] = [
                'key' => $key, 'city' => $first['city'], 'province' => $first['province'], 'n' => (int) $combos->sum('n'), 'space' => (float) $combos->sum('space'),
                'combos' => static::order($combos)->map(fn ($c) => $c + ['fits' => $fit->contains('key', $c['key'])])->all(),
                'kind' => $kind, 'trip' => $best, 'fit' => $fit->pluck('key')->all(), 'newN' => (int) ($combos->sum('n') - $fit->sum('n')),
            ];
        }

        return collect($out)->sortBy(fn ($r) => [['open' => 0, 'full' => 1, 'closed' => 2][$r['kind']], $r['province'], $r['city']])->values()->all();
    }

    /**
     * Add picked combos of a city to a trip. Over the room needs $anyway and a reason (saved with the name).
     *
     * @return array{ok: bool, msg: string, added?: int}
     */
    public static function addPicked(User $user, string $cityKey, int $tripId, array $comboKeys, bool $anyway = false, ?string $reason = null): array
    {
        $row = collect(static::newBoxes($user))->firstWhere('key', $cityKey);
        $trip = Deliverylog::where('logistichub_id', $user->logistichub_id)->find($tripId);
        if (! $row || ! $trip || ! $trip->is_active) {
            return ['ok' => false, 'msg' => 'These boxes or this trip changed. Look again.'];
        }
        if ($trip->is_lock || (Schema::hasColumn('deliverylogs', 'taken_at') && $trip->taken_at)) {
            return ['ok' => false, 'msg' => 'Trip '.$trip->trip_number.' is locked or on the road: no more boxes join. Make a new trip.'];
        }
        $picked = collect($row['combos'])->whereIn('key', $comboKeys);
        if ($picked->isEmpty()) {
            return ['ok' => false, 'msg' => 'Pick at least one box.'];
        }
        $over = static::used($trip) + $picked->sum('space') - static::cap($trip);
        if ($over > 0.001 && ! $anyway) {
            return ['ok' => false, 'msg' => 'Over the space of '.$trip->trip_number.'. Use Add anyway (space is an estimate).'];
        }
        if ($over > 0.001 && blank($reason)) {
            return ['ok' => false, 'msg' => 'Add anyway needs a reason.'];
        }
        $added = static::addInvoices($trip, $picked);
        if ($over > 0.001) {
            TripRules::record(self::RULE, $user, $reason, ['trip_id' => $trip->id, 'trip_number' => $trip->trip_number,
                'note' => 'Add anyway: '.$added.' new '.Str::plural('box', $added).' of '.$row['city'].' over the estimate']);
        }

        return ['ok' => true, 'added' => $added, 'msg' => $added.' '.Str::plural('box', $added).' added to '.$trip->trip_number.' as “Not loaded”'.($over > 0.001 ? ' (Add anyway, saved with your name)' : '').'.'];
    }

    /**
     * A new trip for the waiting boxes of these cities (one trip per province), with a free truck,
     * else the truck that is free first (the trip waits for it).
     *
     * @return list<array{id: int, number: string, truck: ?string}>
     */
    public static function newTrips(User $user, array $cityKeys, ?string $why = null): array
    {
        $ct = new CityTrips($user);
        $keys = array_flip($cityKeys);
        $places = $ct->places()->filter(fn ($p) => isset($keys[static::cityKey($p['province'], $p['city'])]));
        if ($places->isEmpty()) {
            return [];
        }
        $trucks = $ct->trucks();
        $slots = $trucks->where('state', 'free')->values()->merge($trucks->where('state', 'busy')->values());
        $si = 0;
        $trips = [];
        foreach ($places->groupBy('province') as $prov => $cities) {
            $slot = $slots[$si++] ?? null;
            $trips[] = ['province' => $prov, 'cities' => $cities->map(fn ($c) => ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space'], 'via' => []])->values()->all(),
                'load' => (int) $cities->sum('space'), 'cap' => $slot['capacity'] ?? CityTrips::DEFAULT_CAPACITY, 'truck_id' => $slot['id'] ?? null, 'on' => true,
                'why' => $why ?? 'New boxes for cities whose trip is full, locked or on the road.'];
        }
        $ct->made = ['ai' => true, 'instruction' => 'New boxes after the trips were made'];

        return $ct->create($trips, today());
    }

    /** Apply: every city's boxes to its trip with room; the rest on new trips. */
    public static function applyAll(User $user): array
    {
        $added = 0;
        $toNew = [];
        foreach (static::newBoxes($user) as $r) {
            if ($r['kind'] === 'open' && $r['fit']) {
                $res = static::addPicked($user, $r['key'], $r['trip']['id'], $r['fit']);
                $added += $res['added'] ?? 0;
                if ($r['newN'] > 0) {
                    $toNew[] = $r['key'];
                }
            } else {
                $toNew[] = $r['key'];
            }
        }
        $made = $toNew ? static::newTrips($user, $toNew) : [];

        return ['added' => $added, 'made' => $made];
    }

    // ------------------------------------------------------------------ partner hub unload scan

    /** The hub's own trips open for boxes (not locked, not left). */
    protected static function hubOpenTrips(int $hubId, string $cityKey): Collection
    {
        if (! CityTrips::ready()) {
            return collect();
        }
        $ids = TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where('d.logistichub_id', $hubId)->where('d.assigned_to', $hubId)
            ->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->when(Schema::hasColumn('deliverylogs', 'taken_at'), fn ($q) => $q->whereNull('d.taken_at'))
            ->get(['trip_cities.province', 'trip_cities.city', 'd.id'])
            ->filter(fn ($r) => static::cityKey($r->province, $r->city) === $cityKey)->pluck('id')->unique();

        return Deliverylog::with('truck')->whereIn('id', $ids)->orderBy('id')->get();
    }

    /** Boxes of the same combo (same receiver, or same set) waiting at the hub or still on the truck. */
    protected static function siblings(Tripinvoice $row, int $hubId): Collection
    {
        $inv = $row->invdata;
        if (! $inv) {
            return collect();
        }
        $rk = TripPlanner::receiverKey($inv);
        $cands = Tripinvoice::with('invdata')->where('logistichub_id', $hubId)->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->whereKeyNot($row->id)
            ->whereHas('invdata', fn ($q) => $q->where('receiver_city', $inv->receiver_city))->limit(200)->get();

        return $cands->filter(fn ($t) => $t->invdata && (TripPlanner::receiverKey($t->invdata) === $rk || ($inv->set_key && $t->invdata->set_key === $inv->set_key)))->values();
    }

    /**
     * Scan app · Receive truck at a partner hub: put the box on the hub's open trip of its city.
     * Its combo goes where the rest of the combo is. Full → a new hub trip (Add anyway offered).
     *
     * @return ?array{trip: string, tripId: int, why: string, kind: string, full?: array{id: int, number: string}}
     */
    public static function placeAtHub(Tripinvoice $row, int $hubId, ?User $by = null): ?array
    {
        $row->loadMissing('invdata');
        if ($row->hub_assigned || $row->deliveryloghub_id || ! $row->invdata) {
            return null;
        }
        $inv = $row->invdata;
        $key = static::cityKey($inv->receiver_province, $inv->receiver_city);
        $open = static::hubOpenTrips($hubId, $key);
        $sib = static::siblings($row, $hubId);
        $space = BoxSizes::spaceOf($inv->boxtype);
        $assign = app(TripAssignment::class);

        // the combo's other boxes are already on an open trip: this one goes with them (never split)
        $with = $sib->first(fn ($s) => $s->deliveryloghub_id && $open->contains('id', $s->deliveryloghub_id));
        if ($with) {
            $trip = $open->firstWhere('id', $with->deliveryloghub_id);
            $assign->addToHubTrip($trip, [$row]);
            static::countCities($trip, true);

            return ['trip' => $trip->trip_number, 'tripId' => $trip->id, 'kind' => 'ok', 'why' => 'With the rest of its combo ('.$inv->receiver_name.') · '.static::fmt($trip)];
        }
        if ($open->isEmpty()) {
            return null; // no trip for this city yet: Plan trips makes it
        }
        // room for the box and the rest of its combo still coming
        $need = $space + $sib->filter(fn ($s) => ! $s->deliveryloghub_id)->sum(fn ($s) => BoxSizes::spaceOf($s->invdata?->boxtype));
        $fits = $open->first(fn ($t) => static::cap($t) - static::used($t) >= $need - 0.001);
        if ($fits) {
            $assign->addToHubTrip($fits, [$row]);
            static::countCities($fits, true);

            return ['trip' => $fits->trip_number, 'tripId' => $fits->id, 'kind' => 'ok', 'why' => 'Added · '.static::fmt($fits)];
        }
        // full: a new hub trip with a free truck (made at unload, by the AI)
        $full = $open->first();
        $new = static::newHubTrip($hubId, $inv, $by);
        $assign->addToHubTrip($new, [$row]);
        static::countCities($new, true);

        return ['trip' => $new->trip_number, 'tripId' => $new->id, 'kind' => 'new', 'full' => ['id' => $full->id, 'number' => (string) $full->trip_number],
            'why' => $full->trip_number.' is full ('.static::fmt($full).') · new trip '.$new->trip_number.($new->truck ? ' with '.$new->truck->plate_no : ' (no free truck yet)')];
    }

    /** "34 of 35" */
    public static function fmt(Deliverylog $trip): string
    {
        return BoxSizes::fmt(static::used($trip)).' of '.static::cap($trip);
    }

    /** A new hub trip for one city: the hub's free truck (else none yet). */
    protected static function newHubTrip(int $hubId, Invoice $inv, ?User $by): Deliverylog
    {
        $user = $by ?? User::where('logistichub_id', $hubId)->first();
        $ct = new CityTrips($user, true);
        // a free truck that is not on another open trip
        $onTrips = Deliverylog::where('is_active', true)->whereNotNull('truck_id')->pluck('truck_id')->flip();
        $free = $ct->trucks()->where('state', 'free')->first(fn ($t) => ! isset($onTrips[$t['id']]));
        $truck = $free ? Truck::find($free['id']) : null;

        return DB::transaction(function () use ($hubId, $inv, $user, $truck) {
            $trip = Deliverylog::create([
                'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => today()->addDay()->toDateString(), 'departure_date' => today()->addDay()->toDateString(),
                'logistichub_id' => $hubId, 'assigned_to' => $hubId, 'user_id' => $user?->id,
                'plan_why' => 'The trip for '.Str::title((string) $inv->receiver_city).' was full when the boxes were unloaded.',
            ] + (Schema::hasColumn('deliverylogs', 'made_by') ? ['made_by' => 'ai', 'made_note' => 'New trip at unload (trip full)'] : []));
            TripCity::create(['deliverylog_id' => $trip->id, 'province' => Str::title((string) $inv->receiver_province), 'city' => Str::title((string) $inv->receiver_city),
                'city_key' => Barangays::cityKey((string) $inv->receiver_city), 'planned_boxes' => 0]);
            if ($truck && ! $truck->is_assigned) {
                $truck->update(['is_assigned' => true]);
            }

            return $trip->fresh('truck');
        });
    }

    /** Add anyway at the hub: move the box (and its combo) from the new trip to the full one. */
    public static function hubAddAnyway(Tripinvoice $row, int $fullTripId, User $by, ?string $reason = null): array
    {
        $full = Deliverylog::where('logistichub_id', $by->logistichub_id)->find($fullTripId);
        if (! $full || ! $full->is_active || $full->is_lock || (Schema::hasColumn('deliverylogs', 'taken_at') && $full->taken_at)) {
            return ['ok' => false, 'msg' => 'That trip is locked or left: the box stays on the new trip.'];
        }
        $from = $row->deliveryloghub_id ? Deliverylog::find($row->deliveryloghub_id) : null;
        $move = collect([$row])->merge(static::siblings($row, (int) $by->logistichub_id)->filter(fn ($s) => $from && (int) $s->deliveryloghub_id === $from->id));
        foreach ($move as $m) {
            $m->update(['deliveryloghub_id' => $full->id, 'hub_assigned' => true]);
        }
        static::countCities($full, true);
        TripRules::record(self::RULE, $by, $reason ?: 'It still fits (crew)', ['trip_id' => $full->id, 'trip_number' => $full->trip_number, 'box' => $row->invoice,
            'note' => 'Add anyway at unload: '.$move->count().' '.Str::plural('box', $move->count()).' over the estimate']);
        // the new trip is empty now: take it away and free its truck
        if ($from && $from->id !== $full->id && ! Tripinvoice::where('deliveryloghub_id', $from->id)->exists() && (string) ($from->made_note ?? '') === 'New trip at unload (trip full)') {
            $from->truck?->update(['is_assigned' => false]);
            TripCity::where('deliverylog_id', $from->id)->delete();
            $from->delete();
        } elseif ($from) {
            static::countCities($from, true);
        }

        return ['ok' => true, 'msg' => $move->count().' '.Str::plural('box', $move->count()).' on '.$full->trip_number.' anyway ('.static::fmt($full).').'];
    }
}
