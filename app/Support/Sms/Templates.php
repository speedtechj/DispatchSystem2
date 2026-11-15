<?php

namespace App\Support\Sms;

use App\Models\AppSetting;
use Illuminate\Support\Str;

/** The text of each message, in English, Tagalog and Bisaya, with {blanks}. */
class Templates
{
    public const LANGS = ['en' => 'English', 'tl' => 'Tagalog', 'ceb' => 'Bisaya'];

    public const BLANKS = ['{name}', '{boxes}', '{box_count}', '{truck}', '{driver}', '{time}', '{minutes}', '{reason}', '{next_day}', '{hub}', '{hub_phone}'];

    public const DEFAULTS = [
        'out_for_delivery' => [
            'en' => 'Hi {name}, your {box_count} box(es) {boxes} are out for delivery today with truck {truck}. Driver: {driver}.',
            'tl' => 'Hi {name}, ang {box_count} box mo ({boxes}) ay ide-deliver ngayong araw, truck {truck}. Driver: {driver}.',
            'ceb' => 'Hi {name}, ang {box_count} ka box nimo ({boxes}) i-deliver karong adlawa, truck {truck}. Driver: {driver}.',
        ],
        'driver_next' => [
            'en' => 'Hi {name}, our driver is on the way. Expected in about {minutes} minutes. Please prepare an ID.',
            'tl' => 'Hi {name}, papunta na ang driver namin. Darating sa loob ng mga {minutes} minuto. Ihanda po ang ID.',
            'ceb' => 'Hi {name}, padulong na ang among driver. Moabot sa mga {minutes} ka minuto. Palihug andama ang ID.',
        ],
        'delivered' => [
            'en' => 'Hi {name}, box {boxes} was delivered at {time}. Thank you!',
            'tl' => 'Hi {name}, na-deliver na ang box {boxes} nang {time}. Salamat po!',
            'ceb' => 'Hi {name}, na-deliver na ang box {boxes} sa {time}. Salamat!',
        ],
        'not_delivered' => [
            'en' => 'Hi {name}, we tried to deliver box {boxes} but {reason}. We will try again on {next_day}. Call {hub_phone}.',
            'tl' => 'Hi {name}, sinubukan naming i-deliver ang box {boxes} pero {reason}. Babalik kami sa {next_day}. Tumawag sa {hub_phone}.',
            'ceb' => 'Hi {name}, gisulayan namo i-deliver ang box {boxes} pero {reason}. Mobalik mi sa {next_day}. Tawag sa {hub_phone}.',
        ],
        'hub_arrived' => [
            'en' => 'Hi {name}, your box {boxes} arrived at {hub} and will be delivered soon.',
            'tl' => 'Hi {name}, ang box mo ({boxes}) ay dumating na sa {hub} at ide-deliver na sa lalong madaling panahon.',
            'ceb' => 'Hi {name}, ang imong box ({boxes}) niabot na sa {hub} ug i-deliver dayon.',
        ],
        'set_split' => [
            'en' => 'Hi {name}, {box_count} of your boxes are on the way. Box {boxes} follows on the next trip. Call {hub_phone}.',
            'tl' => 'Hi {name}, papunta na ang {box_count} sa mga box mo. Ang box {boxes} ay susunod sa next trip. Tumawag sa {hub_phone}.',
            'ceb' => 'Hi {name}, padulong na ang {box_count} sa imong mga box. Ang box {boxes} mosunod sa sunod nga biyahe. Tawag sa {hub_phone}.',
        ],
    ];

    /** Provinces where receivers get Bisaya, and where they get Tagalog (else English). */
    public const BISAYA = ['cebu', 'bohol', 'siquijor', 'negros oriental', 'leyte', 'southern leyte', 'biliran', 'camiguin', 'misamis oriental', 'misamis occidental',
        'bukidnon', 'agusan del norte', 'agusan del sur', 'surigao del norte', 'surigao del sur', 'dinagat islands', 'davao del norte', 'davao del sur', 'davao oriental',
        'davao occidental', 'davao de oro', 'zamboanga del norte', 'zamboanga del sur', 'zamboanga sibugay', 'lanao del norte', 'samar', 'eastern samar', 'northern samar'];

    public const TAGALOG = ['metro manila', 'ncr', 'manila', 'national capital region', 'bulacan', 'cavite', 'laguna', 'batangas', 'rizal', 'quezon', 'nueva ecija',
        'bataan', 'pampanga', 'tarlac', 'zambales', 'aurora', 'marinduque', 'occidental mindoro', 'oriental mindoro', 'romblon', 'palawan'];

    public static function get(string $kind, string $lang): string
    {
        return (string) (AppSetting::get("sms.tpl.{$kind}.{$lang}") ?: (self::DEFAULTS[$kind][$lang] ?? self::DEFAULTS[$kind]['en'] ?? ''));
    }

    public static function put(string $kind, string $lang, ?string $text): void
    {
        $text = Str::squish((string) $text);
        AppSetting::put("sms.tpl.{$kind}.{$lang}", $text === '' || $text === (self::DEFAULTS[$kind][$lang] ?? null) ? null : $text);
    }

    public static function langFor(?string $province): string
    {
        $rule = SmsSettings::language();
        if ($rule !== 'auto') {
            return isset(self::LANGS[$rule]) ? $rule : 'en';
        }
        $p = Str::lower(Str::squish((string) $province));
        foreach (self::BISAYA as $b) {
            if ($p !== '' && str_contains($p, $b)) {
                return 'ceb';
            }
        }
        foreach (self::TAGALOG as $t) {
            if ($p !== '' && str_contains($p, $t)) {
                return 'tl';
            }
        }

        return 'en';
    }

    public static function render(string $text, array $vals): string
    {
        $out = $text;
        foreach ($vals as $k => $v) {
            $out = str_replace('{'.$k.'}', (string) $v, $out);
        }

        return Str::squish(preg_replace('/\{[a-z_]+\}/', '', $out));
    }

    /** How many SMS parts a text needs (160 / 153 plain, 70 / 67 with emojis or special letters). */
    public static function parts(string $text): int
    {
        $gsm = preg_match('/^[\x{0A}\x{0D}\x{20}-\x{7E}£¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¡ÄÖÑÜ§¿äöñüà€]*$/u', $text) === 1;
        $len = mb_strlen($text);
        [$one, $many] = $gsm ? [160, 153] : [70, 67];

        return $len <= $one ? 1 : (int) ceil($len / $many);
    }

    /** The blanks used in a text. @return list<string> */
    public static function blanksIn(string $text): array
    {
        preg_match_all('/\{[a-z_]+\}/', $text, $m);
        $b = array_values(array_unique($m[0]));
        sort($b);

        return $b;
    }
}
