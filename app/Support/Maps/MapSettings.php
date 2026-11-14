<?php

namespace App\Support\Maps;

use App\Models\AppSetting;
use App\Models\Logistichub;
use App\Models\Warehouse;
use App\Support\Ai\Ai;
use Illuminate\Support\Facades\Crypt;
use Throwable;

/**
 * Admin → Settings → Maps & routes. Keys are saved encrypted. The system uses
 * whatever is there: the chosen map if it has a key, else any map with a key,
 * else no map (barangay order). Nothing here ever blocks a trip.
 */
class MapSettings
{
    public const PROVIDERS = [
        'google' => 'Google Maps',
        'ors' => 'OpenRouteService',
        'none' => 'No map key',
    ];

    public static function chosen(): string
    {
        $p = (string) AppSetting::get('maps.provider', 'google');

        return isset(self::PROVIDERS[$p]) ? $p : 'google';
    }

    public static function key(string $provider): ?string
    {
        $v = AppSetting::get('maps.key.'.$provider);
        if (blank($v)) {
            return null;
        }
        try {
            return Crypt::decryptString($v);
        } catch (Throwable) {
            return null;
        }
    }

    public static function putKey(string $provider, ?string $key): void
    {
        AppSetting::put('maps.key.'.$provider, filled($key) ? Crypt::encryptString(trim($key)) : null);
    }

    public static function masked(string $provider): ?string
    {
        $k = static::key($provider);

        return $k ? substr($k, 0, 4).str_repeat('•', 9).substr($k, -3) : null;
    }

    /** The map really used now: google, ors or none. */
    public static function provider(): string
    {
        $chosen = static::chosen();
        if ($chosen === 'none') {
            return 'none';
        }
        if (static::key($chosen)) {
            return $chosen;
        }
        foreach (['google', 'ors'] as $p) {
            if (static::key($p)) {
                return $p;
            }
        }

        return 'none';
    }

    public static function providerName(?string $p = null): string
    {
        return self::PROVIDERS[$p ?? static::provider()] ?? 'No map key';
    }

    public static function aiCleaning(): bool
    {
        return Ai::enabled('addresses');
    }

    public static function priorityFirst(): bool
    {
        return (bool) AppSetting::get('maps.priority_first', false);
    }

    /** Load truck: stop a box that goes in too early (it can still be loaded with "Load it anyway"). */
    public static function warnEarly(): bool
    {
        return (bool) AppSetting::get('maps.warn_early', true);
    }

    /** [lat, lng] typed or pasted as "10.3157, 123.8854" (Google Maps: right-click → copy). */
    public static function parsePin(?string $text): ?array
    {
        if (! preg_match('/(-?\d{1,2}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)/', (string) $text, $m)) {
            return null;
        }
        [$lat, $lng] = [(float) $m[1], (float) $m[2]];

        return abs($lat) <= 90 && abs($lng) <= 180 && ($lat != 0.0 || $lng != 0.0) ? [$lat, $lng] : null;
    }

    public static function startPin(string $kind, int $id): ?array
    {
        return static::parsePin(AppSetting::get("maps.start.{$kind}.{$id}"));
    }

    public static function putStartPin(string $kind, int $id, ?string $text): void
    {
        $pin = static::parsePin($text);
        AppSetting::put("maps.start.{$kind}.{$id}", $pin ? $pin[0].','.$pin[1] : null);
    }

    /** Where a route starts: the warehouse of the person who made the trip, else its hub. */
    public static function startFor(?int $warehouseId, ?int $hubId): ?array
    {
        if ($warehouseId && ($pin = static::startPin('wh', $warehouseId))) {
            return $pin + ['name' => Warehouse::whereKey($warehouseId)->value('name') ?? 'Warehouse'];
        }
        if ($hubId && ($pin = static::startPin('hub', $hubId))) {
            return $pin + ['name' => Logistichub::whereKey($hubId)->value('hub_name') ?? 'Hub'];
        }
        if ($warehouseId && ($w = Warehouse::find($warehouseId))) {
            $place = Geocoder::find(trim($w->address.', '.$w->city.', '.$w->province, ', '), 1);
            if ($place?->hasPin()) {
                return [$place->lat, $place->lng, 'name' => $w->name];
            }
        }

        return null;
    }
}
