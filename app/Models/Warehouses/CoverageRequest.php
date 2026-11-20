<?php

namespace App\Models\Warehouses;

use App\Models\User;
use App\Models\Warehouse;
use Illuminate\Database\Eloquent\Model;

/** A warehouse asks to take a province that belongs to another warehouse; the admin decides. */
class CoverageRequest extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['decided_at' => 'datetime'];
    }

    public function warehouse()
    {
        return $this->belongsTo(Warehouse::class);
    }

    public function fromWarehouse()
    {
        return $this->belongsTo(Warehouse::class, 'from_warehouse_id');
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }
}
