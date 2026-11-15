<?php

namespace App\Filament\Shared\Ai;

use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Throwable;

/** AI trip helper: a draft of trips from the ready boxes and free trucks; nothing is created until you press Create. */
abstract class TripsPage extends AiPage
{
    protected string $view = 'filament.ai.trips';

    protected static string $feature = 'trips';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedTruck;

    protected static ?string $navigationLabel = 'AI trip helper';

    protected static ?string $title = 'AI trip helper';

    protected static ?string $slug = 'ai-trips';

    protected static ?int $navigationSort = 0;

    public string $mode = '';

    public string $date = '';

    public string $instruction = '';

    /** @var list<array{truck_id: int, dest: ?int, why: string, places: list<array{place: string, units: list<string>}>}> */
    public array $trips = [];

    public string $note = '';

    public bool $usedAi = false;

    public bool $drafted = false;

    public array $created = [];

    public ?string $error = null;

    protected ?Collection $unitCache = null;

    public static function canAccess(): bool
    {
        return parent::canAccess() && TripPlanner::modesFor(Auth::user()) !== [];
    }

    public function getSubheading(): ?string
    {
        return 'The AI drafts trips from the boxes waiting for a trip and your free trucks. Nothing is created until you press Create.';
    }

    public function mount(): void
    {
        $this->mode = TripPlanner::modesFor(Auth::user())[0];
        $this->date = now()->addDay()->toDateString();
    }

    protected function planner(): TripPlanner
    {
        $modes = TripPlanner::modesFor(Auth::user());
        if (! in_array($this->mode, $modes, true)) {
            $this->mode = $modes[0];
        }

        return new TripPlanner(Auth::user(), $this->mode);
    }

    protected function units(): Collection
    {
        return $this->unitCache ??= $this->planner()->units();
    }

    public function setMode(string $mode): void
    {
        if (in_array($mode, TripPlanner::modesFor(Auth::user()), true)) {
            $this->mode = $mode;
            $this->startOver();
        }
    }

    public function suggest(): void
    {
        $this->error = null;
        $this->created = [];
        $out = $this->planner()->suggest(trim($this->instruction));
        $this->trips = array_map(fn ($t) => ['truck_id' => $t['truck_id'], 'dest' => $t['dest'], 'why' => $t['why'], 'places' => $t['places']], $out['trips']);
        $this->note = $out['note'];
        $this->usedAi = $out['ai'];
        $this->drafted = true;
    }

    /** Move a whole barangay (all its receivers) to the next trip. */
    public function movePlace(int $trip, int $place): void
    {
        if (count($this->trips) < 2 || ! isset($this->trips[$trip]['places'][$place])) {
            return;
        }
        $to = ($trip + 1) % count($this->trips);
        $moving = $this->trips[$trip]['places'][$place];
        array_splice($this->trips[$trip]['places'], $place, 1);
        $slot = collect($this->trips[$to]['places'])->search(fn ($p) => $p['place'] === $moving['place']);
        if ($slot === false) {
            $this->trips[$to]['places'][] = $moving;
        } else {
            $this->trips[$to]['places'][$slot]['units'] = array_values(array_unique(array_merge($this->trips[$to]['places'][$slot]['units'], $moving['units'])));
        }
        $this->trips = array_values(array_filter($this->trips, fn ($t) => $t['places']));
    }

