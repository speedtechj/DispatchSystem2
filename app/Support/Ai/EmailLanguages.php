<?php

namespace App\Support\Ai;

use App\Models\AppSetting;

/** Part 45 (board 73): the languages the AI writes emails to consolidators in; the last one is remembered for each consolidator. */
class EmailLanguages
{
    public const ALL = [
        'en' => ['English', 'English'],
        'tl' => ['Tagalog', 'Tagalog (Filipino)'],
        'ceb' => ['Bisaya', 'Cebuano (Bisaya)'],
        'hil' => ['Ilonggo', 'Hiligaynon (Ilonggo)'],
        'ilo' => ['Ilocano', 'Ilocano (Iloko)'],
        'pag' => ['Pangasinan', 'Pangasinan'],
        'pam' => ['Kapampangan', 'Kapampangan'],
    ];

    /** Languages the AI writes less surely: the person is asked to check, and English below is suggested. */
    public const CHECK = ['pag', 'pam'];

    public static function options(): array
    {
        return array_map(fn ($l) => $l[0], self::ALL);
    }

    public static function name(string $code): string
    {
        return self::ALL[$code][1] ?? 'English';
    }

    public static function for(?int $consolidatorId): string
    {
        $v = $consolidatorId ? (string) AppSetting::get('email.lang.'.$consolidatorId, 'en') : 'en';

        return isset(self::ALL[$v]) ? $v : 'en';
    }

    public static function remember(?int $consolidatorId, string $code): void
    {
        if ($consolidatorId && isset(self::ALL[$code])) {
            AppSetting::put('email.lang.'.$consolidatorId, $code);
        }
    }

    /** The instruction for the AI: write in this language (and the English version under it if asked). */
    public static function instruction(string $code, bool $withEnglish): string
    {
        $name = static::name($code);
        $s = $code === 'en' ? 'Write in clear, simple English.' : "Write the email in {$name}, the way a polite office worker from that region writes. Keep box numbers, container numbers, names and dates exactly as given.";
        if ($withEnglish && $code !== 'en') {
            $s .= ' Then add a line "— English —" and the same email in English.';
        }

        return $s;
    }
}
