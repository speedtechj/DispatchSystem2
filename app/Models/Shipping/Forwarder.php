<?php

namespace App\Models\Shipping;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** A company that carries LCL boxes by sea, with its branches (board 64). */
class Forwarder extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['is_active' => 'boolean', 'charge_rate' => 'float'];
    }

    public function branches(): HasMany
    {
        return $this->hasMany(ForwarderBranch::class)->orderBy('name');
    }
}
