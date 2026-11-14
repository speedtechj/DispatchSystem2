<?php

namespace App\Support\Maps;

use App\Models\Deliverylog;
use Illuminate\Support\Facades\Schema;
use Throwable;

/**
 * When boxes are added to or taken off a trip, the trip is sorted again right
 * after the page has answered (so nobody waits for the map).
 */
class SortQueue
{
    protected static array $trips = [];

    protected static bool $armed = false;

    public static function touch(...$ids): void
    {
        foreach ($ids as $id) {
            if ($id) {
                static::$trips[(int) $id] = true;
            }
        }
        if (static::$trips && ! static::$armed) {
            static::$armed = true;
            app()->terminating(fn () => static::run());
        }
    }

    public static function run(): void
    {
        $ids = array_keys(static::$trips);
        static::$trips = [];
        static::$armed = false;
        try {
            if (! $ids || ! Schema::hasTable('trip_routes')) {
                return;
            }
            foreach (Deliverylog::whereKey($ids)->get() as $trip) {
                TripSorter::sort($trip, 40);
            }
        } catch (Throwable $e) {
            report($e);
        }
    }
}
