<?php

namespace App\Support\Help;

use App\Models\Help\HelpGuide;

/**
 * What the Help Center page and the "?" help panel share: language, search,
 * "Ask in your own words", opening a guide and "Was this helpful?".
 */
trait HelpUi
{
    public string $lang = 'en';

    public string $q = '';

    /** @var array{answer: string, guide: ?string, ai: bool, q: string}|null */
    public ?array $answer = null;

    // The using class declares: public ?string $g (the open guide's slug).

    abstract protected function helpApp(): string;

    protected function bootHelpLang(): void
    {
        $this->lang = Help::lang();
    }

    public function setLang(string $lang): void
    {
        $this->lang = Help::lang($lang);
        session(['help.lang' => $this->lang]);
        if ($this->answer) {
            $this->ask();
        }
    }

    public function updatedQ(): void
    {
        $this->answer = null;
    }

    public function ask(?string $text = null): void
    {
        if ($text !== null) {
            $this->q = $text;
        }
        $q = trim($this->q);
        if ($q === '') {
            $this->answer = null;

            return;
        }
        $this->answer = Help::ask($q, $this->helpApp(), $this->lang) + ['q' => $q];
    }

    public function clearSearch(): void
    {
        $this->q = '';
        $this->answer = null;
    }

    public function openGuide(?string $slug): void
    {
        $this->g = $slug && Help::find($this->helpApp(), $slug) ? $slug : null;
        if ($guide = $this->guide()) {
            Help::seen($guide);
        }
    }

    public function vote(bool $yes): void
    {
        if ($guide = $this->guide()) {
            Help::vote($guide, $yes);
        }
    }

    public function guide(): ?HelpGuide
    {
        return Help::find($this->helpApp(), $this->g);
    }

    /** Everything the help views need. */
    protected function helpData(): array
    {
        $app = $this->helpApp();
        $guide = $this->guide();
        $tl = $this->lang === 'tl';

        return [
            'app' => $app,
            'lang' => $this->lang,
            'guide' => $guide,
            'topics' => Help::topics($app, $this->lang),
            'results' => trim($this->q) !== '' ? Help::search($this->q, $app) : collect(),
            'aiOn' => Help::aiOn(),
            'related' => $guide ? collect($guide->related ?? [])->map(fn ($s) => Help::find($app, $s))->filter()->values() : collect(),
            'doIt' => $guide ? Help::linkUrl($guide, $app) : null,
            'voted' => $guide ? Help::voted($guide) : null,
            'answerGuide' => $this->answer && $this->answer['guide'] ? Help::find($app, $this->answer['guide']) : null,
            'tries' => $tl ? static::TRIES_TL[$app] ?? [] : static::TRIES_EN[$app] ?? [],
            'w' => HelpWords::get($tl),
        ];
    }

    public const TRIES_EN = [
        'admin' => ['return a box not delivered', 'why is a box not in inventory', 'print loading list', 'send SMS to receivers'],
        'warehouse' => ['unload a container', 'why is a box not in inventory', 'move boxes to another warehouse', 'print loading list'],
        'company' => ['make my own trip', 'box not delivered what to do', 'where is the truck', 'return a box'],
        'scan' => ['box not on the list', 'too early when loading', 'camera does not open'],
        'driver' => ['pressed deliver by mistake', 'no one home', 'no signal', 'open waze'],
    ];

    public const TRIES_TL = [
        'admin' => ['paano mag-return ng box', 'bakit wala sa inventory ang box', 'print loading list', 'magpadala ng text sa receiver'],
        'warehouse' => ['paano mag-unload ng container', 'bakit wala sa inventory ang box', 'ilipat sa ibang bodega', 'print loading list'],
        'company' => ['gumawa ng sariling trip', 'hindi na-deliver ano gagawin', 'nasaan ang truck', 'ibalik ang box'],
        'scan' => ['wala sa listahan ang box', 'masyadong maaga sa load', 'ayaw bumukas ng camera'],
        'driver' => ['napindot ang deliver nang mali', 'walang tao sa bahay', 'walang signal', 'buksan ang waze'],
    ];
}
