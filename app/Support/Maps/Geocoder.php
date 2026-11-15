<?php

namespace App\Support\Maps;

use App\Models\Maps\GeoPlace;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;
use RuntimeException;
use Throwable;

/**
 * Finds addresses on the map. Each address is looked up once and saved in
 * geo_places; later trips read the saved pin and cost nothing.
 */
class Geocoder
{
    /** The saved place for an address (made "pending" the first time). */
    public static function place(string $address): GeoPlace
    {
        $address = Str::limit(Str::squish($address), 590, '');

        return GeoPlace::firstOrCreate(['key' => GeoPlace::keyFor($address)], ['raw' => $address, 'status' => 'pending']);
    }

    /** Look one address up now if it is still pending. */
    public static function find(string $address, int $budget = 1): GeoPlace
    {
        $place = static::place($address);
        static::resolve(collect([$place]), $budget);

        return $place;
    }

    /**
     * Look up the pending places, at most $budget map calls. Messy addresses are
     * cleaned by the AI first when that is switched on.
     *
     * @param  Collection<int, GeoPlace>  $places
     * @return array{looked: int, ai: int}
     */
    public static function resolve(Collection $places, int $budget = 40): array
    {
        $provider = MapSettings::provider();
        $todo = $places->filter(fn (GeoPlace $p) => $p->status === 'pending' && $p->tries < 3)->unique('id')->values();
        if ($provider === 'none' || $todo->isEmpty() || $budget <= 0) {
            return ['looked' => 0, 'ai' => 0];
        }
        $todo = $todo->take($budget);

        $ai = 0;
        if (MapSettings::aiCleaning()) {
            $ai = AddressCleaner::clean($todo->whereNull('clean'));
        }

        $looked = 0;
        foreach ($todo as $place) {
            $place->tries++;
            try {
                $hit = static::lookup($provider, $place->clean ?: $place->raw);
                $looked++;
                if ($hit) {
                    $place->fill(['lat' => $hit['lat'], 'lng' => $hit['lng'], 'exact' => $hit['exact'], 'status' => 'found', 'source' => $provider]);
                } else {
                    $place->fill(['status' => 'not_found', 'source' => $provider]);
                }
            } catch (Throwable $e) {
                report($e);
            }
            $place->save();
        }

        return ['looked' => $looked, 'ai' => $ai];
    }

    /** @return array{lat: float, lng: float, exact: bool, label: string}|null */
    public static function lookup(string $provider, string $text, ?string $key = null): ?array
    {
        $key ??= MapSettings::key($provider);
        if (! $key) {
            throw new RuntimeException('No key for '.MapSettings::providerName($provider).'.');
        }

        if ($provider === 'google') {
            $r = Http::timeout(8)->get('https://maps.googleapis.com/maps/api/geocode/json', [
                'address' => $text, 'components' => 'country:PH', 'region' => 'ph', 'key' => $key,
            ])->throw()->json();
            $status = $r['status'] ?? '';
            if ($status === 'ZERO_RESULTS') {
                return null;
            }
            if ($status !== 'OK') {
                throw new RuntimeException('Google Maps: '.($r['error_message'] ?? $status));
            }
            $hit = $r['results'][0];

            return [
                'lat' => (float) $hit['geometry']['location']['lat'], 'lng' => (float) $hit['geometry']['location']['lng'],
                'exact' => in_array($hit['geometry']['location_type'] ?? '', ['ROOFTOP', 'RANGE_INTERPOLATED'], true) || ! ($hit['partial_match'] ?? false),
                'label' => (string) ($hit['formatted_address'] ?? $text),
            ];
        }

        if ($provider === 'ors') {
            $r = Http::timeout(8)->get('https://api.heigit.org/pelias/v1/search', [
                'api_key' => $key, 'text' => $text, 'boundary.country' => 'PH', 'size' => 1,
            ])->throw()->json();
            $hit = $r['features'][0] ?? null;
            if (! $hit) {
                return null;
            }
            [$lng, $lat] = $hit['geometry']['coordinates'];

            return [
                'lat' => (float) $lat, 'lng' => (float) $lng,
                'exact' => in_array($hit['properties']['layer'] ?? '', ['address', 'street', 'venue'], true),
                'label' => (string) ($hit['properties']['label'] ?? $text),
            ];
        }

        return null;
    }

    /** Pending addresses left over from busy trips (run by ai:work every 15 minutes). */
    public static function work(int $budget = 60): int
    {
        if (MapSettings::provider() === 'none') {
            return 0;
        }

        return static::resolve(GeoPlace::where('status', 'pending')->where('tries', '<', 3)->oldest('id')->limit($budget)->get(), $budget)['looked'];
    }
}
