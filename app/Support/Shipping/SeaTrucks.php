<?php

namespace App\Support\Shipping;

use App\Models\Deliverylog;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentStop;
use App\Models\Tripinvoice;
use App\Models\TripCrew;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Board 62: the trucks of a sea shipment. All its trips (one per partner hub) go with the main truck
 * (the truck of its main trip) unless a trip keeps its own truck (a second truck).
 * Only the carrying trip is loaded, driven and seen in the Driver app; the others "go with" it.
 */
class SeaTrucks
{
    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Shipments::stopsReady() && Schema::hasColumn('sea_shipment_stops', 'carrier_trip_id');
    }

    /** The trip whose truck carries this stop. */
    public static function carrierOf(SeaShipment $s, SeaShipmentStop $stop): int
    {
        return (int) ($stop->carrier_trip_id ?: $s->deliverylog_id);
    }

    public static function rides(SeaShipment $s, SeaShipmentStop $stop): bool
    {
        return static::carrierOf($s, $stop) !== (int) $stop->deliverylog_id;
    }

    /**
     * Trips that go with another trip's truck and are still on their way (not received).
     *
     * @return list<int>
     */
    public static function riderTripIds(): array
    {
        if (! static::ready()) {
            return [];
        }

        return (DB::table('sea_shipment_stops as st')->join('sea_shipments as s', 's.id', '=', 'st.sea_shipment_id')
            ->whereNull('st.received_at')->where('s.status', '!=', 'received')
            ->whereRaw('coalesce(st.carrier_trip_id, s.deliverylog_id) <> st.deliverylog_id')
            ->pluck('st.deliverylog_id')->map(fn ($i) => (int) $i)->all());
    }

    /**
     * The trips whose boxes this trip's truck carries: itself and the trips that go with it.
     *
     * @return list<int>
     */
    public static function carriedBy(int $tripId): array
    {
        if (! static::ready() || ! $tripId) {
            return [$tripId];
        }
        $s = Shipments::forTrip($tripId);
        if (! $s) {
            return [$tripId];
        }
        $ids = Shipments::stops($s)->filter(fn ($st) => static::carrierOf($s, $st) === $tripId)->pluck('deliverylog_id')->map(fn ($i) => (int) $i)->all();

        return in_array($tripId, $ids, true) ? $ids : array_merge([$tripId], $ids);
    }

    /** The carrying trip of a trip (itself when it drives). */
    public static function carrierTrip(int $tripId): int
    {
        if (! static::ready() || ! ($s = Shipments::forTrip($tripId)) || ! ($stop = Shipments::stopOf($s, $tripId))) {
            return $tripId;
        }

        return static::carrierOf($s, $stop);
    }

    /**
     * The trucks of a shipment: [trip, truck plate, crew, stops it carries, loaded, total, cost].
     *
     * @return Collection<int, array>
     */
    public static function trucks(SeaShipment $s): Collection
    {
        $stops = Shipments::stops($s);
        $byCarrier = $stops->groupBy(fn ($st) => static::ready() ? static::carrierOf($s, $st) : (int) $st->deliverylog_id);
        $trips = Deliverylog::with('truck:id,plate_no')->whereIn('id', $byCarrier->keys())->get()->keyBy('id');
        $crew = TripCrew::with('user:id,first_name,last_name')->whereIn('deliverylog_id', $byCarrier->keys())->get()->groupBy('deliverylog_id');
        $rows = Tripinvoice::whereIn('deliverylog_id', $stops->pluck('deliverylog_id'))->selectRaw('deliverylog_id, count(*) n, sum(case when is_loaded = 1 then 1 else 0 end) l')
            ->groupBy('deliverylog_id')->toBase()->get()->keyBy('deliverylog_id');

        return $byCarrier->map(function (Collection $carried, $tripId) use ($s, $trips, $crew, $rows, $stops) {
            $t = $trips[$tripId] ?? null;
            $own = $stops->firstWhere('deliverylog_id', (int) $tripId);
            $main = (int) $tripId === (int) $s->deliverylog_id;

            return [
                'trip' => $t, 'tripId' => (int) $tripId, 'main' => $main, 'plate' => $t?->truck?->plate_no,
                'crew' => ($crew[$tripId] ?? collect())->map(fn ($c) => trim($c->user?->first_name.' '.mb_substr((string) $c->user?->last_name, 0, 1)).($c->role ? ' ('.$c->role.')' : ''))->filter()->values()->all(),
                'stops' => $carried->sortBy('stop')->values(),
                'loaded' => (int) $carried->sum(fn ($st) => (int) ($rows[$st->deliverylog_id]->l ?? 0)),
                'total' => (int) $carried->sum(fn ($st) => (int) ($rows[$st->deliverylog_id]->n ?? 0)),
                'cost' => $main ? $s->cost_trucking : $own?->trucking_cost,
            ];
        })->sortByDesc('main')->values();
    }

    /** A trip goes with the main truck. Its own truck is kept to give back. */
    public static function goWithMain(SeaShipment $s, int $tripId): bool
    {
        $stop = Shipments::stopOf($s, $tripId);
        if (! static::ready() || ! $stop || ! $stop->exists || $tripId === (int) $s->deliverylog_id || ! static::canChange($s)) {
            return false;
        }
        $trip = Deliverylog::find($tripId);
        $main = Deliverylog::find($s->deliverylog_id);
        DB::transaction(function () use ($stop, $trip, $main) {
            $stop->update(['carrier_trip_id' => null, 'own_truck_id' => $stop->own_truck_id ?? $trip?->truck_id, 'trucking_cost' => null]);
            // the trip shows the truck it goes with; its own crew is not on it any more
            $trip?->forceFill(['truck_id' => $main?->truck_id])->saveQuietly();
        });

        return true;
    }

    /** A trip keeps (gets back) its own truck: a second truck. */
    public static function ownTruck(SeaShipment $s, int $tripId, ?int $truckId = null): bool
    {
        $stop = Shipments::stopOf($s, $tripId);
        if (! static::ready() || ! $stop || ! $stop->exists || $tripId === (int) $s->deliverylog_id || ! static::canChange($s)) {
            return false;
        }
        $truck = $truckId ?: $stop->own_truck_id;
        if (! $truck) {
            return false;
        }
        DB::transaction(function () use ($stop, $tripId, $truck) {
            $stop->update(['carrier_trip_id' => $tripId]);
            Deliverylog::whereKey($tripId)->update(['truck_id' => $truck]);
        });

        return true;
    }

    /** Trucks can change until the shipment leaves for the port. */
    public static function canChange(SeaShipment $s): bool
    {
        return in_array($s->status, ['preparing', 'sealed'], true);
    }

    /** The trucking of a second truck. */
    public static function setCost(SeaShipment $s, int $tripId, ?float $cost): void
    {
        if ($tripId === (int) $s->deliverylog_id) {
            $s->update(['cost_trucking' => $cost]);
        } elseif ($stop = Shipments::stopOf($s, $tripId)) {
            $stop->exists && $stop->update(['trucking_cost' => $cost]);
        }
    }

    // ------------------------------------------------------------------ driver (RoRo)

    /** A RoRo shipment this driver's trip carries, while it is on its way. */
    public static function roroFor(?Deliverylog $trip): ?SeaShipment
    {
        if (! $trip || ! Shipments::ready()) {
            return null;
        }
        $s = Shipments::forTrip($trip->id);
        if (! $s || $s->mode !== 'roro' || ! in_array($s->status, ['sealed', 'to_port', 'sailed', 'arrived'], true)) {
            return null;
        }

        return static::carrierTrip($trip->id) === (int) $trip->id ? $s : null;
    }

    /** What the RoRo driver presses next: [key, label] or null. */
    public static function roroNext(SeaShipment $s, int $tripId): ?array
    {
        return match ($s->status) {
            'sealed' => ['to_port', 'Leaving for the port'],
            'to_port' => ['sailed', 'On the ship'],
            'sailed' => ['arrived', 'Off the ship'],
            'arrived' => ($stop = static::nextDrop($s, $tripId)) ? ['stop:'.$stop->deliverylog_id, 'Arrived at '.$stop->hub?->hub_name] : null,
            default => null,
        };
    }

    /** The next hub our truck drops at (stops it carries, not arrived yet). */
    public static function nextDrop(SeaShipment $s, int $tripId): ?SeaShipmentStop
    {
        return Shipments::stops($s)->filter(fn ($st) => (! static::ready() || static::carrierOf($s, $st) === $tripId) && ! $st->arrived_at && ! $st->received_at)->sortBy('stop')->first();
    }

    /** The driver pressed the next RoRo step. The ship's details can come later from the office. */
    public static function roroStep(SeaShipment $s, int $tripId, string $key): bool
    {
        $next = static::roroNext($s, $tripId);
        if (! $next || $next[0] !== $key) {
            return false;
        }
        if (str_starts_with($key, 'stop:')) {
            $stop = Shipments::stopOf($s, (int) substr($key, 5));

            return (bool) $stop?->update(['arrived_at' => now()]);
        }
        $log = (array) $s->status_log;
        $log[] = ['status' => $key, 'at' => now()->toIso8601String(), 'by' => Auth::id(), 'driver' => true];
        $s->update(['status' => $key, 'status_log' => $log]);

        return true;
    }
}
