#!/usr/bin/env bash
#
# Dispatch System — Maps fix
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/maps-fix.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 4 files"

# ---------------------------------------------------------------- app/Support/Maps/Geocoder.php
mkdir -p 'app/Support/Maps'
cat > 'app/Support/Maps/Geocoder.php' <<'DISPATCH_FILE_END_0'
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
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Support/Maps/RoutePlanner.php
mkdir -p 'app/Support/Maps'
cat > 'app/Support/Maps/RoutePlanner.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Support\Maps;

use Illuminate\Support\Facades\Http;
use Throwable;

/**
 * Puts stops in driving order from the start pin. With a map key the map's own
 * route optimiser is used (real roads); otherwise, or when it fails, a
 * straight-line shortest path (nearest stop next, then untangled).
 */
class RoutePlanner
{
    /**
     * @param  array{0: float, 1: float}|null  $start
     * @param  array<int|string, array{0: float, 1: float}>  $points  id => [lat, lng]
     * @param  list<int|string>  $first  ids that go before the rest (priority)
     * @return array{order: list<int|string>, km: ?float, minutes: ?int, source: string}
     */
    public static function plan(?array $start, array $points, array $first = []): array
    {
        if (! $points) {
            return ['order' => [], 'km' => 0.0, 'minutes' => 0, 'source' => 'none'];
        }

        $groups = $first ? [array_intersect_key($points, array_flip($first)), array_diff_key($points, array_flip($first))] : [$points];
        $groups = array_values(array_filter($groups));

        $provider = MapSettings::provider();
        if ($start && count($groups) === 1 && $provider !== 'none') {
            try {
                $road = $provider === 'google' ? static::google($start, $points) : static::ors($start, $points);
                if ($road) {
                    return $road;
                }
            } catch (Throwable $e) {
                report($e);
            }
        }

        $order = [];
        $from = $start;
        foreach ($groups as $g) {
            $part = static::local($from, $g);
            $order = array_merge($order, $part);
            $from = $points[end($part)];
        }

        $km = 0.0;
        $prev = $start;
        foreach ($order as $id) {
            if ($prev) {
                $km += static::km($prev, $points[$id]);
            }
            $prev = $points[$id];
        }
        $km = round($km * 1.35, 1); // roads are longer than a straight line

        return ['order' => $order, 'km' => $km, 'minutes' => (int) round($km / 22 * 60), 'source' => 'estimate'];
    }

    /** Nearest stop next, then 2-opt to remove crossings. */
    public static function local(?array $start, array $points): array
    {
        $ids = array_keys($points);
        if (count($ids) <= 1) {
            return $ids;
        }
        if (! $start) {
            // begin at the stop farthest from the middle, so the route sweeps across
            $mid = [array_sum(array_column($points, 0)) / count($points), array_sum(array_column($points, 1)) / count($points)];
            usort($ids, fn ($a, $b) => static::km($mid, $points[$b]) <=> static::km($mid, $points[$a]));
            $start = $points[$ids[0]];
        }

        $left = $ids;
        $order = [];
        $at = $start;
        while ($left) {
            usort($left, fn ($a, $b) => static::km($at, $points[$a]) <=> static::km($at, $points[$b]));
            $next = array_shift($left);
            $order[] = $next;
            $at = $points[$next];
        }

        $path = fn (array $o) => array_merge([$start], array_map(fn ($id) => $points[$id], $o));
        $n = count($order);
        for ($pass = 0, $better = true; $better && $pass < 50; $pass++) {
            $better = false;
            $p = $path($order);
            for ($i = 0; $i < $n - 1; $i++) {
                for ($k = $i + 1; $k < $n; $k++) {
                    $a = $p[$i];
                    $b = $p[$i + 1];
                    $c = $p[$k + 1];
                    $d = $p[$k + 2] ?? null;
                    $before = static::km($a, $b) + ($d ? static::km($c, $d) : 0);
                    $after = static::km($a, $c) + ($d ? static::km($b, $d) : 0);
                    if ($after + 1e-9 < $before) {
                        $order = array_merge(array_slice($order, 0, $i), array_reverse(array_slice($order, $i, $k - $i + 1)), array_slice($order, $k + 1));
                        $p = $path($order);
                        $better = true;
                    }
                }
            }
        }

        return $order;
    }

    public static function km(array $a, array $b): float
    {
        $r = 6371.0;
        $dLat = deg2rad($b[0] - $a[0]);
        $dLng = deg2rad($b[1] - $a[1]);
        $h = sin($dLat / 2) ** 2 + cos(deg2rad($a[0])) * cos(deg2rad($b[0])) * sin($dLng / 2) ** 2;

        return 2 * $r * asin(min(1, sqrt($h)));
    }

