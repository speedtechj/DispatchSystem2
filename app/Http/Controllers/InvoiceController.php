<?php

namespace App\Http\Controllers;

use App\Models\AppSetting;
use App\Models\Consolidator;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use App\Models\User;
use Barryvdh\Snappy\Facades\SnappyPdf as PDF;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

class InvoiceController extends Controller
{
    /** Used until Admin sets another number in Settings → Printing. */
    public const BULK_LIMIT = 15;

    /** The most receipts one bulk print may hold (Admin → Settings → Printing). */
    public static function bulkLimit(): int
    {
        return max(1, min(100, (int) AppSetting::get('print.bulk_limit', self::BULK_LIMIT)));
    }

    /**
     * Printable delivery receipt for one invoice, including the truck and
     * crew of the most recent trip the invoice was loaded on.
     */
    public function tripinvoice(int $invoice): Response
    {
        $invoice = Invoice::findOrFail($invoice);

        return $this->pdf([$this->receiptHtml($invoice)], "invoice-{$invoice->invoice}.pdf");
    }

    /** Several receipts in one PDF, one receipt per page (at most the number set in Settings → Printing). */
    public function bulk(Request $request): Response
    {
        $ids = collect(explode(',', (string) $request->query('ids')))
            ->map(fn ($id) => (int) trim($id))->filter()->unique()->values();

        if ($ids->isEmpty()) {
            abort(422, 'Select the boxes to print.');
        }
        if ($ids->count() > static::bulkLimit()) {
            abort(422, 'You can print at most '.static::bulkLimit().' receipts at once.');
        }

        $invoices = Invoice::whereKey($ids)->get()->sortBy(fn ($i) => $ids->search($i->id))->values();
        abort_if($invoices->isEmpty(), 404);

        return $this->pdf($invoices->map(fn (Invoice $i) => $this->receiptHtml($i))->all(), 'receipts-'.now()->format('Ymd-His').'.pdf');
    }

    protected function receiptHtml(Invoice $invoice): string
    {
        $trip = Tripinvoice::with('deliverylog.truck')
            ->where('invoice_id', $invoice->id)
            ->latest('id')
            ->first()
            ?->deliverylog;

        $truck = $trip?->truck;

        $crew = $truck
            ? User::with('workposition')
                ->whereIn('id', Truckcrew::where('truck_id', $truck->id)->pluck('crew'))
                ->get()
            : collect();

        // The crew member whose position mentions "driver" is the driver; the next one is the assistant.
        $isDriver = fn (User $user) => Str::contains(
            Str::lower(($user->workposition?->code ?? '').' '.($user->workposition?->position_description ?? '')),
            ['driver', 'drv'],
        );

        $driver = $crew->first($isDriver) ?? $crew->first();
        $leadman = $crew->reject(fn (User $user) => $user->is($driver))->first();

        return view('invoices.pdfinvoice', [
            'invoice' => $invoice,
            'truck' => $truck,
            'driver' => $driver,
            'leadman' => $leadman,
            'consolidator' => Consolidator::where('code', $invoice->location_code)->first(),
        ])->render();
    }

    /**
     * Join several receipts into one document, each starting on a new page.
     * (One document, because many wkhtmltopdf builds can't take several.)
     *
     * @param  list<string>  $pages
     */
    protected function onePerPage(array $pages): string
    {
        $head = preg_match('~<head[^>]*>.*?</head>~is', $pages[0], $m) ? $m[0] : '<head><meta charset="UTF-8"></head>';
        $bodies = array_map(fn ($html) => preg_match('~<body[^>]*>(.*)</body>~is', $html, $b) ? $b[1] : $html, $pages);
        $last = count($bodies) - 1;

        return '<!DOCTYPE html><html>'.$head.'<body>'
            .implode('', array_map(fn ($body, $i) => '<div style="'.($i < $last ? 'page-break-after: always;' : '').'">'.$body.'</div>', $bodies, array_keys($bodies)))
            .'</body></html>';
    }

    /** @param  list<string>  $pages  one receipt per page */
    protected function pdf(array $pages, string $name): Response
    {
        $binary = config('snappy.pdf.binary');

        // A clear message instead of a crash when the PDF program isn't installed on this computer.
        if (! is_string($binary) || ! is_executable($binary)) {
            return response(
                "Cannot create the PDF receipt.\n\n"
                ."The PDF program (wkhtmltopdf) was not found at: {$binary}\n\n"
                ."Install wkhtmltopdf on this computer, then set its path in .env, for example:\n"
                ."WKHTML_PDF_BINARY=/usr/local/bin/wkhtmltopdf\n\n"
                ."Then run: php artisan config:clear\n",
                503,
                ['Content-Type' => 'text/plain; charset=utf-8'],
            );
        }

        $pdf = PDF::loadHTML(count($pages) === 1 ? $pages[0] : $this->onePerPage($pages));

        foreach (['margin-top', 'margin-bottom', 'margin-right', 'margin-left'] as $margin) {
            $pdf->setOption($margin, '5mm');
        }

        // The receipt loads logos and the barcode from files on this server.
        $pdf->setOption('enable-local-file-access', true);

        // A missing logo or image must not stop the whole receipt from printing.
        $pdf->setOption('load-error-handling', 'ignore');
        $pdf->setOption('load-media-error-handling', 'ignore');

        return $pdf->inline($name);
    }
}
