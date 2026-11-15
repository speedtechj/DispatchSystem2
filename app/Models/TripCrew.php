<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A person on one trip (copied from the truck team; can be changed for this trip only). */
class TripCrew extends Model
{
    protected $guarded = [];

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function replaces(): BelongsTo
    {
        return $this->belongsTo(User::class, 'replaces_user_id');
    }
}
