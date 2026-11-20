<?php

namespace App\Filament\Shared\Trucks;

use App\Models\Deliverylog;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Support\Rentals;
use App\Support\Tracking\Tracker;
use App\Support\TripFlow;
use App\Support\TruckSpace;
use Filament\Facades\Filament;
use Filament\Pages\Page;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;

/** Trucks: one card per truck with its status, own or rental, crew, space and what needs a look. */
class FleetPage extends Page
{
    protected string $view = 'filament.trucks.fleet';

    protected static ?string $slug = 'fleet';

    protected static ?string $navigationLabel = 'Trucks';

    protected static ?string $title = 'Trucks';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-truck';

    public string $filter = 'all';

    public string $search = '';

    public const COLORS = ['#1d6fb8', '#17895e', '#7a4fb0', '#c97a00', '#b5446e', '#0f8a8a'];

    public static function canAccess(): bool
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    public function setFilter(string $f): void
    {
        $this->filter = in_array($f, ['all', 'trip', 'free', 'rental', 'off'], true) ? $f : 'all';
    }

    /** "Different trucks" from the duplicates card: stop asking about this group. */
    public function notDuplicates(string $ids): void
    {
        $trucks = Truck::whereIn('id', array_map('intval', explode(',', $ids)))->get()->filter(fn ($t) => Tracker::canSeeTruck($this->hub(), $t))->values();
        foreach ($trucks as $i => $a) {
            foreach ($trucks->slice($i + 1) as $b) {
                \App\Support\TruckDuplicates::markDifferent($a, $b, Auth::id());
            }
        }
        \Filament\Notifications\Notification::make()->title('Marked as different trucks')->success()->send();
    }

    /** The truck resource of this panel (for Add truck and Edit). */
    public static function truckResource(): ?string
    {
        return collect(Filament::getCurrentPanel()?->getResources() ?? [])->first(fn ($r) => $r::getModel() === Truck::class);
    }

    public static function profileUrl(Truck $t): ?string
    {
        if (static::class === self::class) {
            return null;
        }
        $page = str_replace('Fleet', 'TruckProfile', static::class);

        return class_exists($page) ? $page::getUrl(['truck' => $t->id]) : null;
    }

    /** Everything a card shows for one truck. */
    public static function card(Truck $t, $team): array
    {
        $rental = $t->isRental();
        $booked = $rental && Rentals::isBooked($t);
        $trip = $t->is_active ? TripFlow::runningOn($t->id) : null;
        $stage = $trip ? TripFlow::stage($trip) : null;
        $space = TruckSpace::usable($t);
        [$state, $tone] = match (true) {
            ! $t->is_active => ['Inactive', 'bad'],
            (bool) $trip => [$trip->trip_number.' · '.(TripFlow::STAGES[$stage][0] ?? ''), $stage],
            $rental && ! $booked => ['Not booked', 'muted'],
            $rental => ['Booked today', 'info'],
            default => ['Free', 'free'],
        };
        $load = 0;
        $loadLabel = $rental ? (Rentals::rateText($t) ?: 'Rental') : 'Empty';
        if ($trip) {
            $rows = TripFlow::boxes($trip);
            $total = (clone $rows)->count();
            if (in_array($stage, ['road', 'back'], true)) {
                $load = (clone $rows)->where('is_delivered', true)->count();
                $loadLabel = $load.' of '.$total.' delivered';
                $space = max($total, 1);
            } else {
                $load = (clone $rows)->where('is_loaded', true)->count();
                $loadLabel = $load ? 'Loading' : 'Planned';
            }
        }
        $expires = $t->date_expired;
        $note = match (true) {
            ! $t->is_active => ['Hidden from trips and the crew board', 'muted'],
            $expires && $expires->isPast() => ['Registration expired '.$expires->format('M j'), 'bad'],
            $expires && $expires->lte(today()->addDays(30)) => ['Registration expires in '.today()->diffInDays($expires).' days', 'warn'],
            $rental && ! $booked => [($n = Rentals::nextBooking($t)) ? 'Next booking '.$n->format('M j') : 'No booking yet', 'muted'],
            $team->isEmpty() => ['No crew on this truck', 'bad'],
            default => null,
        };

        return [
            'truck' => $t, 'rental' => $rental, 'state' => $state, 'tone' => $tone,
            'group' => ! $t->is_active ? 'off' : ($trip ? 'trip' : ($rental ? 'rental' : 'free')),
            'kind' => trim(($t->category ?: $t->description ?: 'Truck').' · '.($rental ? ($t->rentalCompany?->name ?? 'rental') : 'own')),
            'color' => static::COLORS[$t->id % count(static::COLORS)],
            'crew' => $team->map(fn ($c) => ['ini' => Str::upper(Str::substr((string) $c->member->first_name, 0, 1).Str::substr((string) $c->member->last_name, 0, 1)), 'name' => $c->member->full_name])->values()->all(),
            'load' => $load, 'space' => $space, 'loadLabel' => $loadLabel,
            'pct' => $space ? min(100, (int) round($load / $space * 100)) : 0,
            'note' => $note,
            'url' => static::profileUrl($t),
        ];
    }

