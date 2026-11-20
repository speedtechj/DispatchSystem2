<?php

namespace App\Filament\Shared\Trips;

use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Models\Truck;
use App\Support\Hubs\HubAreas;
use App\Support\Trips\CityTrips;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Resources\Pages\CreateRecord;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;

/**
 * New trip by hand (board 44): where it goes, the truck (cards with space and crew), when, paperwork,
 * and a live summary. Used by the Admin, Warehouse and Partner hub panels.
 */
abstract class NewTripRecord extends CreateRecord
{
    protected string $view = 'filament.trips.new-trip';

    /** A partner hub's own trips always go direct to its customers. */
    protected static bool $atHub = false;

    /** The panel's Assign invoice page (Admin Routeinvoice, Warehouse Hubroute, Partner hub Routeinvoice). */
    protected static ?string $assignPage = null;

    public string $go = 'direct';

    public ?int $hub = null;

    public ?int $truck = null;

    public string $day = 'today';

    public string $date = '';

    public string $eta = '';

    public int $tripDay = 1;

    public string $waybill = '';

    public string $container = '';

    public function mount(): void
    {
        parent::mount();
        $this->date = today()->toDateString();
        $this->eta = today()->addDay()->toDateString();
        $this->truck = $this->trucks()->firstWhere('state', 'free')['id'] ?? null;
    }

    public function getTitle(): string|Htmlable
    {
        return 'New trip by hand';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function getBreadcrumbs(): array
    {
        return [];
    }

    protected function trucks()
    {
        $kinds = Truck::where('logistichub_id', Auth::user()->logistichub_id)->pluck('category', 'id');

        return (new CityTrips(Auth::user()))->trucks()->map(fn ($t) => $t + ['kind' => (string) ($kinds[$t['id']] ?? '')]);
    }

    public function pickGo(string $go): void
    {
        $this->go = $go === 'hub' && ! static::$atHub ? 'hub' : 'direct';
        if ($this->go === 'hub' && ! $this->hub) {
            $this->hub = $this->hubs()->first()?->id;
        }
    }

    public function pickHub(int $id): void
    {
        $this->hub = $id;
    }

    public function pickTruck(int $id): void
    {
        $t = $this->trucks()->firstWhere('id', $id);
        if ($t && $t['state'] !== 'off') {
            $this->truck = $id;
        }
    }

    public function setDay(string $day): void
    {
        $this->day = in_array($day, ['today', 'tomorrow', 'date'], true) ? $day : 'today';
        if ($this->day !== 'date') {
            $this->date = ($this->day === 'tomorrow' ? today()->addDay() : today())->toDateString();
        }
        $this->eta = Carbon::parse($this->date)->addDay()->toDateString();
    }

    public function updatedDate(): void
    {
        $this->day = 'date';
        $this->eta = Carbon::parse($this->date ?: today())->addDay()->toDateString();
    }

    protected function hubs()
    {
        return Logistichub::query()->where('is_active', true)->where('id', '!=', Auth::user()->logistichub_id)
            ->orderByDesc('is_company')->orderBy('hub_name')->get();
    }

    public function waybillOk(): ?bool
    {
        return $this->waybill === '' ? null : (bool) preg_match('/^[A-Z]{1,4}-?\d{3,}$/i', trim($this->waybill));
    }

    /** Create the trip; $addBoxes opens Assign invoice for it. */
    public function createTrip(bool $addBoxes = false): void
    {
        $this->validate([
            'date' => 'required|date', 'eta' => 'required|date', 'tripDay' => 'required|integer|min:1|max:9',
            'truck' => static::$atHub ? 'required|integer' : 'nullable|integer',
            'waybill' => 'nullable|string|max:60', 'container' => 'nullable|string|max:60',
        ], ['truck.required' => 'Pick the truck.']);
        $u = Auth::user();
        $to = ! static::$atHub && $this->go === 'hub' && $this->hub ? $this->hub : $u->logistichub_id;
        $paper = trim(collect([trim($this->waybill), trim($this->container)])->filter()->join(' / '));
        $trip = Deliverylog::create([
            'truck_id' => $this->truck, 'trip_day' => $this->tripDay, 'eta' => $this->eta, 'departure_date' => $this->date,
            'assigned_to' => $to, 'logistichub_id' => $u->logistichub_id, 'user_id' => $u->id,
            'waybill_number' => $paper ?: null,
        ] + (Schema::hasColumn('deliverylogs', 'made_by') ? ['made_by' => 'manual'] : []));
        if ($this->truck && ! static::$atHub) {
            Truck::whereKey($this->truck)->update(['is_assigned' => 1]);
        }
        $this->record = $trip;
        Notification::make()->title('Trip '.$trip->trip_number.' created')->success()->send();

        $assign = static::$assignPage;
        $this->redirect($addBoxes && $assign ? $assign::getUrl(['ownerRecord' => $trip->id]) : static::getResource()::getUrl('edit', ['record' => $trip]));
    }

    protected function getViewData(): array
    {
        $trucks = $this->trucks();
        $sel = $trucks->firstWhere('id', $this->truck);
        $hubs = static::$atHub ? collect() : $this->hubs();
        $plan = collect(Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => is_subclass_of($p, PlanTripsPage::class));

        return [
            'atHub' => static::$atHub, 'trucks' => $trucks, 'sel' => $sel, 'hubs' => $hubs,
            'hubName' => Logistichub::whereKey(Auth::user()->logistichub_id)->value('hub_name'),
            'toName' => $this->go === 'hub' ? ($hubs->firstWhere('id', $this->hub)?->hub_name ?? '—') : null,
            'planUrl' => $plan ? $plan::getUrl() : null,
            'listUrl' => static::getResource()::getUrl('index'),
            'waybillOk' => $this->waybillOk(),
            'color' => fn (int $id) => class_exists(HubAreas::class) ? HubAreas::color($id) : '#1d6fb8',
            'fmt' => fn (?string $d) => $d ? Carbon::parse($d)->format('D, M j') : '—',
        ];
    }
}
