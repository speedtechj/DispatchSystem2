<?php

namespace App\Models\Photos;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

/** A move, a switch to the real bucket, or a copy from the old system; done in small batches. */
class PhotoTask extends Model
{
    protected $table = 'photo_tasks';

    protected function casts(): array
    {
        return ['options' => 'array', 'started_at' => 'datetime', 'finished_at' => 'datetime', 'checked_at' => 'datetime'];
    }

    public function items(): HasMany
    {
        return $this->hasMany(PhotoTaskItem::class);
    }

    public function opt(string $key, mixed $default = null): mixed
    {
        return ($this->options ?? [])[$key] ?? $default;
    }

    public function pct(): int
    {
        return $this->total ? (int) min(100, floor(($this->done + $this->skipped) * 100 / $this->total)) : ($this->status === 'done' ? 100 : 0);
    }
}
