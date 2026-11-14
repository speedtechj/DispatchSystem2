<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\DB;

class Warehouse extends Model
{
    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    /**
     * Reserve the next warehouse trip number (row-locked, so it is unique
     * even when several people create trips at once).
     */
    public function nextTripNumber(): int
    {
        return DB::transaction(function (): int {
            $warehouse = static::query()->lockForUpdate()->findOrFail($this->getKey());
            $warehouse->increment('trip_no');

            return $this->trip_no = (int) $warehouse->trip_no;
        });
    }
}
