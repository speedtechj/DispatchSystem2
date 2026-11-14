<?php

namespace App\Http\Controllers;

use App\Models\Deliverylog;
use App\Models\Tracking\TruckPosition;
use App\Models\Truck;
use App\Support\DriverTrip;
use App\Support\Tracking\TrackSettings;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;

class TrackController extends Controller
{
    /** Driver app: locations of the phone during a trip (several at once after no signal). */
    public function driver(Request $request): JsonResponse
    {
        $data = $request->validate([
            'points' => 'required|array|min:1|max:300',
            'points.*.lat' => 'required|numeric|between:-90,90',
            'points.*.lng' => 'required|numeric|between:-180,180',
            'points.*.speed' => 'nullable|numeric|min:0|max:300',
            'points.*.heading' => 'nullable|numeric|min:0|max:360',
            'points.*.accuracy' => 'nullable|numeric|min:0|max:100000',
            'points.*.at' => 'required|numeric',
        ]);
        $user = $request->user();
        $trip = DriverTrip::currentTrip($user);
        if (! $trip || ! $user->tracking_consent_at) {
            return response()->json(['ok' => false, 'tracking' => false, 'message' => $trip ? 'Location sharing is off.' : 'Not on a trip.']);
        }
        if (TrackSettings::source($trip->truck_id) === 'tracker') {
            return response()->json(['ok' => true, 'tracking' => false, 'message' => 'This truck has a GPS tracker.']);
        }

        $rows = [];
        foreach ($data['points'] as $p) {
            $at = Carbon::createFromTimestampMs((int) $p['at']);
            if ($at->gt(now()->addMinute()) || $at->lt(now()->subHours(12)) || ($p['accuracy'] ?? 0) > 500) {
                continue;
            }
            $rows[] = [
                'truck_id' => $trip->truck_id, 'deliverylog_id' => $trip->id, 'user_id' => $user->id,
                'lat' => $p['lat'], 'lng' => $p['lng'],
                'speed' => isset($p['speed']) ? round($p['speed'] * 3.6, 1) : null, // phones give m/s
                'heading' => isset($p['heading']) ? (int) $p['heading'] : null,
                'accuracy' => isset($p['accuracy']) ? (int) min(65000, $p['accuracy']) : null,
                'source' => 'app', 'recorded_at' => $at,
            ];
        }
        if ($rows) {
            TruckPosition::insert($rows);
        }

        return response()->json(['ok' => true, 'tracking' => true, 'saved' => count($rows), 'interval' => TrackSettings::int('interval'), 'trip' => $trip->trip_number]);
    }

    /**
     * GPS trackers (or Traccar forwarding): /track/in/{token}?id=PLATE&lat=..&lon=..&speed=..&timestamp=..
     * Speed in km/h; timestamp in seconds or an ISO date (optional).
     */
    public function tracker(Request $request, string $token): JsonResponse
    {
        abort_unless(hash_equals(TrackSettings::trackerToken(), $token), 404);
        $id = trim((string) ($request->input('id') ?? $request->input('plate') ?? $request->input('deviceid')));
        $lat = $request->input('lat');
        $lng = $request->input('lon') ?? $request->input('lng');
        abort_unless($id !== '' && is_numeric($lat) && is_numeric($lng) && abs($lat) <= 90 && abs($lng) <= 180, 422, 'Need id, lat and lon.');

        // "ABC1234", "ABC 1234" and "abc-1234" are the same plate
        $plain = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', $id));
        $truck = Truck::where('plate_no', $id)->first()
            ?? Truck::whereRaw("REPLACE(REPLACE(REPLACE(UPPER(plate_no), ' ', ''), '-', ''), '_', '') = ?", [$plain])->first();
        abort_unless($truck, 404, 'No truck with that plate.');
        $ts = $request->input('timestamp');
        $at = is_numeric($ts) ? Carbon::createFromTimestamp((int) ($ts > 1e11 ? $ts / 1000 : $ts)) : ($ts ? Carbon::parse($ts) : now());

        $trip = Deliverylog::where('truck_id', $truck->id)->where('is_active', true)->latest('id')->first();
        if (! $trip) {
            return response()->json(['ok' => true, 'saved' => 0, 'message' => 'Not on a trip: not saved.']);
        }
        TruckPosition::create([
            'truck_id' => $truck->id, 'deliverylog_id' => $trip->id, 'lat' => $lat, 'lng' => $lng,
            'speed' => is_numeric($request->input('speed')) ? (float) $request->input('speed') : null,
            'heading' => is_numeric($request->input('bearing') ?? $request->input('heading')) ? (int) ($request->input('bearing') ?? $request->input('heading')) : null,
            'source' => 'tracker', 'recorded_at' => $at->min(now()),
        ]);

        return response()->json(['ok' => true, 'saved' => 1]);
    }
}
