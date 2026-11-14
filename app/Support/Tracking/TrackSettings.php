<?php

namespace App\Support\Tracking;

use App\Models\AppSetting;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Str;
use Throwable;

/** Settings → Truck tracking (Admin). */
class TrackSettings
{
    public const SOURCES = [
        'app' => ['Driver app (now)', 'Free. Works while the Driver app is open. Gaps when the driver switches to Waze or the screen locks, mostly on iPhone.'],
        'android' => ['Driver app for Android', 'The same Driver app installed as an Android app keeps sending while Waze is open. Uses the same link as the Driver app.'],
        'tracker' => ['GPS tracker in the truck', 'Works even when the phone is off. The tracker (or its server, e.g. Traccar) sends to the tracker link below.'],
    ];

    public const DEFAULTS = ['interval' => 30, 'keep_days' => 90, 'stopped' => 20, 'no_signal' => 30, 'off_route' => 3, 'back' => 1, 'map' => 'osm'];

    public static function get(string $key): mixed
    {
        return AppSetting::get('track.'.$key, self::DEFAULTS[$key] ?? null);
    }

    public static function int(string $key): int
    {
        return (int) static::get($key);
    }

    public static function put(string $key, mixed $value): void
    {
        AppSetting::put('track.'.$key, $value);
    }

    public static function source(int $truckId): string
    {
        $s = (string) AppSetting::get('track.source.'.$truckId, 'app');

        return isset(self::SOURCES[$s]) ? $s : 'app';
    }

    /** The secret part of the tracker link (made the first time it is needed). */
    public static function trackerToken(): string
    {
        $t = AppSetting::get('track.tracker_token');
        if (! $t) {
            $t = Str::random(32);
            AppSetting::put('track.tracker_token', $t);
        }

        return $t;
    }

    public static function googleKey(): ?string
    {
        $v = AppSetting::get('track.google_browser_key');
        try {
            return $v ? Crypt::decryptString($v) : null;
        } catch (Throwable) {
            return null;
        }
    }

    public static function putGoogleKey(?string $key): void
    {
        AppSetting::put('track.google_browser_key', filled($key) ? Crypt::encryptString(trim($key)) : null);
    }

    /** Google Maps only when chosen and a browser key is saved; otherwise the free OpenStreetMap. */
    public static function mapKey(): ?string
    {
        return static::get('map') === 'google' ? static::googleKey() : null;
    }
}
