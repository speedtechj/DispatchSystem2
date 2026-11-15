<?php

namespace App\Support;

use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Support\Ai\Ai;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Box sizes: trucks fill by space, not by count. The box types come from the manifests
 * (the invoices' box type); the normal box is 1 space and the others are set next to it.
 * Different spellings of one type ("LARGE", "Large box", "LG") are joined into one size.
 * A box with no type, or a type not set yet, counts as 1.
 */
class BoxSizes
{
    public const SETTING = 'boxes.by_space';

    /** Words that mean the same size, after cleaning. */
    protected const SAME = [
        ['xl', 'xlarge', 'extralarge', 'xlg', 'exl', 'xtralarge'],
        ['xxl', 'xxlarge', '2xl', 'extraextralarge'],
        ['l', 'lg', 'lrg', 'lge', 'large'],
        ['m', 'md', 'med', 'mdm', 'medium', 'mid'],
        ['s', 'sm', 'sml', 'small'],
        ['xs', 'xsmall', 'extrasmall'],
        ['reg', 'regular', 'std', 'standard', 'normal'],
        ['jb', 'jmb', 'jumbo'],
    ];

    protected static ?array $map = null;

    protected static ?array $names = null;

    protected static ?bool $ready = null;

    /** The app these memos belong to (a new one in each test, or after a queue worker restart). */
    protected static ?\WeakReference $app = null;

    protected static function fresh(): void
    {
        $app = app();
        if (static::$app?->get() !== $app) {
            static::$app = \WeakReference::create($app);
            static::$map = static::$names = static::$ready = null;
        }
    }

    public static function ready(): bool
    {
        static::fresh();

        return static::$ready ??= Schema::hasTable('box_sizes');
    }

    /**
     * Plan trips by space: switched on (the default) and at least one box type is set bigger
     * or smaller than the normal box. Until then trucks are counted in boxes, as before.
     */
    public static function on(): bool
    {
        return static::switchedOn() && collect(static::map())->contains(fn ($v) => abs($v - 1) > 0.01);
    }

    public static function switchedOn(): bool
    {
        return static::ready() && (string) AppSetting::get(static::SETTING, '1') === '1';
    }

    public static function forget(): void
    {
        static::$map = null;
        static::$names = null;
        static::$ready = null;
        Cache::forget('box.sizes');
        Cache::forget('box.names');
    }

    /** "X-LARGE", "Large Box", " large " → "xlarge", "large", "large". */
    public static function key(?string $type): string
    {
        $k = preg_replace('/[^a-z0-9]+/', '', Str::lower(Str::ascii((string) $type)));
        $short = preg_replace('/(boxes|box|size)$/', '', $k);

        return $short !== '' ? $short : $k;
    }

    /** cleaned spelling => space */
    public static function map(): array
    {
        static::fresh();
        if (static::$map !== null) {
            return static::$map;
        }
        if (! static::ready()) {
            return static::$map = [];
        }

        return static::$map = Cache::remember('box.sizes', 600, function () {
            $out = [];
            foreach (BoxSize::all() as $s) {
                foreach ($s->spellings ?? [] as $k) {
                    $out[$k] = $s->is_set ? (float) $s->space : 1.0;
                }
            }

            return $out;
        });
    }

    /** The truck space one box takes. 1 when planning by space is off, or the type is unknown. */
    public static function spaceOf(?string $type): float
    {
        if (! static::on()) {
            return 1.0;
        }
        $k = static::key($type);

        return $k === '' ? 1.0 : (static::map()[$k] ?? 1.0);
    }

    /** The size a box type belongs to. */
    public static function sizeOf(?string $type): ?BoxSize
    {
        $k = static::key($type);
        if ($k === '' || ! static::ready()) {
            return null;
        }

        return static::sizes()->first(fn (BoxSize $s) => in_array($k, $s->spellings ?? [], true));
    }

    /** The size name for a written box type ("LG" → "Large"); "No type" when empty. */
    public static function nameOfType(?string $type): string
    {
        $k = static::key($type);
        if ($k === '') {
            return 'No type';
        }
        static::fresh();
        static::$names ??= static::ready() ? Cache::remember('box.names', 600, function () {
            $out = [];
            foreach (BoxSize::all() as $s) {
                foreach ($s->spellings ?? [] as $sp) {
                    $out[$sp] = $s->name;
                }
            }

            return $out;
        }) : [];

        return static::$names[$k] ?? trim((string) $type);
    }

    /** @return Collection<int, BoxSize> */
    public static function sizes(): Collection
    {
        return static::ready() ? BoxSize::orderByDesc('is_base')->orderBy('is_set')->orderBy('space')->orderBy('name')->get() : collect();
    }

    public static function base(): ?BoxSize
    {
        return static::ready() ? BoxSize::where('is_base', true)->first() : null;
    }

    /** 1.5 → "1½", 0.5 → "½", 2 → "2". */
    public static function fmt(float $n): string
    {
        $n = round($n * 2) / 2;
        $whole = (int) floor($n);
        $half = $n - $whole > 0.01;

        return $half ? ($whole === 0 ? '½' : $whole.'½') : (string) $whole;
    }

    /** Round to the nearest half. */
    public static function half(float $n): float
    {
        return round($n * 2) / 2;
    }

    // ------------------------------------------------------------------ reading the manifests

    /**
     * How many boxes of each written box type. @return Collection<int, array{raw: string, key: string, n: int}>
     */
    public static function written(?int $days = null): Collection
    {
        $q = Invoice::query()->whereNotNull('boxtype')->where('boxtype', '!=', '');
        if ($days) {
            $q->where('created_at', '>=', now()->subDays($days));
        }

        return $q->select('boxtype', DB::raw('count(*) as n'))->groupBy('boxtype')->get()
            ->map(fn ($r) => ['raw' => trim((string) $r->boxtype), 'key' => static::key($r->boxtype), 'n' => (int) $r->n])
            ->filter(fn ($r) => $r['key'] !== '')->values();
    }

    /**
     * Add every box type on the manifests that is not here yet (as "New · not set").
     * The most common one becomes the normal box the first time.
     */
    public static function sync(): int
    {
        if (! static::ready()) {
            return 0;
        }
        $known = BoxSize::pluck('spellings')->flatten()->flip();
        $added = 0;
        $groups = static::written()->groupBy('key');
        foreach ($groups as $key => $rows) {
            if (isset($known[$key])) {
                continue;
            }
            BoxSize::create(['name' => static::nameOf($rows), 'spellings' => [$key], 'space' => 1, 'is_base' => false, 'is_set' => false]);
            $added++;
        }
        if (! BoxSize::where('is_base', true)->exists() && ($top = static::biggest())) {
            $top->update(['is_base' => true, 'is_set' => true, 'space' => 1]);
        }
        static::forget();

        return $added;
    }

    /** The name as most often written: "LARGE" and "Large" → "Large". */
    protected static function nameOf(Collection $rows): string
    {
        $raw = $rows->sortByDesc('n')->first()['raw'];

        return Str::length($raw) <= 3 ? Str::upper($raw) : Str::title(Str::lower($raw));
    }

    /** The size with the most boxes. */
    protected static function biggest(): ?BoxSize
    {
        $counts = static::counts();

        return BoxSize::all()->sortByDesc(fn (BoxSize $s) => $counts[$s->id] ?? 0)->first();
    }

    /** size id => boxes (last $days days, or all when null). */
    public static function counts(?int $days = null): array
    {
        $byKey = static::written($days)->groupBy('key')->map(fn ($g) => $g->sum('n'));
        $out = [];
        foreach (BoxSize::all() as $s) {
            $out[$s->id] = collect($s->spellings ?? [])->sum(fn ($k) => $byKey[$k] ?? 0);
        }

        return $out;
    }

    /** size id => the ways it is written on the manifests ("LARGE", "Large box", "LG"). */
    public static function spellingsShown(): array
    {
        $byKey = static::written()->groupBy('key')->map(fn ($g) => $g->sortByDesc('n')->pluck('raw')->unique()->take(4)->all());
        $out = [];
        foreach (BoxSize::all() as $s) {
            $out[$s->id] = collect($s->spellings ?? [])->flatMap(fn ($k) => $byKey[$k] ?? [])->unique()->take(6)->values()->all();
        }

        return $out;
    }

    // ------------------------------------------------------------------ changing sizes

    /** Make this the normal box (1). The others are changed so they stay the same real size. */
    public static function setBase(BoxSize $size): void
    {
        $old = (float) ($size->is_set ? $size->space : 1) ?: 1;
        DB::transaction(function () use ($size, $old) {
            foreach (BoxSize::all() as $s) {
                if ($s->id === $size->id) {
                    $s->update(['is_base' => true, 'is_set' => true, 'space' => 1]);
                } else {
                    $s->update(['is_base' => false, 'space' => max(0.5, static::half(((float) $s->space) / $old))]);
                }
            }
        });
        static::forget();
    }

    public static function setSpace(BoxSize $size, float $space): void
    {
        if ($size->is_base) {
            return;
        }
        $size->update(['space' => max(0.5, min(10, static::half($space))), 'is_set' => true]);
    }

    /** "X-LARGE" is the same as "XL": its spellings move over and it is gone. */
    public static function join(BoxSize $from, BoxSize $into): void
    {
        if ($from->id === $into->id) {
            return;
        }
        DB::transaction(function () use ($from, $into) {
            $into->update(['spellings' => array_values(array_unique([...($into->spellings ?? []), ...($from->spellings ?? [])]))]);
            if ($from->is_base) {
                $into->update(['is_base' => true, 'is_set' => true, 'space' => 1]);
            }
            $from->delete();
        });
        static::forget();
    }

    public static function keepApart(BoxSize $a, BoxSize $b): void
    {
        $a->update(['kept_apart' => array_values(array_unique([...($a->kept_apart ?? []), $b->id]))]);
        $b->update(['kept_apart' => array_values(array_unique([...($b->kept_apart ?? []), $a->id]))]);
    }

    /**
     * Box types that look like the same box. The smaller one joins the bigger one.
     *
     * @return list<array{from: BoxSize, into: BoxSize, why: string}>
     */
    public static function lookAlike(): array
    {
        $sizes = BoxSize::all();
        $counts = static::counts();
        $pairs = [];
        $seen = [];
        foreach ($sizes as $a) {
            foreach ($sizes as $b) {
                if ($a->id >= $b->id || in_array($b->id, $a->kept_apart ?? [], true)) {
                    continue;
                }
                $why = static::sameWhy($a->spellings ?? [], $b->spellings ?? []);
                if (! $why) {
                    continue;
                }
                [$from, $into] = ($counts[$a->id] ?? 0) <= ($counts[$b->id] ?? 0) ? [$a, $b] : [$b, $a];
                if ($from->is_base) {
                    [$from, $into] = [$into, $from];
                }
                if (isset($seen[$from->id])) {
                    continue;
                }
                $seen[$from->id] = true;
                $pairs[] = ['from' => $from, 'into' => $into, 'why' => $why];
            }
        }

        return $pairs;
    }

    protected static function sameWhy(array $a, array $b): ?string
    {
        $groupOf = function (string $k): ?int {
            foreach (static::SAME as $i => $group) {
                if (in_array($k, $group, true)) {
                    return $i;
                }
            }

            return null;
        };
        foreach ($a as $x) {
            foreach ($b as $y) {
                $gx = $groupOf($x);
                $gy = $groupOf($y);
                if ($gx !== null && $gx === $gy) {
                    return 'same size word';
                }
                if ($gx !== null && $gy !== null) {
                    continue; // two different size words ("large" and "xlarge")
                }
                $short = strlen($x) <= strlen($y) ? $x : $y;
                $long = $short === $x ? $y : $x;
                if (strlen($short) >= 3 && str_starts_with($long, $short)) {
                    return 'one is short for the other';
                }
                if (strlen($short) >= 5 && strlen($x) === strlen($y) && levenshtein($x, $y) <= 1) {
                    return 'spelled almost the same';
                }
            }
        }

        return null;
    }

    /**
     * With the AI helper on: pairs the simple check missed (consolidator names like "Bulilit"
     * and "Small"). Only names that exist are used.
     *
     * @return list<array{from: BoxSize, into: BoxSize, why: string}>
     */
    public static function lookAlikeAi(): array
    {
        if (! Ai::enabled('box_sizes')) {
            return [];
        }
        $sizes = BoxSize::all();
        $counts = static::counts();
        $list = $sizes->map(fn (BoxSize $s) => ['id' => $s->id, 'name' => $s->name, 'written' => $s->spellings, 'boxes' => $counts[$s->id] ?? 0])->values()->all();
        try {
            $out = Ai::json('box_sizes',
                'These are box types written on cargo manifests of a Philippine balikbayan box company. Find types that are clearly the SAME box size written differently '
                .'(abbreviations, typos, Tagalog/English, "box" added). Do not pair different sizes. Return {"same": [{"from_id": id, "into_id": id, "why": "few words"}]}; the one with fewer boxes is "from".',
                json_encode($list, JSON_UNESCAPED_UNICODE), 'fast', 600);
        } catch (\Throwable) {
            return [];
        }
        $byId = $sizes->keyBy('id');
        $pairs = [];
        foreach ((array) ($out['same'] ?? []) as $p) {
            $from = $byId[(int) ($p['from_id'] ?? 0)] ?? null;
            $into = $byId[(int) ($p['into_id'] ?? 0)] ?? null;
            if ($from && $into && $from->id !== $into->id && ! $from->is_base && ! in_array($into->id, $from->kept_apart ?? [], true)) {
                $pairs[] = ['from' => $from, 'into' => $into, 'why' => '✨ '.Str::limit((string) ($p['why'] ?? 'AI'), 60)];
            }
        }

        return $pairs;
    }

    // ------------------------------------------------------------------ trucks and trips

    /**
     * The space of boxes, and how many of each size.
     *
     * @param  iterable<Invoice|null>  $invoices
     * @return array{space: float, boxes: int, mix: array<string, int>}
     */
    public static function measure(iterable $invoices): array
    {
        $space = 0.0;
        $boxes = 0;
        $mix = [];
        foreach ($invoices as $inv) {
            $boxes++;
            $space += static::spaceOf($inv?->boxtype);
            $name = static::nameOfType($inv?->boxtype);
            $mix[$name] = ($mix[$name] ?? 0) + 1;
        }
        arsort($mix);

        return ['space' => static::half($space), 'boxes' => $boxes, 'mix' => $mix];
    }

    /** "24 Medium · 8 XL · 6 Bulilit" */
    public static function mixText(array $mix, int $max = 4): string
    {
        return collect($mix)->take($max)->map(fn ($n, $name) => $n.' '.$name)->join(' · ');
    }

    /**
     * Space on a trip: loaded so far and in all, and the truck's space.
     *
     * @return array{loaded: float, total: float, cap: ?int, reserve: int}
     */
    public static function tripSpace(Deliverylog $trip, bool $atHub = false): array
    {
        $boxes = Tripinvoice::query()->with('invdata:id,boxtype')
            ->where($atHub ? 'deliveryloghub_id' : 'deliverylog_id', $trip->id)
            ->get(['id', 'invoice_id', 'is_loaded', 'is_loaded_hub']);
        $loadedFlag = $atHub ? 'is_loaded_hub' : 'is_loaded';
        $loaded = $boxes->filter(fn ($b) => $b->{$loadedFlag})->sum(fn ($b) => static::spaceOf($b->invdata?->boxtype));

        return [
            'loaded' => static::half($loaded),
            'total' => static::half($boxes->sum(fn ($b) => static::spaceOf($b->invdata?->boxtype))),
            'cap' => $trip->truck && ($trip->truck->capacity || TruckSpace::fit($trip->truck)) ? TruckSpace::capacity($trip->truck) : null,
            'reserve' => $trip->truck && TruckSpace::ready() ? (int) ($trip->truck->reserve_pct ?? 0) : 0,
        ];
    }

    /**
     * The most each truck carried on one trip in the last 90 days.
     *
     * @return array<int, array{space: float, boxes: int}>
     */
    public static function truckPast(array $truckIds): array
    {
        if (! $truckIds) {
            return [];
        }
        $trips = Deliverylog::whereIn('truck_id', $truckIds)->where('created_at', '>=', now()->subDays(90))->pluck('truck_id', 'id');
        if ($trips->isEmpty()) {
            return [];
        }
        $rows = Tripinvoice::query()->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
            ->whereIn('tripinvoices.deliverylog_id', $trips->keys())
            ->select('tripinvoices.deliverylog_id', 'invoices.boxtype', DB::raw('count(*) as n'))
            ->groupBy('tripinvoices.deliverylog_id', 'invoices.boxtype')->get();
        $perTrip = [];
        foreach ($rows as $r) {
            $t = $r->deliverylog_id;
            $perTrip[$t]['space'] = ($perTrip[$t]['space'] ?? 0) + static::spaceOf($r->boxtype) * $r->n;
            $perTrip[$t]['boxes'] = ($perTrip[$t]['boxes'] ?? 0) + $r->n;
        }
        $out = [];
        foreach ($perTrip as $tripId => $v) {
            $truck = $trips[$tripId];
            if (! isset($out[$truck]) || $v['space'] > $out[$truck]['space']) {
                $out[$truck] = ['space' => static::half($v['space']), 'boxes' => $v['boxes']];
            }
        }

        return $out;
    }
}