    /**
     * Google road route with the stops put in the best order (up to 25 stops), a round trip
     * from the start. Uses the Routes API; if that is not switched on for the key yet,
     * the older Directions API, so nothing stops working while you switch.
     */
    protected static function google(array $start, array $points): ?array
    {
        if (count($points) > 25) {
            return null;
        }
        $ids = array_keys($points);
        $key = MapSettings::key('google');
        $at = fn (array $p) => ['location' => ['latLng' => ['latitude' => $p[0], 'longitude' => $p[1]]]];

        $res = Http::timeout(15)->withHeaders([
            'X-Goog-Api-Key' => $key,
            'X-Goog-FieldMask' => 'routes.optimizedIntermediateWaypointIndex,routes.legs.distanceMeters,routes.legs.duration',
        ])->post('https://routes.googleapis.com/directions/v2:computeRoutes', [
            'origin' => $at($start), 'destination' => $at($start),
            'intermediates' => array_values(array_map($at, $points)),
            'travelMode' => 'DRIVE', 'routingPreference' => 'TRAFFIC_UNAWARE',
            'optimizeWaypointOrder' => true, 'regionCode' => 'ph',
        ]);

        if ($res->successful()) {
            $route = $res->json('routes.0');
            if (! $route) {
                return null;
            }
            $order = $route['optimizedIntermediateWaypointIndex'] ?? range(0, count($ids) - 1);
            if ($order === [-1]) {
                $order = range(0, count($ids) - 1);
            }
            $legs = array_slice($route['legs'] ?? [], 0, count($ids)); // leave out the drive back

            return [
                'order' => array_map(fn ($i) => $ids[$i], $order),
                'km' => round(array_sum(array_map(fn ($l) => $l['distanceMeters'] ?? 0, $legs)) / 1000, 1),
                'minutes' => (int) round(array_sum(array_map(fn ($l) => (int) rtrim((string) ($l['duration'] ?? '0s'), 's'), $legs)) / 60),
                'source' => 'google',
            ];
        }

        // Routes API not switched on for this key (403) or not reachable: try the older Directions API
        if (! in_array($res->status(), [403, 404], true)) {
            $res->throw();
        }

        return static::googleDirections($start, $points, $key);
    }

    /** The older Google Directions API (Legacy at Google since March 2025). */
    protected static function googleDirections(array $start, array $points, ?string $key): ?array
    {
        $ids = array_keys($points);
        $r = Http::timeout(12)->get('https://maps.googleapis.com/maps/api/directions/json', [
            'origin' => $start[0].','.$start[1], 'destination' => $start[0].','.$start[1],
            'waypoints' => 'optimize:true|'.implode('|', array_map(fn ($p) => $p[0].','.$p[1], $points)),
            'region' => 'ph', 'key' => $key,
        ])->throw()->json();
        if (($r['status'] ?? '') !== 'OK') {
            return null;
        }
        $route = $r['routes'][0];
        $legs = array_slice($route['legs'], 0, count($ids)); // leave out the drive back

        return [
            'order' => array_map(fn ($i) => $ids[$i], $route['waypoint_order']),
            'km' => round(array_sum(array_map(fn ($l) => $l['distance']['value'], $legs)) / 1000, 1),
            'minutes' => (int) round(array_sum(array_map(fn ($l) => $l['duration']['value'], $legs)) / 60),
            'source' => 'google',
        ];
    }

