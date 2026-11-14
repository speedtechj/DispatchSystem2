<?php

namespace App\Support\Fuel;

use App\Models\AppSetting;
use App\Models\Deliverylog;
use App\Models\Fuel\FuelCash;
use App\Models\Fuel\FuelFill;
use App\Models\Maps\TripRoute;
use App\Models\Tracking\TruckPosition;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Support\Maps\RoutePlanner;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Fuel: settings, diesel or gasoline, this week's price from the receipts, km per liter,
 * the cash estimate for a trip, and saving a fill with its checks.
 */
class Fuel
{
    public const TYPES = ['diesel' => 'Diesel', 'gasoline' => 'Gasoline'];

    public const PROVIDERS = ['petron' => 'Petron Fleet Card', 'shell' => 'Shell Fleet Card', 'caltex' => 'Caltex StarCard', 'seaoil' => 'SEAOIL PriceLOCQ', 'other' => 'Other'];

    /** Product names on receipts. Diesel words are checked first ("V-Power Diesel" is diesel). */
    protected const DIESEL = ['diesel', 'biodiesel', 'turbo d', 'diesel max', 'techron d', 'fuelsave d', 'ado', 'gasoil', 'gas oil'];

    protected const GASOLINE = ['gasoline', 'unleaded', 'premium', 'xcs', 'blaze', 'xtra', 'v-power', 'vpower', 'silver', 'platinum', 'extreme', 'super', 'regular', 'ron', 'gas 9', '91', '95', '97', '100', 'fuelsave g', 'sprint'];

    // ------------------------------------------------------------------ settings

    public static function setting(string $key, mixed $default = null): mixed
    {
        $v = AppSetting::get('fuel.'.$key, $default);

        return is_string($v) && str_starts_with($v, '{') ? (json_decode($v, true) ?? $v) : $v;
    }

    public static function put(string $key, mixed $value): void
    {
        AppSetting::put('fuel.'.$key, is_array($value) ? json_encode($value) : $value);
    }

    public static function companyTin(): string
    {
        return (string) static::setting('company_tin', '');
    }

    public static function cashMinKm(): int
    {
        return (int) static::setting('cash_min_km', 150);
    }

    public static function bufferPct(): int
    {
        return (int) static::setting('buffer_pct', 10);
    }

    public static function defaultKml(): float
    {
        return (float) static::setting('default_kml', 7);
    }

    public static function ready(): bool
    {
        return Schema::hasTable('fuel_fills');
    }

    // ------------------------------------------------------------------ diesel or gasoline

    /** "Diesel Max" → diesel, "XCS" → gasoline, unknown → null. */
    public static function typeOf(?string $product): ?string
    {
        $p = ' '.Str::lower(Str::ascii((string) $product)).' ';
        if (trim($p) === '') {
            return null;
        }
        foreach (static::DIESEL as $w) {
            if (str_contains($p, $w)) {
                return 'diesel';
            }
        }
        foreach (static::GASOLINE as $w) {
            if (preg_match('/(^|[^a-z0-9])'.preg_quote($w, '/').'([^a-z0-9]|$)/', $p)) {
                return 'gasoline';
            }
        }

        return null;
    }

    // ------------------------------------------------------------------ price

    /** The start of the price week: prices change on Tuesday. */
    public static function weekStart(?Carbon $day = null): Carbon
    {
        $day = ($day ?? now())->copy()->startOfDay();

        return $day->isTuesday() ? $day : $day->previous(Carbon::TUESDAY);
    }

    /**
     * This week's price per liter: the admin's price for this week, else the middle price of the
     * receipts since Tuesday, else last week's receipts.
     *
     * @return array{price: ?float, from: string, count: int}
     */
    public static function price(string $type, ?Carbon $day = null): array
    {
        $week = static::weekStart($day);
        $set = static::setting("price.{$type}");
        if (is_array($set) && ($set['week'] ?? null) === $week->toDateString() && ($set['price'] ?? 0) > 0) {
            return ['price' => (float) $set['price'], 'from' => 'set by the office', 'count' => 0];
        }
        foreach ([[$week, $week->copy()->addWeek()], [$week->copy()->subWeek(), $week]] as $i => [$from, $to]) {
            $prices = FuelFill::where('fuel_type', $type)->whereNotNull('price_per_liter')
                ->where('filled_at', '>=', $from)->where('filled_at', '<', $to)->pluck('price_per_liter');
            if ($prices->isNotEmpty()) {
                return ['price' => static::median($prices), 'from' => ($i ? 'last week\'s ' : '').$prices->count().' '.Str::plural('receipt', $prices->count()), 'count' => $prices->count()];
            }
        }

        return ['price' => null, 'from' => 'no receipts yet', 'count' => 0];
    }

