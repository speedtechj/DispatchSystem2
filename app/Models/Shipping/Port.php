<?php

namespace App\Models\Shipping;

use Illuminate\Database\Eloquent\Model;

/** A sea port, for Container and RoRo (board 64). */
class Port extends Model
{
    protected $guarded = [];

    public const KINDS = ['both' => 'Container and RoRo', 'container' => 'Container', 'roro' => 'RoRo'];

    protected function casts(): array
    {
        return ['is_active' => 'boolean', 'lat' => 'float', 'lng' => 'float'];
    }
}
