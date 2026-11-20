<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/** One city of a trip planned by city: its boxes join the trip when scanned onto the truck. */
class TripCity extends Model
{
    protected $guarded = [];

    public function deliverylog()
    {
        return $this->belongsTo(Deliverylog::class);
    }
}
