<?php

namespace App\Support\Maps;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Maps\GeoPlace;
use App\Models\Maps\TripRoute;
use App\Models\Maps\TripStop;
use App\Models\Routearea;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Ai\TripPlanner;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Sorts a delivery trip: one stop per receiver (all their boxes together), the
 * stops in driving order, and a truck spot for every stop. The first stop is
 * delivered first, so its boxes go in last, at the door (BACK); the last stops
 * go in first, next to the cab (FRONT).
 */
class TripSorter
{
    public const SOURCES = [
        'google' => 'Sorted by Google Maps',
        'ors' => 'Sorted by OpenRouteService',
        'estimate' => 'Sorted by distance (straight line)',
        'barangay' => 'Sorted by barangay (no map key)',
        'manual' => 'Your own order (locked)',
    ];

    /** Trips that go to another hub carry all boxes to one place: no stops to sort. */
    public static function isTransfer(Deliverylog $trip): bool
    {
        return $trip->assigned_to && (int) $trip->assigned_to !== (int) $trip->logistichub_id
            && ! Tripinvoice::where('deliveryloghub_id', $trip->id)->exists();
    }

    public static function boxes(Deliverylog $trip): Builder
    {
        return Tripinvoice::query()->where(fn (Builder $q) => $q->where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id));
    }

    public static function canSee(?User $user, Deliverylog $trip): bool
    {
        if (! $user) {
            return false;
        }
        if ($user->hasRole('super_admin')) {
            return true;
        }

        return in_array((int) $user->logistichub_id, [(int) $trip->logistichub_id, (int) $trip->assigned_to], true);
    }

    public static function address(?Invoice $i): string
    {
        return collect([$i?->receiver_address, $i?->receiver_barangay, $i?->receiver_city, $i?->receiver_province])
            ->map(fn ($v) => Str::squish((string) $v))->filter()->unique()->push('Philippines')->join(', ');
    }

    /** Sort again only when boxes were added or removed since the last time. */
    public static function ensure(Deliverylog $trip, int $budget = 15): ?TripRoute
    {
        if (static::isTransfer($trip)) {
            return null;
        }
        $route = TripRoute::where('deliverylog_id', $trip->id)->first();
        if (! $route || $route->boxes_hash !== static::hash($trip) || ($route->waiting > 0 && MapSettings::provider() !== 'none')) {
            $route = static::sort($trip, $budget);
        }

        return $route;
    }

    public static function hash(Deliverylog $trip): string
    {
        return sha1(static::boxes($trip)->orderBy('id')->pluck('id')->join(','));
    }

    public static function sort(Deliverylog $trip, int $budget = 40, bool $unlock = false): ?TripRoute
    {
        if (static::isTransfer($trip)) {
            return null;
        }

        $boxes = static::boxes($trip)->with(Barangays::ready() ? ['invdata.barangayFill'] : ['invdata'])->get()->filter(fn ($b) => $b->invdata);
        // boxes with no barangay that were not filled in yet: try now (same receiver, map, driver GPS, AI)
        if (Barangays::ready() && Barangays::on('fill')) {
            $waiting = $boxes->map(fn ($b) => $b->invdata->barangayFill)->filter(fn ($f) => $f && $f->status === 'pending');
            if ($waiting->isNotEmpty()) {
                $waiting->each(fn ($f) => $f->setRelation('invoice', $boxes->first(fn ($b) => $b->invdata->id === $f->invoice_id)->invdata));
                Barangays::work(0, 10, $waiting->values());
            }
        }
        $route = TripRoute::firstOrNew(['deliverylog_id' => $trip->id]);
        if ($unlock) {
            $route->locked = false;
        }

        // one unit per receiver
        $areas = Routearea::whereIn('id', $boxes->pluck('invdata.routearea_id')->filter()->unique())->pluck('code', 'id');
        $units = $boxes->groupBy(fn ($b) => TripPlanner::receiverKey($b->invdata))->map(function (Collection $g, string $key) use ($areas) {
            $i = $g->first()->invdata;

            return [
                'key' => substr($key, 0, 40), 'inv' => $i, 'ids' => $g->pluck('id')->values()->all(), 'n' => $g->count(),
                'prio' => $g->contains(fn ($b) => $b->invdata->is_priority),
                'sortarea' => Str::lower(($areas[$i->routearea_id] ?? 'zzz').'|'.$i->receiver_province.'|'.$i->receiver_city.'|'.(Barangays::of($i) ?? '~').'|'.$i->receiver_name),
                'brgy' => (string) Barangays::of($i),
                'place' => Geocoder::place(static::address($i)),
            ];
        })->keyBy('key');

        $found = Geocoder::resolve($units->pluck('place'), $budget);

        $old = TripStop::where('deliverylog_id', $trip->id)->orderBy('stop_no')->pluck('receiver_key')->all();
        $source = null;
        $km = null;
        $minutes = null;

        if ($route->locked && $old) {
            $order = array_values(array_merge(array_intersect($old, $units->keys()->all()), array_diff($units->keys()->all(), $old)));
            $source = 'manual';
        } else {
            [$order, $source, $km, $minutes] = static::order($trip, $units);
        }

        $zones = static::zones(array_map(fn ($k) => $units[$k]['n'], $order));

        DB::transaction(function () use ($trip, $units, $order, $zones) {
            TripStop::where('deliverylog_id', $trip->id)->whereNotIn('receiver_key', $order ?: ['-'])->delete();
            foreach ($order as $n => $k) {
                $u = $units[$k];
                $i = $u['inv'];
                $pin = $u['place']->hasPin();
                TripStop::updateOrCreate(['deliverylog_id' => $trip->id, 'receiver_key' => $k], [
                    'stop_no' => $n + 1,
                    'name' => Str::title(Str::squish((string) $i->receiver_name)),
                    'address' => $u['place']->clean ?: collect([$i->receiver_address, $u['brgy'], $i->receiver_city])->filter()->map(fn ($v) => Str::title(Str::squish($v)))->join(', '),
                    'barangay' => Str::title(Str::squish($u['brgy'])),
                    'city' => Str::title(Str::squish((string) $i->receiver_city)),
                    'phone' => Str::limit((string) $i->receiver_mobile_no, 38, ''),
                    'lat' => $pin ? $u['place']->lat : null, 'lng' => $pin ? $u['place']->lng : null,
                    'exact' => $pin && $u['place']->exact,
                    'geo_place_id' => $u['place']->id,
                    'zone' => $zones[$n], 'boxes' => $u['n'], 'priority' => $u['prio'], 'box_ids' => $u['ids'],
                ] + (Barangays::ready() ? ['barangay_note' => Barangays::note($i)] : []));
            }
        });

        $route->fill([
            'source' => $source, 'km' => $km, 'minutes' => $minutes,
            'boxes_hash' => static::hash($trip),
            'waiting' => $units->filter(fn ($u) => $u['place']->status === 'pending' && $u['place']->tries < 3)->count(),
            'ai_fixed' => GeoPlace::whereIn('id', $units->pluck('place.id'))->whereNotNull('clean')->whereColumn('clean', '!=', 'raw')->count(),
            'sorted_at' => now(),
        ])->save();
        unset(static::$zoneMemo[$trip->id]);

        return $route;
    }

    /** @return array{0: list<string>, 1: string, 2: ?float, 3: ?int} */
    protected static function order(Deliverylog $trip, Collection $units): array
    {
        $prioFirst = MapSettings::priorityFirst();
        $pinned = $units->filter(fn ($u) => $u['place']->hasPin());
        $rest = $units->reject(fn ($u) => $u['place']->hasPin())->sortBy(fn ($u) => ($prioFirst && $u['prio'] ? '0' : '1').$u['sortarea']);

        if ($pinned->isEmpty()) {
            return [$rest->keys()->all(), 'barangay', null, null];
        }

        $start = MapSettings::startFor($trip->user?->warehouse_id, $trip->logistichub_id);
        $plan = RoutePlanner::plan($start ? [$start[0], $start[1]] : null,
            $pinned->map(fn ($u) => [$u['place']->lat, $u['place']->lng])->all(),
            $prioFirst ? $pinned->filter(fn ($u) => $u['prio'])->keys()->all() : []);
        $order = $plan['order'];

        // stops without a pin go right after a stop in the same barangay, else the same city, else at the end
        foreach ($rest as $k => $u) {
            $at = null;
            $val = fn ($unit, $field) => Str::lower(Str::squish((string) ($field === 'barangay' ? $unit['brgy'] : $unit['inv']->receiver_city)));
            foreach (['barangay', 'city'] as $field) {
                foreach ($order as $pos => $other) {
                    if ($val($units[$other], 'city') === $val($u, 'city') && ($field === 'city' || ($val($u, 'barangay') !== '' && $val($units[$other], 'barangay') === $val($u, 'barangay')))) {
                        $at = $pos;
                    }
                }
                if ($at !== null) {
                    break;
                }
            }
            if ($at === null) {
                $order[] = $k;
            } else {
                array_splice($order, $at + 1, 0, [$k]);
            }
        }

        return [$order, $plan['source'] === 'estimate' || ! $start ? 'estimate' : $plan['source'], $plan['km'], $plan['minutes']];
    }

    /**
     * Truck spot per stop, by boxes: the first third of the boxes delivered = BACK (door),
     * the middle third = MIDDLE, the last third = FRONT (next to the cab).
     *
     * @param  list<int>  $boxes  boxes per stop in delivery order
     * @return list<string>
     */
    public static function zones(array $boxes): array
    {
        $total = max(1, array_sum($boxes));
        $acc = 0;
        $out = [];
        foreach ($boxes as $n) {
            $mid = ($acc + $n / 2) / $total;
            $acc += $n;
            $out[] = $mid < 1 / 3 ? 'back' : ($mid < 2 / 3 ? 'middle' : 'front');
        }

        return $out;
    }

    /** Staff dragged a stop: keep their order from now on (locked). */
    public static function move(Deliverylog $trip, int $stopId, int $toIndex): void
    {
        $stops = TripStop::where('deliverylog_id', $trip->id)->orderBy('stop_no')->get()->values();
        $from = $stops->search(fn ($s) => $s->id === $stopId);
        if ($from === false) {
            return;
        }
        $list = $stops->all();
        $moving = array_splice($list, $from, 1);
        array_splice($list, max(0, min($toIndex, count($list))), 0, $moving);
        static::saveOrder($trip, collect($list));
    }

    public static function saveOrder(Deliverylog $trip, Collection $stops): void
    {
        $zones = static::zones($stops->pluck('boxes')->map(fn ($n) => (int) $n)->all());
        DB::transaction(function () use ($stops, $zones) {
            foreach ($stops->values() as $n => $s) {
                $s->update(['stop_no' => $n + 1, 'zone' => $zones[$n]]);
            }
        });
        TripRoute::updateOrCreate(['deliverylog_id' => $trip->id], ['locked' => true, 'source' => 'manual', 'km' => null, 'minutes' => null]);
        unset(static::$zoneMemo[$trip->id]);
    }

    public static function stops(Deliverylog $trip): Collection
    {
        return TripStop::where('deliverylog_id', $trip->id)->orderBy('stop_no')->get();
    }

    protected static array $zoneMemo = [];

    /** tripinvoice id => ['zone' => 'front', 'stop' => 3] for one trip. */
    public static function zoneMap(Deliverylog $trip): array
    {
        if (! isset(static::$zoneMemo[$trip->id])) {
            $map = [];
            foreach (TripStop::where('deliverylog_id', $trip->id)->get(['stop_no', 'zone', 'box_ids']) as $s) {
                foreach ($s->box_ids ?? [] as $id) {
                    $map[(int) $id] = ['zone' => $s->zone, 'stop' => $s->stop_no];
                }
            }
            static::$zoneMemo[$trip->id] = $map;
        }

        return static::$zoneMemo[$trip->id];
    }
}
