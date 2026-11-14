<?php

namespace App\Support\Maps;

use App\Models\Maps\GeoPlace;
use App\Support\Ai\Ai;
use Illuminate\Support\Collection;
use Illuminate\Support\Str;
use Throwable;

/**
 * AI address cleaning: "purok 3 near chapel, Lapu2" → "Purok 3, Pusok, Lapu-Lapu City, Cebu",
 * so the map finds more addresses. Uses the AI key from Settings → AI.
 */
class AddressCleaner
{
    /** @param  Collection<int, GeoPlace>  $places */
    public static function clean(Collection $places): int
    {
        if ($places->isEmpty() || ! Ai::enabled('addresses')) {
            return 0;
        }

        $fixed = 0;
        foreach ($places->chunk(25) as $chunk) {
            $list = $chunk->values()->map(fn (GeoPlace $p, int $i) => ['i' => $i, 'address' => $p->raw])->all();
            try {
                $out = Ai::json('addresses',
                    'You fix Philippine delivery addresses so a map can find them. For each address, write it as: house/street or purok, barangay, city or municipality, province. '
                    .'Fix spelling and short forms (Brgy, Lapu2, Mandaue Cty). Remove notes like "near chapel" or "beside store". Never invent a barangay or city that is not in the text. '
                    .'Answer as {"addresses":[{"i":0,"address":"..."}]}',
                    json_encode($list, JSON_UNESCAPED_UNICODE), 'fast', 2000);
            } catch (Throwable $e) {
                report($e);

                continue;
            }
            foreach ($out['addresses'] ?? [] as $row) {
                $place = $chunk->values()[$row['i'] ?? -1] ?? null;
                $clean = Str::limit(Str::squish((string) ($row['address'] ?? '')), 590, '');
                if (! $place || $clean === '') {
                    continue;
                }
                $place->clean = $clean;
                if (Str::lower($clean) !== Str::lower($place->raw)) {
                    $fixed++;
                }
                $place->save();
            }
        }

        return $fixed;
    }
}
