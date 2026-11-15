<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\TripCrew;
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

    // ------------------------------------------------------------------ steps

    public static function stage(Deliverylog $trip): string
    {
        if (! $trip->is_active) {
            return 'closed';
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
        if ($trip->is_current || Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->exists()) {
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
            $trip->forceFill(['closed_at' => now(), 'release_reason' => $auto ? 'auto' : $reason])->saveQuietly();
        }
    }

    // ------------------------------------------------------------------ crew of the trip

    /** Copy the truck team onto the trip, when it has no crew yet. */
    public static function copyCrew(Deliverylog $trip): void
    {
        if (! static::ready() || ! $trip->truck_id || TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            return;
        }
        $users = User::with('workposition')->whereIn('id', Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew'))->get();
        foreach ($users as $u) {
            TripCrew::firstOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $u->id], ['role' => $u->workposition?->position_description]);
        }
    }

    /** The truck changed before the trip left: take the new truck's team. */
    public static function truckChanged(Deliverylog $trip): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        TripCrew::where('deliverylog_id', $trip->id)->whereNull('replaces_user_id')->delete();
        static::copyCrew($trip);
    }

    /** Someone joined or left the truck team: update the trips of the truck that did not leave yet. */
    public static function teamChanged(int $truckId, int $userId, bool $joined): void
    {
        if (! static::ready() || ! $truckId || ! $userId) {
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
            }
        }
    }

    /** @return Collection<int, TripCrew> */
    public static function crew(Deliverylog $trip): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        static::copyCrew($trip);

        return TripCrew::with('user.workposition', 'replaces')->where('deliverylog_id', $trip->id)->orderBy('id')->get()
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
                ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('id')->first();
            if ($trip) {
                return $trip;
            }
        }
        $truckId = Truckcrew::where('crew', $user->getKey())->latest('id')->value('truck_id');
        if (! $truckId) {
            return null;
        }
        $trip = Deliverylog::with('truck')->where('truck_id', $truckId)->where('is_active', true)->latest('id')->first();
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
}
