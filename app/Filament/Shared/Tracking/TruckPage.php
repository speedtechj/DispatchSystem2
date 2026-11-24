<?php

namespace App\Filament\Shared\Tracking;

use App\Models\Deliverylog;
use App\Models\Tracking\TruckAlert;
use App\Models\Truck;
use App\Support\Tracking\Tracker;
use App\Support\Tracking\TrackSettings;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;

/** One truck: today (map, step by step), trip history with replay, and its alerts. */
abstract class TruckPage extends Page
{
    use TracksTrucks;

    protected string $view = 'filament.tracking.truck';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'truck-tracking/truck';

    #[Url(as: 'truck')]
    #[Locked]
    public int $truckId = 0;

    /** today, history, alerts */
    #[Url]
    public string $tab = 'today';

    public ?int $replayTrip = null;

    /** alert id => note typed when checking it */
    public array $notes = [];

    public static function canAccess(): bool
    {
        return (bool) Auth::user();
    }

    public function mount(): void
    {
        $this->truckId = (int) request()->query('truck', $this->truckId);
        $truck = Truck::find($this->truckId);
        // board 63: a partner hub may follow our RoRo truck that brings its boxes
        abort_unless($truck && (Tracker::canSeeTruck($this->hub(), $truck)
            || (is_int($this->hub()) && \App\Support\Shipping\SeaTrucks::roroTruckFor($this->hub(), $truck->id))), 404);
        if (! in_array($this->tab, ['today', 'history', 'alerts'], true)) {
            $this->tab = 'today';
        }
    }

    public function truck(): Truck
    {
        return once(fn () => Truck::findOrFail($this->truckId));
    }

    protected function trip(): ?Deliverylog
    {
        return once(fn () => Deliverylog::with('truck')->where('truck_id', $this->truckId)->where('is_active', true)->latest('id')->first());
    }

    public function getTitle(): string|Htmlable
    {
        return $this->truckId ? (string) (Truck::whereKey($this->truckId)->value('plate_no') ?? 'Truck') : 'Truck';
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['today', 'history', 'alerts'], true) ? $tab : 'today';
        $this->replayTrip = null;
        if ($this->tab === 'today') {
            $this->dispatch('truck-map', data: $this->todayMap() + ['refit' => true]);
        }
    }

    public function replay(int $tripId): void
    {
        $trip = Deliverylog::where('truck_id', $this->truckId)->find($tripId);
        if (! $trip) {
            return;
        }
        $this->replayTrip = $trip->id;
        $this->dispatch('truck-map', data: ['replay' => Tracker::path($this->truckId, $trip->id), 'refit' => true] + array_diff_key($this->tripMap($trip, false), ['from' => 1]));
    }

    public function check(int $alertId): void
    {
        $a = TruckAlert::where('truck_id', $this->truckId)->find($alertId);
        $a?->update(['checked_by' => Auth::id(), 'checked_at' => now(), 'note' => mb_substr(trim((string) ($this->notes[$alertId] ?? '')), 0, 500) ?: $a->note]);
        Notification::make()->title('Marked as checked')->success()->send();
    }

    public function refresh(): void
    {
        if ($this->tab === 'today') {
            $this->dispatch('truck-map', data: $this->todayMap() + ['refit' => false]);
        }
    }

    protected function todayMap(): array
    {
        $trip = $this->trip();
        $card = $trip ? Tracker::card($trip) : null;

        return $this->tripMap($trip) + ['trucks' => $card ? [['id' => $card['id'], 'plate' => $card['plate'], 'lat' => $card['lat'], 'lng' => $card['lng'], 'kind' => $card['kind'], 'state' => $card['state'], 'sel' => true]] : []];
    }

    protected function getViewData(): array
    {
        $truck = $this->truck();
        $trip = $this->trip();
        $crew = Tracker::crew($truck->id);
        $history = $this->tab === 'history' ? Tracker::history($truck) : collect();
        $month = $history->filter(fn ($h) => true);

        return [
            'truck' => $truck,
            'trip' => $trip,
            'crew' => $crew,
            'source' => TrackSettings::SOURCES[TrackSettings::source($truck->id)][0],
            'card' => $trip ? Tracker::card($trip) : null,
            'stats' => $this->tab === 'today' ? Tracker::day($truck, $trip) : [],
            'events' => $this->tab === 'today' ? Tracker::events($truck, $trip) : [],
            'history' => $history,
            'totals' => [
                'km' => round((float) $month->sum('km')),
                'trips' => $month->count(),
                'firstTry' => $month->sum('delivered') ? (int) round($month->sum('firstTry') / $month->sum('delivered') * 100) : null,
            ],
            'alerts' => $this->tab === 'alerts' ? TruckAlert::with('checker', 'trip')->where('truck_id', $truck->id)->latest('started_at')->limit(100)->get() : collect(),
            'map' => $this->todayMap() + ['refit' => true],
            'googleKey' => $this->googleKey(),
        ];
    }
}
