<?php

namespace App\Support\Maps;

use App\Models\AppSetting;
use App\Models\Invoice;
use App\Models\Maps\BarangayFill;
use App\Models\Maps\ReceiverPlace;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Ai\Ai;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Throwable;

/**
 * Missing barangay: filled in from (1) the same receiver before, (2) the map, (3) driver GPS,
 * (4) the AI reading the address. The manifest address itself is never changed.
 */
class Barangays
{
    /** Settings → AI → AI address cleaning: key => [default, icon, title, what it does, new]. */
    public const OPTIONS = [
        'clean' => [true, '🧹', 'Clean messy addresses for the map', 'What it does today: “Lapu2” → Lapu-Lapu City, “Brgy” → Barangay', false],
        'fill' => [true, '📍', 'Fill in a missing barangay', 'Picks only from the real barangays of that city, never a made-up name', true],
        'landmarks' => [true, '🏬', 'Use landmarks and subdivisions as clues', '“near SM Marilao”, “Villa Arcadia Subd.” help find the barangay (kept for the driver too)', true],
        'early' => [true, '⏱', 'Run right after the manifest is read', 'So the barangay is ready before the AI trip helper plans (before: only when the trip is mapped)', true],
        'remember' => [true, '🧠', 'Remember it for the receiver', 'Same phone or name and street next time: no AI needed, no cost', true],
        'check' => [true, '✅', 'Send unsure ones to Addresses to check', 'The office clicks ✓ OK or Change; everything else is used by itself', true],
    ];

    public const LEVELS = [90 => 'Very sure (90%)', 75 => 'Sure (75%)', 60 => 'Fairly sure (60%)'];

    public const SOURCES = ['same' => 'Same receiver', 'map' => 'Map', 'driver' => 'Driver GPS', 'ai' => 'AI guess', 'office' => 'Checked by the office'];

    public static function ready(): bool
    {
        return Schema::hasTable('barangay_fills');
    }

    public static function on(string $option): bool
    {
        return (bool) AppSetting::get('addr.'.$option, self::OPTIONS[$option][0] ?? false);
    }

    public static function level(): int
    {
        $l = (int) AppSetting::get('addr.level', 75);

        return array_key_exists($l, self::LEVELS) ? $l : 75;
    }

    /** The barangay to use for a box: the manifest's, else the one filled in (sure or checked). */
    public static function of(?Invoice $i): ?string
    {
        if (! $i) {
            return null;
        }
        $own = Str::squish((string) $i->receiver_barangay);
        if ($own !== '' && ! static::blankish($own)) {
            return $own;
        }
        if (! static::ready()) {
            return null;
        }
        $fill = $i->relationLoaded('barangayFill') ? $i->barangayFill : $i->barangayFill()->first();

        return $fill?->isUsed() ? $fill->barangay : null;
    }

    /** Small note for a trip stop: where the barangay came from, or that there is none. */
    public static function note(?Invoice $i): ?string
    {
        if (! $i || (Str::squish((string) $i->receiver_barangay) !== '' && ! static::blankish($i->receiver_barangay))) {
            return null;
        }
        $fill = static::ready() ? ($i->relationLoaded('barangayFill') ? $i->barangayFill : $i->barangayFill()->first()) : null;

        return match (true) {
            $fill?->status === 'checked' => 'checked',
            $fill?->status === 'used' => $fill->source === 'ai' ? 'AI' : (self::SOURCES[$fill->source] ?? 'filled'),
            $fill?->status === 'check' => 'AI guess, not checked',
            default => 'no barangay',
        };
    }

    /** "N/A", "-", "none" count as no barangay. */
    public static function blankish(?string $v): bool
    {
        return in_array(Str::lower(trim((string) $v, " .-")), ['', 'na', 'n/a', 'none', 'null', '0', 'x'], true);
    }

    public static function cityKey(?string $city): string
    {
        $c = Str::lower(Str::squish(preg_replace('/[^\pL\pN ]+/u', ' ', (string) $city)));
        $c = preg_replace('/^(city of|municipality of) /', '', $c);

        return trim(preg_replace('/ city$/', '', $c));
    }