    /** Put a waiting barangay onto a trip. */
    public function addPlace(string $place, int $trip): void
    {
        if (! isset($this->trips[$trip])) {
            return;
        }
        $used = collect($this->trips)->flatMap(fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units']))->flip();
        $keys = $this->units()->filter(fn ($u) => TripPlanner::placeKey($u) === $place && ! isset($used[$u['key']]))->pluck('key')->values()->all();
        if ($keys) {
            $this->trips[$trip]['places'][] = ['place' => $place, 'units' => $keys];
        }
    }

    public function removeTrip(int $trip): void
    {
        unset($this->trips[$trip]);
        $this->trips = array_values($this->trips);
    }

    public function setTruck(int $trip, $truckId): void
    {
        $truckId = (int) $truckId;
        if (! isset($this->trips[$trip]) || ! $this->planner()->trucks()->contains('id', $truckId)) {
            return;
        }
        // swap with the trip that had this truck
        foreach ($this->trips as $i => $t) {
            if ($i !== $trip && $t['truck_id'] === $truckId) {
                $this->trips[$i]['truck_id'] = $this->trips[$trip]['truck_id'];
            }
        }
        $this->trips[$trip]['truck_id'] = $truckId;
    }

    public function setDest(int $trip, $dest): void
    {
        if (isset($this->trips[$trip]) && $this->planner()->destinations()->contains('id', (int) $dest)) {
            $this->trips[$trip]['dest'] = (int) $dest;
        }
    }

    public function startOver(): void
    {
        $this->trips = [];
        $this->note = '';
        $this->drafted = false;
        $this->created = [];
        $this->error = null;
    }

    public function create(): void
    {
        $this->error = null;
        $view = $this->tripsView();
        if ($view->isEmpty()) {
            return;
        }
        if ($over = $view->first(fn ($t) => $t['over'])) {
            $this->error = BoxSizes::on()
                ? "{$over['title']} needs more space than truck {$over['truck']} has (".BoxSizes::fmt($over['space'])." of {$over['capacity']}). Move a barangay to another trip first."
                : "{$over['title']} has more boxes than truck {$over['truck']} can carry. Move a barangay to another trip first.";

            return;
        }
        try {
            $date = Carbon::parse($this->date);
        } catch (Throwable) {
            $this->error = 'Pick the trip date.';

            return;
        }
        try {
            $this->created = $this->planner()->create($this->trips, $date);
        } catch (Throwable $e) {
            report($e);
            $this->error = $e instanceof \DomainException ? $e->getMessage() : 'The trips could not be created: '.$e->getMessage();

            return;
        }
        $this->trips = [];
        $this->drafted = false;
        Notification::make()->title(count($this->created).' '.str('trip')->plural(count($this->created)).' created')->success()->send();
    }

    /** The draft with counts, for the screen. */
    protected function tripsView(): Collection
    {
        $units = $this->units()->keyBy('key');
        $trucks = $this->planner()->trucks()->keyBy('id');
        $word = $this->mode === 'transfer' ? 'Transfer' : 'Trip';

        return collect($this->trips)->map(function ($t, $i) use ($units, $trucks, $word) {
            $places = collect($t['places'])->map(function ($p) use ($units) {
                $us = collect($p['units'])->map(fn ($k) => $units[$k] ?? null)->filter();

                return [
                    'place' => $p['place'], 'barangay' => Str::afterLast($p['place'], ' › '),
                    'city' => Str::of($p['place'])->beforeLast(' › ')->afterLast(' › ')->toString(),
                    'n' => $us->sum('n'), 'space' => $us->sum('space'), 'receivers' => $us->count(), 'big' => $us->sortByDesc('n')->first(),
                ];
            })->filter(fn ($p) => $p['n'] > 0)->values();
            $all = collect($t['places'])->flatMap(fn ($p) => $p['units'])->map(fn ($k) => $units[$k] ?? null)->filter();
            $truck = $trucks[$t['truck_id']] ?? null;
            $n = $all->sum('n');
            $space = BoxSizes::half($all->sum('space'));
            $cap = $truck['capacity'] ?? 0;
            $mix = [];
            foreach ($all as $u) {
                foreach ($u['mix'] ?? [] as $name => $c) {
                    $mix[$name] = ($mix[$name] ?? 0) + $c;
                }
            }
            arsort($mix);

            return [
                'i' => $i, 'title' => $word.' '.($i + 1), 'truck_id' => $t['truck_id'], 'truck' => $truck['plate'] ?? '—', 'capacitySet' => $truck['set'] ?? false,
                'capacity' => $cap, 'boxes' => $n, 'space' => $space, 'mix' => BoxSizes::mixText($mix),
                'pct' => $cap ? min(100, (int) round($space / $cap * 100)) : 0, 'over' => $cap && $space > $cap,
                'prio' => $all->sum('prio'), 'retry' => $all->sum('retry'), 'dest' => $t['dest'], 'why' => $t['why'], 'places' => $places,
            ];
        })->filter(fn ($t) => $t['boxes'] > 0)->values();
    }

    protected function getViewData(): array
    {
        $planner = $this->planner();
        $units = $this->units();
        $used = collect($this->trips)->flatMap(fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units']))->flip();
        $waiting = $units->reject(fn ($u) => isset($used[$u['key']]));

        $tree = $units->groupBy('province')->sortKeys()->map(fn ($p, $prov) => [
            'name' => $prov, 'n' => $p->sum('n'),
            'cities' => $p->groupBy('city')->sortKeys()->map(fn ($c, $city) => [
                'name' => $city, 'n' => $c->sum('n'),
                'brgys' => $c->groupBy('barangay')->sortKeys()->map(fn ($b, $brgy) => $brgy.' '.$b->sum('n'))->join(' · '),
            ])->values(),
        ])->values();

        return [
            'paused' => $this->pausedReason(),
            'modes' => collect(TripPlanner::modesFor(Auth::user()))->mapWithKeys(fn ($m) => [$m => TripPlanner::MODES[$m]]),
            'tree' => $tree,
            'ready' => $units->sum('n'),
            'prio' => $units->sum('prio'),
            'retry' => $units->sum('retry'),
            'bigGroups' => $units->where('n', '>=', 5)->count(),
            'tripsView' => $this->tripsView(),
            'trucks' => $planner->trucks(),
            'dests' => $planner->destinations(),
            'waitingPlaces' => $waiting->groupBy(fn ($u) => TripPlanner::placeKey($u))->map(fn ($g, $k) => ['place' => $k, 'n' => $g->sum('n'), 'prio' => $g->sum('prio') + $g->sum('retry')])->sortByDesc('prio')->values(),
            'word' => $this->mode === 'transfer' ? 'transfer' : 'trip',
            'bySpace' => BoxSizes::on(),
            'readySpace' => BoxSizes::half($units->sum('space')),
        ];
    }
}
