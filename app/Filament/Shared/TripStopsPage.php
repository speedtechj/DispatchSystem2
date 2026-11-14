<?php

namespace App\Filament\Shared;

use App\Models\Deliverylog;
use App\Models\Maps\TripStop;
use App\Support\Maps\MapSettings;
use App\Support\Maps\TripSorter;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;

/**
 * Delivery Log › trip › Stops & loading order: the stops on a map, the delivery
 * order (drag to change) and where each receiver's boxes go in the truck.
 */
abstract class TripStopsPage extends Page
{
    protected string $view = 'filament.maps.trip-stops';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'trip-stops';

    protected static ?string $title = 'Stops & loading order';

    #[Url(as: 'trip')]
    #[Locked]
    public int $tripId = 0;

    public function mount(): void
    {
        $this->tripId = (int) request()->query('trip', $this->tripId);
        $trip = Deliverylog::find($this->tripId);
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
    }

    public function trip(): Deliverylog
    {
        return once(fn () => Deliverylog::with('truck', 'destination')->findOrFail($this->tripId));
    }

    public function getTitle(): string|Htmlable
    {
        return 'Stops & loading order';
    }

    public function getSubheading(): ?string
    {
        $t = $this->trip();

        return 'Trip '.$t->trip_number.($t->truck?->plate_no ? ' · Truck '.$t->truck->plate_no : '');
    }

    public function resort(): void
    {
        TripSorter::sort($this->trip(), 60, unlock: true);
        Notification::make()->title('Sorted again')->success()->send();
        $this->dispatchMap();
    }

    public function toggleLock(): void
    {
        $route = TripSorter::ensure($this->trip());
        if ($route?->locked) {
            $this->resort();

            return;
        }
        TripSorter::saveOrder($this->trip(), TripSorter::stops($this->trip()));
        Notification::make()->title('Order locked')->body('New boxes are added at the end; your order is kept.')->send();
    }

    /** Drag and drop on the stop list. */
    public function moveStop(int $stopId, int $toIndex): void
    {
        TripSorter::move($this->trip(), $stopId, $toIndex);
        $this->dispatchMap();
    }

    protected function dispatchMap(): void
    {
        $this->dispatch('trip-map', data: $this->mapData(TripSorter::stops($this->trip())));
    }

    protected function mapData($stops): array
    {
        $t = $this->trip();
        $start = MapSettings::startFor($t->user?->warehouse_id, $t->logistichub_id);

        return [
            'start' => $start ? ['lat' => $start[0], 'lng' => $start[1], 'name' => $start['name']] : null,
            'stops' => $stops->map(fn (TripStop $s) => [
                'no' => $s->stop_no, 'name' => $s->name, 'address' => $s->address, 'boxes' => $s->boxes, 'zone' => $s->zoneLabel(),
                'lat' => $s->lat, 'lng' => $s->lng, 'kind' => $s->priority ? 'prio' : ($s->exact ? 'ok' : 'area'),
            ])->values()->all(),
        ];
    }

    protected function getViewData(): array
    {
        $trip = $this->trip();
        $transfer = TripSorter::isTransfer($trip);
        $route = $transfer ? null : TripSorter::ensure($trip);
        $stops = $transfer ? collect() : TripSorter::stops($trip);
        if ($route && $route->waiting > 0 && MapSettings::provider() !== 'none') {
            app()->terminating(fn () => TripSorter::sort($trip->fresh(), 60));
        }

        return [
            'trip' => $trip,
            'transfer' => $transfer,
            'route' => $route,
            'stops' => $stops,
            'boxes' => (int) $stops->sum('boxes'),
            'noPin' => $stops->filter(fn ($s) => ! $s->hasPin())->count(),
            'map' => $this->mapData($stops),
            'sourceText' => TripSorter::SOURCES[$route?->source ?? ''] ?? null,
            'printUrl' => route('trip.loading-list', $trip),
        ];
    }
}
