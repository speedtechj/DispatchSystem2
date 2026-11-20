<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\RentalCompany;
use App\Models\Truck;
use App\Models\TruckBooking;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;

/**
 * Rental trucks: shown in trip lists, the AI and the crew board only on the days they are booked;
 * your own trucks first; the rental cost of each trip (per trip, per day or per km).
 */
class Rentals
{
    public const RATES = ['trip' => 'Per trip', 'day' => 'Per day', 'km' => 'Per km'];

    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Schema::hasColumn('trucks', 'ownership') && Schema::hasTable('truck_bookings');
    }

    /** Trucks usable on this day: own trucks, and rentals booked that day. */
    public static function usable(Builder $q, ?Carbon $day = null): Builder
    {
        if (! static::ready()) {
            return $q;
        }
        $day = ($day ?? today())->toDateString();

        return $q->where(fn ($q) => $q->where('ownership', '!=', 'rental')->orWhereNull('ownership')
            ->orWhereIn('id', TruckBooking::whereDate('day', $day)->select('truck_id')));
    }

    public static function isBooked(Truck $truck, ?Carbon $day = null): bool
    {
        return static::ready() && TruckBooking::where('truck_id', $truck->id)->whereDate('day', ($day ?? today())->toDateString())->exists();
    }

    /** Book or free a day. Returns true when the day is now booked. */
    public static function toggleDay(Truck $truck, Carbon $day): bool
    {
        $row = TruckBooking::where('truck_id', $truck->id)->whereDate('day', $day->toDateString())->first();
        if ($row) {
            $row->delete();

            return false;
        }
        TruckBooking::create(['truck_id' => $truck->id, 'day' => $day->toDateString(), 'user_id' => Auth::id()]);

        return true;
    }

    /** @return list<string> Y-m-d of the booked days in this month */
    public static function bookedDays(Truck $truck, Carbon $month): array
    {
        return TruckBooking::where('truck_id', $truck->id)
            ->whereBetween('day', [$month->copy()->startOfMonth()->toDateString(), $month->copy()->endOfMonth()->toDateString()])
            ->pluck('day')->map(fn ($d) => Carbon::parse($d)->toDateString())->all();
    }

    public static function nextBooking(Truck $truck): ?Carbon
    {
        $d = TruckBooking::where('truck_id', $truck->id)->whereDate('day', '>', today()->toDateString())->orderBy('day')->value('day');

        return $d ? Carbon::parse($d) : null;
    }

    /** How the truck charges, in words: "₱3,500 a trip · ₱28 a km". */
    public static function rateText(Truck $truck): string
    {
        return collect(['trip' => $truck->rate_trip, 'day' => $truck->rate_day, 'km' => $truck->rate_km])
            ->filter(fn ($v) => $v > 0)->map(fn ($v, $k) => '₱'.number_format($v).' a '.$k)->join(' · ');
    }

    /**
     * The rental cost of a trip: per trip if set, else per day (once a day per truck), else per km
     * (when the km is filled in). Returns [cost, rate key] or [null, null].
     */
    public static function costOf(Deliverylog $trip): array
    {
        $truck = $trip->truck;
        if (! $truck || ! $truck->isRental()) {
            return [null, null];
        }
        if ($truck->rate_trip > 0) {
            return [(float) $truck->rate_trip, 'trip'];
        }
        if ($truck->rate_day > 0) {
            $day = Carbon::parse($trip->departure_date ?? $trip->created_at ?? now())->toDateString();
            $first = Deliverylog::where('truck_id', $truck->id)->whereDate('departure_date', $day)->orderBy('id')->value('id');

            return [$first && $first !== $trip->id ? 0.0 : (float) $truck->rate_day, 'day'];
        }
        if ($truck->rate_km > 0) {
            return [$trip->rental_km ? round($trip->rental_km * $truck->rate_km, 2) : null, 'km'];
        }

        return [null, null];
    }

    /** A trip got a rental truck: note the rental driver and the cost. */
    public static function fillTrip(Deliverylog $trip): void
    {
        if (! static::ready()) {
            return;
        }
        $truck = $trip->truck_id ? Truck::find($trip->truck_id) : null;
        if (! $truck || ! $truck->isRental()) {
            $trip->rental_driver = null;
            $trip->rental_cost = null;
            $trip->rental_rate = null;

            return;
        }
        $trip->setRelation('truck', $truck);
        $trip->rental_driver ??= $truck->rental_driver;
        [$cost, $rate] = static::costOf($trip);
        $trip->rental_cost = $cost;
        $trip->rental_rate = $rate;
    }

    /**
     * Rental trips of a month (optionally one company): date, trip, truck, charge, boxes, per box.
     *
     * @return Collection<int, array>
     */
    public static function month(Carbon $month, ?int $companyId = null, int|false|null $hub = null): Collection
    {
        if (! static::ready() || $hub === false) {
            return collect();
        }

        return Deliverylog::with('truck.rentalCompany', 'destination:id,hub_name')
            ->whereIn('truck_id', Truck::where('ownership', 'rental')->when($companyId, fn ($q) => $q->where('rental_company_id', $companyId))->select('id'))
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))
            ->whereBetween('departure_date', [$month->copy()->startOfMonth()->toDateString(), $month->copy()->endOfMonth()->toDateString()])
            ->orderBy('departure_date')->get()
            ->map(function (Deliverylog $t) {
                $boxes = TripFlow::boxes($t)->count();

                return ['trip' => $t, 'date' => Carbon::parse($t->departure_date), 'company' => $t->truck?->rentalCompany?->name ?? '—',
                    'plate' => $t->truck?->plate_no, 'cost' => $t->rental_cost, 'rate' => $t->rental_rate, 'boxes' => $boxes,
                    'perBox' => $t->rental_cost !== null && $boxes ? round($t->rental_cost / $boxes) : null];
            });
    }

    /** Own trucks: fuel per box in the month (what you compare a rental with). */
    public static function ownPerBox(Carbon $month, int|false|null $hub = null): ?float
    {
        if (! \App\Support\Fuel\Fuel::ready() || $hub === false) {
            return null;
        }
        $own = Truck::where(fn ($q) => $q->where('ownership', '!=', 'rental')->orWhereNull('ownership'))->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->pluck('id');
        $range = [$month->copy()->startOfMonth(), $month->copy()->endOfMonth()];
        $fuel = (float) \App\Models\Fuel\FuelFill::whereIn('truck_id', $own)->whereBetween('filled_at', $range)->sum('total');
        $boxes = \App\Models\Tripinvoice::where('is_delivered', true)->whereBetween('updated_at', $range)
            ->whereIn('deliverylog_id', Deliverylog::whereIn('truck_id', $own)->select('id'))->count();

        return $fuel > 0 && $boxes > 0 ? round($fuel / $boxes) : null;
    }

    /** @return Collection<int, RentalCompany> */
    public static function companies(int|false|null $hub = null): Collection
    {
        return static::ready() ? RentalCompany::query()->when(is_int($hub), fn ($q) => $q->where(fn ($q) => $q->where('logistichub_id', $hub)->orWhereNull('logistichub_id')))->orderBy('name')->get() : collect();
    }
}
