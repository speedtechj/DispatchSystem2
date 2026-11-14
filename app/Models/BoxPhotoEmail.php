<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class BoxPhotoEmail extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['recipients' => 'array', 'photo_ids' => 'array'];
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function consolidator(): BelongsTo
    {
        return $this->belongsTo(Consolidator::class);
    }
}
