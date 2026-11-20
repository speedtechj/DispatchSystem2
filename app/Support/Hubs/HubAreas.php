<?php

namespace App\Support\Hubs;

use App\Models\Hubs\HubArea;
use App\Models\Hubs\HubAreaRequest;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\User;
use App\Support\Maps\Barangays;
use Filament\Notifications\Notification;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Hub areas: which active partner hub delivers each place.
 * One owner per place. The smallest place wins: barangay, then city, then province.
 * A place with no hub is delivered direct by the warehouse.
 */
class HubAreas
{
    /** Philippine regions: a new hub is suggested the places of its own region that have no hub. */
    public const REGIONS = [
        'NCR' => ['Metro Manila'],
        'CAR' => ['Abra', 'Apayao', 'Benguet', 'Ifugao', 'Kalinga', 'Mountain Province'],
        'Ilocos' => ['Ilocos Norte', 'Ilocos Sur', 'La Union', 'Pangasinan'],
        'Cagayan Valley' => ['Batanes', 'Cagayan', 'Isabela', 'Nueva Vizcaya', 'Quirino'],
        'Central Luzon' => ['Aurora', 'Bataan', 'Bulacan', 'Nueva Ecija', 'Pampanga', 'Tarlac', 'Zambales'],
        'Calabarzon' => ['Batangas', 'Cavite', 'Laguna', 'Quezon', 'Rizal'],
        'Mimaropa' => ['Marinduque', 'Occidental Mindoro', 'Oriental Mindoro', 'Palawan', 'Romblon'],
        'Bicol' => ['Albay', 'Camarines Norte', 'Camarines Sur', 'Catanduanes', 'Masbate', 'Sorsogon'],
        'Western Visayas' => ['Aklan', 'Antique', 'Capiz', 'Guimaras', 'Iloilo'],
        'Negros Island' => ['Negros Occidental', 'Negros Oriental', 'Siquijor'],
        'Central Visayas' => ['Bohol', 'Cebu'],
        'Eastern Visayas' => ['Biliran', 'Eastern Samar', 'Leyte', 'Northern Samar', 'Samar', 'Southern Leyte'],
        'Zamboanga Peninsula' => ['Zamboanga del Norte', 'Zamboanga del Sur', 'Zamboanga Sibugay'],
        'Northern Mindanao' => ['Bukidnon', 'Camiguin', 'Lanao del Norte', 'Misamis Occidental', 'Misamis Oriental'],
        'Davao' => ['Davao de Oro', 'Davao del Norte', 'Davao del Sur', 'Davao Occidental', 'Davao Oriental'],
        'Soccsksargen' => ['Cotabato', 'Sarangani', 'South Cotabato', 'Sultan Kudarat'],
        'Caraga' => ['Agusan del Norte', 'Agusan del Sur', 'Dinagat Islands', 'Surigao del Norte', 'Surigao del Sur'],
        'BARMM' => ['Basilan', 'Lanao del Sur', 'Maguindanao del Norte', 'Maguindanao del Sur', 'Sulu', 'Tawi-Tawi'],
    ];

    /** One color per hub, the same on every page. */
    public static function color(int $hubId): string
    {
        $c = ['#1d6fb8', '#c97a00', '#17895e', '#7a4fd6', '#c2410c', '#0e7490'];

        return $c[$hubId % count($c)];
    }

    public static function ready(): bool
    {
        return Schema::hasTable('hub_areas');
    }

    /** Partner hubs that can own places (active, not the main hub). */
    public static function hubs(bool $activeOnly = true): Collection
    {
        return Logistichub::query()->where('is_company', true)->when($activeOnly, fn ($q) => $q->where('is_active', true))->orderBy('hub_name')->get();
    }

    public static function pKey(?string $province): string
    {
        $p = Str::lower(Str::ascii(Str::squish((string) $province)));
        $p = preg_replace('/^(province of|prov\.?)\s+/', '', $p);

        return trim(preg_replace('/[^a-z0-9]+/', ' ', $p));
    }

    public static function cKey(?string $city): string
    {
        return Barangays::cityKey($city);
    }

    public static function bKey(?string $barangay): string
    {
        return Barangays::nameKey($barangay);
    }

    /** Changes when an area changes or a hub is switched on or off (for caches). */
    public static function version(): string
    {
        if (! static::ready()) {
            return '0';
        }

        return DB::table('hub_area_log')->max('id').'.'.DB::table('hub_areas')->count().'.'.Logistichub::where('is_company', true)->where('is_active', true)->count();
    }

    /**
     * Every place of an active partner hub: "p|c|b" => hub id. Read it once, then use hubOf() for many boxes.
     *
     * @return array<string, int>
     */
    public static function map(): array
    {
        if (! static::ready()) {
            return [];
        }
        $active = static::hubs()->pluck('id')->flip();

        return HubArea::query()->get(['logistichub_id', 'p_key', 'c_key', 'b_key'])
            ->filter(fn ($a) => isset($active[$a->logistichub_id]))
            ->mapWithKeys(fn ($a) => [$a->p_key.'|'.$a->c_key.'|'.$a->b_key => (int) $a->logistichub_id])->all();
    }