    /** "Brgy. Sto. Niño" and "santo nino" compare the same. */
    public static function nameKey(?string $b): string
    {
        $b = Str::lower(Str::ascii(Str::squish((string) $b)));
        $b = preg_replace('/\b(brgy|bgy|barangay|brg)\b\.?/', '', $b);
        $b = preg_replace(['/\bsto\b\.?/', '/\bsta\b\.?/', '/\bpob\b\.?/', '/\bsn\b\.?/'], ['santo', 'santa', 'poblacion', 'san'], $b);

        return trim(preg_replace('/[^a-z0-9]+/', ' ', $b));
    }

    /** @return list<string> keys for the same receiver: phone, and name + street */
    public static function receiverKeys(Invoice $i): array
    {
        $keys = [];
        $phone = substr(preg_replace('/\D+/', '', (string) $i->receiver_mobile_no), -10);
        if (strlen($phone) >= 9) {
            $keys[] = 'p'.$phone;
        }
        $name = Str::lower(Str::squish($i->receiver_name.'|'.$i->receiver_address));
        if (strlen($name) > 3) {
            $keys[] = 'n'.md5($name.'|'.static::cityKey($i->receiver_city));
        }

        return $keys;
    }

    /** Real barangays of a city: the ones in your own manifests and the ones already checked. */
    public static function known(?string $city): array
    {
        $ck = static::cityKey($city);
        if ($ck === '') {
            return [];
        }

        return Cache::remember('brgy.known.'.md5($ck), 600, function () use ($ck) {
            $core = Str::before($ck, ' ') ?: $ck;
            $names = DB::table('invoices')->where('receiver_city', 'like', '%'.$core.'%')->where('receiver_barangay', '!=', '')
                ->select('receiver_city', 'receiver_barangay')->distinct()->limit(4000)->get()
                ->filter(fn ($r) => static::cityKey($r->receiver_city) === $ck)->pluck('receiver_barangay');
            if (Schema::hasTable('receiver_places')) {
                $names = $names->merge(ReceiverPlace::where('city_key', $ck)->whereNotNull('barangay')->pluck('barangay'));
            }

            return $names->map(fn ($n) => Str::title(Str::squish($n)))->reject(fn ($n) => static::blankish($n))
                ->unique(fn ($n) => static::nameKey($n))->sort()->values()->take(400)->all();
        });
    }

    /** The known barangay this name means, or null. */
    public static function match(?string $name, array $known): ?string
    {
        $k = static::nameKey($name);
        if ($k === '') {
            return null;
        }
        $best = null;
        $score = 0;
        foreach ($known as $b) {
            $bk = static::nameKey($b);
            if ($bk === $k) {
                return $b;
            }
            similar_text($bk, $k, $pct);
            if ($pct > $score) {
                [$best, $score] = [$b, $pct];
            }
        }

        return $score >= 88 ? $best : null;
    }

    /** A new box with no barangay: queue it (no map or AI call here). */
    public static function queue(Invoice $i): void
    {
        try {
            if (! static::ready() || ! static::on('fill') || ! static::blankish($i->receiver_barangay)) {
                return;
            }
            BarangayFill::firstOrCreate(['invoice_id' => $i->id], ['container_id' => $i->container_id, 'status' => 'pending']);
        } catch (Throwable $e) {
            report($e);
        }
    }

    /** Boxes not delivered yet with no barangay and no row: queue them. */
    public static function scan(int $limit = 3000): int
    {
        if (! static::ready() || ! static::on('fill')) {
            return 0;
        }
        $rows = DB::table('invoices as i')->leftJoin('barangay_fills as f', 'f.invoice_id', '=', 'i.id')
            ->whereNull('f.id')->where('i.is_delivered', false)
            ->where(fn ($q) => $q->whereNull('i.receiver_barangay')->orWhereIn(DB::raw('lower(trim(i.receiver_barangay))'), ['', 'na', 'n/a', 'none', '-', 'null']))
            ->limit($limit)->get(['i.id', 'i.container_id']);
        $now = now();
        foreach ($rows->chunk(500) as $chunk) {
            BarangayFill::insertOrIgnore($chunk->map(fn ($r) => ['invoice_id' => $r->id, 'container_id' => $r->container_id, 'status' => 'pending', 'created_at' => $now, 'updated_at' => $now])->all());
        }

        return $rows->count();
    }

