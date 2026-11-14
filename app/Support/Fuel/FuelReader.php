<?php

namespace App\Support\Fuel;

use App\Support\Ai\Ai;
use Illuminate\Support\Str;

/**
 * Reads a fuel receipt photo (station, product, liters, price, total, VAT, TIN, invoice no.,
 * card) and an odometer photo with the AI. Off, or nothing read: the driver types it.
 */
class FuelReader
{
    public static function on(): bool
    {
        try {
            return Ai::enabled('fuel_receipts');
        } catch (\Throwable) {
            return false;
        }
    }

    /** @return array<string, mixed> only the fields that were read */
    public static function receipt(string $path): array
    {
        if (! static::on() || ! ($image = Ai::image('public', $path))) {
            return [];
        }
        $system = 'You read fuel station receipts (sales invoices) from the Philippines: Petron, Shell, Caltex, SEAOIL, Phoenix, Unioil, Cleanfuel and others. '
            .'Read only what is printed; use null for anything you cannot read. Numbers without commas or peso signs. '
            .'fuel_type: "diesel" or "gasoline" from the product name (Diesel Max, Turbo Diesel, V-Power Diesel, FuelSave Diesel → diesel; XCS, Blaze, Xtra Advance, V-Power, Silver, Platinum, Unleaded, Extreme 95/97 → gasoline). '
            .'vatable = "VATable sales"/"VAT sales"; vat = "VAT amount"/"12% VAT". station_tin = the seller TIN at the top. buyer_name and buyer_tin = the customer name and TIN written or printed for the buyer, if any. '
            .'card_last4 = last 4 digits of a fleet/credit card if shown. date as YYYY-MM-DD and time as HH:MM (24h) if shown. '
            .'Answer as {"station": str, "product": str, "fuel_type": str, "liters": num, "price_per_liter": num, "total": num, "vatable": num, "vat": num, '
            .'"station_tin": str, "invoice_no": str, "buyer_name": str, "buyer_tin": str, "card_last4": str, "odometer": int, "date": str, "time": str}.';
        try {
            $out = Ai::json('fuel_receipts', $system, [$image, ['type' => 'text', 'text' => 'Read this receipt.']], 'fast', 500);
        } catch (\Throwable) {
            return [];
        }

        $num = fn ($v) => is_numeric(str_replace(',', '', (string) $v)) ? round((float) str_replace(',', '', (string) $v), 2) : null;
        $str = fn ($v, $n = 120) => is_string($v) && trim($v) !== '' && strtolower(trim($v)) !== 'null' ? Str::limit(trim($v), $n, '') : null;
        $read = [
            'station' => $str($out['station'] ?? null), 'product' => $str($out['product'] ?? null, 80),
            'liters' => $num($out['liters'] ?? null), 'price_per_liter' => $num($out['price_per_liter'] ?? null), 'total' => $num($out['total'] ?? null),
            'vatable' => $num($out['vatable'] ?? null), 'vat' => $num($out['vat'] ?? null),
            'station_tin' => $str($out['station_tin'] ?? null, 30), 'invoice_no' => $str($out['invoice_no'] ?? null, 40),
            'buyer_tin' => $str($out['buyer_tin'] ?? null, 30), 'card_last4' => $str($out['card_last4'] ?? null, 8),
            'odometer' => is_numeric($out['odometer'] ?? null) ? (int) $out['odometer'] : null,
        ];
        $type = Fuel::typeOf($read['product']) ?? (in_array($out['fuel_type'] ?? null, ['diesel', 'gasoline'], true) ? $out['fuel_type'] : null);
        $read['fuel_type'] = $type;
        if (! empty($out['date']) && preg_match('/^\d{4}-\d{2}-\d{2}$/', (string) $out['date'])) {
            $when = $out['date'].' '.(preg_match('/^\d{1,2}:\d{2}$/', (string) ($out['time'] ?? '')) ? $out['time'] : '00:00');
            try {
                $at = \Illuminate\Support\Carbon::parse($when);
                if ($at->isBetween(now()->subDays(3), now()->addHour())) {
                    $read['filled_at'] = $at->format('Y-m-d H:i');
                }
            } catch (\Throwable) {
            }
        }
        // the numbers must agree: liters × price ≈ total
        if ($read['liters'] && $read['total'] && ! $read['price_per_liter']) {
            $read['price_per_liter'] = round($read['total'] / $read['liters'], 2);
        }

        return array_filter($read, fn ($v) => $v !== null);
    }

    public static function odometer(string $path): ?int
    {
        if (! static::on() || ! ($image = Ai::image('public', $path))) {
            return null;
        }
        try {
            $out = Ai::json('fuel_receipts', 'You read the odometer (total km) on a truck dashboard photo. Ignore the trip meter. Answer as {"odometer": int or null}.',
                [$image, ['type' => 'text', 'text' => 'Read the odometer.']], 'fast', 60);
        } catch (\Throwable) {
            return null;
        }

        return is_numeric($out['odometer'] ?? null) && (int) $out['odometer'] > 0 ? (int) $out['odometer'] : null;
    }

    /** Do the receipt numbers agree? liters × price ≈ total, VATable + VAT ≈ total. */
    public static function problems(array $f): array
    {
        $p = [];
        $l = (float) ($f['liters'] ?? 0);
        $pr = (float) ($f['price_per_liter'] ?? 0);
        $t = (float) ($f['total'] ?? 0);
        if ($l > 0 && $pr > 0 && $t > 0 && abs($l * $pr - $t) > max(2, $t * 0.01)) {
            $p[] = 'Liters × price is ₱'.number_format($l * $pr, 2).', not the total ₱'.number_format($t, 2).'.';
        }
        $v = $f['vat'] ?? null;
        $va = $f['vatable'] ?? null;
        if ($v !== null && $v !== '' && $va !== null && $va !== '' && $t > 0 && abs((float) $v + (float) $va - $t) > max(1, $t * 0.01)) {
            $p[] = 'VATable + VAT is not the total.';
        }

        return $p;
    }
}
