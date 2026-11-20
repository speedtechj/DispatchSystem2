<?php

namespace App\Filament\Shared\Trucks;

use App\Models\Deliverylog;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\TripCrew;
use App\Support\Fuel\Fuel;
use App\Support\Rentals;
use App\Support\Tracking\Tracker;
use App\Support\TripFlow;
use App\Support\TruckSpace;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** One truck: Overview, Crew, Details, Trips, and Rental (booked days) for a rental truck. */
class TruckProfilePage extends Page
{
    protected string $view = 'filament.trucks.profile';

    protected static ?string $slug = 'truck-profile';

    protected static bool $shouldRegisterNavigation = false;

    #[Url(as: 'truck')]
    public ?int $truckId = null;

    #[Url]
    public string $tab = 'overview';

    public string $month = '';

    public static function canAccess(): bool
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function mount(): void
    {
        abort_unless($this->truck(), 404);
        $this->month = today()->format('Y-m');
    }

    public function truck(): ?Truck
    {
        $t = $this->truckId ? Truck::with('rentalCompany')->find($this->truckId) : null;

        return $t && Tracker::canSeeTruck(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()), $t) ? $t : null;
    }

    public function getTitle(): string|Htmlable
    {
        return (string) $this->truck()?->plate_no;
    }

    /** The plate is shown big in the card at the top, so the page has no separate heading. */
    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['overview', 'crew', 'details', 'trips', 'rental'], true) ? $tab : 'overview';
    }

    public function toggleActive(): void
    {
        $t = $this->truck();
        $t->update(['is_active' => ! $t->is_active]);
        Notification::make()->title($t->plate_no.' is '.($t->is_active ? 'active' : 'inactive: hidden from trips, the AI and the crew board'))->success()->send();
    }

    public function addCrew($userId): void
    {
        $t = $this->truck();
        $user = $userId ? TripFlow::crewPeople(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()))->firstWhere('id', (int) $userId) : null;
        if (! $user) {
            return;
        }
        Truckcrew::where('crew', $user->id)->where('truck_id', '!=', $t->id)->get()->each->delete();
        Truckcrew::firstOrCreate(['truck_id' => $t->id, 'crew' => $user->id], ['user_id' => Auth::id()]);
    }

    public function removeCrew(int $userId): void
    {
        Truckcrew::where('truck_id', $this->truck()->id)->where('crew', $userId)->get()->each->delete();
    }

    public function toggleDay(string $day): void
    {
        $t = $this->truck();
        if (! $t->isRental()) {
            return;
        }
        $booked = Rentals::toggleDay($t, Carbon::parse($day));
        Notification::make()->title(Carbon::parse($day)->format('M j').($booked ? ' booked' : ' freed'))->success()->send();
    }

    public function shiftMonth(int $by): void
    {
        $this->month = Carbon::createFromFormat('Y-m', $this->month)->startOfMonth()->addMonths($by)->format('Y-m');
    }

    protected function editUrl(Truck $t): ?string
    {
        $editor = str_replace('TruckProfile', 'TruckEditor', static::class);
        if (static::class !== self::class && class_exists($editor)) {
            return $editor::getUrl(['truck' => $t->id]);
        }
        $res = FleetPage::truckResource();

        return $res && $res::hasPage('edit') ? $res::getUrl('edit', ['record' => $t]) : null;
    }

    protected function getViewData(): array
    {
        $t = $this->truck();
        $card = FleetPage::card($t, Truckcrew::with('member')->where('truck_id', $t->id)->get()->filter(fn ($c) => $c->member));
        $trip = TripFlow::runningOn($t->id);
        $tripPage = str_replace(['Trucks\\TruckProfilePage', 'TruckProfile'], ['Trips\\TripPage', 'Trip'], static::class);
        $tripUrl = fn ($trip) => class_exists($tripPage) ? $tripPage::urlFor($trip) : null;
        $monthStart = today()->startOfMonth();
        $monthTrips = Deliverylog::where('truck_id', $t->id)->where('created_at', '>=', $monthStart)->get();
        $delivered = $monthTrips->sum(fn ($x) => TripFlow::boxes($x)->where('is_delivered', true)->count());
        $kml = Fuel::ready() ? Fuel::kml($t->id) : null;
        $kmlBefore = Fuel::ready() ? Fuel::kml($t->id, 5, 5) : null;
        $perBox = null;
        if ($t->isRental()) {
            $cost = $monthTrips->sum('rental_cost');
            $perBox = $cost > 0 && $delivered ? round($cost / $delivered) : null;
        } elseif (Fuel::ready()) {
            $fuel = (float) \App\Models\Fuel\FuelFill::where('truck_id', $t->id)->where('filled_at', '>=', $monthStart)->sum('total');
            $perBox = $fuel > 0 && $delivered ? round($fuel / $delivered) : null;
        }

        $look = [];
        if ($t->date_expired && $t->date_expired->isPast()) {
            $look[] = ['bad', '📄 Registration expired '.$t->date_expired->format('M j, Y')];
        } elseif ($t->date_expired && $t->date_expired->lte(today()->addDays(30))) {
            $look[] = ['warn', '📄 Registration expires '.$t->date_expired->format('M j').' (in '.today()->diffInDays($t->date_expired).' days)'];
        }
        if ($kml && $kmlBefore && $kml < $kmlBefore * 0.85) {
            $look[] = ['warn', '⛽ Fuel: '.$kml.' km/L lately, usually '.$kmlBefore.' km/L ('.round((1 - $kml / $kmlBefore) * 100).'% worse)'];
        }
        if ($t->is_active && ! $card['crew']) {
            $look[] = ['bad', '👥 No crew on this truck'];
        }

        $month = Carbon::createFromFormat('Y-m', $this->month)->startOfMonth();
        $booked = $t->isRental() ? Rentals::bookedDays($t, $month) : [];

        return [
            't' => $t, 'card' => $card, 'tripNow' => $trip, 'stage' => $trip ? TripFlow::stage($trip) : null,
            'next' => $trip ? TripFlow::nextAfter($trip) : null, 'tripUrl' => $tripUrl,
            'tiles' => [
                ['Space', TruckSpace::usable($t).' boxes', $t->capacity ? 'set by you' : 'from the truck size'],
                ['This month', $monthTrips->count().' '.str('trip')->plural($monthTrips->count()), $delivered.' boxes delivered'],
                ['Fuel', $kml ? $kml.' km/L' : '—', $kml && $kmlBefore ? 'usually '.$kmlBefore.' km/L' : 'no fills with odometer yet'],
                ['Cost per box', $perBox ? '₱'.number_format($perBox) : '—', $t->isRental() ? 'rental, this month' : 'fuel, this month'],
            ],
            'look' => $look,
            'crew' => Truckcrew::with('member.workposition')->where('truck_id', $t->id)->get()->filter(fn ($c) => $c->member)->values(),
            'addable' => TripFlow::crewPeople(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()))
                ->reject(fn ($u) => Truckcrew::where('truck_id', $t->id)->where('crew', $u->id)->exists())->mapWithKeys(fn ($u) => [$u->id => $u->full_name])->all(),
            'history' => Deliverylog::with('destination:id,hub_name')->where('truck_id', $t->id)->latest('id')->limit(15)->get()->map(function ($x) use ($tripUrl) {
                $rows = TripFlow::boxes($x);
                $total = (clone $rows)->count();
                $del = (clone $rows)->where('is_delivered', true)->count();
                $stage = TripFlow::stage($x);

                return ['trip' => $x, 'url' => $tripUrl($x), 'date' => Carbon::parse($x->departure_date ?? $x->created_at)->format('M j'),
                    'crew' => TripCrew::with('user')->where('deliverylog_id', $x->id)->get()->map(fn ($c) => $c->user?->first_name)->filter()->join(', ') ?: '—',
                    'boxes' => $total, 'result' => $stage === 'closed' ? ($del === $total ? 'All delivered' : $del.' delivered · '.($total - $del).' not') : TripFlow::STAGES[$stage][0],
                    'ok' => $stage === 'closed', 'cost' => $x->rental_cost];
            }),
            'editUrl' => $this->editUrl($t),
            'backUrl' => ($fleet = str_replace('TruckProfile', 'Fleet', static::class)) !== static::class && class_exists($fleet) ? $fleet::getUrl() : null,
            'monthDate' => $month, 'booked' => $booked,
            'rateText' => Rentals::rateText($t),
        ];
    }
}
