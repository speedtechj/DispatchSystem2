<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\TripCrew;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * A trip from plan to closed: Planned → Loading → Ready → On the road → Back → Closed.
 * Each trip keeps its own crew (copied from the truck team). The trip closes and the truck is
 * released by itself when every box is delivered or returned.
 */
class TripFlow
{
    /** key => [label, who moves it on, colour] */
    public const STAGES = [
        'waiting' => ['Next trip · waits for the truck', 'Automatic', 'gray'],
        'planned' => ['Planned', 'Office', 'info'],
        'loading' => ['Loading', 'Warehouse', 'warning'],
        'ready' => ['Ready', 'Office locked it', 'primary'],
        'road' => ['On the road', 'Driver', 'success'],
        'back' => ['Back', 'Driver', 'warning'],
        'closed' => ['Closed', 'Automatic', 'gray'],
    ];

    public const RELEASE_REASONS = [
        'done' => 'Trip done',
        'hub' => 'Boxes handed to the partner hub',
        'broke_down' => 'Truck broke down',
        'cancelled' => 'Trip cancelled',
        'other' => 'Other',
    ];

    public const SWAP_REASONS = ['sick' => 'Sick', 'day_off' => 'Day off', 'other_truck' => 'On another truck', 'other' => 'Other'];

    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Schema::hasTable('trip_crews') && Schema::hasColumn('deliverylogs', 'taken_at');
    }

    public static function queueReady(): bool
    {
        static $ready;

        return $ready ??= Schema::hasColumn('deliverylogs', 'waits_for');
    }

    // ------------------------------------------------------------------ next trip waiting

    /** Trips not waiting for another trip that still runs (the trip they waited for may be closed by hand). */
    public static function notWaiting($q)
    {
        return $q->where(fn ($q) => $q->whereNull('waits_for')
            ->orWhereIn('waits_for', Deliverylog::query()->select('id')->where('is_active', false)));
    }

    /** The trip that still runs on this truck (another one than $except). */
    public static function runningOn(?int $truckId, ?int $except = null): ?Deliverylog
    {
        return $truckId ? Deliverylog::where('truck_id', $truckId)->where('is_active', true)
            ->when($except, fn ($q) => $q->whereKeyNot($except))
            ->when(static::queueReady(), fn ($q) => static::notWaiting($q))->oldest('id')->first() : null;
    }

    /** Trips loaded once for a whole list (speed): [app id, id => trip]. Set by known(). */
    protected static array $known = [null, [], []];

    /** Remember these trips' "waits for" trips for this request, so stage() needs no query per row. */
    public static function known(iterable $trips): void
    {
        $ids = collect($trips)->pluck('waits_for')->filter()->unique()->values()->all();
        $tripIds = collect($trips)->pluck('id')->all();
        static::$known = [spl_object_id(app()), $ids && static::queueReady() ? Deliverylog::whereIn('id', $ids)->get()->keyBy('id')->all() : [],
            // trip id => has a loaded box (for stage(): loading)
            array_fill_keys(Tripinvoice::whereIn('deliverylog_id', $tripIds)->where('is_loaded', true)->distinct()->pluck('deliverylog_id')->all(), true) + array_fill_keys($tripIds, false)];
    }

    /** This trip waits for the truck's current trip to close. */
    public static function waitsFor(Deliverylog $trip): ?Deliverylog
    {
        if (! static::queueReady() || ! $trip->waits_for) {
            return null;
        }
        $before = static::$known[0] === spl_object_id(app()) && isset(static::$known[1][$trip->waits_for])
            ? static::$known[1][$trip->waits_for] : Deliverylog::find($trip->waits_for);

        return $before && $before->is_active ? $before : null;
    }

    /** The next trip planned for the same truck, waiting for this one. */
    public static function nextAfter(Deliverylog $trip): ?Deliverylog
    {
        return static::queueReady() ? Deliverylog::where('waits_for', $trip->id)->where('is_active', true)->oldest('id')->first() : null;
    }

    /** Truck list for a trip: free trucks, and trucks still out (the trip then waits for them). */
    public static function truckOptions(?int $hubId, ?int $tripId = null): array
    {
        // Own trucks, and rental trucks booked today (own first).
        $trucks = Rentals::usable(Truck::query()->where('is_active', 1)->when($hubId, fn ($q) => $q->where('logistichub_id', $hubId)))
            ->get()->sortBy(fn ($t) => [$t->isRental() ? 1 : 0, $t->plate_no])->values();

        return $trucks->mapWithKeys(function ($t) use ($tripId) {
            $on = $t->is_assigned ? static::runningOn($t->id, $tripId) : null;
            if ($t->is_assigned && ! $on && ! static::queueReady()) {
                return [];
            }

            return [$t->id => $t->plate_no.($t->isRental() ? ' · rental, '.(Rentals::rateText($t) ?: 'booked today') : '').($on ? ' · on '.$on->trip_number.' (this trip waits for it)' : '')];
        })->all();
    }

    // ------------------------------------------------------------------ steps

    public static function stage(Deliverylog $trip): string
    {
        if (! $trip->is_active) {
            return 'closed';
        }
        if (static::waitsFor($trip)) {
            return 'waiting';
        }
        if (static::ready() && $trip->back_at) {
            return 'back';
        }
        if (static::ready() && $trip->taken_at) {
            return 'road';
        }
        if ($trip->is_lock) {
            return 'ready';
        }
        $known = static::$known[0] === spl_object_id(app()) && array_key_exists($trip->id, static::$known[2]) ? static::$known[2][$trip->id] : null;
        if ($trip->is_current || ($known ?? Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->exists())) {
            return 'loading';
        }

        return 'planned';
    }

    public static function label(Deliverylog $trip): string
    {
        return static::STAGES[static::stage($trip)][0];
    }

    /** The leadman (or anyone on the crew) takes the trip: it is on the road, with the box count confirmed. */
    public static function take(Deliverylog $trip, ?User $by = null): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        $by ??= Auth::user();
        $trip->forceFill(['taken_at' => now(), 'taken_by' => $by?->id, 'taken_boxes' => static::boxes($trip)->count(), 'is_current' => true])->save();
    }

    /** The driver is back at the hub; boxes not delivered are scanned back with Return boxes. */
    public static function back(Deliverylog $trip): void
    {
        if (! static::ready() || $trip->back_at) {
            return;
        }
        $trip->forceFill(['back_at' => now(), 'taken_at' => $trip->taken_at ?? now()])->save();
        static::maybeClose($trip->fresh());
    }

    /** Boxes the trip still carries (main trip or a partner hub's own trip). */
    public static function boxes(Deliverylog $trip)
    {
        return Tripinvoice::query()->where(fn ($q) => $q->where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id));
    }

    /** Boxes still to deliver or return. Boxes a partner hub received off this truck count as done. */
    public static function left(Deliverylog $trip): int
    {
        $handed = TruckReceiptReady::finishedHubs($trip->id);

        return static::boxes($trip)->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->when($handed, fn ($q) => $q->where(fn ($q) => $q->whereNull('logistichub_id')->orWhereNotIn('logistichub_id', $handed)->orWhere('deliveryloghub_id', $trip->id)))
            ->count();
    }

    /** Close the trip and free the truck when nothing is left: every box delivered, returned or received by the hub. */
    public static function maybeClose(?Deliverylog $trip): bool
    {
        if (! $trip || ! static::ready() || ! $trip->is_active || ! $trip->truck_id) {
            return false;
        }
        // Every box delivered, returned (taken off the trip) or received by the partner hub.
        $total = static::boxes($trip)->count();
        if ($total === 0 ? ! $trip->back_at : static::left($trip) > 0) {
            return false;
        }
        static::release($trip, 'done', auto: true);

        return true;
    }

    /** Free the truck and close the trip (by itself, or by the office with a reason). */
    public static function release(Deliverylog $trip, string $reason = 'done', bool $auto = false): void
    {
        app(TripAssignment::class)->releaseTruck($trip);
        if (static::ready()) {
            $trip->forceFill(['closed_at' => now(), 'release_reason' => $auto ? 'auto' : $reason]
                // done by itself: the Delivered date fills in (board 45c)
                + ($auto && ! $trip->delivery_date ? ['delivery_date' => now()->toDateString()] : []))->saveQuietly();
        }
        // The next trip waiting for this truck starts now: the crew sees it right away.
        if ($next = static::nextAfter($trip)) {
            $next->forceFill(['waits_for' => null])->saveQuietly();
            // More trips planned for this truck: they now wait for the one that just started, in order.
            Deliverylog::where('waits_for', $trip->id)->where('is_active', true)->whereKeyNot($next->id)->update(['waits_for' => $next->id]);
            $trip->truck?->update(['is_assigned' => true]);
        }
    }

    // ------------------------------------------------------------------ crew of the trip

    /** Copy the truck team onto the trip, when it has no crew yet. */
    public static function copyCrew(Deliverylog $trip): void
    {
        if (! static::ready() || ! $trip->truck_id || TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            return;
        }
        // Only active people: someone made inactive stays off new trips.
        $users = User::with('workposition')->where('is_active', true)->whereIn('id', Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew'))->get();
        foreach ($users as $u) {
            TripCrew::firstOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $u->id], ['role' => $u->workposition?->position_description]);
        }
    }

    /** The truck changed before the trip left: take the new truck's team. */
    public static function truckChanged(Deliverylog $trip, ?int $oldTruckId = null): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        // The old truck's team leaves the trip; people the office picked by hand stay.
        $oldTeam = $oldTruckId ? Truckcrew::where('truck_id', $oldTruckId)->pluck('crew') : collect();
        TripCrew::where('deliverylog_id', $trip->id)->whereNull('replaces_user_id')->whereIn('user_id', $oldTeam)->delete();
        static::forgetCrew();
        if (! TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            static::copyCrew($trip);
        }
    }

    /** Someone joined or left the truck team: update the trips of the truck that did not leave yet. */
    public static function teamChanged(int $truckId, int $userId, bool $joined): void
    {
        if (! static::ready() || ! $truckId || ! $userId || ($joined && ! User::whereKey($userId)->where('is_active', true)->exists())) {
            return;
        }
        $trips = Deliverylog::where('truck_id', $truckId)->where('is_active', true)->whereNull('taken_at')->pluck('id');
        foreach ($trips as $tripId) {
            if ($joined) {
                if (! TripCrew::where('deliverylog_id', $tripId)->where('replaces_user_id', $userId)->exists()) {
                    TripCrew::firstOrCreate(['deliverylog_id' => $tripId, 'user_id' => $userId], ['role' => User::find($userId)?->workposition?->position_description]);
                }
            } else {
                TripCrew::where('deliverylog_id', $tripId)->where('user_id', $userId)->whereNull('replaces_user_id')->delete();
                static::forgetCrew();
            }
        }
    }

    /** @return Collection<int, TripCrew> */
    /** @var array<string, Collection> crew per trip, once per request (cleared when the crew changes) */
    protected static array $crewMemo = [];

    public static function forgetCrew(): void
    {
        static::$crewMemo = [];
    }

    public static function crew(Deliverylog $trip): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $key = spl_object_id(app()).':'.$trip->id;
        if (isset(static::$crewMemo[$key])) {
            return static::$crewMemo[$key];
        }
        static::copyCrew($trip);

        return static::$crewMemo[$key] = TripCrew::with('user.workposition', 'replaces')->where('deliverylog_id', $trip->id)->orderBy('id')->get()
            ->sortBy(fn ($c) => static::isLead($c) ? 0 : 1)->values();
    }

    public static function isLead(TripCrew $c): bool
    {
        return Str::contains(Str::lower((string) ($c->role ?? $c->user?->workposition?->position_description)), 'lead');
    }

    /** Who may tap "I take the trip": the leadman; anyone on the crew when there is no leadman. */
    public static function canTake(Deliverylog $trip, User $user): bool
    {
        $crew = static::crew($trip);
        $leads = $crew->filter(fn ($c) => static::isLead($c));

        return ($leads->isNotEmpty() ? $leads : $crew)->contains(fn ($c) => (int) $c->user_id === (int) $user->id);
    }

    /**
     * Set the crew for this trip only. People not in the truck team are marked as replacing
     * the team members left out.
     *
     * @param  list<int>  $userIds
     */
    public static function setCrew(Deliverylog $trip, array $userIds, ?string $reason = null): void
    {
        $userIds = array_values(array_unique(array_map('intval', $userIds)));
        $team = Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew')->map(fn ($i) => (int) $i)->unique()->values()->all();
        $out = array_values(array_diff($team, $userIds));
        TripCrew::where('deliverylog_id', $trip->id)->whereNotIn('user_id', $userIds)->delete();
        static::forgetCrew();
        $users = User::with('workposition')->whereIn('id', $userIds)->get()->keyBy('id');
        foreach ($userIds as $i => $id) {
            $isNew = ! in_array($id, $team, true);
            TripCrew::updateOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $id], [
                'role' => $users[$id]?->workposition?->position_description,
                'replaces_user_id' => $isNew ? ($out[$i] ?? $out[0] ?? null) : null,
                'reason' => $isNew ? $reason : null,
            ]);
        }
    }

    /** The trip a crew member works on now: newest active trip with them on its crew (or their truck's). */
    public static function tripFor(User $user): ?Deliverylog
    {
        if (static::ready()) {
            $trip = Deliverylog::with('truck')->where('is_active', true)
                ->when(static::queueReady(), fn ($q) => static::notWaiting($q))
                ->whereNotIn('id', \App\Support\Shipping\SeaTrucks::riderTripIds()) // board 62: a trip that goes with another truck is not driven
                ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('id')->first();
            if ($trip) {
                return $trip;
            }
        }
        $truckId = Truckcrew::where('crew', $user->getKey())->latest('id')->value('truck_id');
        if (! $truckId) {
            return null;
        }
        $trip = Deliverylog::with('truck')->where('truck_id', $truckId)->where('is_active', true)
            ->whereNotIn('id', \App\Support\Shipping\SeaTrucks::riderTripIds())
            ->when(static::queueReady(), fn ($q) => static::notWaiting($q))->latest('id')->first();
        // Someone replaced this person on that trip: it is not theirs.
        if ($trip && static::ready() && TripCrew::where('deliverylog_id', $trip->id)->exists()
            && ! TripCrew::where('deliverylog_id', $trip->id)->where('user_id', $user->id)->exists()) {
            return null;
        }

        return $trip;
    }

    /** The trip that closed in the last 12 hours, for the "Trip done" screen. */
    public static function justClosedFor(User $user): ?Deliverylog
    {
        if (! static::ready()) {
            return null;
        }

        return Deliverylog::with('truck')->where('is_active', false)->where('closed_at', '>=', now()->subHours(12))
            ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('closed_at')->first();
    }

    // ------------------------------------------------------------------ warnings (crew board)

    /** Crew people of the hub (null = all hubs). */
    public static function crewPeople(int|false|null $hub): Collection
    {
        return User::with('workposition')->where('is_crew', true)->where('is_active', true)
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))
            ->when($hub === false, fn ($q) => $q->whereRaw('1 = 0'))
            ->orderBy('first_name')->get();
    }

    /**
     * What needs a look now: trips ready but not taken, trucks back with boxes not returned,
     * trucks out very long, crew without a truck, trucks on a trip without crew.
     *
     * @return list<array{tone: string, text: string}>
     */
    public static function warnings(int|false|null $hub): array
    {
        if (! static::ready() || $hub === false) {
            return [];
        }
        $out = [];
        $trips = Deliverylog::with('truck:id,plate_no')->where('is_active', true)->whereNotNull('truck_id')
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->get();
        foreach ($trips as $t) {
            $stage = static::stage($t);
            if ($stage === 'ready' && $t->ready_at && $t->ready_at->lt(now()->subMinutes(30))) {
                $out[] = ['kind' => 'ready', 'trip' => $t, 'tone' => 'warn', 'text' => 'Trip '.$t->trip_number.' is ready since '.$t->ready_at->format('g:i A').' · nobody took it yet.'];
            }
            if ($stage === 'back' && $t->back_at?->lt(now()->subHours(2)) && ($left = static::left($t)) > 0) {
                $out[] = ['kind' => 'back', 'trip' => $t, 'tone' => 'warn', 'text' => 'Truck '.$t->truck?->plate_no.' is back since '.$t->back_at->format('g:i A').' · '.$left.' '.str('box')->plural($left).' not returned yet (Return boxes).'];
            }
            if ($stage === 'road' && $t->taken_at?->lt(now()->subHours(14))) {
                $out[] = ['kind' => 'road', 'trip' => $t, 'tone' => 'warn', 'text' => 'Truck '.$t->truck?->plate_no.' is on trip '.$t->trip_number.' since '.$t->taken_at->format('M j g:i A').'. Still out?'];
            }
            if (in_array($stage, ['ready', 'road'], true) && ! TripCrew::where('deliverylog_id', $t->id)->exists()) {
                $out[] = ['kind' => 'nocrew', 'trip' => $t, 'tone' => 'bad', 'text' => 'Trip '.$t->trip_number.' has no crew.'];
            }
        }
        foreach (Truckcrew::with('member', 'truck')->whereHas('member', fn ($q) => $q->where('is_active', false))->get() as $c) {
            if ($hub === null || (int) $c->truck?->logistichub_id === $hub) {
                $out[] = ['kind' => 'inactive', 'truck_id' => $c->truck_id, 'user_id' => $c->crew, 'tone' => 'warn', 'text' => ($c->member?->full_name ?? 'Someone').' is inactive but still on the team of '.($c->truck?->plate_no ?? 'a truck').'.'];
            }
        }
        // On the team of an active truck (a truck made inactive does not count).
        $onTruck = Truckcrew::whereHas('truck', fn ($q) => $q->where('is_active', true))->pluck('crew')->map(fn ($i) => (int) $i)->all();
        foreach (static::crewPeople($hub)->reject(fn ($u) => in_array((int) $u->id, $onTruck, true)) as $u) {
            $out[] = ['kind' => 'notruck', 'tone' => 'info', 'text' => $u->full_name.' has no truck.'];
        }

        return $out;
    }
}
