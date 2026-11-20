<?php

namespace App\Filament\Shared\Ai;

use App\Support\Aging\AgingAdvice;
use App\Support\Aging\BoxAging;
use App\Support\Ai\AiScope;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Livewire\Attributes\Url;

/** Box aging: how long boxes have waited since unload, at each stage; which are late and why. */
abstract class AgingPage extends AiPage
{
    protected string $view = 'filament.ai.aging';

    protected static string $feature = 'aging';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedClock;

    protected static ?string $navigationLabel = 'Box aging';

    protected static ?string $title = 'Box aging';

    protected static ?string $slug = 'box-aging';

    protected static ?int $navigationSort = -1;

    #[Url]
    public string $stage = '';

    #[Url]
    public int $bucket = -1;

    #[Url]
    public string $show = '';

    public string $by = 'place';

    public bool $freshAdvice = false;

    public function getSubheading(): ?string
    {
        return 'How long each box has waited since it was unloaded, at each stage.';
    }

    public static function getNavigationBadge(): ?string
    {
        // never counts here (that would slow every page); shows the number from the last count
        [$hub, $wh] = static::scope();
        $n = BoxAging::lateCountCached($hub, $wh);

        return $n ? (string) $n : null;
    }

    public static function getNavigationBadgeColor(): ?string
    {
        return 'danger';
    }

    /** @return array{0: ?int, 1: ?int} [hub, warehouse] for this person in this panel */
    protected static function scope(): array
    {
        $user = Auth::user();
        $hub = AiScope::hubId($user) ?: null;
        $wh = Filament::getCurrentPanel()?->getId() === 'warehouse' ? ($user->warehouse_id ?: null) : null;

        return [$hub, $hub ? null : $wh];
    }

    protected static function rowsFor(bool $fresh = false): Collection
    {
        [$hub, $wh] = static::scope();

        return BoxAging::rows($hub, $wh, $fresh);
    }

    public function pick(string $stage, int $bucket): void
    {
        $this->stage = $stage;
        $this->bucket = $bucket;
        $this->show = '';
    }

    public function showOnly(string $what): void
    {
        $this->show = $what;
        $this->stage = '';
        $this->bucket = -1;
    }

    public function refresh(): void
    {
        static::rowsFor(true);
    }

    public function askAi(): void
    {
        $this->freshAdvice = true;
    }

    protected function getViewData(): array
    {
        $rows = static::rowsFor();
        [$hub, $wh] = static::scope();
        $advice = AgingAdvice::for($rows, ($hub ?? 'x').'.'.($wh ?? 'x'), $this->freshAdvice, call: $this->freshAdvice);
        $this->freshAdvice = false;

        $table = collect(BoxAging::STAGES)->map(function ($label, $key) use ($rows) {
            $r = $rows->where('stage', $key);
            $lim = BoxAging::limitFor($key, 'all');

            return [
                'key' => $key, 'label' => $label, 'warn' => $lim[0], 'late' => $lim[1], 'lateN' => $r->where('stageStatus', 'late')->count(),
                'cells' => collect(BoxAging::BUCKETS)->map(function ($b, $i) use ($r) {
                    $in = $r->filter(fn ($x) => $x['days'] >= $b[0] && $x['days'] <= $b[1]);

                    return ['i' => $i, 'n' => $in->count(), 'status' => $in->contains('stageStatus', 'late') ? 'late' : ($in->contains('stageStatus', 'warn') ? 'warn' : 'ok')];
                })->all(),
            ];
        })->values();

        $list = match (true) {
            $this->show === 'late' => $rows->where('status', 'late'),
            $this->show === 'tomorrow' => $rows->where('tomorrow', true),
            $this->stage !== '' && $this->bucket >= 0 => $rows->where('stage', $this->stage)
                ->filter(fn ($x) => $x['days'] >= BoxAging::BUCKETS[$this->bucket][0] && $x['days'] <= BoxAging::BUCKETS[$this->bucket][1]),
            default => $rows->where('status', 'late'),
        };
        $listTitle = match (true) {
            $this->show === 'tomorrow' => 'Will be late tomorrow',
            $this->stage !== '' && $this->bucket >= 0 => (BoxAging::STAGES[$this->stage] ?? '').' · '.BoxAging::BUCKETS[$this->bucket][2],
            default => 'Late boxes',
        };

        $groupKey = $this->by === 'consolidator' ? 'consolidator' : 'owner';
        $places = $rows->groupBy(fn ($r) => $groupKey === 'consolidator' ? ($r['consolidator'] ?: '—') : ($r['hub'] && in_array($r['stage'], ['hub', 'truck', 'failed'], true) ? $r['hub'] : 'Warehouse'))
            ->map(fn ($g, $name) => [
                'name' => $name, 'n' => $g->count(), 'late' => $g->where('status', 'late')->count(),
                'ok' => round($g->where('status', 'ok')->count() / max(1, $g->count()) * 100),
                'warn' => round($g->where('status', 'warn')->count() / max(1, $g->count()) * 100),
                'lateP' => round($g->where('status', 'late')->count() / max(1, $g->count()) * 100),
            ])->sortByDesc('late')->take(8)->values();

        return [
            'sum' => BoxAging::summary($rows),
            'advice' => $advice,
            'table' => $table,
            'list' => $list->sortByDesc('days')->take(25)->values(),
            'listCount' => $list->count(),
            'listTitle' => $listTitle,
            'places' => $places,
            'isHub' => (bool) $hub,
            'stageLabels' => BoxAging::STAGES,
            'tripsUrl' => Str::of(Filament::getCurrentPanel()?->getUrl() ?? url('/'))->rtrim('/').'/plan-trips',
        ];
    }
}