    /** @return list<array{week: Carbon, diesel: ?float, gasoline: ?float}> */
    public static function priceWeeks(int $weeks = 6): array
    {
        $out = [];
        $start = static::weekStart();
        for ($i = 0; $i < $weeks; $i++) {
            $w = $start->copy()->subWeeks($i);
            $row = ['week' => $w];
            foreach (array_keys(static::TYPES) as $type) {
                $p = FuelFill::where('fuel_type', $type)->whereNotNull('price_per_liter')
                    ->where('filled_at', '>=', $w)->where('filled_at', '<', $w->copy()->addWeek())->pluck('price_per_liter');
                $row[$type] = $p->isNotEmpty() ? static::median($p) : null;
            }
            $out[] = $row;
        }

        return $out;
    }

    public static function median(Collection $values): float
    {
        $v = $values->map(fn ($x) => (float) $x)->sort()->values();
        $n = $v->count();

        return round($n % 2 ? $v[intdiv($n, 2)] : ($v[$n / 2 - 1] + $v[$n / 2]) / 2, 2);
    }

    // ------------------------------------------------------------------ km per liter

    /** The truck's usual km per liter (last 5 fills with an odometer), or null. */
    public static function kml(int $truckId, int $last = 5, int $skip = 0): ?float
    {
        $fills = FuelFill::where('truck_id', $truckId)->whereNotNull('km_since')->where('km_since', '>', 0)
            ->orderByDesc('filled_at')->skip($skip)->take($last)->get(['km_since', 'liters']);
        $l = $fills->sum('liters');

        return $fills->isNotEmpty() && $l > 0 ? round($fills->sum('km_since') / $l, 1) : null;
    }

    // ------------------------------------------------------------------ cash for a trip

    /**
     * Cash for a trip: trip km ÷ the truck's km per liter × this week's price + buffer,
     * rounded up to ₱10. Pieces are null when not known yet.
     *
     * @return array{km: ?float, kml: float, kmlFrom: string, type: string, price: ?float, priceFrom: string, buffer: int, liters: ?float, amount: ?float, short: bool}
     */
    public static function estimate(Deliverylog $trip): array
    {
        $truck = $trip->truck;
        $km = TripRoute::where('deliverylog_id', $trip->id)->value('km');
        $kml = $truck ? static::kml($truck->id) : null;
        $type = $truck?->fuel_type ?: 'diesel';
        $p = static::price($type);
        $buffer = static::bufferPct();
        $liters = $km ? round($km / ($kml ?: static::defaultKml()), 1) : null;
        $amount = $liters && $p['price'] ? ceil(round($liters * $p['price'] * (1 + $buffer / 100) / 10, 4)) * 10 : null;

        return [
            'km' => $km ? (float) $km : null, 'kml' => $kml ?: static::defaultKml(), 'kmlFrom' => $kml ? 'from its last fills' : 'usual for trucks (no fills yet)',
            'type' => $type, 'price' => $p['price'], 'priceFrom' => $p['from'], 'buffer' => $buffer, 'liters' => $liters, 'amount' => $amount,
            'short' => $km !== null && $km < static::cashMinKm(),
        ];
    }

    public static function cashFor(?Deliverylog $trip): ?FuelCash
    {
        return $trip ? FuelCash::where('deliverylog_id', $trip->id)->first() : null;
    }

    // ------------------------------------------------------------------ the driver's truck

    /** The truck the driver is on: today's trip, or the truck they are crew of. */
    public static function truckFor(User $driver, ?Deliverylog $trip): ?Truck
    {
        if ($trip?->truck) {
            return $trip->truck;
        }
        $id = Truckcrew::where('crew', $driver->id)->latest('id')->value('truck_id');

        return $id ? Truck::find($id) : null;
    }

    // ------------------------------------------------------------------ saving a fill