    /** OpenRouteService optimisation (up to 50 stops), from the start to the last stop. api.heigit.org since 2026. */
    protected static function ors(array $start, array $points): ?array
    {
        if (count($points) > 50) {
            return null;
        }
        $ids = array_keys($points);
        $jobs = [];
        foreach ($ids as $i => $id) {
            $jobs[] = ['id' => $i + 1, 'location' => [$points[$id][1], $points[$id][0]]];
        }
        $r = Http::timeout(15)->withHeaders(['Authorization' => MapSettings::key('ors')])
            ->post('https://api.heigit.org/vroom/v0', [
                'jobs' => $jobs,
                'vehicles' => [['id' => 1, 'profile' => 'driving-car', 'start' => [$start[1], $start[0]]]],
                'options' => ['g' => true],
            ])->throw()->json();
        $route = $r['routes'][0] ?? null;
        if (! $route) {
            return null;
        }
        $order = [];
        foreach ($route['steps'] as $s) {
            if (($s['type'] ?? '') === 'job') {
                $order[] = $ids[$s['job'] - 1];
            }
        }
        if (count($order) !== count($ids)) {
            return null;
        }

        return ['order' => $order, 'km' => round(($route['distance'] ?? $r['summary']['distance'] ?? 0) / 1000, 1), 'minutes' => (int) round(($route['duration'] ?? 0) / 60), 'source' => 'ors'];
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- resources/views/filament/pages/maps-routes.blade.php
mkdir -p 'resources/views/filament/pages'
cat > 'resources/views/filament/pages/maps-routes.blade.php' <<'DISPATCH_FILE_END_2'
<x-filament-panels::page>
<div class="ds-mp">
    <section class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>What the system uses now</h2></div>
        <div class="ds-mp__chain">
            @foreach ($chain as $i => [$title, $what, $text, $on])
                <div @class(['ds-mp__step', 'is-on' => $on])>
                    <span class="ds-mp__stephead"><i>{{ $i + 1 }}</i><b>{{ $title }}</b></span>
                    <strong>{{ $what }}</strong>
                    <small>{{ $text }}</small>
                </div>
            @endforeach
        </div>
        @if ($fallback)
            <p class="ds-mp__warn">{{ \App\Support\Maps\MapSettings::providerName(\App\Support\Maps\MapSettings::chosen()) }} has no key yet, so {{ $inUse === 'none' ? 'the barangay order' : \App\Support\Maps\MapSettings::providerName($inUse) }} is used for now.</p>
        @endif
        <p class="ds-board__muted">Always, with or without keys: one stop per receiver (all their boxes together) · loading order is the reverse of the delivery order · staff can drag stops · an address the map can't find goes next to its barangay, so a trip is never blocked.</p>
    </section>

    @if ($full)
    <section class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>Map service</h2><span class="ds-board__muted">finds each address and the best order of stops</span></div>
        <div class="ds-mp__providers">
            @foreach ($providers as $p)
                <button type="button" wire:click="pick('{{ $p['key'] }}')" @class(['ds-mp__provider', 'is-picked' => $provider === $p['key']])>
                    <span class="ds-mp__provhead"><b>{{ $p['name'] }}</b>
                        <em @class(['is-on' => $inUse === $p['key']])>{{ $inUse === $p['key'] ? 'In use' : ($p['masked'] ? 'Key saved' : ($p['key'] === 'none' ? 'Fallback' : 'No key')) }}</em></span>
                    <small>{{ $p['text'] }}</small>
                    <code>{{ $p['key'] === 'none' ? 'Nothing to set' : ($p['masked'] ? 'Key: '.$p['masked'] : 'No key yet') }}</code>
                </button>
            @endforeach
        </div>
        @if ($provider !== 'none')
            <form wire:submit="saveKey" class="ds-mp__keyrow">
                <input type="password" wire:model="key" autocomplete="off" placeholder="Paste your {{ \App\Support\Maps\MapSettings::PROVIDERS[$provider] }} key" aria-label="Map key">
                <x-filament::button type="submit">Save key</x-filament::button>
                <x-filament::button type="button" color="gray" wire:click="test">Test</x-filament::button>
                @if (\App\Support\Maps\MapSettings::key($provider))
                    <x-filament::button type="button" color="danger" outlined wire:click="removeKey" wire:confirm="Remove this key? Trips go back to the other map or the barangay order.">Remove</x-filament::button>
                @endif
            </form>
            @error('key')<p class="ds-ai__err">{{ $message }}</p>@enderror
            <label class="ds-mp__testaddr"><span>Test with this address</span><input type="text" wire:model="testAddress"></label>
            @if ($testResult)
                <p @class(['ds-mp__result', 'is-ok' => $testOk])>{{ $testResult }}</p>
            @endif
            <p class="ds-board__muted">
                @if ($provider === 'google')
                    Get a key at console.cloud.google.com → APIs &amp; Services. Turn on <b>Geocoding API</b> and <b>Routes API</b> (the older Directions API also still works). The key stays on the server; the map picture in the app is OpenStreetMap, so it is not shown to phones.
                @else
                    Get a free key at openrouteservice.org → Sign up → Dashboard → Tokens (the same key works on api.heigit.org).
                @endif
            </p>
        @endif
    </section>

    @else
        <section class="ds-board__panel">
            <p class="ds-board__muted">Map keys and the switches below are set by Admin (Settings → Maps &amp; routes), for every warehouse and hub. Here you set where your routes start and fix the pins of addresses on your trips.</p>
            <div class="ds-mp__stats">
                <span><b>AI address cleaning:</b> {{ $aiReady ? 'on' : 'off' }}</span>
                <span><b>Priority stops first:</b> {{ $priorityFirst ? 'on' : 'off' }}</span>
                <span><b>"Too early" warning in Load truck:</b> {{ $warnEarly ? 'on' : 'off' }}</span>
            </div>
        </section>
    @endif

    <div @class(['ds-mp__two', 'is-one' => ! $full])>
        @if ($full)
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>AI address cleaning</h2></div>
            <p class="ds-board__muted">Uses the AI key from Settings → AI. Turns "purok 3 near chapel, Lapu2" into "Purok 3, Pusok, Lapu-Lapu City, Cebu" before the map looks it up.</p>
            <button type="button" wire:click="toggleAi" @class(['ds-mp__toggle', 'is-on' => $aiOn])>{{ $aiOn ? ($aiReady ? 'On · AI key found ✓' : 'On · but no AI key yet') : 'Off · switch on' }}</button>
            @if ($aiOn && ! $hasAiKey)
                <p class="ds-mp__warn">Add the AI key in Settings → AI, or addresses are used as typed.</p>
            @endif

            <div class="ds-board__panel-head" style="margin-top: 1rem"><h2>Priority boxes</h2></div>
            <p class="ds-board__muted">Deliver receivers with a priority box first, even if the route is a bit longer.</p>
            <button type="button" wire:click="togglePriority" @class(['ds-mp__toggle', 'is-on' => $priorityFirst])>{{ $priorityFirst ? 'On · priority stops first' : 'Off · shortest route' }}</button>

            <div class="ds-board__panel-head" style="margin-top: 1rem"><h2>"Too early" warning</h2></div>
            <p class="ds-board__muted">Load truck stops a box that goes in too early (it belongs nearer the door). The crew can still press "Load it anyway".</p>
            <button type="button" wire:click="toggleEarly" @class(['ds-mp__toggle', 'is-on' => $warnEarly])>{{ $warnEarly ? 'On · warn the crew' : 'Off · just show the truck spot' }}</button>
        </section>
        @endif

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Start of every route</h2></div>
            <p class="ds-board__muted">Paste the pin of each place, like <code>10.3157, 123.8854</code>. In Google Maps: right-click the building and click the numbers to copy them. Empty = found from the address.</p>
            <form wire:submit="saveStarts" class="ds-mp__starts">
                @foreach ($warehouses as $w)
                    <label><span>{{ $w->name }} <small>warehouse</small></span><input type="text" wire:model="starts.wh:{{ $w->id }}" placeholder="not set"></label>
                @endforeach
                @if ($warehouses->isEmpty() && $hubs->isEmpty())
                    <p class="ds-board__muted">Your account has no warehouse or hub, so there is no start pin to set.</p>
                @endif
                @foreach ($hubs as $h)
                    <label><span>{{ $h->hub_name }} <small>hub</small></span><input type="text" wire:model="starts.hub:{{ $h->id }}" placeholder="not set"></label>
                @endforeach
                @if ($warehouses->isNotEmpty() || $hubs->isNotEmpty())<div><x-filament::button type="submit" size="sm">Save pins</x-filament::button></div>@endif
            </form>
        </section>
    </div>

    <section class="ds-board__panel">
        <div class="ds-mp__stats">
            <span><b>Saved locations:</b> {{ number_format($stats['found']) }}</span>
            <span><b>Map look-ups this month:</b> {{ number_format($stats['month']) }} <small>(new addresses only)</small></span>
            <span><b>Waiting:</b> {{ number_format($stats['waiting']) }}</span>
            <span><b>Not found:</b> {{ number_format($stats['missing']) }} <small>(placed by barangay)</small></span>
        </div>
    </section>

    @if ($suggested->isNotEmpty())
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Pins from drivers</h2><span class="ds-board__muted">"Can't find it" in the Driver app: the driver dropped a pin where the house really is</span></div>
            <div class="ds-mp__fix">
                @foreach ($suggested as $g)
                    <div wire:key="sg-{{ $g->id }}">
                        <span><b>{{ $g->clean ?: $g->raw }}</b><small>Driver's pin {{ round($g->suggested_lat, 5) }}, {{ round($g->suggested_lng, 5) }} · {{ $g->suggested_at?->diffForHumans() }}
                            · <a href="https://www.google.com/maps/search/?api=1&query={{ $g->suggested_lat }},{{ $g->suggested_lng }}" target="_blank" rel="noopener">see on map</a></small></span>
                        <x-filament::button size="sm" wire:click="acceptSuggestion({{ $g->id }})">Use this pin</x-filament::button>
                        <x-filament::button size="sm" color="gray" wire:click="rejectSuggestion({{ $g->id }})">Ignore</x-filament::button>
                    </div>
                @endforeach
            </div>
        </section>
    @endif

    @if ($fix->isNotEmpty())
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Fix pins</h2><span class="ds-board__muted">addresses the map could not find</span></div>
            <div class="ds-mp__fix">
                @foreach ($fix as $g)
                    <div wire:key="fx-{{ $g->id }}">
                        <span><b>{{ $g->raw }}</b>@if ($g->clean && $g->clean !== $g->raw)<small>AI: {{ $g->clean }}</small>@endif</span>
                        <input type="text" wire:model="pins.{{ $g->id }}" placeholder="10.3157, 123.8854">
                        <x-filament::button size="sm" wire:click="savePin({{ $g->id }})">Save pin</x-filament::button>
                    </div>
                @endforeach
            </div>
        </section>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- tests/Feature/MapsRoutesTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/MapsRoutesTest.php' <<'DISPATCH_FILE_END_3'
<?php

use App\Filament\Delivery\Pages\Dashboard as DriverDashboard;
use App\Filament\Pages\MapsRoutes;
use App\Filament\Pages\Scanload;
use App\Filament\Pages\TripStops;
use App\Filament\Warehouse\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Maps\GeoPlace;
use App\Models\Maps\TripRoute;
use App\Models\Maps\TripStop;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Maps\LoadOrder;
use App\Support\Maps\MapSettings;
use App\Support\Maps\RoutePlanner;
use App\Support\Maps\TripSorter;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

/** Receivers along a line from the warehouse: Ana is farthest, Maria nearest. */
const MAP_PINS = [
    'Basak' => [10.3400, 123.9500],   // Maria (nearest)
    'Tipolo' => [10.3500, 123.9700],  // Liza
    'Pusok' => [10.3600, 123.9900],   // Jose (priority)
    'Gabi' => [10.3700, 124.0100],    // Ana (farthest)
];

function mapBox(string $no, string $name, string $brgy, string $city, string $phone, array $extra = []): Invoice
{
    return Invoice::create(array_merge([
        'container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'Sender', 'receiver_name' => $name,
        'receiver_address' => 'Purok 1', 'receiver_province' => 'Cebu', 'receiver_city' => $city, 'receiver_barangay' => $brgy,
        'receiver_mobile_no' => $phone, 'boxtype' => 'Regular', 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1,
    ], $extra));
}

function fakeGoogle(): void
{
    Http::fake([
        'maps.googleapis.com/maps/api/geocode/*' => function ($request) {
            foreach (MAP_PINS as $brgy => [$lat, $lng]) {
                if (str_contains($request['address'], $brgy)) {
                    return Http::response(['status' => 'OK', 'results' => [['formatted_address' => $brgy.', Cebu', 'geometry' => ['location' => ['lat' => $lat, 'lng' => $lng], 'location_type' => 'ROOFTOP']]]]);
                }
            }

            return Http::response(['status' => 'ZERO_RESULTS', 'results' => []]);
        },
        'routes.googleapis.com/*' => fn ($request) => Http::response(['routes' => [[
            // the map's own order: keep the stops as sent, but say how far it is
            'optimizedIntermediateWaypointIndex' => range(0, count($request['intermediates']) - 1),
            'legs' => array_fill(0, count($request['intermediates']) + 1, ['distanceMeters' => 5000, 'duration' => '600s']),
        ]]]),
        'maps.googleapis.com/maps/api/directions/*' => fn ($request) => Http::response(['status' => 'OK', 'routes' => [[
            // the map's own order: keep the stops as sent, but say how far it is
            'waypoint_order' => range(0, substr_count($request['waypoints'], '|') - 1),
            'legs' => array_fill(0, substr_count($request['waypoints'], '|') + 1, ['distance' => ['value' => 5000], 'duration' => ['value' => 600]]),
        ]]]),
    ]);
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $hub = $this->admin->logistichub_id;
    $this->truck = Truck::create(['plate_no' => 'MAP 123', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 40, 'category' => 'Truck', 'description' => '6-wheeler', 'registration_no' => 'RM', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    $this->trip = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today()]);

    $boxes = collect();
    foreach (range(1, 3) as $i) {
        $boxes->push(mapBox("MAR-{$i}", 'Maria Santos', 'Basak', 'Mandaue City', '09171112222'));
    }
    $boxes->push(mapBox('LIZ-1', 'Liza Gomez', 'Tipolo', 'Mandaue City', '09175556666'));
    $boxes->push(mapBox('LIZ-2', 'Liza Gomez', 'Tipolo', 'Mandaue City', '09175556666'));
    $boxes->push(mapBox('JOS-1', 'Jose Ramos', 'Pusok', 'Lapu-Lapu City', '09173334444', ['is_priority' => true]));
    foreach (range(1, 3) as $i) {
        $boxes->push(mapBox("ANA-{$i}", 'Ana Reyes', 'Gabi', 'Cordova', '09179998888'));
    }
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, $boxes);
    AppSetting::put('maps.start.hub.'.$hub, '10.3300, 123.9300');
});

