<?php

namespace App\Models\Boxes;

use App\Models\Container;
use App\Models\Whdeliverylog;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A truck waiting at a container unload: its boxes go straight from the container onto it. */
class WhCrossdock extends Model
{
    protected $table = 'wh_crossdocks';

    protected $guarded = [];

    protected function casts(): array
    {
        return ['paused' => 'boolean', 'ended_at' => 'datetime'];
    }

    public function container(): BelongsTo
    {
        return $this->belongsTo(Container::class);
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Whdeliverylog::class, 'whdeliverylog_id');
    }
}
