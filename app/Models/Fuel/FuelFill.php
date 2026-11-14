<?php

namespace App\Models\Fuel;

use App\Models\Deliverylog;
use App\Models\Truck;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Support\Facades\Storage;

/** One fill: what the receipt says, how it was paid, the odometer, and the checks. */
class FuelFill extends Model
{
    protected $table = 'fuel_fills';

    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'filled_at' => 'datetime', 'liters' => 'float', 'price_per_liter' => 'float', 'total' => 'float', 'vatable' => 'float',
            'vat' => 'float', 'km_per_liter' => 'float', 'lat' => 'float', 'lng' => 'float', 'buyer_tin_ok' => 'boolean',
            'gps_ok' => 'boolean', 'ai_read' => 'boolean', 'ai_data' => 'array',
        ];
    }

    public function truck(): BelongsTo
    {
        return $this->belongsTo(Truck::class);
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function driver(): BelongsTo
    {
        return $this->belongsTo(User::class, 'driver_id');
    }

    public function receiptUrl(): ?string
    {
        return $this->receipt_path ? Storage::disk('public')->url($this->receipt_path) : null;
    }

    public function odometerUrl(): ?string
    {
        return $this->odometer_path ? Storage::disk('public')->url($this->odometer_path) : null;
    }
}