    /** The hub that delivers this box, or null (the warehouse delivers it direct). */
    public static function hubOf(?Invoice $i, ?array $map = null): ?int
    {
        if (! $i) {
            return null;
        }
        $map ??= static::map();
        if ($map === []) {
            return null;
        }
        $p = static::pKey($i->receiver_province);
        $c = static::cKey($i->receiver_city);
        if ($c !== '') {
            $b = static::bKey(Barangays::of($i));
            if ($b !== '' && isset($map[$p.'|'.$c.'|'.$b])) {
                return $map[$p.'|'.$c.'|'.$b];
            }
            if (isset($map[$p.'|'.$c.'|'])) {
                return $map[$p.'|'.$c.'|'];
            }
        }

        return $map[$p.'||'] ?? null;
    }

    /** The owner of exactly this place (any hub, active or not). */
    public static function owner(string $province, ?string $city = null, ?string $barangay = null): ?HubArea
    {
        return HubArea::where('p_key', static::pKey($province))->where('c_key', $city ? static::cKey($city) : '')
            ->where('b_key', $barangay ? static::bKey($barangay) : '')->first();
    }

    /**
     * Give a place to a hub. A place owned by another hub is not taken: the conflict comes back, unless $move.
     *
     * @return array{ok: bool, conflict?: HubArea}
     */
    public static function add(int $hubId, string $province, ?string $city, ?string $barangay, ?User $by, bool $move = false): array
    {
        $province = Str::title(Str::squish($province));
        $city = filled($city) ? Str::title(Str::squish($city)) : null;
        $barangay = filled($barangay) && $city ? Str::title(Str::squish($barangay)) : null;
        if (static::pKey($province) === '') {
            return ['ok' => false];
        }
        $have = static::owner($province, $city, $barangay);
        if ($have && (int) $have->logistichub_id === $hubId) {
            return ['ok' => true];
        }
        if ($have && ! $move) {
            return ['ok' => false, 'conflict' => $have];
        }
        $label = collect([$barangay ? 'Brgy. '.$barangay : null, $city, $province])->filter()->join(', ');
        DB::transaction(function () use ($have, $hubId, $province, $city, $barangay, $by, $label) {
            if ($have) {
                static::log($hubId, $label.': '.static::name($have->logistichub_id).' → '.static::name($hubId), $by);
                $have->update(['logistichub_id' => $hubId]);

                return;
            }
            HubArea::create(['logistichub_id' => $hubId, 'province' => $province, 'city' => $city, 'barangay' => $barangay,
                'p_key' => static::pKey($province), 'c_key' => $city ? static::cKey($city) : '', 'b_key' => $barangay ? static::bKey($barangay) : '']);
            static::log($hubId, static::name($hubId).': + '.$label, $by);
        });

        return ['ok' => true];
    }

    public static function remove(HubArea $a, ?User $by): void
    {
        static::log($a->logistichub_id, static::name($a->logistichub_id).': − '.$a->label(), $by);
        $a->delete();
    }

    public static function name(?int $hubId): string
    {
        return $hubId ? (string) (Logistichub::whereKey($hubId)->value('hub_name') ?? 'hub #'.$hubId) : '';
    }

    public static function log(?int $hubId, string $text, ?User $by): void
    {
        DB::table('hub_area_log')->insert(['logistichub_id' => $hubId, 'text' => Str::limit($text, 295, ''), 'user_id' => $by?->id, 'created_at' => now(), 'updated_at' => now()]);
    }

    /** A hub asks for a place; the office gets it in the bell. */
    public static function request(int $hubId, string $province, ?string $city, ?string $barangay, ?string $reason, ?User $by): HubAreaRequest
    {
        // who delivers it now: the barangay's hub, or the city's, or the province's
        $now = ($barangay ? static::owner($province, $city, $barangay) : null)?->logistichub_id
            ?? ($city ? static::owner($province, $city) : null)?->logistichub_id
            ?? static::owner($province)?->logistichub_id;
        $r = HubAreaRequest::create(['logistichub_id' => $hubId, 'province' => Str::title(Str::squish($province)), 'city' => filled($city) ? Str::title(Str::squish($city)) : null,
            'barangay' => filled($barangay) ? Str::title(Str::squish($barangay)) : null, 'reason' => Str::limit((string) $reason, 295, ''), 'now_hub_id' => $now, 'user_id' => $by?->id]);
        try {
            $office = User::where('is_admin', true)->get()->merge(User::role('super_admin')->get())->unique('id');
            Notification::make()->title(static::name($hubId).' asks for '.$r->label())
                ->body(collect([$now ? 'now '.static::name($now) : 'no hub now', $reason])->filter()->join(' · '))->warning()->sendToDatabase($office);
        } catch (\Throwable $e) {
            report($e);
        }

        return $r;
    }

