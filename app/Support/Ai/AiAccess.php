<?php

namespace App\Support\Ai;

use App\Models\AppSetting;
use App\Models\User;
use Illuminate\Support\Facades\Auth;

/**
 * Who can use each AI helper (board 48): Admin → Settings → AI → Who can use AI.
 *
 * - mode "all": everyone with the page; "picked": only the picked people.
 * - each helper can follow that, be for everyone, or have its own list.
 * - helpers that run by themselves (photo check, alerts, address cleaning) and the public customer
 *   chat keep running for the whole company.
 * - jobs and commands (no one signed in) are never stopped by this.
 */
class AiAccess
{
    public const KEY = 'ai.access';

    /** Run by themselves or are public: not limited by person. */
    public const AUTO = ['photo_check', 'alerts', 'addresses', 'customer_chat'];

    /** @return array{mode: string, users: list<int>, over: array<string, string|list<int>>} */
    public static function get(): array
    {
        $v = AppSetting::get(self::KEY);
        $v = is_string($v) ? json_decode($v, true) : $v;
        $v = is_array($v) ? $v : [];

        return [
            'mode' => ($v['mode'] ?? 'all') === 'picked' ? 'picked' : 'all',
            'users' => array_values(array_unique(array_map('intval', $v['users'] ?? []))),
            'over' => collect($v['over'] ?? [])->filter(fn ($o, $k) => isset(AiFeatures::ALL[$k]) && ($o === 'all' || is_array($o)))
                ->map(fn ($o) => $o === 'all' ? 'all' : array_values(array_unique(array_map('intval', $o))))->all(),
        ];
    }

    public static function put(array $access): void
    {
        AppSetting::put(self::KEY, json_encode([
            'mode' => ($access['mode'] ?? 'all') === 'picked' ? 'picked' : 'all',
            'users' => array_values(array_unique(array_map('intval', $access['users'] ?? []))),
            'over' => collect($access['over'] ?? [])->filter(fn ($o, $k) => isset(AiFeatures::ALL[$k]) && ($o === 'all' || is_array($o)))->all(),
        ]));
    }

    /** The people who can use it, or null for everyone. */
    public static function list(string $feature, ?array $access = null): ?array
    {
        $a = $access ?? static::get();
        $o = $a['over'][$feature] ?? null;
        if ($o === 'all') {
            return null;
        }
        if (is_array($o)) {
            return $o;
        }

        return $a['mode'] === 'picked' ? $a['users'] : null;
    }

    public static function allows(string $feature, ?User $user = null, ?array $access = null): bool
    {
        $user ??= Auth::user();
        if (! $user || in_array($feature, self::AUTO, true)) {
            return true;
        }
        $list = static::list($feature, $access);

        return $list === null || in_array((int) $user->getKey(), $list, true);
    }
}
