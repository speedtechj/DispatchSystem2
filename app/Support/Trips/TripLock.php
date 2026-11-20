<?php

namespace App\Support\Trips;

use App\Models\AppSetting;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\TripFlow;

/**
 * Lock a trip only when it is ready: every box loaded, the truck here, a lead man on the crew.
 * The office locks it on the Trip page; the trip also locks by itself when the lead man takes it (Driver app).
 */
class TripLock
{
    public const RULE = 'lock_ready';

    /**
     * The three checks.
     *
     * @return list<array{key: string, ok: bool, title: string, sub: string}>
     */
    public static function checks(Deliverylog $trip): array
    {
        $main = Tripinvoice::where('deliverylog_id', $trip->id);
        $own = Tripinvoice::where('deliveryloghub_id', $trip->id);
        $total = (clone $main)->count() + (clone $own)->count();
        $loaded = (clone $main)->where('is_loaded', true)->count() + (clone $own)->where('is_loaded_hub', true)->count();
        $busy = TripFlow::ready() ? TripFlow::waitsFor($trip) : null;
        $crew = TripFlow::ready() ? TripFlow::crew($trip) : collect();
        $lead = $crew->first(fn ($c) => TripFlow::isLead($c));
        $plate = (string) $trip->truck?->plate_no;

        return [
            ['key' => 'boxes', 'ok' => $total > 0 && $loaded >= $total, 'title' => 'All boxes loaded',
                'sub' => $total === 0 ? 'No boxes on the trip yet' : ($loaded >= $total ? $total.' of '.$total.' boxes' : $loaded.' of '.$total.': '.($total - $loaded).' still to load')],
            ['key' => 'truck', 'ok' => $trip->truck_id && ! $busy, 'title' => 'Truck is here',
                'sub' => ! $trip->truck_id ? 'No truck on the trip yet' : ($busy ? $plate.' is still on '.$busy->trip_number : $plate.' is free for this trip')],
            ['key' => 'crew', 'ok' => (bool) $lead, 'title' => 'Crew is ready',
                'sub' => $lead ? $crew->map(fn ($c) => \Illuminate\Support\Str::before((string) $c->user?->full_name, ' ').(TripFlow::isLead($c) ? ' (lead man)' : ''))->filter()->join(' · ') : 'No lead man on this trip: set it with Crew on this trip'],
        ];
    }

    public static function isReady(Deliverylog $trip): bool
    {
        return collect(static::checks($trip))->every('ok');
    }

    /** What is missing, in words: "not every box is loaded, no lead man". */
    public static function missing(Deliverylog $trip): string
    {
        $words = ['boxes' => 'not every box is loaded', 'truck' => 'the truck is not here', 'crew' => 'no lead man'];

        return collect(static::checks($trip))->reject(fn ($c) => $c['ok'])->map(fn ($c) => $words[$c['key']])->join(', ');
    }

    /** The trip locks by itself when the lead man takes it (if every check is green). */
    public static function autoOnTake(): bool
    {
        return (string) AppSetting::get('rules.lock_on_take', '1') === '1';
    }

    public static function setAutoOnTake(bool $on): void
    {
        AppSetting::put('rules.lock_on_take', $on ? '1' : '0');
    }

    /**
     * Lock the trip. Not ready: allowed by the trip rules (off, or with a reason), else the office is asked.
     *
     * @return string locked | reason | office
     */
    public static function lock(Deliverylog $trip, ?User $by, ?string $reason = null): string
    {
        if ($trip->is_lock) {
            return 'locked';
        }
        if (! static::isReady($trip)) {
            $need = TripRules::need(self::RULE, $by);
            if ($need === 'office') {
                TripRules::ask(self::RULE, $by, $reason, ['trip_id' => $trip->id, 'trip_number' => $trip->trip_number, 'note' => 'Not ready: '.static::missing($trip)]);

                return 'office';
            }
            if ($need === 'reason' && blank($reason)) {
                return 'reason';
            }
            TripRules::record(self::RULE, $by, $reason ?: null, ['trip_id' => $trip->id, 'trip_number' => $trip->trip_number, 'note' => 'Locked not ready: '.static::missing($trip)]);
        }
        $trip->update(['is_lock' => true]);

        return 'locked';
    }
}
