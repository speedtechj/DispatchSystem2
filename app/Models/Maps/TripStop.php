<?php

namespace App\Models\Maps;

use Illuminate\Database\Eloquent\Model;

/** One receiver on a trip: the stop number and where all their boxes go in the truck. */
class TripStop extends Model
{
    protected $table = 'trip_stops';

    protected $guarded = [];

    public const ZONES = ['front' => 'FRONT', 'middle' => 'MIDDLE', 'back' => 'BACK'];

    /** front is loaded first (deepest, next to the cab), back last (at the door). */
    public const RANK = ['front' => 0, 'middle' => 1, 'back' => 2];

    protected function casts(): array
    {
        return ['lat' => 'float', 'lng' => 'float', 'exact' => 'boolean', 'priority' => 'boolean', 'box_ids' => 'array'];
    }

    public function hasPin(): bool
    {
        return $this->lat !== null && $this->lng !== null;
    }

    public function zoneLabel(): string
    {
        return self::ZONES[$this->zone] ?? 'MIDDLE';
    }
}
