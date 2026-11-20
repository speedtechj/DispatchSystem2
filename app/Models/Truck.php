<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Truck extends Model
{
    protected function casts(): array
    {
        return [
            'is_active' => 'boolean',
            'is_assigned' => 'boolean',
            'date_registered' => 'date',
            'date_expired' => 'date',
            'rate_trip' => 'float',
            'rate_day' => 'float',
            'rate_km' => 'float',
        ];
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public function truckcrews()
    {
        return $this->hasMany(Truckcrew::class);
    }

    public function rentalCompany()
    {
        return $this->belongsTo(RentalCompany::class);
    }

    public function bookings()
    {
        return $this->hasMany(TruckBooking::class);
    }

    public function isRental(): bool
    {
        return ($this->ownership ?? 'own') === 'rental';
    }

    public function logistichub()
    {
        return $this->belongsTo(Logistichub::class);
    }
}
