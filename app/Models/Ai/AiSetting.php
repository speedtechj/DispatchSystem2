<?php

namespace App\Models\Ai;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Cache;

/** The one row of AI settings (Admin → Settings → AI). */
class AiSetting extends Model
{
    protected $table = 'ai_settings';

    protected $hidden = ['api_key'];

    protected function casts(): array
    {
        return ['api_key' => 'encrypted', 'features' => 'array', 'aging' => 'array', 'monthly_limit' => 'decimal:2'];
    }

    protected static ?self $memo = null;

    public static function current(): self
    {
        return static::$memo ??= Cache::remember('ai.settings', 300, fn () => static::query()->first() ?? new static([
            'model_fast' => 'claude-haiku-5-5', 'model_smart' => 'claude-sonnet-5-5', 'monthly_limit' => 20, 'features' => [],
        ]));
    }

    protected static function booted(): void
    {
        static::saved(function () {
            static::$memo = null;
            Cache::forget('ai.settings');
        });
    }

    public function hasKey(): bool
    {
        return filled($this->api_key);
    }

    public function isOn(string $feature): bool
    {
        return in_array($feature, $this->features ?? [], true);
    }
}
