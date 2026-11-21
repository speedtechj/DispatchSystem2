<?php

namespace App\Support\Help;

use App\Models\Help\HelpGuide;
use App\Support\Ai\Ai;
use Filament\Facades\Filament;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * The Help guide: guides for each app, search in English and Tagalog, the guide for the page
 * you are on, and "Ask in your own words" (AI that answers only from the guides).
 */
class Help
{
    /** Filament panel id => help app */
    public const APPS = ['admin' => 'admin', 'warehouse' => 'warehouse', 'company' => 'company', 'scan' => 'scan', 'delivery' => 'driver'];

    public const APP_NAMES = ['admin' => 'Admin', 'warehouse' => 'Warehouse', 'company' => 'Partner hub', 'scan' => 'Scan app', 'driver' => 'Driver app'];

    /** Words that say nothing about what you need. */
    protected const STOP = ['the', 'a', 'an', 'to', 'of', 'is', 'it', 'in', 'on', 'how', 'do', 'i', 'my', 'what', 'why', 'can', 'and', 'or', 'for', 'when', 'where', 'not', 'be', 'are', 'with', 'this', 'that', 'me',
        'ang', 'ng', 'sa', 'na', 'mga', 'ba', 'po', 'paano', 'bakit', 'ano', 'saan', 'kung', 'ko', 'ako', 'yung', 'yong', 'lang', 'naman', 'pa', 'ay', 'at', 'si', 'mag', 'para', 'kapag', 'pag', 'hindi', 'wala', 'walang', 'nang', 'yan', 'ito', 'iyon', 'ni', 'kay'];

    /** Taglish words people type => words in the guides. */
    protected const ALSO = [
        'ibalik' => 'return', 'bumalik' => 'return', 'balik' => 'return', 'sira' => 'damaged', 'basa' => 'wet', 'hanapin' => 'find', 'nawawala' => 'missing',
        'nasaan' => 'where', 'bilang' => 'inventory', 'bodega' => 'warehouse', 'kargahan' => 'load', 'karga' => 'load', 'baba' => 'unload', 'ibaba' => 'unload',
        'text' => 'sms', 'texts' => 'sms', 'mapa' => 'map', 'daan' => 'navigate', 'signal' => 'signal', 'litrato' => 'photo', 'picture' => 'photo', 'pic' => 'photo',
        'deliver' => 'deliver', 'delivered' => 'deliver', 'delivery' => 'deliver', 'undo' => 'undo', 'mali' => 'undo', 'trak' => 'truck', 'print' => 'print',
    ];

    protected static array $memo = [];

    protected static ?bool $ready = null;

    /** The help table is there (the migration has run). */
    public static function ready(): bool
    {
        return static::$ready ??= Schema::hasTable('help_guides');
    }

    public static function forget(): void
    {
        static::$memo = [];
        static::$ready = null;
        Cache::forget('help.version');
    }

    /** Copy the built-in guides into the table (only the ones not there yet). */
    public static function installDefaults(): int
    {
        if (! Schema::hasTable('help_guides')) {
            return 0;
        }
        $have = HelpGuide::pluck('slug')->all();
        $added = 0;
        foreach (DefaultGuides::all() as $g) {
            if (in_array($g['slug'], $have, true)) {
                continue;
            }
            HelpGuide::create($g + ['is_published' => true]);
            $added++;
        }
        static::forget();

        return $added;
    }

    /** The help app for the panel you are in. */
    public static function currentApp(): string
    {
        $id = Filament::getCurrentPanel()?->getId();

        return static::APPS[$id] ?? 'admin';
    }

    public static function lang(?string $lang = null): string
    {
        $lang ??= session('help.lang', 'en');

        return $lang === 'tl' ? 'tl' : 'en';
    }

    /** @return Collection<int, HelpGuide> */
    public static function guides(string $app): Collection
    {
        if (! static::ready()) {
            return collect();
        }

        return static::$memo[$app] ??= HelpGuide::query()->for($app)->orderBy('sort')->orderBy('id')->get();
    }

    public static function find(string $app, ?string $slug): ?HelpGuide
    {
        return $slug ? static::guides($app)->firstWhere('slug', $slug) : null;
    }

    /** Topics with their guides, in order. @return list<array{key: string, icon: string, name: string, guides: Collection}> */
    public static function topics(string $app, string $lang): array
    {
        $guides = static::guides($app)->groupBy('topic');
        $out = [];
        foreach (DefaultGuides::TOPICS as $key => [$icon, $en, $tl]) {
            if ($guides->has($key)) {
                $out[] = ['key' => $key, 'icon' => $icon, 'name' => $lang === 'tl' ? $tl : $en, 'guides' => $guides[$key]];
            }
        }
        foreach ($guides as $key => $list) {
            if (! isset(DefaultGuides::TOPICS[$key])) {
                $out[] = ['key' => $key, 'icon' => '📘', 'name' => Str::headline($key), 'guides' => $list];
            }
        }

        return $out;
    }

