<?php

namespace App\Models\Maps;

use Illuminate\Database\Eloquent\Model;

/** What we know about a receiver's place: their barangay, and where the driver delivered. */
class ReceiverPlace extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['lat' => 'float', 'lng' => 'float', 'confirmed_at' => 'datetime'];
    }
}