it('puts boxes in truck spots: the first third delivered at the door, the last third next to the cab', function () {
    expect(TripSorter::zones([3, 2, 1, 3]))->toBe(['back', 'middle', 'middle', 'front'])
        ->and(TripSorter::zones([1]))->toBe(['middle'])
        ->and(TripSorter::zones([5, 5, 5]))->toBe(['back', 'middle', 'front']);
});

it('sorts by barangay with no map key, one stop per receiver', function () {
    Http::preventStrayRequests();
    $route = TripSorter::sort($this->trip);
    $stops = TripSorter::stops($this->trip);

    expect($route->source)->toBe('barangay')
        ->and($stops)->toHaveCount(4)
        ->and($stops->firstWhere('name', 'Maria Santos')->boxes)->toBe(3)
        ->and($stops->sum('boxes'))->toBe(9)
        ->and($stops->pluck('zone')->first())->toBe('back')
        ->and($stops->pluck('zone')->last())->toBe('front')
        ->and(GeoPlace::where('status', 'pending')->count())->toBe(4); // waiting for a map key, no cost
});

it('finds each address once with a Google key and sorts the stops by road from the start pin', function () {
    MapSettings::putKey('google', 'AIza-test');
    fakeGoogle();

    $route = TripSorter::sort($this->trip);
    $stops = TripSorter::stops($this->trip);

    expect($route->source)->toBe('google')
        ->and($route->km)->toBe(20.0) // 4 legs of 5 km, the drive back left out
        ->and($stops->pluck('name')->all())->toBe(['Maria Santos', 'Liza Gomez', 'Jose Ramos', 'Ana Reyes'])
        ->and($stops->first()->zone)->toBe('back')
        ->and($stops->last()->zone)->toBe('front')
        ->and($stops->every(fn ($s) => $s->hasPin() && $s->exact))->toBeTrue();

    // the next trip reads the saved pins: no new look-ups
    $looked = collect(Http::recorded())->filter(fn ($r) => str_contains($r[0]->url(), 'geocode'))->count();
    TripSorter::sort($this->trip);
    expect(collect(Http::recorded())->filter(fn ($r) => str_contains($r[0]->url(), 'geocode'))->count())->toBe($looked);
});

