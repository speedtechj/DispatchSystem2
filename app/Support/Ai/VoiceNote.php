<?php

namespace App\Support\Ai;

use App\Enums\FailedDeliveryReason;
use Illuminate\Support\Str;

/** Driver voice note: turns what the driver said (in any language) into a reason and a short note. */
class VoiceNote
{
    /** @return array{reason: ?string, note: string} */
    public static function parse(string $said): array
    {
        $reasons = collect(FailedDeliveryReason::cases())->map(fn ($r) => $r->value.' = '.$r->getLabel())->join('; ');
        $out = Ai::json('voice',
            'A delivery driver in the Philippines explains why a box could not be delivered. They may speak English, Tagalog, Bisaya or a mix. '
            .'Return {"reason": one code from this list, "note": a short clear note in English (max 25 words) with the useful details: who said what, when to come back}. '
            .'Codes: '.$reasons,
            Str::limit($said, 800), 'fast', 200);
        $reason = FailedDeliveryReason::tryFrom((string) ($out['reason'] ?? ''));

        return ['reason' => $reason?->value, 'note' => Str::limit(trim((string) ($out['note'] ?? '')), 480, '')];
    }
}
