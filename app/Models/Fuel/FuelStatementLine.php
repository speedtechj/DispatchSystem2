<?php

namespace App\Models\Fuel;

use App\Models\Truck;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** One charge on a fuel card statement, matched to a fill from the Driver app. */
class FuelStatementLine extends Model
{
    protected $table = 'fuel_statement_lines';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['charged_at' => 'datetime', 'liters' => 'float', 'amount' => 'float'];
    }

    public function statement(): BelongsTo
    {
        return $this->belongsTo(FuelStatement::class, 'fuel_statement_id');
    }

    public function truck(): BelongsTo
    {
        return $this->belongsTo(Truck::class);
    }

    public function fuelFill(): BelongsTo
    {
        return $this->belongsTo(FuelFill::class, 'fuel_fill_id');
    }
}
