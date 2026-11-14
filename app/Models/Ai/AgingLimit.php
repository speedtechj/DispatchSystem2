<?php

namespace App\Models\Ai;

use App\Support\Aging\BoxAging;
use Illuminate\Database\Eloquent\Model;

class AgingLimit extends Model
{
    protected $table = 'ai_aging_limits';

    protected static function booted(): void
    {
        static::saved(fn () => BoxAging::forgetLimits());
        static::deleted(fn () => BoxAging::forgetLimits());
    }
}