it('sorts by straight line when the map route fails, and puts a stop without a pin next to its barangay', function () {
    MapSettings::putKey('ors', 'ors-test');
    AppSetting::put('maps.provider', 'google'); // no Google key: falls back to OpenRouteService
    expect(MapSettings::provider())->toBe('ors');
    mapBox('X-1', 'Pedro Cruz', 'Tipolo', 'Mandaue City', '09170000001');
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, Invoice::where('invoice', 'X-1')->get());

    Invoice::where('invoice', 'X-1')->update(['receiver_address' => 'Purok 9 near chapel']);
    // Pedro's address is not found
    Http::fake(['api.heigit.org/pelias/*' => function ($request) {
        if (str_contains($request['text'], 'Purok 9')) {
            return Http::response(['features' => []]);
        }
        foreach (MAP_PINS as $brgy => [$lat, $lng]) {
            if (str_contains($request['text'], $brgy)) {
                return Http::response(['features' => [['geometry' => ['coordinates' => [$lng, $lat]], 'properties' => ['layer' => 'street', 'label' => $brgy]]]]);
            }
        }

        return Http::response(['features' => []]);
    }, 'api.heigit.org/vroom/*' => Http::response('down', 500)]);

    $route = TripSorter::sort($this->trip);
    $names = TripSorter::stops($this->trip)->pluck('name')->all();

    expect($route->source)->toBe('estimate')
        ->and($names)->toBe(['Maria Santos', 'Liza Gomez', 'Pedro Cruz', 'Jose Ramos', 'Ana Reyes'])
        ->and(GeoPlace::where('status', 'not_found')->count())->toBe(1);
});