    /**
     * Save a fill and work out the checks: km since the last fill, km per liter, price per
     * liter when missing, VAT sums, the company TIN, and the truck GPS at that time.
     */
    public static function save(array $data, Truck $truck, ?User $driver, ?Deliverylog $trip): FuelFill
    {
        $at = Carbon::parse($data['filled_at'] ?? now());
        $liters = round((float) $data['liters'], 2);
        $total = round((float) $data['total'], 2);
        $price = (float) ($data['price_per_liter'] ?? 0) ?: ($liters > 0 ? round($total / $liters, 2) : null);
        $odo = isset($data['odometer']) && $data['odometer'] !== '' ? (int) $data['odometer'] : null;

        $prev = $odo ? FuelFill::where('truck_id', $truck->id)->whereNotNull('odometer')->where('filled_at', '<', $at)->orderByDesc('filled_at')->first() : null;
        $kmSince = $prev && $odo > $prev->odometer && $odo - $prev->odometer < 5000 ? $odo - $prev->odometer : null;

        [$gpsOk, $gpsM, $lat, $lng] = static::gpsCheck($truck->id, $at, $data['lat'] ?? null, $data['lng'] ?? null);

        $vat = isset($data['vat']) && $data['vat'] !== '' ? round((float) $data['vat'], 2) : null;
        $vatable = isset($data['vatable']) && $data['vatable'] !== '' ? round((float) $data['vatable'], 2) : ($vat !== null ? round($total - $vat, 2) : null);

        return FuelFill::create([
            'truck_id' => $truck->id, 'deliverylog_id' => $trip?->id, 'driver_id' => $driver?->id,
            'logistichub_id' => $truck->logistichub_id ?: $trip?->logistichub_id, 'filled_at' => $at,
            'station' => $data['station'] ?? null, 'product' => $data['product'] ?? null,
            'fuel_type' => $data['fuel_type'] ?? static::typeOf($data['product'] ?? null),
            'liters' => $liters, 'price_per_liter' => $price, 'total' => $total, 'vatable' => $vatable, 'vat' => $vat,
            'station_tin' => $data['station_tin'] ?? null, 'invoice_no' => $data['invoice_no'] ?? null,
            'buyer_tin_ok' => static::buyerTinOk($data['buyer_tin'] ?? null, $total, $data['buyer_tin_ok'] ?? null),
            'paid_with' => ($data['paid_with'] ?? 'card') === 'cash' ? 'cash' : 'card', 'card_last4' => $data['card_last4'] ?? null,
            'odometer' => $odo, 'km_since' => $kmSince, 'km_per_liter' => $kmSince && $liters > 0 ? round($kmSince / $liters, 2) : null,
            'receipt_path' => $data['receipt_path'] ?? null, 'odometer_path' => $data['odometer_path'] ?? null,
            'lat' => $lat, 'lng' => $lng, 'gps_ok' => $gpsOk, 'gps_distance_m' => $gpsM,
            'ai_read' => (bool) ($data['ai_read'] ?? false), 'ai_data' => $data['ai_data'] ?? null,
        ]);
    }

    /**
     * Is the company's TIN on the receipt? Only asked from ₱1,000 (below that the buyer's
     * details are not needed). Null when not known (no company TIN set, or nothing read).
     */
    public static function buyerTinOk(?string $buyerTin, float $total, mixed $told = null): ?bool
    {
        if ($told !== null && $told !== '') {
            return (bool) $told;
        }
        $mine = preg_replace('/\D/', '', static::companyTin());
        if ($total < 1000 || strlen($mine) < 9) {
            return null;
        }
        $theirs = preg_replace('/\D/', '', (string) $buyerTin);

        return $theirs !== '' && str_starts_with($theirs, substr($mine, 0, 9));
    }

    /**
     * Was the phone where the truck was? Compares the phone's location (when the driver
     * allowed it) with the truck GPS within 15 minutes of the fill.
     *
     * @return array{0: ?bool, 1: ?int, 2: ?float, 3: ?float}
     */
    public static function gpsCheck(int $truckId, Carbon $at, mixed $lat, mixed $lng): array
    {
        $pos = TruckPosition::where('truck_id', $truckId)
            ->whereBetween('recorded_at', [$at->copy()->subMinutes(15), $at->copy()->addMinutes(15)])
            ->get()->sortBy(fn ($p) => abs($p->recorded_at->diffInSeconds($at)))->first();
        $lat = is_numeric($lat) ? (float) $lat : null;
        $lng = is_numeric($lng) ? (float) $lng : null;
        if (! $pos) {
            return [null, null, $lat, $lng];
        }
        if ($lat === null || $lng === null) {
            return [null, null, $pos->lat, $pos->lng];
        }
        $m = (int) round(RoutePlanner::km([$lat, $lng], [$pos->lat, $pos->lng]) * 1000);

        return [$m <= 1000, $m, $lat, $lng];
    }
}
