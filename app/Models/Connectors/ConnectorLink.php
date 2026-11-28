<?php

namespace App\Models\Connectors;

use App\Models\Consolidator;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * One consolidator's connector (Part 47). The token and secret come from the
 * pairing and are kept encrypted; they are never shown again.
 */
class ConnectorLink extends Model
{
    protected $guarded = ['id'];

    protected $hidden = ['token', 'secret'];

    protected function casts(): array
    {
        return [
            'token' => 'encrypted',
            'secret' => 'encrypted',
            'health' => 'array',
            'statuses' => 'array',
            'statuses_at' => 'datetime',
            'last_seen_at' => 'datetime',
            'last_results_at' => 'datetime',
            'paused_at' => 'datetime',
            'next_try_at' => 'datetime',
            'mailed_at' => 'datetime',
            'paired_at' => 'datetime',
        ];
    }

    protected static function booted(): void
    {
        static::saved(fn () => \App\Support\Connectors\Recorder::forgetLinks());
        static::deleted(fn () => \App\Support\Connectors\Recorder::forgetLinks());
    }

    public function consolidator(): BelongsTo
    {
        return $this->belongsTo(Consolidator::class);
    }

    public function mappings(): HasMany
    {
        return $this->hasMany(ConnectorMapping::class);
    }

    public function events(): HasMany
    {
        return $this->hasMany(ConnectorEvent::class);
    }

    public function isPaired(): bool
    {
        return filled($this->key_id) && filled($this->secret);
    }

    public function isPush(): bool
    {
        return $this->mode !== 'pull';
    }

    /** Shown on the cards: Online, Offline, Paused, Setup, Off. */
    public function stateLabel(): string
    {
        return match ($this->state) {
            'online' => 'Online',
            'offline' => 'Offline',
            'paused' => 'Paused',
            'off' => 'Off',
            default => $this->isPaired() ? 'Paired' : 'Setup',
        };
    }
}
