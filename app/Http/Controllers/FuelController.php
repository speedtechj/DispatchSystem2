<?php

namespace App\Http\Controllers;

use App\Support\Fuel\Fuel;
use App\Support\Fuel\FuelReport;
use App\Support\Tracking\Tracker;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\StreamedResponse;

/** Fuel › VAT: the month's fuel receipts as a CSV file the accountant opens in Excel. */
class FuelController extends Controller
{
    public function vatExport(Request $request): StreamedResponse
    {
        abort_unless(Fuel::ready(), 404);
        $panel = in_array($request->query('panel'), ['admin', 'warehouse', 'company'], true) ? $request->query('panel') : 'warehouse';
        $hub = Tracker::hubFor($request->user(), $panel);
        abort_if($hub === false, 403);
        $month = preg_match('/^\d{4}-\d{2}$/', (string) $request->query('month')) ? $request->query('month') : now()->format('Y-m');
        $report = new FuelReport($hub, $month);
        $fills = $report->fills()->with(['truck', 'trip'])->orderBy('filled_at')->get();

        return response()->streamDownload(function () use ($fills) {
            $out = fopen('php://output', 'w');
            fwrite($out, "\xEF\xBB\xBF"); // so Excel reads ₱ and ñ
            fputcsv($out, ['Date', 'Station', 'Station TIN', 'Invoice no.', 'Product', 'Fuel', 'Liters', 'Price per liter', 'VATable sales', 'VAT 12%', 'Total', 'Company TIN on receipt', 'Paid with', 'Truck', 'Trip'], ',', '"', '\\');
            foreach ($fills as $f) {
                fputcsv($out, [
                    $f->filled_at->format('Y-m-d H:i'), $f->station, $f->station_tin, $f->invoice_no, $f->product, $f->fuel_type,
                    $f->liters, $f->price_per_liter, $f->vatable, $f->vat, $f->total,
                    $f->buyer_tin_ok === true ? 'yes' : ($f->buyer_tin_ok === false ? 'MISSING' : ($f->total < 1000 ? 'not needed' : '')),
                    $f->paid_with, $f->truck?->plate_no, $f->trip?->trip_number,
                ], ',', '"', '\\');
            }
            fputcsv($out, ['', 'Total', '', '', '', '', $fills->sum('liters'), '', $fills->sum('vatable'), $fills->sum('vat'), $fills->sum('total')], ',', '"', '\\');
            fclose($out);
        }, "fuel-vat-{$month}.csv", ['Content-Type' => 'text/csv; charset=UTF-8']);
    }
}
