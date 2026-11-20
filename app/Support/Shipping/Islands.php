<?php

namespace App\Support\Shipping;

use App\Models\Boxes\WhSection;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Support\Boxes\Sections;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Where a hub is (Luzon, Visayas, Mindanao) and whether boxes go there by sea. Set in
 * Settings → Hubs · island & sea; until then suggested from the provinces of the hub's
 * warehouse section, or from the hub's name.
 */
class Islands
{
    public const ISLANDS = ['luzon' => 'Luzon', 'visayas' => 'Visayas', 'mindanao' => 'Mindanao'];

    public const VISAYAS = ['aklan', 'antique', 'capiz', 'guimaras', 'iloilo', 'negros occidental', 'bohol', 'cebu', 'negros oriental', 'siquijor',
        'biliran', 'eastern samar', 'leyte', 'northern samar', 'samar', 'western samar', 'southern leyte'];

    public const MINDANAO = ['zamboanga del norte', 'zamboanga del sur', 'zamboanga sibugay', 'bukidnon', 'camiguin', 'lanao del norte', 'misamis occidental',
        'misamis oriental', 'davao de oro', 'compostela valley', 'davao del norte', 'davao del sur', 'davao occidental', 'davao oriental', 'cotabato', 'north cotabato',
        'sarangani', 'south cotabato', 'sultan kudarat', 'agusan del norte', 'agusan del sur', 'dinagat islands', 'surigao del norte', 'surigao del sur',
        'basilan', 'lanao del sur', 'maguindanao', 'maguindanao del norte', 'maguindanao del sur', 'sulu', 'tawi-tawi', 'tawi tawi'];

    /** Words in a hub's name, for a first guess. */
    protected const NAMES = [
        'visayas' => ['cebu', 'mandaue', 'lapu', 'iloilo', 'bacolod', 'tacloban', 'dumaguete', 'tagbilaran', 'bohol', 'roxas', 'kalibo', 'ormoc', 'catbalogan', 'leyte', 'samar', 'negros', 'visayas'],
        'mindanao' => ['davao', 'cdo', 'cagayan de oro', 'general santos', 'gensan', 'zamboanga', 'butuan', 'iligan', 'cotabato', 'surigao', 'koronadal', 'ozamiz', 'dipolog', 'pagadian', 'malaybalay', 'valencia', 'mindanao'],
    ];

    public static function ready(): bool
    {
        return Schema::hasColumn('logistichubs', 'by_sea');
    }

    public static function ofProvince(?string $province): string
    {
        $p = Sections::clean($province);

        return in_array($p, self::VISAYAS, true) ? 'visayas' : (in_array($p, self::MINDANAO, true) ? 'mindanao' : 'luzon');
    }

    /** @return array{island: string, from: string} */
    public static function suggest(Logistichub $hub): array
    {
        // speed: asked for every trip row; one answer per hub per request
        static $memo = [null, []];
        if ($memo[0] !== spl_object_id(app())) {
            $memo = [spl_object_id(app()), []];
        }

        return $memo[1][$hub->id.'|'.$hub->hub_name] ??= static::suggestNow($hub);
    }

    protected static function suggestNow(Logistichub $hub): array
    {
        if (Sections::ready()) {
            $prov = WhSection::where('logistichub_id', $hub->id)->get()->flatMap(fn ($s) => (array) $s->provinces)->filter();
            if ($prov->isNotEmpty()) {
                $island = $prov->map(fn ($p) => static::ofProvince($p))->countBy()->sortDesc()->keys()->first();
                $codes = WhSection::where('logistichub_id', $hub->id)->pluck('code')->join(', ');

                return ['island' => $island, 'from' => 'section '.$codes.' · '.$prov->take(3)->join(', ')];
            }
        }
        $name = Str::lower($hub->hub_name.' '.$hub->hub_code);
        foreach (self::NAMES as $island => $words) {
            foreach ($words as $w) {
                if (str_contains($name, $w)) {
                    return ['island' => $island, 'from' => 'the name "'.$hub->hub_name.'"'];
                }
            }
        }

        return ['island' => 'luzon', 'from' => 'nothing found: Luzon'];
    }

    public static function islandOf(Logistichub $hub): string
    {
        return static::ready() && $hub->island ? $hub->island : static::suggest($hub)['island'];
    }

    /** Boxes for this hub go by sea (or RoRo): set by hand, else Visayas and Mindanao. */
    public static function bySea(Logistichub $hub): bool
    {
        if (static::ready() && $hub->by_sea !== null) {
            return (bool) $hub->by_sea;
        }

        return static::islandOf($hub) !== 'luzon';
    }

    /** The usual arrival port: set on the hub, else the port of its last shipment. */
    public static function port(Logistichub $hub): ?string
    {
        if (static::ready() && $hub->port) {
            return $hub->port;
        }

        return Shipments::ready() ? SeaShipment::where('logistichub_id', $hub->id)->whereNotNull('port_to')->latest('id')->value('port_to') : null;
    }

    /** Ids of the hubs reached by sea. */
    public static function seaHubIds(): array
    {
        return Logistichub::where('is_company', true)->get()->filter(fn ($h) => static::bySea($h))->pluck('id')->all();
    }
}
