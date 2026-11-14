<?php

namespace App\Filament\Shared\Tracking;

use App\Models\Deliverylog;
use App\Support\Tracking\Tracker;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Truck tracking: the trucks on a trip now, on a map. Each panel sees only its own hub's trucks. */
abstract class TruckTrackingPage extends Page
{
    use TracksTrucks;

    protected string $view = 'filament.tracking.live';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedMapPin;

    protected static ?string $navigationLabel = 'Truck tracking';

    protected static ?string $title = 'Truck tracking';

    protected static ?string $slug = 'truck-tracking';

    protected static ?int $navigationSort = 3;

    #[Url(as: 'truck')]
    public ?int $sel = null;

    /** live or replay */
    #[Url]
    public string $tab = 'live';

    public static function canAccess(): bool
    {
        return (bool) Auth::user();
    }

    public function pick(int $truckId): void
    {
        $this->sel = $truckId;
        $this->sendMap(true);
    }

    public function setTab(string $tab): void
    {
        $this->tab = $tab === 'replay' ? 'replay' : 'live';
        $this->sendMap(true);
    }

    /** Every 30 seconds. */
    public function refresh(): void
    {
        $this->sendMap(false);
    }

    protected function trips()
    {
        return once(fn () => Tracker::activeTrips($this->hub()));
    }

    protected function cards()
    {
        return once(fn () => $this->trips()->map(fn (Deliverylog $t) => Tracker::card($t)));
    }

    protected function current(): ?array
    {
        $cards = $this->cards();

        return $cards->firstWhere('id', $this->sel) ?? $cards->first();
    }

    protected function mapData(bool $refit): array
    {
        $cur = $this->current();
        $trip = $cur ? $this->trips()->firstWhere('id', $cur['trip_id']) : null;
        if ($this->tab === 'replay' && $trip) {
            $path = Tracker::path($trip->truck_id, $trip->id);

            return ['replay' => $path, 'refit' => true] + array_diff_key($this->tripMap($trip, false), ['from' => 1]);
        }

        return $this->tripMap($trip) + [
            'refit' => $refit,
            'trucks' => $this->cards()->map(fn ($c) => ['id' => $c['id'], 'plate' => $c['plate'], 'lat' => $c['lat'], 'lng' => $c['lng'], 'kind' => $c['kind'], 'state' => $c['state'], 'sel' => $cur && $c['id'] === $cur['id']])->values()->all(),
        ];
    }

    protected function sendMap(bool $refit): void
    {
        $this->dispatch('truck-map', data: $this->mapData($refit));
    }

    protected function getViewData(): array
    {
        $cards = $this->cards();
        $cur = $this->current();

        return [
            'cards' => $cards,
            'cur' => $cur,
            'counts' => [
                'moving' => $cards->filter(fn ($c) => str_starts_with($c['state'], 'Moving') || str_starts_with($c['state'], 'At stop'))->count(),
                'stopped' => $cards->where('kind', 'warn')->count(),
                'bad' => $cards->where('kind', 'bad')->count(),
                'delivered' => $cards->sum('delivered'), 'total' => $cards->sum('total'),
            ],
            'map' => $this->mapData(true),
            'googleKey' => $this->googleKey(),
            'replayPath' => $this->tab === 'replay' && $cur ? Tracker::path($cur['id'], $cur['trip_id']) : [],
            'truckUrl' => fn (int $id) => static::truckPageClass()::getUrl(['truck' => $id]),
        ];
    }

    /** @return class-string<TruckPage> */
    abstract protected static function truckPageClass(): string;
}
