<?php

namespace App\Support\Fuel;

use App\Models\Fuel\FuelFill;
use App\Models\Fuel\FuelStatement;
use App\Models\Fuel\FuelStatementLine;
use App\Models\Truck;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;

/**
 * Import a fuel card statement (CSV from Petron, Shell Fleet Hub, Caltex StarCard Online,
 * SEAOIL PriceLOCQ, or any other) and match each charge to a fill from the Driver app:
 * same truck, within 3 hours, and the same liters (3% either way).
 */
class FuelStatements
{
    /** Words in the column titles, for each thing we need. The first match wins. */
    protected const COLUMNS = [
        'datetime' => ['transaction date time', 'date/time', 'date time', 'datetime', 'txn date time', 'trans date time'],
        'date' => ['transaction date', 'trans date', 'txn date', 'date'],
        'time' => ['transaction time', 'trans time', 'txn time', 'time'],
        'card' => ['card number', 'card no', 'card #', 'pan', 'card'],
        'plate' => ['plate number', 'plate no', 'vehicle plate', 'plate', 'vehicle', 'registration'],
        'station' => ['station name', 'merchant name', 'site name', 'station', 'merchant', 'site', 'location'],
        'product' => ['product name', 'product description', 'product', 'item', 'fuel type', 'description'],
        'liters' => ['liters', 'litres', 'volume', 'quantity', 'qty', 'ltrs', 'ltr'],
        'amount' => ['net amount', 'total amount', 'amount', 'total', 'value', 'gross'],
        'odometer' => ['odometer', 'odo', 'mileage', 'km reading'],
    ];

    public const STATUS = [
        'matched' => 'Matched',
        'liters_differ' => 'Liters differ',
        'no_fill' => 'No fill in the app',
        'no_truck' => 'Card or plate not known',
    ];

    /** Read a CSV file and save the statement with each line matched. */
    public static function import(string $file, string $provider, ?int $userId, ?int $hub, string $name): FuelStatement
    {
        $rows = static::read($file);
        $statement = FuelStatement::create([
            'provider' => array_key_exists($provider, Fuel::PROVIDERS) ? $provider : 'other', 'filename' => Str::limit($name, 180, ''),
            'logistichub_id' => $hub, 'uploaded_by' => $userId, 'lines' => 0,
        ]);
        $trucks = Truck::query()->when($hub, fn ($q) => $q->where('logistichub_id', $hub))->get();
        $byCard = $trucks->filter(fn ($t) => $t->fuel_card_last4)->keyBy(fn ($t) => substr(preg_replace('/\D/', '', $t->fuel_card_last4), -4));
        $byPlate = $trucks->keyBy(fn ($t) => static::plate($t->plate_no));
        $used = [];
        $dates = [];

        foreach ($rows as $r) {
            if (! $r['amount'] && ! $r['liters']) {
                continue;
            }
            $card4 = $r['card'] ? substr(preg_replace('/\D/', '', $r['card']), -4) : null;
            $truck = ($card4 ? $byCard->get($card4) : null) ?? ($r['plate'] ? $byPlate->get(static::plate($r['plate'])) : null);
            [$status, $fillId] = $truck ? static::match($truck->id, $r['at'], $r['liters'], $used) : ['no_truck', null];
            if ($fillId) {
                $used[$fillId] = true;
            }
            FuelStatementLine::create([
                'fuel_statement_id' => $statement->id, 'truck_id' => $truck?->id, 'fuel_fill_id' => $fillId, 'charged_at' => $r['at'],
                'card' => $r['card'] ? '****'.$card4 : null, 'plate' => $r['plate'], 'station' => $r['station'], 'product' => $r['product'],
                'fuel_type' => Fuel::typeOf($r['product']), 'liters' => $r['liters'], 'amount' => $r['amount'], 'odometer' => $r['odometer'],
                'status' => $status,
            ]);
            if ($r['at']) {
                $dates[] = $r['at'];
            }
        }
        $statement->update([
            'lines' => $statement->lines()->count(),
            'from' => $dates ? min($dates)->toDateString() : null, 'to' => $dates ? max($dates)->toDateString() : null,
        ]);

        return $statement;
    }

