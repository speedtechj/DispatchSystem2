<?php

namespace App\Models\Tracking;

use App\Models\Deliverylog;
use App\Models\Truck;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** Something to look at on a truck: stopped too long, no location, off the route, back with boxes. */
class TruckAlert extends Model
{
    protected $table = 'truck_alerts';

    protected $guarded = [];

    public const ICONS = ['stopped' => '⏸', 'no_signal' => '📡', 'off_route' => '↪', 'back_with_boxes' => '🏠'];

    protected function casts(): array
    {
        return ['lat' => 'float', 'lng' => 'float', 'started_at' => 'datetime', 'ended_at' => 'datetime', 'checked_at' => 'datetime', 'ai_actions' => 'array'];
    }

    public function truck(): BelongsTo
    {
        return $this->belongsTo(Truck::class);
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function checker(): BelongsTo
    {
        return $this->belongsTo(User::class, 'checked_by');
    }

    public function minutes(): int
    {
        return (int) $this->started_at->diffInMinutes($this->ended_at ?? now());
    }
}
