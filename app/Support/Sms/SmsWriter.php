<?php

namespace App\Support\Sms;

use App\Models\DeliveryAttempt;
use App\Support\Ai\Ai;
use Illuminate\Support\Str;
use Throwable;

/** AI SMS writer: shorter, friendlier, translated texts, and the driver's note turned into the reason. */
class SmsWriter
{
    public const ACTIONS = [
        'short' => 'Make it fit in ONE SMS: at most 150 characters when the blanks are filled with short words. Keep the meaning.',
        'friendly' => 'Make it friendlier and clearer for a Filipino customer, still short (one SMS if you can).',
        'tl' => 'Translate it to natural, polite Tagalog (Filipino) used in delivery texts.',
        'ceb' => 'Translate it to natural, polite Bisaya (Cebuano) used in delivery texts.',
        'en' => 'Translate it to simple, polite English.',
    ];

    /** @return array{text: string, note: string} */
    public static function rewrite(string $text, string $action): array
    {
        $blanks = Templates::blanksIn($text);
        $out = trim(Ai::text('sms_writer',
            'You write SMS texts that a delivery company sends to receivers in the Philippines. '.self::ACTIONS[$action].' '
            .'Words in curly braces like {name} or {boxes} are blanks: keep every one exactly as written, do not add new ones, do not translate them. '
            .'No emojis, no quotes, no line breaks. Answer with the new text only.',
            $text, 'fast', 400), " \n\"'");
        $out = Str::squish($out);
        if ($out === '' || Templates::blanksIn($out) !== $blanks) {
            throw new \RuntimeException('The AI changed the {blanks}. Try again.');
        }
        $before = mb_strlen($text);
        $after = mb_strlen($out);

        return ['text' => $out, 'note' => match ($action) {
            'short' => "Made shorter: {$before} → {$after} characters.",
            'friendly' => 'Made friendlier and clearer.',
            default => 'Translated to '.(Templates::LANGS[$action] ?? $action).'.',
        }];
    }

    /** "but {reason}": from the driver's note when there is one (AI), else from the reason picked. */
    public static function reason(DeliveryAttempt $a, string $lang): string
    {
        $plain = Str::lower($a->reason?->getLabel() ?? 'we could not reach you');
        if (! filled($a->note) || ! Ai::enabled('sms_writer')) {
            return $plain;
        }
        try {
            $out = Str::squish(trim(Ai::text('sms_writer',
                'A delivery driver in the Philippines could not deliver a box and wrote a short note. Turn it into the end of this sentence for the receiver: '
                .'"we tried to deliver your box but ___". Write only the words for ___ in '.(Templates::LANGS[$lang] ?? 'English')
                .', polite, at most 60 characters, no names, no phone numbers, no emojis.',
                'Reason picked: '.$plain."\nDriver note: ".Str::limit((string) $a->note, 300), 'fast', 120), " .\n\"'"));

            return $out !== '' && mb_strlen($out) <= 80 ? $out : $plain;
        } catch (Throwable) {
            return $plain;
        }
    }
}
