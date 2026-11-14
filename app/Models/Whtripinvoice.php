<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Whtripinvoice extends Model
{
    protected function casts(): array
    {
        return [
            'is_unloaded' => 'boolean',
            'is_loaded' => 'boolean',
            'is_active' => 'boolean',
            'is_locked' => 'boolean',
        ];
    }

    //
    public function whdeliverylog()
    {
        return $this->belongsTo(Whdeliverylog::class, 'whdeliverylog_id');
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public function truck()
    {

        return $this->belongsTo(Truck::class);
    }

    public function warehouse()
    {

        return $this->belongsTo(Warehouse::class);
    }

    public function invoice()
    {
        return $this->belongsTo(Invoice::class);
    }

    public function invdata()
    {
        return $this->belongsTo(Invoice::class);
    }
}
