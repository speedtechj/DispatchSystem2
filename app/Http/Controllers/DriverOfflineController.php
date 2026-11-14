<?php

namespace App\Http\Controllers;

use App\Enums\FailedDeliveryReason;
use App\Models\Maps\TripStop;
use App\Models\OfflineSubmission;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Branding;
use App\Support\DriverTrip;
use App\Support\Maps\TripSorter;
use App\Support\Photos\PhotoShrinker;
use DomainException;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

/**
 * Driver app without signal.
 *  - trip():  today's boxes, saved on the phone while there is signal.
 *  - sync():  one delivery or not-delivered saved on the phone, sent when the signal is back.
 *             Uses the same rules as the app (TripAssignment). Sending the same one twice does nothing.
 *  - shell(): the page the phone opens with no signal (no data in it; it reads what the phone saved).
 */
class DriverOfflineController extends Controller
{
    /** How far back a phone time is believed (older = "now"). */
    public const MAX_AGE_HOURS = 48;

    protected function driver(): ?User
    {
        $user = Auth::user();

        return $user && $user->is_active && $user->panelcategory?->code === 'drv' && ! $user->is_admin ? $user : null;
    }

    public function trip(): JsonResponse
    {
        $driver = $this->driver();
        if (! $driver) {
            return response()->json(['message' => 'Sign in to the Driver app.'], 401);
        }

        $trip = DriverTrip::for($driver);
        $boxes = $trip->trip
            ? $trip->boxes()->with('invdata')->withCount('deliveryAttempts')->orderBy('invoice')->get()
            : collect();

        return response()->json([
            'csrf' => csrf_token(),
            'saved_at' => now()->toIso8601String(),
            'driver' => ['id' => $driver->id, 'first_name' => $driver->first_name],
            'trip' => $trip->trip ? [
                'id' => $trip->trip->id,
                'number' => $trip->trip->trip_number,
                'plate' => $trip->trip->truck?->plate_no,
            ] : null,
            'boxes' => $boxes->map(fn (Tripinvoice $b) => [
                'id' => $b->id,
                'invoice' => $b->invoice,
                'codes' => array_values(array_unique(array_filter([$b->invoice, $b->invdata?->invoice]))),
                'name' => Str::title((string) $b->invdata?->receiver_name),
                'address' => collect([$b->invdata?->receiver_address, $b->invdata?->receiver_barangay, $b->invdata?->receiver_city])
                    ->filter()->map(fn ($p) => Str::title($p))->join(', '),
                'phone' => $b->invdata?->receiver_mobile_no,
                'delivered' => (bool) $b->is_delivered,
                'attempted' => $b->delivery_attempts_count > 0,
            ])->values(),
            // Maps & routes: the stops in order, so Navigate works without signal too
            'stops' => $trip->trip && TripSorter::ensure($trip->trip, 0)
                ? TripSorter::stops($trip->trip)->map(fn (TripStop $s) => [
                    'id' => $s->id, 'no' => $s->stop_no, 'name' => $s->name, 'address' => $s->address,
                    'place' => trim(($s->barangay ? $s->barangay.', ' : '').$s->city, ', '),
                    'lat' => $s->lat, 'lng' => $s->lng, 'exact' => $s->exact, 'priority' => $s->priority,
                    'go' => $s->hasPin() ? $s->lat.','.$s->lng : $s->address.', Philippines',
                    'phone' => $s->phone, 'boxes' => array_map('intval', $s->box_ids ?? []),
                ])->values()
                : [],
            'reasons' => collect(FailedDeliveryReason::cases())->map(fn (FailedDeliveryReason $r) => [
                'value' => $r->value, 'label' => $r->getLabel(), 'prompt' => $r->notePrompt(),
                'note' => $r->requiresNote(), 'photo' => $r->requiresPhoto(),
            ])->values(),
        ]);
    }

