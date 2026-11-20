<?php

namespace App\Filament\Shared\Trips;

use App\Support\BoxSizes;
use App\Support\Tracking\Tracker;
use App\Support\Trips\CityTrips;
use App\Support\Trips\TripFill;
use App\Support\Trips\TripRules;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;

/**
 * New boxes since the trips were made (board 45b): boxes of cities that already have a trip.
 * Space left → add (combos first, never split); full → new trip or Add anyway; locked or left → new trip.
 */
class NewBoxesPage extends Page
{
    protected string $view = 'filament.trips.new-boxes';

    protected static ?string $slug = 'new-boxes';

    protected static ?string $title = 'New boxes';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-inbox-arrow-down';

    /** Picker: city key, trip id, chosen combo keys, Add anyway reason. */
    public ?string $pickCity = null;

    public ?int $pickTrip = null;

    /** @var array<string, bool> */
    public array $sel = [];

    public string $reason = '';

    public static function canAccess(): bool
    {
        $u = Auth::user();

        return CityTrips::ready() && $u?->logistichub_id && Tracker::hubFor($u, Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    /** Rows once per request. */
    protected ?array $rowsMemo = null;

    public function rows(): array
    {
        return $this->rowsMemo ??= TripFill::newBoxes(Auth::user());
    }

    protected function fresh(): void
    {
        $this->rowsMemo = null;
        Cache::forget('menu:'.Filament::getCurrentPanel()?->getId().':'.Auth::id().':newBoxes');
    }

    public function openPick(string $city, ?bool $anyway = false): void
    {
        $row = collect($this->rows())->firstWhere('key', $city);
        if (! $row || empty($row['trip']) || ! empty($row['trip']['locked'])) {
            return;
        }
        $this->pickCity = $city;
        $this->pickTrip = (int) $row['trip']['id'];
        $this->reason = '';
        // space left: what fits is picked (combos first); full: nothing picked
        $this->sel = $anyway ? [] : collect($row['fit'])->mapWithKeys(fn ($k) => [$k => true])->all();
    }

    public function toggle(string $key): void
    {
        $this->sel[$key] = empty($this->sel[$key]);
    }

    public function pickFit(): void
    {
        $row = collect($this->rows())->firstWhere('key', $this->pickCity);
        $this->sel = $row ? collect($row['fit'])->mapWithKeys(fn ($k) => [$k => true])->all() : [];
    }

    public function pickNone(): void
    {
        $this->sel = [];
    }

    public function closePick(): void
    {
        $this->pickCity = null;
        $this->pickTrip = null;
        $this->sel = [];
    }

    public function confirmPick(): void
    {
        if (! $this->pickCity || ! $this->pickTrip) {
            return;
        }
        $keys = array_keys(array_filter($this->sel));
        $p = $this->picker();
        $res = TripFill::addPicked(Auth::user(), $this->pickCity, $this->pickTrip, $keys, (bool) ($p['over'] ?? false), $this->reason);
        Notification::make()->title($res['msg'])->{$res['ok'] ? 'success' : 'warning'}()->send();
        if ($res['ok']) {
            $this->closePick();
            $this->fresh();
        }
    }

    public function newTrip(string $city): void
    {
        $made = TripFill::newTrips(Auth::user(), [$city]);
        $this->fresh();
        Notification::make()->title($made ? 'New trip '.collect($made)->pluck('number')->join(', ').' made with these boxes · ✦ AI' : 'No boxes to put on a new trip.')
            ->{$made ? 'success' : 'warning'}()->send();
    }

    public function applyAll(): void
    {
        $res = TripFill::applyAll(Auth::user());
        $this->fresh();
        $msg = $res['added'].' '.Str::plural('box', $res['added']).' added to trips with room'
            .($res['made'] ? ' · new '.Str::plural('trip', count($res['made'])).' '.collect($res['made'])->pluck('number')->join(', ') : '').'. No combo was split.';
        Notification::make()->title($msg)->success()->send();
    }

    /** The open picker: rows, space, over. */
    public function picker(): ?array
    {
        if (! $this->pickCity) {
            return null;
        }
        $row = collect($this->rows())->firstWhere('key', $this->pickCity);
        if (! $row || empty($row['trip'])) {
            return null;
        }
        $t = $row['trip'];
        $chosen = collect($row['combos'])->filter(fn ($c) => ! empty($this->sel[$c['key']]));
        $space = (float) $chosen->sum('space');
        $n = (int) $chosen->sum('n');
        $over = max(0, $t['used'] + $space - $t['cap']);

        return ['row' => $row, 'trip' => $t, 'n' => $n, 'space' => $space, 'over' => $over > 0.001, 'overBy' => $over,
            // the bar grows past the truck space when over, so the part over shows in amber
            'usedPct' => round($t['used'] / max(1, $t['cap'], $t['used'] + $space) * 100), 'newPct' => round($space / max(1, $t['cap'], $t['used'] + $space) * 100),
            'reasons' => TripRules::ready() ? TripRules::reasons() : ['It still fits (small box)', 'Other']];
    }

    protected function getViewData(): array
    {
        $rows = $this->rows();
        $plan = collect(Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => is_subclass_of($p, PlanTripsPage::class));

        return ['rows' => $rows, 'total' => (int) collect($rows)->sum('n'),
            'toAdd' => (int) collect($rows)->where('kind', 'open')->sum(fn ($r) => $r['n'] - $r['newN']),
            'toNew' => (int) collect($rows)->sum(fn ($r) => $r['kind'] === 'open' ? $r['newN'] : $r['n']),
            'p' => $this->picker(), 'planUrl' => $plan ? $plan::getUrl() : null, 'fmt' => fn ($v) => BoxSizes::fmt((float) $v)];
    }
}
