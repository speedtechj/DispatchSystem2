<?php

namespace App\Support\Ai;

use App\Models\Logistichub;
use App\Models\User;

/** Who sees what: partner hub users only their own hub, everyone else in the office or a warehouse sees all. */
class AiScope
{
    /** null = sees everything, int = only this partner hub, false = nothing. */
    /** @var array<string, int|false|null> */
    protected static array $memo = [];

    public static function hubId(?User $user): int|false|null
    {
        if (! $user) {
            return false;
        }

        $key = $user->getKey().'|'.$user->logistichub_id.'|'.$user->warehouse_id.'|'.(int) $user->is_admin;
        if (! array_key_exists($key, static::$memo)) {
            static::$memo[$key] = static::work($user);
        }

        return static::$memo[$key];
    }

    protected static function work(User $user): int|false|null
    {
        if ($user->hasRole('super_admin') || $user->is_admin) {
            return null;
        }
        $hub = $user->logistichub_id ? Logistichub::find($user->logistichub_id) : null;
        if ($hub && $hub->is_company) {
            return (int) $hub->id;
        }

        return ($hub || $user->warehouse_id) ? null : false;
    }
}
