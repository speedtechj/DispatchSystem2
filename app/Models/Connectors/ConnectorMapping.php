<?php

namespace App\Models\Connectors;

use Illuminate\Database\Eloquent\Model;

/** Our event (code or code@place) → the consolidator's own status (Part 47). */
class ConnectorMapping extends Model
{
    protected $guarded = ['id'];

    protected function casts(): array
    {
        return ['skip' => 'boolean'];
    }
}
