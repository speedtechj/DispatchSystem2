<?php

namespace App\Support\Ai;

use App\Jobs\CheckPhotoWithAi;
use App\Models\Ai\AiPhotoCheck;
use App\Models\Boxissue;
use App\Models\BoxPhoto;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Tripinvoice;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Throwable;

/** AI photo check: looks at box photos and proof-of-delivery photos, flags the ones that look wrong. */
class PhotoCheck
{
    /** Below this "how sure" the AI's verdict is not shown as a problem. */
    public const MIN_CONFIDENCE = 55;

    public static function queueBoxPhoto(BoxPhoto $photo): void
    {
        if ($photo->is_batch || ! Ai::switchedOn('photo_check')) {
            return;
        }
        $check = AiPhotoCheck::firstOrCreate(['box_photo_id' => $photo->id], [
            'source' => 'scan', 'path' => $photo->path, 'step' => $photo->step,
            'invoice' => $photo->invoice, 'invoice_id' => $photo->invoice_id,
            'worker_said' => $photo->condition ?: 'good',
            'warehouse_id' => $photo->warehouse_id,
            'logistichub_id' => $photo->logistichub_id ?: Tripinvoice::where('invoice_id', $photo->invoice_id)->latest('id')->value('logistichub_id'),
        ]);
        static::dispatch($check);
    }

    /** @param  array<int, string>  $paths  photos on the public disk */
    public static function queueDelivery(Tripinvoice $box, array $paths): void
    {
        if (! Ai::switchedOn('photo_check')) {
            return;
        }
        foreach (array_values($paths) as $path) {
            $check = AiPhotoCheck::firstOrCreate(['tripinvoice_id' => $box->id, 'path' => $path], [
                'source' => 'delivery', 'step' => 'delivered', 'invoice' => $box->invoice, 'invoice_id' => $box->invoice_id,
                'worker_said' => 'delivered', 'logistichub_id' => $box->logistichub_id,
            ]);
            static::dispatch($check);
        }
    }

    protected static function dispatch(AiPhotoCheck $check): void
    {
        if ($check->checked_at || ! Ai::enabled('photo_check')) {
            return; // the scheduler picks it up later (ai:work)
        }
        // runs after the page has answered, so scanning never waits for the AI
        CheckPhotoWithAi::dispatchAfterResponse($check->id);
    }

    public static function run(AiPhotoCheck $check): void
    {
        if ($check->checked_at || ! Ai::enabled('photo_check')) {
            return;
        }
        $image = $check->source === 'scan' ? Ai::image('local', $check->path) : Ai::image('public', $check->path);
        if (! $image) {
            $check->update(['verdict' => 'unclear', 'note' => 'Photo file not found', 'checked_at' => now()]);

            return;
        }

        $delivery = $check->source === 'delivery';
        $system = $delivery
            ? 'You check proof-of-delivery photos for a Philippine cargo company that delivers balikbayan boxes to homes. '
                .'verdict: "ok" when the photo clearly shows the box at a home or being received by a person; "blurry" when too blurry or dark to see; '
                .'"no_box" when no box can be seen; "damaged" when the delivered box is clearly crushed, torn or opened. '
                .'Answer as {"verdict": "...", "confidence": 0-100, "note": "what you see, max 12 words, plain English"}.'
            : 'You check photos of balikbayan boxes (cardboard boxes, often taped, with labels) taken while unloading and loading at a cargo warehouse. '
                .'verdict: "ok" when the box looks normal (some scuffs, writing and tape are normal); "damaged" when crushed, caved in, torn or with a hole; '
                .'"wet" when there are water marks or soggy cardboard; "open" when the tape is cut or a flap is open; "unclear" when you cannot see the box well. '
                .'Answer as {"verdict": "...", "confidence": 0-100, "note": "what you see, max 12 words, plain English"}. The white strip at the bottom is just a text stamp.';

        try {
            $out = Ai::json('photo_check', $system, [$image, ['type' => 'text', 'text' => 'Check this photo.']], 'fast', 200);
        } catch (AiUnavailable) {
            return; // try again later
        }

        $verdict = array_key_exists($out['verdict'] ?? '', AiPhotoCheck::VERDICTS) ? $out['verdict'] : 'unclear';
        $confidence = max(0, min(100, (int) ($out['confidence'] ?? 0)));
        $flag = $verdict !== 'ok' && $verdict !== 'unclear' && $confidence >= self::MIN_CONFIDENCE;

        $check->update([
            'verdict' => $verdict, 'confidence' => $confidence, 'note' => Str::limit(trim((string) ($out['note'] ?? '')), 180, ''),
            'flagged' => $flag, 'checked_at' => now(),
        ]);
    }

    /** Staff agree it's damaged: open an Invoice Issue with the photo. */
    public static function confirm(AiPhotoCheck $check, User $by): ?Invoiceissue
    {
        return DB::transaction(function () use ($check, $by): ?Invoiceissue {
            $invoice = $check->invoice_id ? Invoice::find($check->invoice_id) : null;
            $issue = null;
            if ($invoice) {
                $copy = 'invoiceissue-attachments/ai-'.$check->id.'-'.Str::random(6).'.jpg';
                try {
                    $bytes = $check->source === 'scan' ? Storage::disk('local')->get($check->path) : Storage::disk('public')->get($check->path);
                    Storage::disk('public')->put($copy, (string) $bytes);
                } catch (Throwable) {
                    $copy = null;
                }
                $type = Boxissue::where('issue_type', 'like', '%damag%')->value('id') ?? Boxissue::value('id');
                $issue = Invoiceissue::create([
                    'invoice' => $invoice->invoice,
                    'invoice_id' => $invoice->id,
                    'container_id' => $invoice->container_id,
                    'boxissue_id' => $type,
                    'user_id' => $by->id,
                    'remarks' => trim('AI photo check: '.$check->label().'. '.$check->note.' ('.AiPhotoCheck::stepLabel($check->step).')'),
                    'attachment_pic' => $copy ? [$copy] : [],
                ]);
            }
            $check->update(['decision' => 'damaged', 'decided_by' => $by->id, 'decided_at' => now(), 'invoiceissue_id' => $issue?->id]);

            return $issue;
        });
    }

    public static function dismiss(AiPhotoCheck $check, User $by): void
    {
        $check->update(['decision' => 'fine', 'decided_by' => $by->id, 'decided_at' => now()]);
    }
}