it('cleans messy addresses with the AI before the map looks them up', function () {
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => ['addresses']]);
    Cache::forget('ai.settings');
    MapSettings::putKey('google', 'AIza-test');
    Http::fake([
        'api.anthropic.com/*' => fn ($request) => Http::response(['content' => [['type' => 'text', 'text' => json_encode(['addresses' => collect(json_decode($request['messages'][0]['content'], true))
            ->map(fn ($a) => ['i' => $a['i'], 'address' => str_replace('Purok 1', 'Purok 1 (fixed)', $a['address'])])->all()])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]),
    ]);
    fakeGoogle();

    $route = TripSorter::sort($this->trip);

    expect($route->ai_fixed)->toBe(4)
        ->and(GeoPlace::whereNotNull('clean')->count())->toBe(4)
        ->and(collect(Http::recorded())->contains(fn ($r) => str_contains($r[0]->url(), 'geocode') && str_contains($r[0]['address'], '(fixed)')))->toBeTrue();
});

it('keeps the staff order once a stop is dragged, and puts new boxes at the end', function () {
    TripSorter::sort($this->trip);
    $ana = TripStop::where('name', 'Ana Reyes')->first();
    TripSorter::move($this->trip, $ana->id, 0);

    expect(TripSorter::stops($this->trip)->first()->name)->toBe('Ana Reyes')
        ->and(TripSorter::stops($this->trip)->first()->zone)->toBe('back')
        ->and(TripRoute::where('deliverylog_id', $this->trip->id)->value('locked'))->toBeTrue();

    mapBox('NEW-1', 'Carlo Lim', 'Talamban', 'Cebu City', '09170000002');
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, Invoice::where('invoice', 'NEW-1')->get());
    TripSorter::ensure($this->trip);

    expect(TripSorter::stops($this->trip)->pluck('name')->first())->toBe('Ana Reyes')
        ->and(TripSorter::stops($this->trip)->pluck('name')->last())->toBe('Carlo Lim');
});

