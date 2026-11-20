<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/** One bypass of a trip rule, or a request waiting for the office. */
class TripOverride extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['data' => 'array', 'decided_at' => 'datetime'];
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public function decider()
    {
        return $this->belongsTo(User::class, 'decided_by');
    }
}
