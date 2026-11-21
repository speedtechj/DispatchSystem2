<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A person on one trip (copied from the truck team; can be changed for this trip only). */
class TripCrew extends Model
{
    protected $guarded = [];

    protected static function booted(): void
    {
        static::saved(fn () => \App\Support\TripFlow::forgetCrew());
        static::deleted(fn () => \App\Support\TripFlow::forgetCrew());
    }

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