    /** The guides for the page you are on (route names without the panel part). @return Collection<int, HelpGuide> */
    public static function forRoute(?string $routeName, string $app): Collection
    {
        if (! $routeName) {
            return collect();
        }
        $rest = preg_replace('/^filament\.[^.]+\./', '', $routeName);

        return static::guides($app)->filter(fn (HelpGuide $g) => collect($g->pages ?? [])->contains(fn ($p) => $p && Str::is($p, $rest)))->values();
    }

    /** @return list<string> */
    public static function words(string $text): array
    {
        $text = Str::lower(Str::ascii($text));
        $words = preg_split('/[^a-z0-9]+/', $text, -1, PREG_SPLIT_NO_EMPTY) ?: [];
        $out = [];
        foreach ($words as $w) {
            if (strlen($w) < 2 || in_array($w, static::STOP, true)) {
                continue;
            }
            $out[] = $w;
            if (isset(static::ALSO[$w])) {
                $out[] = static::ALSO[$w];
            }
        }

        return array_values(array_unique($out));
    }

    /** Guides that match the words, best first. @return Collection<int, HelpGuide> */
    public static function search(string $q, string $app, int $limit = 8): Collection
    {
        $words = static::words($q);
        if (! $words) {
            return collect();
        }

        $guides = static::guides($app);
        // Each guide's words by place; rare words (in few guides) count more than common ones like "box".
        $docs = $guides->map(fn (HelpGuide $g) => [
            'g' => $g,
            'title' => static::words($g->title_en.' '.$g->title_tl.' '.str_replace('-', ' ', $g->slug)),
            'sum' => static::words($g->summary_en.' '.$g->summary_tl.' '.$g->when_en.' '.$g->when_tl),
            'steps' => static::words(collect($g->steps ?? [])->map(fn ($s) => ($s['title_en'] ?? '').' '.($s['title_tl'] ?? ''))->join(' ')),
            'body' => static::words(collect($g->steps ?? [])->map(fn ($s) => ($s['text_en'] ?? '').' '.($s['text_tl'] ?? ''))->join(' ')
                .' '.collect($g->problems ?? [])->map(fn ($p) => implode(' ', array_filter([$p['q_en'] ?? '', $p['q_tl'] ?? '', $p['a_en'] ?? '', $p['a_tl'] ?? ''])))->join(' ')
                .' '.$g->result_en.' '.$g->result_tl),
        ]);
        $n = max(1, $docs->count());
        $weight = [];
        foreach ($words as $w) {
            $df = $docs->filter(fn ($d) => static::hit($w, array_merge($d['title'], $d['sum'], $d['steps'], $d['body'])) > 0)->count();
            $weight[$w] = $df ? log(1 + $n / $df) : 0;
        }

        return $docs
            ->map(function ($d) use ($words, $weight) {
                $score = 0;
                foreach ($words as $w) {
                    $score += $weight[$w] * (static::hit($w, $d['title']) * 6 + static::hit($w, $d['sum']) * 3 + static::hit($w, $d['steps']) * 2 + static::hit($w, $d['body']));
                }

                return [$d['g'], $score];
            })
            ->filter(fn ($r) => $r[1] > 0)
            ->pipe(function ($rows) {
                $top = $rows->max(fn ($r) => $r[1]) ?: 0;

                return $rows->filter(fn ($r) => $r[1] >= $top * 0.35); // drop weak matches
            })
            ->sortByDesc(fn ($r) => $r[1] * 1000 - $r[0]->sort)
            ->take($limit)
            ->map(fn ($r) => $r[0])
            ->values();
    }

    /** 1 for the same word, 0.6 when one starts with the other (return / returned). */
    protected static function hit(string $w, array $list): float
    {
        if (in_array($w, $list, true)) {
            return 1;
        }
        if (strlen($w) >= 4) {
            foreach ($list as $x) {
                if (strlen($x) >= 4 && (str_starts_with($x, $w) || str_starts_with($w, $x))) {
                    return 0.6;
                }
            }
        }

        return 0;
    }

    public static function aiOn(): bool
    {
        try {
            return Ai::enabled('help_ask');
        } catch (\Throwable) {
            return false;
        }
    }

