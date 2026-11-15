<?php

namespace App\Support;

use App\Models\Shipping\TruckReceipt;
use Illuminate\Support\Facades\Schema;

/** Partner hubs that finished receiving a truck (their boxes on it count as done for the trip). */
class TruckReceiptReady
{
    /** @return list<int> */
    public static function finishedHubs(int $tripId): array
    {
        static $ready;
        $ready ??= Schema::hasTable('truck_receipts');

        return $ready ? TruckReceipt::where('deliverylog_id', $tripId)->whereNotNull('finished_at')->pluck('logistichub_id')->map(fn ($i) => (int) $i)->all() : [];
    }
}
