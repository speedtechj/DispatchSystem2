<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\DB;

class Logistichub extends Model
{
    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    /**
     * Reserve the next trip number for this hub.
     *
     * The row is locked while the counter is bumped, so two dispatchers
     * creating trips at the same moment can never get the same number.
     */
    public function nextTripNumber(): int
    {
        return DB::transaction(function (): int {
            $hub = static::query()->lockForUpdate()->findOrFail($this->getKey());
            $hub->increment('trip_counter');

            return $this->trip_counter = (int) $hub->trip_counter;
        });
    }
}
