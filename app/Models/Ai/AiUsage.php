<?php

namespace App\Models\Ai;

use Illuminate\Database\Eloquent\Model;

class AiUsage extends Model
{
    protected $table = 'ai_usage';

    public const UPDATED_AT = null;

    protected function casts(): array
    {
        return ['ok' => 'boolean', 'cost' => 'float'];
    }

    public static function spentThisMonth(): float
    {
        return (float) static::where('created_at', '>=', now()->startOfMonth())->sum('cost');
    }
}
