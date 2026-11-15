<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Facades\Auth;
use RuntimeException;

class Deliverylog extends Model
{
    protected function casts(): array
    {
        return [
            'eta' => 'date',
            'departure_date' => 'date',
            'delivery_date' => 'date',
            'is_current' => 'boolean',
            'is_active' => 'boolean',
            'is_lock' => 'boolean',
            'taken_at' => 'datetime',
            'back_at' => 'datetime',
            'closed_at' => 'datetime',
        ];
    }

    protected static function booted(): void
    {
        static::creating(function (Deliverylog $trip): void {
            if (filled($trip->trip_number)) {
                return;
            }

            $hubId = Auth::user()?->logistichub_id ?? $trip->logistichub_id;
            $hub = Logistichub::find($hubId);

            if (! $hub) {
                throw new RuntimeException('Cannot create a trip: your account is not linked to a logistic hub.');
            }

            $trip->trip_number = $hub->hub_code.$hub->nextTripNumber();
        });

        // Trip steps: the crew of the trip is copied from the truck team (and follows a truck change).
        static::created(fn (Deliverylog $trip) => \App\Support\TripFlow::copyCrew($trip));
        static::updated(function (Deliverylog $trip): void {
            if ($trip->wasChanged('truck_id')) {
                \App\Support\TripFlow::truckChanged($trip);
            }
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

    public function logistichub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class);
    }

    /** The hub this trip is going to. */
    public function destination(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'assigned_to');
    }

    public function tripinvoices(): HasMany
    {
        return $this->hasMany(Tripinvoice::class);
    }

    /** Invoices handed over to this trip by a partner hub. */
    public function hubTripinvoices(): HasMany
    {
        return $this->hasMany(Tripinvoice::class, 'deliveryloghub_id');
    }
}
