<?php

namespace App\Models\Warehouses;

use App\Models\Warehouse;
use Illuminate\Database\Eloquent\Model;

/** A province (or one town of it) delivered by a warehouse. */
class WarehouseCoverage extends Model
{
    protected $guarded = [];

    public function warehouse()
    {
        return $this->belongsTo(Warehouse::class);
    }
}
