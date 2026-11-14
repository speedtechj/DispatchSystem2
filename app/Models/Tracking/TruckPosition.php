<?php

namespace App\Models\Tracking;

use Illuminate\Database\Eloquent\Model;

/** One location of a truck, sent by the Driver app or a GPS tracker during a trip. */
class TruckPosition extends Model
{
    protected $table = 'truck_positions';

    public $timestamps = false;

    protected $guarded = [];

    protected function casts(): array
    {
        return ['lat' => 'float', 'lng' => 'float', 'speed' => 'float', 'recorded_at' => 'datetime'];
    }
}