    protected function getViewData(): array
    {
        $hub = $this->hub();
        $gone = \App\Support\TruckDuplicates::ready() ? \App\Models\TruckMerge::where('kind', 'merge')->whereNull('undone_at')->pluck('dropped_id')->all() : [];
        $trucks = Truck::with('rentalCompany')->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->whereNotIn('id', $gone)->orderByDesc('is_active')->orderBy('plate_no')->get();
        $teams = Truckcrew::with('member')->whereIn('truck_id', $trucks->modelKeys())->get()->filter(fn ($c) => $c->member)->groupBy('truck_id');
        $cards = $trucks->map(fn (Truck $t) => static::card($t, $teams[$t->id] ?? collect()));
        $counts = ['all' => $cards->count(), 'trip' => $cards->where('group', 'trip')->count(), 'free' => $cards->where('group', 'free')->count(),
            'rental' => $cards->where('rental', true)->count(), 'off' => $cards->where('group', 'off')->count()];
        $q = Str::lower(trim($this->search));
        $shown = $cards->filter(fn ($c) => match ($this->filter) {
            'rental' => $c['rental'], 'all' => true, default => $c['group'] === $this->filter,
        })->filter(fn ($c) => $q === '' || Str::contains(Str::lower($c['truck']->plate_no.' '.$c['state'].' '.collect($c['crew'])->pluck('name')->join(' ')), $q));
        $res = static::truckResource();

        $dupePage = static::class !== self::class ? str_replace('Fleet', 'TruckDuplicates', static::class) : null;
        $groups = $dupePage && class_exists($dupePage) && $dupePage::canAccess() ? \App\Support\TruckDuplicates::groups($hub) : collect();

        return [
            'dupes' => $groups->map(fn ($g) => ['plate' => \App\Support\TruckDuplicates::format($g->first()->plate_no), 'ids' => $g->pluck('id')->join(','),
                'copies' => $g->map(fn ($t) => ['plate' => $t->plate_no, 'hub' => $t->logistichub?->hub_name, 'trips' => \App\Support\TruckDuplicates::tripCount($t), 'off' => ! $t->is_active]),
                'url' => $dupePage::urlFor($g)]),
            'flagged' => $groups->reduce(function ($out, $g) {
                foreach ($g as $t) {
                    $out[$t->id] = $g->firstWhere('id', '!=', $t->id)?->plate_no;
                }

                return $out;
            }, []),
            'cards' => $shown->values(),
            'counts' => $counts,
            'summary' => $counts['all'].' trucks · '.$counts['trip'].' on a trip · '.$counts['free'].' free · '.$counts['rental'].' rental · '.$counts['off'].' inactive',
            'createUrl' => static::class !== self::class && class_exists($editor = str_replace('Fleet', 'TruckEditor', static::class)) ? $editor::getUrl() : ($res && $res::hasPage('create') ? $res::getUrl('create') : null),
        ];
    }
}