    /** Fill in the waiting ones. $maps = most map lookups, AI is asked in batches. */
    public static function work(int $limit = 60, int $maps = 30, ?Collection $only = null): array
    {
        if (! static::ready() || ! static::on('fill')) {
            return ['done' => 0, 'ai' => 0];
        }
        $fills = $only ?? BarangayFill::with('invoice')->where('status', 'pending')->where('tries', '<', 3)->oldest('id')->limit($limit)->get();
        $askAi = [];
        $done = 0;
        foreach ($fills as $f) {
            if (! $f->invoice || ! static::blankish($f->invoice->receiver_barangay)) {
                $f->delete();

                continue;
            }
            $f->tries++;
            $r = static::cheap($f->invoice, $maps);
            if ($r) {
                static::apply($f, $r);
                $done++;
            } else {
                $askAi[] = $f;
            }
        }
        $ai = 0;
        if ($askAi) {
            $results = static::canAskAi() ? static::askAi(collect($askAi)->map->invoice->all()) : [];
            foreach ($askAi as $n => $f) {
                $r = $results[$n] ?? null;
                static::apply($f, $r ?? ['barangay' => null, 'source' => null, 'confidence' => 0, 'clue' => static::canAskAi() ? 'The AI found no barangay clue' : 'Only the city is written', 'clues' => [], 'candidates' => []]);
                $ai += $r ? 1 : 0;
                $done++;
            }
        }

        return ['done' => $done, 'ai' => $ai];
    }

    public static function canAskAi(): bool
    {
        return Ai::enabled('addresses') && ! Ai::overLimit();
    }

    /**
     * Steps 1–3, no AI: same receiver before, the map, driver GPS nearby.
     *
     * @return array{barangay: string, source: string, confidence: int, clue: string, clues: array, candidates: array, lat?: float, lng?: float}|null
     */
    public static function cheap(Invoice $i, int &$maps = 0): ?array
    {
        $ck = static::cityKey($i->receiver_city);
        $known = static::known($i->receiver_city);

        // 1 · same receiver before
        if (static::on('remember')) {
            $keys = static::receiverKeys($i);
            $p = $keys ? ReceiverPlace::whereIn('key', $keys)->where('city_key', $ck)->whereNotNull('barangay')->latest('updated_at')->first() : null;
            if ($p) {
                return static::hit($p->barangay, 'same', 100, 'Same receiver'.($p->confirmed_at ? ', '.$p->confirmed_at->format('M j') : ''));
            }
        }
        $phone = substr(preg_replace('/\D+/', '', (string) $i->receiver_mobile_no), -10);
        if (strlen($phone) >= 9) {
            $before = Invoice::where('id', '!=', $i->id)->where('receiver_mobile_no', 'like', '%'.substr($phone, -4))->where('receiver_barangay', '!=', '')
                ->latest('id')->limit(200)->get(['id', 'receiver_mobile_no', 'receiver_city', 'receiver_barangay', 'created_at'])
                ->first(fn ($o) => substr(preg_replace('/\D+/', '', (string) $o->receiver_mobile_no), -10) === $phone
                    && static::cityKey($o->receiver_city) === $ck && ! static::blankish($o->receiver_barangay));
            if ($before) {
                return static::hit(Str::title(Str::squish($before->receiver_barangay)), 'same', 100, 'Same receiver, '.Carbon::parse($before->created_at)->format('M j').' box');
            }
        }

        // 2 · the map (the address is looked up once and saved; the trip map uses the same lookup)
        $place = null;
        if (MapSettings::provider() !== 'none' && $maps > 0) {
            $maps--;
            try {
                $place = Geocoder::find(TripSorter::address($i));
            } catch (Throwable $e) {
                report($e);
            }
            if ($place && filled($place->barangay ?? null)) {
                $name = static::match($place->barangay, $known) ?? Str::title($place->barangay);

                return static::hit($name, 'map', 95, 'Map found the address', $place->lat, $place->lng);
            }
        }

        // 3 · driver GPS: a receiver delivered next to this pin
        if ($place?->hasPin()) {
            $near = ReceiverPlace::where('city_key', $ck)->whereNotNull('barangay')->whereNotNull('lat')
                ->whereBetween('lat', [$place->lat - 0.004, $place->lat + 0.004])->whereBetween('lng', [$place->lng - 0.004, $place->lng + 0.004])
                ->get()->map(fn ($p) => [$p, static::meters($place->lat, $place->lng, $p->lat, $p->lng)])
                ->filter(fn ($x) => $x[1] <= 300)->sortBy(fn ($x) => $x[1])->first();
            if ($near) {
                return static::hit($near[0]->barangay, 'driver', 90, 'Driver GPS'.($near[0]->confirmed_at ? ', '.$near[0]->confirmed_at->format('M j') : '').' · '.round($near[1]).' m away', $place->lat, $place->lng);
            }
        }

        return null;
    }

