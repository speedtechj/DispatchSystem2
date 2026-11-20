<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/** A day a rental truck is booked. */
class TruckBooking extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['day' => 'date'];
    }
}
