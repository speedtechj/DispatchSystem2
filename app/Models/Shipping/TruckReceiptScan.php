<?php

namespace App\Models\Shipping;

use Illuminate\Database\Eloquent\Model;

/** One box scanned in at the partner hub off a truck. */
class TruckReceiptScan extends Model
{
    public $timestamps = false;

    protected $guarded = [];

    protected function casts(): array
    {
        return ['created_at' => 'datetime'];
    }
}