    protected static function hit(string $b, string $source, int $conf, string $why, ?float $lat = null, ?float $lng = null): array
    {
        return ['barangay' => $b, 'source' => $source, 'confidence' => $conf, 'clue' => $why, 'clues' => [], 'candidates' => [['name' => $b, 'pct' => $conf, 'why' => $why]], 'lat' => $lat, 'lng' => $lng];
    }

    /**
     * Step 4: the AI reads the addresses (address and city only, never the name or phone).
     *
     * @param  list<Invoice>  $invoices
     * @return array<int, array> results by the same index
     */
    public static function askAi(array $invoices): array
    {
        $out = [];
        foreach (array_chunk($invoices, 15, true) as $chunk) {
            $items = [];
            foreach ($chunk as $n => $i) {
                $address = static::on('landmarks') ? $i->receiver_address : static::withoutNotes($i->receiver_address);
                $items[] = ['i' => $n, 'address' => Str::limit(Str::squish((string) $address), 300, ''), 'city' => Str::squish($i->receiver_city.', '.$i->receiver_province, ', '), 'barangays' => static::known($i->receiver_city)];
            }
            try {
                $res = Ai::json('addresses',
                    'You find the barangay of Philippine delivery addresses whose barangay is missing. For each item, use the clues in the address '
                    .'(subdivision, street, purok, landmark like a mall or school, short forms like "Brgy SJ" or "Pob.") and pick the barangay from that item\'s "barangays" list. '
                    .'Never answer a name that is not in the list; if the list is empty, answer only a barangay that is written in the address. If there is no real clue, answer null. '
                    .'Give how sure you are (0-100), one short reason, the exact words from the address you used, and up to 3 candidates. '
                    .'Answer as {"items":[{"i":0,"barangay":"..." or null,"confidence":0,"why":"...","clues":[{"text":"words from the address","kind":"subdivision|landmark|street|short form"}],"candidates":[{"name":"...","pct":0,"why":"..."}]}]}',
                    json_encode($items, JSON_UNESCAPED_UNICODE), 'fast', 2500);
            } catch (Throwable $e) {
                report($e);

                continue;
            }
            foreach ($res['items'] ?? [] as $row) {
                $n = $row['i'] ?? null;
                if (! array_key_exists($n, $chunk)) {
                    continue;
                }
                $known = static::known($chunk[$n]->receiver_city);
                $pick = fn ($name) => $known ? static::match($name, $known) : (filled($name) && str_contains(static::nameKey($chunk[$n]->receiver_address), static::nameKey($name)) ? Str::title($name) : null);
                $b = $pick($row['barangay'] ?? null);
                $cands = collect($row['candidates'] ?? [])->map(fn ($c) => ['name' => $pick($c['name'] ?? null), 'pct' => max(0, min(100, (int) ($c['pct'] ?? 0))), 'why' => Str::limit((string) ($c['why'] ?? ''), 120)])
                    ->filter(fn ($c) => $c['name'])->unique('name')->take(3)->values()->all();
                $out[$n] = [
                    'barangay' => $b, 'source' => 'ai', 'confidence' => $b ? max(0, min(100, (int) ($row['confidence'] ?? 0))) : 0,
                    'clue' => Str::limit((string) ($row['why'] ?? ''), 280), 'candidates' => $cands,
                    'clues' => collect($row['clues'] ?? [])->map(fn ($c) => ['text' => Str::limit((string) ($c['text'] ?? ''), 80, ''), 'kind' => Str::limit((string) ($c['kind'] ?? 'clue'), 20, '')])
                        ->filter(fn ($c) => $c['text'] !== '' && Str::contains(Str::lower($chunk[$n]->receiver_address), Str::lower($c['text'])))->take(4)->values()->all(),
                ];
            }
        }

        return $out;
    }

