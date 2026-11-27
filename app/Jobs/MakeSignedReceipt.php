<?php

namespace App\Jobs;

use App\Models\DeliverySignature;
use App\Support\Deliveries\SignedReceipt;
use App\Support\Sms\SmsEvents;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Throwable;

/** Part 44: make the signed receipt (PDF + picture), put the picture in the delivery photos, text the receiver if damaged. */
class MakeSignedReceipt implements ShouldQueue
{
    use Queueable;

    public int $tries = 3;

    public function __construct(public int $signatureId) {}

    public function handle(): void
    {
        $s = DeliverySignature::with('tripinvoice')->find($this->signatureId);
        if (! $s) {
            return;
        }
        if (! $s->receipt_pdf) {
            SignedReceipt::make($s);
        }
        $box = $s->tripinvoice;
        if ($s->receipt_jpg && $box) {
            $photos = array_values((array) $box->delivery_picture);
            if (! in_array($s->receipt_jpg, $photos, true)) {
                $photos[] = $s->receipt_jpg; // the signed receipt as a picture, with the delivery photos
                $box->forceFill(['delivery_picture' => $photos])->saveQuietly();
            }
        }
        if ($s->isDamaged() && ! $s->sms_message_id) {
            try {
                SmsEvents::damaged($s->fresh());
            } catch (Throwable $e) {
                report($e);
            }
        }
    }
}