it('tells the loading crew what to load next and warns about a box that is too early', function () {
    TripSorter::sort($this->trip);
    $next = LoadOrder::next($this->trip);
    $last = TripSorter::stops($this->trip)->last();
    expect($next['stop'])->toBe($last->stop_no)->and($next['zone'])->toBe('front');

    $page = Livewire::test(Scanload::class)->set('data.deliverylog_id', $this->trip->id)->assertSee('Load next');
    $first = TripSorter::stops($this->trip)->first();
    $doorBox = Invoice::find(Tripinvoice::find($first->box_ids[0])->invoice_id)->invoice;

    $page->call('scan', $doorBox);
    $page->assertSet('lastStatus', 'warning')->assertSet('early.code', $doorBox)->assertSee('Too early');
    expect(Tripinvoice::find($first->box_ids[0])->is_loaded)->toBeFalse();

    $page->call('loadAnyway')->assertSet('lastStatus', 'success');
    expect(Tripinvoice::find($first->box_ids[0])->is_loaded)->toBeTrue();

    AppSetting::put('maps.warn_early', 0);
    $page->call('scan', Invoice::find(Tripinvoice::find($first->box_ids[1])->invoice_id)->invoice)->assertSet('lastStatus', 'success');
    AppSetting::put('maps.warn_early', 1);

    $frontBox = Invoice::find(Tripinvoice::find($last->box_ids[0])->invoice_id)->invoice;
    $page->call('scan', $frontBox)->assertSet('lastStatus', 'success')->assertSet('spot.zone', 'front');
});

it('shows the stops page with the map, the truck and the loading list', function () {
    $this->get(TripStops::getUrl(['trip' => $this->trip->id]))->assertOk()->assertSee('Delivery order')->assertSee('Ana Reyes')->assertSee('load #1');
    Livewire::withQueryParams(['trip' => $this->trip->id])->test(TripStops::class)->call('resort')->assertDispatched('trip-map');

    $stops = TripSorter::stops($this->trip);
    $html = $this->get(route('trip.loading-list', $this->trip))->assertOk()->assertSee('Loading list')->getContent();
    expect(strpos($html, 'FRONT'))->toBeLessThan(strpos($html, 'BACK'))
        ->and(strpos($html, $stops->last()->name))->toBeLessThan(strpos($html, $stops->first()->name));
});

it('does not sort a trip that goes to another hub', function () {
    $other = Logistichub::where('id', '!=', $this->admin->logistichub_id)->value('id');
    $this->trip->update(['assigned_to' => $other]);

    expect(TripSorter::ensure($this->trip->fresh()))->toBeNull();
    $this->get(TripStops::getUrl(['trip' => $this->trip->id]))->assertOk()->assertSee('All boxes are one stop');
})->skip(fn () => Logistichub::count() < 2, 'needs two hubs');

it('shows the driver the stops with Navigate, and takes a pin when they cannot find the house', function () {
    TripSorter::sort($this->trip);
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => $driver->id, 'user_id' => $this->admin->id]);
    $this->trip->update(['is_active' => true]);
    $this->actingAs($driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));

    $stop = TripSorter::stops($this->trip)->first();
    Livewire::test(DriverDashboard::class)->assertSee('Your stops')->assertSee('Navigate')->assertSee('Google Maps')->assertSee('Waze')
        ->call('suggestPin', $stop->id, 10.341, 123.951);

    $place = GeoPlace::find($stop->geo_place_id);
    expect($place->suggested_lat)->toBe(10.341);

    // the office uses the driver's pin
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(MapsRoutes::class)->assertSee('Pins from drivers')->call('acceptSuggestion', $place->id);
    expect($place->fresh()->lat)->toBe(10.341)->and($place->fresh()->status)->toBe('manual');
});

it('saves map keys encrypted, tests them, and reads pasted start pins', function () {
    Http::fake(['maps.googleapis.com/*' => Http::response(['status' => 'OK', 'results' => [['formatted_address' => 'Basak, Mandaue City', 'geometry' => ['location' => ['lat' => 10.34, 'lng' => 123.95], 'location_type' => 'APPROXIMATE'], 'partial_match' => true]]])]);

    Livewire::test(MapsRoutes::class)
        ->assertSee('What the system uses now')->assertSee('Barangay order')
        ->set('key', 'AIza-SECRET-123')->call('saveKey')
        ->call('test')->assertSee('The key works')
        ->set('starts.wh:1', '10.3157, 123.8854')->call('saveStarts')
        ->call('toggleAi')->call('togglePriority');

    expect(AppSetting::where('key', 'maps.key.google')->value('value'))->not->toContain('AIza-SECRET')
        ->and(MapSettings::key('google'))->toBe('AIza-SECRET-123')
        ->and(MapSettings::provider())->toBe('google')
        ->and(MapSettings::startPin('wh', 1))->toBe([10.3157, 123.8854])
        ->and(AiSetting::current()->isOn('addresses'))->toBeTrue()
        ->and(MapSettings::priorityFirst())->toBeTrue()
        ->and(MapSettings::parsePin('not a pin'))->toBeNull();
});

