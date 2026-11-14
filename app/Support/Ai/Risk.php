<?php

namespace App\Support\Ai;

use App\Enums\FailedDeliveryReason;
use App\Models\DeliveryAttempt;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Support\Branding;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Str;

/**
 * How likely a box on a trip will not be delivered, and why. Plain rules on your own history,
 * so the score is the same every time and costs nothing. The AI only writes the text for the receiver.
 */
class Risk
{
    public const SHOW_FROM = 40;

    /**
     * @return array{score: int, reasons: list<string>, short: string}
     */
    public static function of(Tripinvoice $box, ?Collection $attempts = null, ?Collection $pastRefusals = null): array
    {
        $inv = $box->invdata;
        $attempts ??= $box->relationLoaded('deliveryAttempts') ? $box->deliveryAttempts : $box->deliveryAttempts()->get();
        $score = 0;
        $reasons = [];

        $count = $attempts->count();
        if ($count > 0) {
            $last = $attempts->sortByDesc('created_at')->first();
            $label = $last->reason instanceof FailedDeliveryReason ? $last->reason->getLabel() : 'not delivered';
            $score += min(60, 30 * $count);
            $reasons[] = $count === 1
                ? sprintf('Tried before on %s: %s', $last->created_at->format('D M j'), Str::lower($label))
                : sprintf('Tried %d times, last on %s: %s', $count, $last->created_at->format('D M j'), Str::lower($label));
            if (in_array($last->reason, [FailedDeliveryReason::Refused, FailedDeliveryReason::AddressNotFound], true)) {
                $score += 15;
            }
        }

        $phone = preg_replace('/\D+/', '', (string) $inv?->receiver_mobile_no);
        if ($phone === '') {
            $score += 25;
            $reasons[] = 'No phone number';
        } elseif (! preg_match('/^(09\d{9}|639\d{9}|9\d{9})$/', $phone)) {
            $score += 20;
            $reasons[] = 'Phone number looks wrong ('.$inv->receiver_mobile_no.')';
        }

        $address = trim((string) $inv?->receiver_address);
        if (mb_strlen($address) < 12 || ! preg_match('/\d|purok|sitio|street|st\.|blk|block|lot|zone|road|rd\.|ave/i', $address)) {
            $score += 20;
            $reasons[] = 'Address has no street, number or landmark';
        }
        if (blank($inv?->receiver_barangay)) {
            $score += 10;
            $reasons[] = 'No barangay';
        }

        if ($pastRefusals && $inv && $pastRefusals->contains(fn ($r) => static::sameReceiver($r, $inv))) {
            $score += 25;
            $reasons[] = 'This receiver refused a box before';
        }

        $score = min(95, $score);

        return ['score' => $score, 'reasons' => $reasons, 'short' => $reasons[0] ?? ''];
    }

    /** Receivers who refused a box in the last year (name + phone), to check other boxes against. */
    public static function pastRefusals(): Collection
    {
        return DeliveryAttempt::where('reason', FailedDeliveryReason::Refused->value)
            ->where('created_at', '>=', now()->subYear())
            ->with('invoice:id,receiver_name,receiver_mobile_no')->get()
            ->map(fn ($a) => $a->invoice)->filter()->values();
    }

    protected static function sameReceiver(Invoice $a, Invoice $b): bool
    {
        $phone = fn ($i) => substr(preg_replace('/\D+/', '', (string) $i->receiver_mobile_no), -10);

        return $a->id !== $b->id && (
            ($phone($a) !== '' && $phone($a) === $phone($b))
            || Str::lower(trim((string) $a->receiver_name)) === Str::lower(trim((string) $b->receiver_name))
        );
    }

    /** The text for the receiver, written by the AI in the chosen language. */
    public static function message(Tripinvoice $box, string $lang, ?string $company = null): string
    {
        $inv = $box->invdata;
        $trip = $box->deliverylog;
        $first = Str::of((string) $inv?->receiver_name)->title()->explode(' ')->first();
        $when = $trip?->delivery_date ? Carbon::parse($trip->delivery_date)->format('l, F j') : 'soon';
        $company ??= Branding::companyName();
        $risk = static::of($box);

        $language = ['en' => 'English', 'tl' => 'Tagalog (simple, polite, use "po")', 'ceb' => 'Bisaya / Cebuano (simple, polite)'][$lang] ?? 'English';

        return Ai::text('risky',
            "You write short SMS texts (max 300 characters) for {$company}, a cargo company delivering balikbayan boxes from abroad in the Philippines. "
            .'Friendly and clear. No emojis. Ask the receiver to reply. Sign with the company name. Write only the text message.',
            "Language: {$language}\nReceiver first name: {$first}\nBox number: {$box->invoice}\nDelivery day: {$when}\n"
            .'Address we have: '.trim($inv?->receiver_address.', '.$inv?->receiver_barangay.', '.$inv?->receiver_city, ', ')."\n"
            .'Why we are texting (do not quote this, just ask what is needed): '.implode('; ', $risk['reasons']),
            'fast', 300);
    }
}
