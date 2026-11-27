<?php

namespace App\Support\Deliveries;

use App\Http\Controllers\InvoiceController;
use App\Models\DeliverySignature;
use App\Models\Invoice;
use App\Support\Pdf\WkBinary;
use App\Support\Photos\Storage\PhotoFolders;
use Illuminate\Support\Facades\Storage;
use Knp\Snappy\Image;
use Knp\Snappy\Pdf;
use Throwable;

/**
 * Part 44 (board 70b): the receipt you print today, with only its blank lines filled in:
 * delivery date, time, truck, recipient name, relationship, the signature, the boxes ticked,
 * and the damage in REMARKS. Saved as receipt.pdf, and as receipt.jpg in the delivery photos.
 */
class SignedReceipt
{
    /** Tests: write small stand-in files instead of running wkhtmltopdf. */
    public static bool $fake = false;

    public static function html(DeliverySignature $s): string
    {
        $invoice = Invoice::findOrFail($s->invoice_id);
        $data = InvoiceController::receiptData($invoice);
        $at = $s->signed_at ?? $s->created_at ?? now();
        $remarks = $s->isDamaged()
            ? 'Damaged: '.$s->damageText().'. The receiver saw the damage before signing.'
            : '';
        if ($s->cant_sign) {
            $remarks = trim($remarks.' The receiver could not sign.');
        }
        $data['signed'] = [
            'date' => $at->format('M j, Y'),
            'time' => $at->format('g:i A'),
            'truck' => (string) ($data['truck']?->description ?: $data['truck']?->plate_no ?: ''),
            'name' => (string) $s->recipient_name,
            'relationship' => (string) $s->relationship,
            'sig' => $s->signatureData(),
            'damaged' => $s->isDamaged(),
            'remarks' => $remarks,
        ];

        return view('invoices.pdfinvoice', $data)->render();
    }

    /**
     * The picture keeps only the first copy of the receipt (it is printed twice on the page):
     * cut at the first long white gap after the text, and saved a bit smaller.
     */
    public static function firstCopy(string $jpg): string
    {
        if (! function_exists('imagecreatefromstring') || ! ($im = @imagecreatefromstring($jpg))) {
            return $jpg;
        }
        $w = imagesx($im);
        $h = imagesy($im);
        $started = false;
        $white = 0;
        $cut = $h;
        for ($y = 0; $y < $h; $y += 2) {
            $dark = false;
            for ($x = 0; $x < $w; $x += 3) {
                $c = imagecolorat($im, $x, $y);
                if ((($c >> 16) & 255) + (($c >> 8) & 255) + ($c & 255) < 600) {
                    $dark = true;
                    break;
                }
            }
            if ($dark) {
                $started = true;
                $white = 0;
            } elseif ($started && ($white += 2) >= 110) {
                $cut = min($h, $y - $white + 40);
                break;
            }
        }
        $out = imagecrop($im, ['x' => 0, 'y' => 0, 'width' => $w, 'height' => max(200, $cut)]) ?: $im;
        ob_start();
        imagejpeg($out, null, 78);

        return (string) ob_get_clean();
    }

    /** Make receipt.pdf and receipt.jpg next to the delivery photos. Returns false when it could not. */
    public static function make(DeliverySignature $s): bool
    {
        $dir = PhotoFolders::dir('delivery', $s->tripinvoice?->invoice ?? (string) $s->invoice_id, $s->signed_at);
        $base = $dir.'/receipt-'.$s->token;
        $disk = Storage::disk('public');
        try {
            if (static::$fake) {
                $pdf = '%PDF-1.4 signed receipt '.$s->token;
                $jpg = base64_decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==');
            } else {
                $bin = WkBinary::find();
                if (! $bin) {
                    return false;
                }
                $html = static::html($s);
                $pdf = (new Pdf($bin))->getOutputFromHtml($html, [
                    'margin-top' => '5mm', 'margin-bottom' => '5mm', 'margin-left' => '5mm', 'margin-right' => '5mm',
                    'enable-local-file-access' => true, 'load-error-handling' => 'ignore', 'load-media-error-handling' => 'ignore',
                ]);
                $jpg = null;
                $img = dirname($bin).'/wkhtmltoimage';
                if (WkBinary::works($img)) {
                    $jpg = (new Image($img))->getOutputFromHtml($html, ['format' => 'jpg', 'quality' => 70, 'width' => 900, 'enable-local-file-access' => true, 'load-error-handling' => 'ignore']);
                }
            }
            $disk->put($base.'.pdf', $pdf);
            $s->receipt_pdf = $base.'.pdf';
            if ($jpg) {
                $jpg = static::firstCopy($jpg);
                $disk->put($base.'.jpg', $jpg);
                $s->receipt_jpg = $base.'.jpg';
            }
            $s->save();

            return true;
        } catch (Throwable $e) {
            report($e);

            return false;
        }
    }
}