    protected static function withoutNotes(?string $a): string
    {
        return trim(preg_replace('/\b(near|beside|in front of|across|tapat( ng)?|malapit sa|likod ng)\b[^,]*/i', '', (string) $a), ' ,');
    }

    /** Save a result: sure ones are used, unsure ones go to Addresses to check. */
    public static function apply(BarangayFill $f, array $r): void
    {
        $b = $r['barangay'] ?? null;
        $conf = (int) ($r['confidence'] ?? 0);
        $status = match (true) {
            ! $b => 'none',
            ($r['source'] ?? null) !== 'ai' || $conf >= static::level() => 'used',
            static::on('check') => 'check',
            default => 'none',
        };
        $f->fill(['barangay' => $b, 'source' => $r['source'] ?? null, 'confidence' => $conf, 'clue' => $r['clue'] ?? null,
            'clues' => $r['clues'] ?? [], 'candidates' => $r['candidates'] ?? [], 'status' => $status])->save();
        if ($status === 'used' && ($r['source'] ?? null) !== 'same') {
            static::remember($f->invoice, $b, $r['source'], $r['lat'] ?? null, $r['lng'] ?? null, false);
        }
    }

    /** The office picks the barangay (✓ OK or Change). Also for the receiver's other boxes when asked. */
    public static function confirm(BarangayFill $f, string $barangay, ?User $by = null, bool $sameReceiver = true): int
    {
        $n = 0;
        $fills = collect([$f]);
        if ($sameReceiver && $f->invoice) {
            $keys = TripPlannerKey::of($f->invoice);
            $fills = $fills->merge(BarangayFill::with('invoice')->where('id', '!=', $f->id)->whereIn('status', ['pending', 'check', 'none', 'used'])
                ->whereHas('invoice', fn ($q) => $q->where('is_delivered', false)->where('set_key', $f->invoice->set_key))->get()
                ->filter(fn ($o) => $o->invoice && TripPlannerKey::of($o->invoice) === $keys));
        }
        foreach ($fills as $x) {
            $x->fill(['barangay' => $barangay, 'status' => 'checked', 'source' => $x->id === $f->id && $x->barangay === $barangay ? $x->source : 'office',
                'checked_by' => $by?->id, 'checked_at' => now()])->save();
            $n++;
        }
        if ($f->invoice) {
            static::remember($f->invoice, $barangay, 'office', null, null, true);
        }

        return $n;
    }

    public static function remember(?Invoice $i, ?string $barangay, ?string $source, ?float $lat = null, ?float $lng = null, bool $confirmed = false): void
    {
        if (! $i || ! static::on('remember') || ! Schema::hasTable('receiver_places')) {
            return;
        }
        foreach (static::receiverKeys($i) as $key) {
            $p = ReceiverPlace::firstOrNew(['key' => $key]);
            $p->city_key = static::cityKey($i->receiver_city);
            if ($barangay) {
                $p->barangay = $barangay;
                $p->source = $source;
            }
            if ($lat !== null && $lng !== null) {
                [$p->lat, $p->lng] = [$lat, $lng];
            }
            if ($confirmed) {
                $p->confirmed_at = now();
            }
            $p->save();
        }
        Cache::forget('brgy.known.'.md5(static::cityKey($i->receiver_city)));
    }

