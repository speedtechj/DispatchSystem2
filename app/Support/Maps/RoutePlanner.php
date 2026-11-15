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
