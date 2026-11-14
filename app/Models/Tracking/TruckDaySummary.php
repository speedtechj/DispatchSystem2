<?php

namespace App\Models\Tracking;

use Illuminate\Database\Eloquent\Model;

/** The end-of-day summary of the trucks (numbers, grades and the AI text), one per day and hub. */
class TruckDaySummary extends Model
{
    protected $table = 'truck_day_summaries';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['day' => 'date', 'data' => 'array'];
    }
}
