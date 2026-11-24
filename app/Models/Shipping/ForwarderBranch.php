<?php

namespace App\Models\Shipping;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A forwarder's warehouse or pier: where our truck hands boxes over, or where a hub picks them up. */
class ForwarderBranch extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['lat' => 'float', 'lng' => 'float'];
    }

    public function forwarder(): BelongsTo
    {
        return $this->belongsTo(Forwarder::class);
    }

    /** "2GO Cebu · Pier 3, Cebu City · 8 AM–5 PM" */
    public function line(): string
    {
        return collect([$this->name, $this->address, $this->hours])->filter()->join(' · ');
    }
}
