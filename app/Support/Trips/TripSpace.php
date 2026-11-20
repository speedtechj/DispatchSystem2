<?php

namespace App\Support\Trips;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Support\BoxSizes;
use App\Support\TruckSpace;

/** How full the truck of a trip is while loading. */
class TripSpace
{
    /** Only for trucks whose space is set (by hand or from the cargo size). */
    public static function capacity(Deliverylog $trip): ?int
    {
        $t = $trip->truck;
        if (! $t || ! ($t->capacity || TruckSpace::fit($t))) {
            return null;
        }

        return TruckSpace::capacity($t);
    }

    public static function used(Deliverylog $trip): float
    {
        return (float) Tripinvoice::with('invdata:id,boxtype')->where('deliverylog_id', $trip->id)->where('is_loaded', true)->get()
            ->sum(fn ($r) => BoxSizes::spaceOf($r->invdata?->boxtype));
    }

    /** The box does not fit: [used, cap, space]; null when it fits or the truck space is not set. */
    public static function overFull(Deliverylog $trip, Invoice $box): ?array
    {
        $cap = static::capacity($trip);
        if (! $cap) {
            return null;
        }
        $used = static::used($trip);
        $sp = BoxSizes::spaceOf($box->boxtype);

        return $used + $sp > $cap ? ['used' => BoxSizes::fmt($used), 'cap' => $cap, 'space' => BoxSizes::fmt($sp)] : null;
    }
}