    public static function decide(HubAreaRequest $r, bool $yes, ?User $by): void
    {
        if ($yes) {
            static::add($r->logistichub_id, $r->province, $r->city, $r->barangay, $by, true);
        }
        $r->update(['status' => $yes ? 'approved' : 'refused', 'decided_by' => $by?->id, 'decided_at' => now()]);
        if (! $yes) {
            static::log($r->logistichub_id, static::name($r->logistichub_id).' asked for '.$r->label().': refused', $by);
        }
        try {
            $users = User::where('logistichub_id', $r->logistichub_id)->get();
            Notification::make()->title($r->label().': '.($yes ? 'approved' : 'refused'))
                ->body($yes ? 'New boxes for this place now come to your hub.' : 'It stays as it is.')->{$yes ? 'success' : 'warning'}()->sendToDatabase($users);
        } catch (\Throwable $e) {
            report($e);
        }
    }

    public static function pendingCount(): int
    {
        return static::ready() ? HubAreaRequest::where('status', 'pending')->count() : 0;
    }

    /** Boxes per week for a province (or a city), from the last 4 weeks of manifests. */
    public static function perWeek(string $province, ?string $city = null): int
    {
        $q = Invoice::query()->where('created_at', '>=', now()->subDays(28))->where('receiver_province', 'like', $province);
        if ($city) {
            $q->where('receiver_city', 'like', $city.'%');
        }

        return (int) round($q->count() / 4);
    }

    public static function regionOf(?string $province): ?string
    {
        $k = static::pKey($province);
        foreach (self::REGIONS as $r => $list) {
            foreach ($list as $p) {
                if (static::pKey($p) === $k) {
                    return $r;
                }
            }
        }

        return null;
    }

    /**
     * Suggested area for a hub, from where it is: its own province and the provinces of its region with no hub;
     * places of its province that another hub (from another province) delivers come back as "closer".
     *
     * @return array{free: list<array{province: string, city: ?string, sub: string, perWeek: int}>, closer: list<array{area: HubArea, sub: string}>}
     */
    public static function suggest(Logistichub $hub): array
    {
        $out = ['free' => [], 'closer' => []];
        if (blank($hub->province)) {
            return $out;
        }
        $own = Str::title(Str::squish($hub->province));
        $taken = HubArea::query()->get();
        $ownedProvince = fn (string $p) => $taken->first(fn ($a) => $a->p_key === static::pKey($p) && $a->c_key === '');
        $anyInProvince = fn (string $p) => $taken->contains(fn ($a) => $a->p_key === static::pKey($p));
        $hubProv = Logistichub::query()->pluck('province', 'id')->map(fn ($p) => static::pKey($p));

        if (! $ownedProvince($own)) {
            $out['free'][] = ['province' => $own, 'city' => null, 'sub' => 'Whole province · the hub is here', 'perWeek' => static::perWeek($own)];
        }
        foreach (self::REGIONS[static::regionOf($own)] ?? [] as $p) {
            if (static::pKey($p) !== static::pKey($own) && ! $anyInProvince($p)) {
                $out['free'][] = ['province' => $p, 'city' => null, 'sub' => 'No hub now · same region', 'perWeek' => static::perWeek($p)];
            }
        }
        foreach ($taken->where('p_key', static::pKey($own)) as $a) {
            if ((int) $a->logistichub_id !== (int) $hub->id && ($hubProv[$a->logistichub_id] ?? '') !== static::pKey($own)) {
                $out['closer'][] = ['area' => $a, 'sub' => $a->label().' is with '.static::name($a->logistichub_id).', a hub in another province. '.$hub->hub_name.' is in '.$own.'.'];
            }
        }
        $out['free'] = collect($out['free'])->sortByDesc('perWeek')->take(6)->values()->all();

        return $out;
    }

    /** Places of hubs that are switched off: their boxes go direct now. */
    public static function orphans(): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $off = Logistichub::where('is_company', true)->where('is_active', false)->pluck('hub_name', 'id');

        return HubArea::whereIn('logistichub_id', $off->keys())->get()->groupBy('logistichub_id')
            ->map(fn ($g, $id) => ['hub' => $off[$id], 'id' => (int) $id, 'places' => $g])->values();
    }

    /** Cities shared by two hubs (barangays given to a hub other than the city's main hub). */
    public static function splitCities(): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $all = HubArea::query()->get();

        return $all->where('b_key', '!=', '')->groupBy(fn ($a) => $a->p_key.'|'.$a->c_key)->map(function ($brgys, $k) use ($all) {
            [$p, $c] = explode('|', $k);
            $main = $all->first(fn ($a) => $a->p_key === $p && $a->c_key === $c && $a->b_key === '')
                ?? $all->first(fn ($a) => $a->p_key === $p && $a->c_key === '' && $a->b_key === '');
            $first = $brgys->first();
            $known = Invoice::query()->where('receiver_city', 'like', $first->city.'%')->where('receiver_province', 'like', $first->province)
                ->whereNotNull('receiver_barangay')->where('receiver_barangay', '!=', '')->distinct()->count('receiver_barangay');

            return ['city' => $first->city, 'province' => $first->province, 'main' => $main?->logistichub_id,
                'byHub' => $brgys->groupBy('logistichub_id'), 'known' => max($known, $brgys->count())];
        })->values();
    }
}
