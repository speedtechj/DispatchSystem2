<?php

namespace App\Support\Aging;

use Illuminate\Support\Str;

/** Which part of the Philippines a receiver's province is in. Far places get longer limits. */
class Regions
{
    public const LABELS = ['metro_manila' => 'Metro Manila', 'luzon' => 'Luzon', 'visayas' => 'Visayas', 'mindanao' => 'Mindanao'];

    protected const METRO = ['metro manila', 'ncr', 'manila', 'national capital region', 'quezon city', 'makati', 'pasig', 'taguig', 'caloocan', 'pasay', 'paranaque', 'parañaque', 'las pinas', 'las piñas', 'muntinlupa', 'mandaluyong', 'marikina', 'valenzuela', 'malabon', 'navotas', 'san juan', 'pateros'];

    protected const VISAYAS = ['cebu', 'bohol', 'negros', 'negros occidental', 'negros oriental', 'iloilo', 'capiz', 'aklan', 'antique', 'guimaras', 'leyte', 'southern leyte', 'samar', 'eastern samar', 'northern samar', 'western samar', 'biliran', 'siquijor'];

    protected const MINDANAO = ['davao', 'davao del sur', 'davao del norte', 'davao oriental', 'davao occidental', 'davao de oro', 'compostela valley', 'zamboanga', 'zamboanga del norte', 'zamboanga del sur', 'zamboanga sibugay', 'misamis oriental', 'misamis occidental', 'bukidnon', 'lanao del norte', 'lanao del sur', 'camiguin', 'agusan del norte', 'agusan del sur', 'surigao del norte', 'surigao del sur', 'dinagat islands', 'south cotabato', 'cotabato', 'north cotabato', 'sultan kudarat', 'sarangani', 'maguindanao', 'maguindanao del norte', 'maguindanao del sur', 'basilan', 'sulu', 'tawi-tawi', 'general santos', 'cagayan de oro'];

    public static function of(?string $province, ?string $city = null): string
    {
        $p = Str::of((string) $province)->lower()->replace(['province of', 'province'], '')->squish()->toString();
        $c = Str::of((string) $city)->lower()->squish()->toString();
        foreach ([$p, $c] as $v) {
            if ($v === '') {
                continue;
            }
            if (in_array($v, self::METRO, true) || str_contains($v, 'metro manila')) {
                return 'metro_manila';
            }
        }
        foreach (self::MINDANAO as $m) {
            if ($p !== '' && ($p === $m || str_starts_with($p, $m))) {
                return 'mindanao';
            }
        }
        foreach (self::VISAYAS as $v) {
            if ($p !== '' && ($p === $v || str_starts_with($p, $v))) {
                return 'visayas';
            }
        }

        return 'luzon';
    }
}