    /** @return array{0: string, 1: ?int} */
    protected static function match(int $truckId, ?Carbon $at, ?float $liters, array $used): array
    {
        if (! $at) {
            return ['no_fill', null];
        }
        $fill = FuelFill::where('truck_id', $truckId)->whereBetween('filled_at', [$at->copy()->subHours(3), $at->copy()->addHours(3)])
            ->whereNotIn('id', array_keys($used))->get()
            ->sortBy(fn ($f) => [abs(($f->liters ?? 0) - ($liters ?? 0)) > max(1, ($liters ?? 0) * 0.03) ? 1 : 0, abs($f->filled_at->diffInSeconds($at))])
            ->first();
        if (! $fill) {
            return ['no_fill', null];
        }
        $same = $liters === null || abs($fill->liters - $liters) <= max(1, $liters * 0.03);

        return [$same ? 'matched' : 'liters_differ', $fill->id];
    }

    public static function plate(?string $p): string
    {
        return strtoupper(preg_replace('/[^A-Za-z0-9]/', '', (string) $p));
    }

    /**
     * The rows of a CSV statement, with the columns found by their titles.
     *
     * @return list<array{at: ?Carbon, card: ?string, plate: ?string, station: ?string, product: ?string, liters: ?float, amount: ?float, odometer: ?int}>
     */
    public static function read(string $file): array
    {
        $fh = fopen($file, 'r');
        if (! $fh) {
            return [];
        }
        $first = (string) fgets($fh);
        rewind($fh);
        $sep = substr_count($first, ';') > substr_count($first, ',') ? ';' : (substr_count($first, "\t") > substr_count($first, ',') ? "\t" : ',');

        $map = null;
        $rows = [];
        while (($cells = fgetcsv($fh, 0, $sep, '"', '\\')) !== false) {
            $cells = array_map(fn ($c) => trim((string) preg_replace('/^\xEF\xBB\xBF/', '', (string) $c)), $cells);
            if ($map === null) {
                $map = static::header($cells);
                if (count(array_intersect(array_keys($map), ['amount', 'liters'])) === 0) {
                    $map = null; // not the title row yet (statements often start with account details)
                }

                continue;
            }
            $get = fn ($k) => isset($map[$k]) && isset($cells[$map[$k]]) && $cells[$map[$k]] !== '' ? $cells[$map[$k]] : null;
            $num = fn ($v) => $v !== null && is_numeric($n = str_replace([',', '₱', 'PHP', ' '], '', $v)) ? (float) $n : null;
            $rows[] = [
                'at' => static::when($get('datetime') ?? trim(($get('date') ?? '').' '.($get('time') ?? ''))),
                'card' => $get('card'), 'plate' => $get('plate'), 'station' => $get('station'), 'product' => $get('product'),
                'liters' => $num($get('liters')), 'amount' => $num($get('amount')),
                'odometer' => ($o = $num($get('odometer'))) ? (int) $o : null,
            ];
        }
        fclose($fh);

        return $rows;
    }

    /** column => index */
    protected static function header(array $cells): array
    {
        $titles = array_map(fn ($c) => trim(preg_replace('/\s+/', ' ', Str::lower(str_replace(['_', '.'], ' ', $c)))), $cells);
        $map = [];
        foreach (static::COLUMNS as $key => $words) {
            foreach ($words as $w) {
                foreach ($titles as $i => $t) {
                    if (! in_array($i, $map, true) && ($t === $w || str_contains($t, $w))) {
                        $map[$key] = $i;

                        continue 3;
                    }
                }
            }
        }

        return $map;
    }

    protected static function when(?string $v): ?Carbon
    {
        $v = trim((string) $v);
        if ($v === '') {
            return null;
        }
        foreach (['m/d/Y H:i:s', 'm/d/Y H:i', 'm/d/Y g:i A', 'm/d/Y g:i:s A', 'Y-m-d H:i:s', 'Y-m-d H:i', 'd-M-Y H:i', 'd/m/Y H:i', 'm/d/Y', 'Y-m-d'] as $f) {
            try {
                $d = Carbon::createFromFormat($f, $v);
                if ($d !== false && $d->format($f) === $v) {
                    return $d;
                }
            } catch (\Throwable) {
            }
        }
        try {
            return Carbon::parse($v);
        } catch (\Throwable) {
            return null;
        }
    }
}
