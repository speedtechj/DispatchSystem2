<?php

namespace App\Models\Fuel;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** A fuel card statement file that was imported. */
class FuelStatement extends Model
{
    protected $table = 'fuel_statements';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['from' => 'date', 'to' => 'date'];
    }

    public function lines(): HasMany
    {
        return $this->hasMany(FuelStatementLine::class);
    }
}