    public function sync(Request $request): JsonResponse
    {
        $driver = $this->driver();
        if (! $driver) {
            return response()->json(['message' => 'Sign in to the Driver app.'], 401);
        }

        $data = $request->validate([
            'uuid' => ['required', 'uuid'],
            'type' => ['required', 'in:deliver,miss'],
            'tripinvoice_id' => ['required', 'integer'],
            'at' => ['required', 'date'],
            'reason' => ['nullable', 'string'],
            'note' => ['nullable', 'string', 'max:500'],
            'photos' => ['array', 'max:12'],
            'photos.*' => ['image', 'max:12288'],
        ]);

        // Sent before (e.g. the answer got lost): give the same answer again.
        if ($done = OfflineSubmission::where('uuid', $data['uuid'])->where('user_id', $driver->id)->first()) {
            return $this->answer($done);
        }

        $at = Carbon::parse($data['at'])->setTimezone(config('app.timezone'));
        if ($at->isFuture() || $at->lt(now()->subHours(self::MAX_AGE_HOURS))) {
            $at = now();
        }

        $box = DriverTrip::for($driver)->boxes()->with('invdata')->find($data['tripinvoice_id']);
        $result = ['status' => 'saved', 'message' => null];

        if (! $box) {
            $result = ['status' => 'conflict', 'message' => 'This box is no longer on your trip. Keep it on the truck and call the office.'];
        } elseif ($box->is_delivered) {
            $mine = (int) $box->delivered_by === (int) $driver->id;
            $result = $mine
                ? ['status' => 'saved', 'message' => 'Already delivered by you.']
                : ['status' => 'conflict', 'message' => 'Someone else already marked this box delivered. Call the office.'];
        } else {
            $dir = $data['type'] === 'deliver' ? $box->invoice : 'not-delivered/'.$box->invoice;
            $paths = collect($request->file('photos', []))->map(function ($f) use ($dir) {
                $path = $f->store($dir, 'public');
                PhotoShrinker::file('public', $path);

                return $path;
            })->all();

            try {
                DB::transaction(function () use ($data, $box, $driver, $paths, $at): void {
                    $service = app(TripAssignment::class);
                    if ($data['type'] === 'deliver') {
                        if ($paths === []) {
                            throw new DomainException('A delivery needs at least one photo.');
                        }
                        $service->markDelivered($box, $paths, $driver);
                        $box->forceFill(['delivered_at' => $at])->save();
                    } else {
                        $reason = FailedDeliveryReason::tryFrom((string) ($data['reason'] ?? '')) ?? FailedDeliveryReason::Other;
                        $attempt = $service->recordFailedAttempt($box, $driver, $reason, $data['note'] ?? null, $paths);
                        $attempt->forceFill(['created_at' => $at])->save();
                    }
                });
            } catch (DomainException $e) {
                foreach ($paths as $p) {
                    Storage::disk('public')->delete($p);
                }
                $result = ['status' => 'conflict', 'message' => $e->getMessage()];
            }
        }

        $row = OfflineSubmission::create([
            'uuid' => $data['uuid'], 'user_id' => $driver->id, 'tripinvoice_id' => $data['tripinvoice_id'],
            'type' => $data['type'], 'status' => $result['status'], 'message' => $result['message'], 'happened_at' => $at,
            'payload' => ['reason' => $data['reason'] ?? null, 'note' => $data['note'] ?? null, 'photos' => count($request->file('photos', []))],
        ]);

        return $this->answer($row);
    }

    protected function answer(OfflineSubmission $row): JsonResponse
    {
        return response()->json(['uuid' => $row->uuid, 'status' => $row->status, 'message' => $row->message]);
    }

    /** The page the phone opens with no signal. It holds no data; driver-offline.js reads what the phone saved. */
    public function shell(): Response
    {
        return response(view('pwa.driver-offline', [
            'company' => Branding::companyName(),
            'script' => asset('js/app/driver-offline.js').'?v='.self::scriptVersion(),
        ])->render(), 200, ['Cache-Control' => 'no-cache']);
    }

    public static function scriptVersion(): string
    {
        $file = public_path('js/app/driver-offline.js');

        return is_file($file) ? substr(md5((string) filemtime($file)), 0, 8) : '0';
    }
}
