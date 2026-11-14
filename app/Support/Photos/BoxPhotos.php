<?php

namespace App\Support\Photos;

use App\Models\BoxPhoto;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\PhotoSetting;
use App\Models\User;
use App\Support\Ai\PhotoCheck;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/** Saves scan photos: made smaller (max 1600 px, JPEG) and stamped with invoice, date and who took it. */
class BoxPhotos
{
    public const MAX_SIDE = 1600;

    /**
     * @param  array{container_id?: ?int, deliverylog_id?: ?int, whdeliverylog_id?: ?int, warehouse_id?: ?int, logistichub_id?: ?int}  $context
     */
    public static function store(UploadedFile $file, string $step, ?Invoice $invoice, array $context, ?User $user, ?string $condition = null, ?string $note = null): BoxPhoto
    {
        $taken = now();
        $stamp = collect([
            $invoice?->invoice ?? 'BATCH',
            BoxPhoto::SHORT[$step] ?? $step,
            $condition ? strtoupper($condition) : null,
            $taken->format('d M Y g:i A'),
            $user?->full_name,
        ])->filter()->join('  |  ');

        $bytes = static::shrink((string) file_get_contents($file->getRealPath()), $stamp);
        $path = 'box-photos/'.$taken->format('Y/m').'/'.Str::uuid().'.jpg';
        Storage::disk('local')->put($path, $bytes);

        $photo = BoxPhoto::create([
            'invoice_id' => $invoice?->id,
            'invoice' => $invoice?->invoice,
            'step' => $step,
            'condition' => $condition,
            'note' => $note ? Str::limit(trim($note), 250, '') : null,
            'is_batch' => ! $invoice,
            'path' => $path,
            'size' => strlen($bytes),
            'container_id' => $context['container_id'] ?? null,
            'deliverylog_id' => $context['deliverylog_id'] ?? null,
            'whdeliverylog_id' => $context['whdeliverylog_id'] ?? null,
            'warehouse_id' => $context['warehouse_id'] ?? null,
            'logistichub_id' => $context['logistichub_id'] ?? null,
            'user_id' => $user?->id,
            'taken_at' => $taken,
        ]);

        PhotoCheck::queueBoxPhoto($photo);

        return $photo;
    }

    /** Resize to MAX_SIDE, add a dark strip with the stamp text, save as JPEG. Without GD the file is kept as is. */
    public static function shrink(string $bytes, string $stamp): string
    {
        if (! function_exists('imagecreatefromstring') || ! ($src = @imagecreatefromstring($bytes))) {
            return $bytes;
        }
        $src = PhotoShrinker::upright($src, PhotoShrinker::orientation($bytes)); // iPhone photos come sideways

        $w = imagesx($src);
        $h = imagesy($src);
        $scale = min(1, self::MAX_SIDE / max($w, $h));
        $nw = max(1, (int) round($w * $scale));
        $nh = max(1, (int) round($h * $scale));
        $img = imagecreatetruecolor($nw, $nh);
        imagecopyresampled($img, $src, 0, 0, 0, 0, $nw, $nh, $w, $h);
        imagedestroy($src);

        // stamp: white text on a dark strip, drawn small then scaled up so it stays readable
        $font = 5;
        $zoom = max(1, (int) floor($nw / 700));
        $pad = 6;
        $text = Str::ascii($stamp);
        $max = (int) floor(($nw / $zoom - $pad * 2) / imagefontwidth($font));
        $text = Str::limit($text, $max, '');
        $sw = (int) ceil($nw / $zoom);
        $sh = imagefontheight($font) + $pad * 2;
        $strip = imagecreatetruecolor($sw, $sh);
        imagefilledrectangle($strip, 0, 0, $sw, $sh, imagecolorallocate($strip, 14, 36, 51));
        imagestring($strip, $font, $pad, $pad, $text, imagecolorallocate($strip, 255, 255, 255));
        $dst = imagecreatetruecolor($nw, $sh * $zoom);
        imagecopyresized($dst, $strip, 0, 0, 0, 0, $nw, $sh * $zoom, $sw, $sh);
        imagecopymerge($img, $dst, 0, $nh - $sh * $zoom, 0, 0, $nw, $sh * $zoom, 80);
        imagedestroy($strip);
        imagedestroy($dst);

        ob_start();
        imagejpeg($img, null, 78);
        imagedestroy($img);

        return (string) ob_get_clean();
    }

    /** Photos of one box, oldest first. */
    public static function forInvoice(?int $invoiceId, ?User $user)
    {
        return $invoiceId
            ? BoxPhoto::visibleTo($user)->with('container:id,container_no', 'deliverylog:id,trip_number', 'whdeliverylog:id,trip_number', 'user:id,first_name,last_name', 'warehouse:id,name', 'logistichub:id,hub_name')
                ->where('invoice_id', $invoiceId)->orderBy('taken_at')->orderBy('id')->get()
            : collect();
    }

    /** Delete photos older than the keep time, except boxes with an open Invoice Issue. */
    public static function prune(): int
    {
        $months = PhotoSetting::current()->keep_months;
        if ($months < 1) {
            return 0;
        }

        $openIssue = Invoiceissue::query()->whereHas('invdata', fn ($q) => $q->where(fn ($q) => $q->where('is_resolved', false)->orWhereNull('is_resolved')))->select('invoice');
        $n = 0;
        BoxPhoto::where('taken_at', '<', now()->subMonths($months))
            ->where(fn ($q) => $q->whereNull('invoice')->orWhereNotIn('invoice', $openIssue))
            ->chunkById(200, function ($photos) use (&$n) {
                foreach ($photos as $p) {
                    $p->delete();
                    $n++;
                }
            });

        return $n;
    }
}
