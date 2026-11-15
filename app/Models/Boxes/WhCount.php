<?php

namespace App\Models\Boxes;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** A count of one warehouse section. Several phones can count it together. */
class WhCount extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['finished_at' => 'datetime'];
    }

    public function section(): BelongsTo
    {
        return $this->belongsTo(WhSection::class, 'wh_section_id');
    }

    public function scans(): HasMany
    {
        return $this->hasMany(WhCountScan::class);
    }
}