    /**
     * Ask in your own words. The AI answers only from this app's guides and names the guide to open.
     * Without AI (off, or it failed) the best search match is used.
     *
     * @return array{answer: string, guide: ?string, ai: bool}
     */
    public static function ask(string $q, string $app, string $lang): array
    {
        $q = trim(Str::limit($q, 300, ''));
        $best = static::search($q, $app, 1)->first();
        $fallback = [
            'answer' => $best ? $best->t('summary', $lang) : ($lang === 'tl' ? 'Walang gabay na tugma. Subukan ang ibang salita, o magtanong sa office.' : 'No guide matches. Try other words, or ask the office.'),
            'guide' => $best?->slug, 'ai' => false,
        ];
        if ($q === '' || ! static::aiOn()) {
            return $fallback;
        }

        $key = 'help.ask.'.md5($app.'|'.$lang.'|'.Str::lower($q).'|'.static::version());

        return Cache::remember($key, now()->addDay(), function () use ($q, $app, $lang, $fallback) {
            $guides = static::guides($app)->map(fn (HelpGuide $g) => [
                'slug' => $g->slug,
                'title' => $g->t('title', $lang),
                'summary' => $g->t('summary', $lang),
                'when' => $g->t('when', $lang),
                'steps' => collect($g->stepsIn($lang))->map(fn ($s, $i) => ($i + 1).'. '.$s['title'].': '.$s['text'])->all(),
                'result' => $g->t('result', $lang),
                'problems' => collect($g->problemsIn($lang))->map(fn ($p) => $p['q'].' → '.$p['a'])->all(),
            ])->values()->all();

            $system = 'You are the help desk inside a cargo delivery system (boxes from containers, trucks, trips, drivers) used in the Philippines. '
                .'Answer ONLY from the guides you are given. Do not invent pages, buttons or rules. '
                .'If the guides do not answer the question, say so in one sentence and suggest asking the office; then guide is null. '
                .'Answer in the language of the question: English, Tagalog or Taglish. Use plain words and at most 3 short sentences. Name the page or button to press. '
                .'Return {"answer": string, "guide": the slug of the one guide to open, or null}.';
            try {
                $out = Ai::json('help_ask', $system, 'App: '.(static::APP_NAMES[$app] ?? $app)."\n\nGuides:\n".json_encode($guides, JSON_UNESCAPED_UNICODE)."\n\nQuestion: ".$q, 'fast', 400);
            } catch (\Throwable $e) {
                return $fallback;
            }
            $answer = trim((string) ($out['answer'] ?? ''));
            if ($answer === '') {
                return $fallback;
            }
            $slug = $out['guide'] ?? null;
            $slug = is_string($slug) && static::find($app, $slug) ? $slug : null;

            return ['answer' => Str::limit($answer, 600), 'guide' => $slug, 'ai' => true];
        });
    }

    /** Changes when any guide is saved, so old AI answers are not reused. */
    protected static function version(): string
    {
        return Cache::rememberForever('help.version', fn () => (string) (HelpGuide::max('updated_at') ?? '0').'-'.HelpGuide::count());
    }

    /** "Was this helpful?" once per guide per sign-in. */
    public static function vote(HelpGuide $guide, bool $yes): bool
    {
        $key = 'help.voted.'.$guide->id;
        if (session()->has($key)) {
            return false;
        }
        session()->put($key, $yes);
        HelpGuide::whereKey($guide->id)->increment($yes ? 'helpful_yes' : 'helpful_no');

        return true;
    }

    public static function voted(HelpGuide $guide): ?bool
    {
        return session('help.voted.'.$guide->id);
    }

    public static function seen(HelpGuide $guide): void
    {
        $key = 'help.seen.'.$guide->id;
        if (! session()->has($key)) {
            session()->put($key, true);
            HelpGuide::whereKey($guide->id)->increment('views');
        }
    }

    /** "Do it now": the page for this guide in this app, if there is one. */
    public static function linkUrl(HelpGuide $guide, string $app): ?string
    {
        $rest = ($guide->links ?? [])[$app] ?? null;
        $panel = array_search($app, static::APPS, true);
        if (! $rest || ! $panel) {
            return null;
        }
        $name = "filament.{$panel}.{$rest}";
        if (! Route::has($name)) {
            return null;
        }
        try {
            return route($name);
        } catch (\Throwable) {
            return null;
        }
    }

    /** The Help Center page in this app (admin, warehouse, company). */
    public static function centerUrl(string $app, ?string $slug = null): ?string
    {
        $panel = array_search($app, static::APPS, true);
        $name = "filament.{$panel}.pages.help";

        return Route::has($name) ? route($name, $slug ? ['g' => $slug] : []) : null;
    }

    /** The guide to open for a Scan app mode. */
    public static function forScanMode(?string $mode): string
    {
        return match ($mode) {
            'unload' => 'unload-container',
            'load', 'hub_load' => 'load-truck',
            'return' => 'return-boxes',
            'wh_load', 'wh_unload' => 'warehouse-transfer',
            'port', 'ship_receive' => 'sea-shipments',
            'count' => 'section-count',
            'pick' => 'pick-boxes',
            'ret_receive' => 'return-shipments',
            default => 'scan-tips',
        };
    }
}
