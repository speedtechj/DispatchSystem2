<?php

namespace App\Support\Maps;

use App\Models\Invoice;
use App\Support\Ai\TripPlanner;

/** Same receiver, the way the trip planner counts it. */
class TripPlannerKey
{
    public static function of(Invoice $i): string
    {
        return TripPlanner::receiverKey($i);
    }
}
