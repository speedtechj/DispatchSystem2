<?php

namespace App\Models\Maps;

use Illuminate\Database\Eloquent\Model;

/** How a trip was sorted: by which map, how far, and whether staff locked their own order. */
class TripRoute extends Model
{
    protected $table = 'trip_routes';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['locked' => 'boolean', 'km' => 'float', 'sorted_at' => 'datetime'];
    }
}
