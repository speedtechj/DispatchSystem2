<?php

namespace App\Support\Connectors;

use Illuminate\Support\Str;

/** ✨ Suggestions for the mapping: their status names that match our event (by words). */
class Suggest
{
    /** code => [words that should be there, words that must not] */
    public const WORDS = [
        'ds.unloaded' => [['unload', 'unloaded', 'warehouse', 'philippine', 'ph'], ['2nd', '3rd', 'transfer', 'return']],
        'ds.transfer' => [['transfer', 'transferred', 'hub', 'warehouse'], ['shipping', 'port', 'inter', 'island']],
        'ds.return_to_warehouse' => [['return', 'returned', 'warehouse'], ['hub', 'unloaded', 'unload', 'philippine']],
        'ds.to_port' => [['shipping', 'line', 'port', 'transfer'], ['arrived']],
        'ds.sailing' => [['transit', 'sailing', 'vessel', 'shipped'], ['arrived']],
        'ds.arrived_port' => [['arrived', 'port'], ['philippine', 'warehouse']],
        'ds.partner_hub' => [['inter', 'island', 'transferred', 'hub', 'arrived'], ['shipping', 'port', 'return']],
        'ds.load.1' => [['loaded', 'load', 'truck', 'delivery', 'out'], ['2nd', '3rd', 'second', 'third', 'attempt']],
        'ds.load.2' => [['loaded', 'truck', '2nd', 'second', 'attempt', 're'], ['3rd', 'third']],
        'ds.load.3' => [['loaded', 'truck', '3rd', 'third', 'attempt'], ['2nd', 'second']],
        'ds.back_to_hub.2' => [['return', 'returned', 'back', 'hub', '2nd', 'second'], ['3rd', 'loaded', 'warehouse', 'delivered']],
        'ds.back_to_hub.3' => [['return', 'returned', 'back', 'hub', '3rd', 'third'], ['2nd', 'loaded', 'warehouse', 'delivered']],
        'ds.waiting_next_try' => [['waiting', 'next', 'redelivery', 'hold', 'hub'], ['loaded']],
        'ds.delivered' => [['delivered'], ['not', 'damaged', 'undelivered']],
        'ds.delivered_damaged' => [['delivered', 'damaged', 'damage'], ['not', 'undelivered']],
        'ds.correction' => [['correction', 'update', 'remarks'], []],
    ];

    /** A 2nd or 3rd try is only matched by a status that says so. */
    public const MUST = [
        'ds.load.2' => ['2nd', 'second'], 'ds.load.3' => ['3rd', 'third'],
        'ds.back_to_hub.2' => ['2nd', 'second'], 'ds.back_to_hub.3' => ['3rd', 'third'],
    ];

    /**
     * @param  list<array{id: int, name: string}>  $statuses
     * @return list<array{id: int, name: string, score: int}> best first, at most 3
     */
    public static function for(string $code, ?string $place, array $statuses): array
    {
        [$want, $not] = static::WORDS[$code] ?? [[], []];
        $placeWords = $place ? static::words($place) : [];
        $out = [];
        foreach ($statuses as $s) {
            $w = static::words($s['name']);
            if (isset(static::MUST[$code]) && ! array_intersect(static::MUST[$code], $w)) {
                continue;
            }
            $score = 0;
            foreach ($want as $k) {
                $score += in_array($k, $w, true) ? 2 : 0;
            }
            foreach ($not as $k) {
                $score -= in_array($k, $w, true) ? 4 : 0;
            }
            foreach ($placeWords as $p) {
                $score += in_array($p, $w, true) ? 5 : 0;
            }
            if ($w && ! array_diff($w, $want)) {
                $score += 2; // the whole name is what we look for ("Delivered")
            }
            if ($place === null && static::hasPlaceName($w)) {
                $score -= 1; // "any place" fits a general status better
            }
            if ($score >= 3) {
                $out[] = ['id' => (int) $s['id'], 'name' => $s['name'], 'score' => $score];
            }
        }
        usort($out, fn ($a, $b) => $b['score'] <=> $a['score'] ?: $a['id'] <=> $b['id']);

        return array_slice($out, 0, 3);
    }

    /** @return list<string> */
    public static function words(string $text): array
    {
        $t = Str::lower(Str::ascii($text));
        $t = preg_replace('/(\d)(st|nd|rd|th)\b/', '$1$2 ', $t);

        return array_values(array_filter(preg_split('/[^a-z0-9]+/', $t)));
    }

    protected static function hasPlaceName(array $w): bool
    {
        return (bool) array_intersect($w, ['tarlac', 'isabela', 'benguet', 'visayas', 'mindanao', 'masbate', 'palawan', 'mindoro', 'cavite', 'manila']);
    }

    /** Percent shown next to a suggestion. */
    public static function percent(int $score): int
    {
        return min(99, 40 + $score * 6);
    }
}
