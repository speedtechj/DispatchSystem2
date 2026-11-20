<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class TruckMerge extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['moved' => 'array', 'before' => 'array', 'undone_at' => 'datetime'];
    }

    public function kept()
    {
        return $this->belongsTo(Truck::class, 'kept_id');
    }

    public function dropped()
    {
        return $this->belongsTo(Truck::class, 'dropped_id');
    }
}
