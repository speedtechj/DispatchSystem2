<?php

namespace App\Models\Fuel;

use App\Models\Deliverylog;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** Fuel cash given for a trip, and how it was settled (change returned). */
class FuelCash extends Model
{
    protected $table = 'fuel_cash';

    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'km' => 'float', 'km_per_liter' => 'float', 'price' => 'float', 'estimate' => 'float', 'given' => 'float',
            'returned' => 'float', 'given_at' => 'datetime', 'settled_at' => 'datetime',
        ];
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function givenBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'given_by');
    }

    public function settledBy(): BelongsTo
    {
        return $this->belongsTo(User::class, 'settled_by');
    }

    /** Cash receipts for this trip. */
    public function spent(): float
    {
        return (float) FuelFill::where('deliverylog_id', $this->deliverylog_id)->where('paid_with', 'cash')->sum('total');
    }

    public function left(): float
    {
        return round($this->given - $this->spent(), 2);
    }
}
