<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Facades\Auth;
use RuntimeException;

class Whdeliverylog extends Model
{
    protected function casts(): array
    {
        return [
            'departure_date' => 'date',
            'delivery_date' => 'date',
            'is_active' => 'boolean',
            'is_lock' => 'boolean',
            'truck_here' => 'boolean',
            'truck_here_at' => 'datetime',
        ];
    }

    protected static function booted(): void
    {
        // "The truck is here now" turns off by itself when the trip is locked or closed.
        static::saving(function (Whdeliverylog $trip): void {
            if ($trip->truck_here && ($trip->is_lock || $trip->is_active === false)) {
                $trip->truck_here = false;
            }
        });

        static::creating(function (Whdeliverylog $trip): void {
            if (filled($trip->trip_number)) {
                return;
            }

            $warehouse = Warehouse::find(Auth::user()?->warehouse_id ?? $trip->warehouse_id);

            if (! $warehouse) {
                throw new RuntimeException('Cannot create a trip: your account is not linked to a warehouse.');
            }

            $trip->trip_number = $warehouse->id.$warehouse->nextTripNumber();
        });
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function truck(): BelongsTo
    {
        return $this->belongsTo(Truck::class);
    }

    public function warehouse(): BelongsTo
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function whtripinvoices(): HasMany
    {
        return $this->hasMany(Whtripinvoice::class);
    }
}
