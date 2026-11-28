<?php

namespace App\Support\Connectors;

use App\Models\AppSetting;

/**
 * Settings → Consolidator connections → Rules (all consolidators).
 * Saved as one JSON value in app_settings.
 */
class Rules
{
    public const KEY = 'connectors.rules';

    /** key => [title, text, default] */
    public const ALL = [
        'prio' => ['Delivered and undo first', 'They jump ahead of a big unload in the line.', true],
        'hold' => ['10-minute hold (Delivered, Unload, Transfer)', 'An undo inside 10 minutes is never sent. Load goes when the trip leaves.', true],
        'pause' => ['Pause a connector after 5 failed tries', 'Then try every 10 minutes; nothing is lost.', true],
        'mail' => ['Email the admins when a connector is paused or 500+ wait', 'Also shown on this page.', true],
        'night' => ['Send backfill only at night (10 PM – 5 AM)', 'For a big history, to keep their server free in the day.', false],
    ];

    public const HOLD_MINUTES = 10;

    public const BATCH = 200;

    public const PAUSE_AFTER = 5;

    public const RETRY_MINUTES = 10;

    public const MAIL_WAITING = 500;

    /** @return array<string, bool> */
    public static function all(): array
    {
        $saved = json_decode((string) AppSetting::get(static::KEY, '{}'), true);
        $saved = is_array($saved) ? $saved : [];
        $out = [];
        foreach (static::ALL as $k => [, , $default]) {
            $out[$k] = (bool) ($saved[$k] ?? $default);
        }

        return $out;
    }

    public static function on(string $key): bool
    {
        return static::all()[$key] ?? false;
    }

    /** @param array<string, mixed> $rules */
    public static function save(array $rules): void
    {
        $clean = [];
        foreach (array_keys(static::ALL) as $k) {
            $clean[$k] = (bool) ($rules[$k] ?? false);
        }
        AppSetting::put(static::KEY, json_encode($clean));
    }
}