    /** Delivered: the driver's phone was here, so this receiver's place is known for next time. */
    public static function learnFromDelivery(Tripinvoice $t): void
    {
        try {
            if (! static::ready() || ! Schema::hasTable('truck_positions') || ! $t->delivered_at) {
                return;
            }
            $i = $t->invdata;
            $pos = DB::table('truck_positions')->where('deliverylog_id', $t->deliverylog_id)
                ->whereBetween('recorded_at', [$t->delivered_at->copy()->subMinutes(10), $t->delivered_at->copy()->addMinutes(10)])->get()
                ->sortBy(fn ($p) => abs(Carbon::parse($p->recorded_at)->diffInSeconds($t->delivered_at)))->first();
            if ($i && $pos) {
                static::remember($i, static::of($i), 'driver', (float) $pos->lat, (float) $pos->lng, true);
            }
        } catch (Throwable $e) {
            report($e);
        }
    }

    public static function meters(float $aLat, float $aLng, float $bLat, float $bLng): float
    {
        $r = 6371000;
        $dLat = deg2rad($bLat - $aLat);
        $dLng = deg2rad($bLng - $aLng);
        $h = sin($dLat / 2) ** 2 + cos(deg2rad($aLat)) * cos(deg2rad($bLat)) * sin($dLng / 2) ** 2;

        return 2 * $r * asin(min(1, sqrt($h)));
    }

    /** Boxes this panel may see (admin: all; warehouse: its own; partner hub: boxes coming to it). */
    public static function scope(Builder $q, ?User $user, ?string $panel): Builder
    {
        $q->whereHas('invoice', fn ($i) => $i->where('is_delivered', false));
        if (! $user || $panel === 'admin') {
            return $q;
        }
        if ($panel === 'warehouse') {
            return $q->whereHas('invoice', fn ($i) => $i->where('warehouse_id', $user->warehouse_id));
        }
        $hub = (int) $user->logistichub_id;

        return $q->whereHas('invoice', fn ($i) => $i->whereExists(fn ($e) => $e->from('tripinvoices as h')->whereColumn('h.invoice_id', 'invoices.id')->where('h.logistichub_id', $hub)));
    }

    /** Try an address without saving a box (Settings → AI → Try it). */
    public static function tryOne(string $address, string $city, string $province = ''): array
    {
        $i = new Invoice(['receiver_address' => $address, 'receiver_city' => $city, 'receiver_province' => $province, 'receiver_barangay' => '', 'receiver_name' => '', 'receiver_mobile_no' => '']);
        $i->id = 0;
        $clean = null;
        if (static::on('clean') && Ai::enabled('addresses')) {
            $place = Geocoder::place(TripSorter::address($i));
            if (! $place->clean) {
                AddressCleaner::clean(collect([$place]));
            }
            $clean = $place->clean;
        }
        $maps = 1;
        $r = static::cheap($i, $maps) ?? (static::canAskAi() ? (static::askAi([$i])[0] ?? null) : null);
        $r ??= ['barangay' => null, 'source' => null, 'confidence' => 0, 'clue' => static::canAskAi() ? 'No barangay clue' : 'The AI is off', 'clues' => [], 'candidates' => []];
        $r['clean'] = $clean ?? TripSorter::address($i);
        $r['status'] = match (true) {
            ! $r['barangay'] => 'none',
            $r['source'] !== 'ai' || $r['confidence'] >= static::level() => 'used',
            static::on('check') => 'check',
            default => 'none',
        };

        return $r;
    }

    /** This month on the settings page. */
    public static function month(): array
    {
        $from = today()->startOfMonth();
        $fills = static::ready() ? BarangayFill::where('updated_at', '>=', $from) : null;

        return [
            'cleaned' => Schema::hasTable('geo_places') ? DB::table('geo_places')->whereNotNull('clean')->where('updated_at', '>=', $from)->count() : 0,
            'filled' => $fills ? (clone $fills)->whereIn('status', ['used', 'checked'])->count() : 0,
            'check' => $fills ? (clone $fills)->where('status', 'check')->count() : 0,
            'cost' => Schema::hasTable('ai_usage') ? (float) DB::table('ai_usage')->where('feature', 'addresses')->where('created_at', '>=', $from)->sum('cost') : 0.0,
        ];
    }
}
