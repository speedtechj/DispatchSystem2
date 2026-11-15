<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Truckcrew extends Model
{
    /** The truck team changed: trips of this truck that did not leave yet follow it (swaps made for one trip stay). */
    protected static function booted(): void
    {
        static::created(fn (Truckcrew $c) => \App\Support\TripFlow::teamChanged((int) $c->truck_id, (int) $c->crew, true));
        static::deleted(fn (Truckcrew $c) => \App\Support\TripFlow::teamChanged((int) $c->truck_id, (int) $c->crew, false));
    }

    public function truck()
    {
        return $this->belongsTo(Truck::class);
    }
    public function user() {
        return $this->belongsTo(User::class);
    }
    
}
