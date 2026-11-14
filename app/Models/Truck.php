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
}