it('untangles a straight-line route', function () {
    $order = RoutePlanner::local([0, 0], ['a' => [0, 3], 'b' => [0, 1], 'c' => [0, 2]]);
    expect($order)->toBe(['b', 'c', 'a']);
});

it('gives the warehouse and the partner hub their own Maps & routes page and the stops page, without the keys', function () {
    TripSorter::sort($this->trip);
    $place = GeoPlace::where('status', 'pending')->first();
    $place->update(['status' => 'not_found']);

    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    $wh->update(['logistichub_id' => $this->admin->logistichub_id]);
    $this->actingAs($wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));

    $this->get(App\Filament\Warehouse\Pages\MapsRoutes::getUrl())->assertOk()
        ->assertSee('What the system uses now')->assertSee('set by Admin')->assertDontSee('Paste your Google Maps key');
    Livewire::test(App\Filament\Warehouse\Pages\MapsRoutes::class)
        ->set('pins.'.$place->id, '10.30, 123.90')->call('savePin', $place->id)
        ->set('key', 'AIza-from-warehouse')->call('saveKey');
    expect($place->fresh()->status)->toBe('manual')->and(MapSettings::key('google'))->toBeNull();

    $this->get(App\Filament\Warehouse\Pages\TripStops::getUrl(['trip' => $this->trip->id]))->assertOk()->assertSee('Delivery order');
    Livewire::test(ListDeliverylogs::class)->assertSee('Stops &amp; loading', false);

    // a partner hub only sees places on its own trips
    $co = User::where('email', 'company@example.com')->firstOrFail();
    $this->flushSession(); // a new person signs in
    $this->actingAs($co);
    Filament::setCurrentPanel(Filament::getPanel('company'));
    $this->get(App\Filament\Company\Pages\MapsRoutes::getUrl())->assertOk()->assertSee('Start of every route')->assertDontSee('Purok 1, Basak');
    $place->update(['suggested_lat' => 1, 'suggested_lng' => 1, 'suggested_at' => now()]);
    Livewire::test(App\Filament\Company\Pages\MapsRoutes::class)->call('acceptSuggestion', $place->id)->call('toggleAi');
    expect($place->fresh()->lat)->toBe(10.3)->and((bool) AiSetting::query()->first()?->isOn('addresses'))->toBeFalse();
});

it('saves the stops on the driver phone so Navigate works without signal', function () {
    TripSorter::sort($this->trip);
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => $driver->id, 'user_id' => $this->admin->id]);
    $this->trip->update(['is_active' => true]);

    $data = $this->actingAs($driver)->getJson('/delivery-offline/trip')->assertOk()->json();
    $first = TripSorter::stops($this->trip)->first();

    expect($data['stops'])->toHaveCount(4)
        ->and($data['stops'][0]['no'])->toBe(1)
        ->and($data['stops'][0]['name'])->toBe($first->name)
        ->and($data['stops'][0]['boxes'])->toBe($first->box_ids)
        ->and($data['stops'][0]['go'])->toContain('Philippines'); // no pin yet: the address is sent

    expect(file_get_contents(resource_path('js/driver-offline.js')))->toContain('data-dso="nav"')->toContain('works offline with a downloaded map');
});

it('uses the older Google Directions API when Routes API is not switched on for the key', function () {
    $start = [10.33, 123.90];
    $points = ['a' => [10.34, 123.95], 'b' => [10.36, 124.00]];
    Http::fake([
        'routes.googleapis.com/*' => Http::response(['error' => ['code' => 403, 'status' => 'PERMISSION_DENIED']], 403),
        'maps.googleapis.com/maps/api/directions/*' => Http::response(['status' => 'OK', 'routes' => [[
            'waypoint_order' => [1, 0],
            'legs' => [['distance' => ['value' => 7000], 'duration' => ['value' => 900]], ['distance' => ['value' => 3000], 'duration' => ['value' => 300]], ['distance' => ['value' => 9000], 'duration' => ['value' => 900]]],
        ]]]),
    ]);
    $google = new ReflectionMethod(\App\Support\Maps\RoutePlanner::class, 'google');
    $r = $google->invoke(null, $start, $points);
    expect($r['order'])->toBe(['b', 'a'])->and($r['km'])->toBe(10.0)->and($r['minutes'])->toBe(20);
    Http::assertSent(fn ($req) => str_contains($req->url(), 'routes.googleapis.com') && $req['optimizeWaypointOrder'] === true && $req->hasHeader('X-Goog-FieldMask'));
});
DISPATCH_FILE_END_3

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
