<?php

namespace App\Support\Sms;

/** Philippine mobile numbers: "0917 123 4567", "+63 917…", "639171234567", "9171234567" → 09171234567. */
class Phone
{
    public static function clean(?string $raw): ?string
    {
        // the first number when two are typed ("0917… / 0918…")
        $first = preg_split('/[\/,;]| or /i', (string) $raw)[0] ?? '';
        $d = preg_replace('/\D/', '', $first);
        if (str_starts_with($d, '63') && strlen($d) === 12) {
            $d = '0'.substr($d, 2);
        } elseif (strlen($d) === 10 && str_starts_with($d, '9')) {
            $d = '0'.$d;
        }

        return preg_match('/^09\d{9}$/', $d) ? $d : null;
    }

    public static function international(string $clean): string
    {
        return '+63'.substr($clean, 1);
    }

    public static function pretty(?string $clean): string
    {
        return $clean ? substr($clean, 0, 4).' '.substr($clean, 4, 3).' '.substr($clean, 7) : '';
    }
}
