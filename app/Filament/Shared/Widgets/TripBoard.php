<?php

namespace App\Filament\Shared\Widgets;

use App\Services\TripAssignment;
use App\Support\TripBoard as Board;
use Filament\Notifications\Notification;
use Filament\Widgets\Widget;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Reactive;

/**
 * Today at a glance, trips that need attention, and two small charts, on top
 * of a trip list. Used by Delivery Log (Admin, Warehouse), the partner hub's
 * Delivery Log, and the warehouse-to-warehouse trip log.
 *
 *   TripBoard::make(['kind' => 'delivery', 'resource' => DeliverylogResource::class])
 */
class TripBoard extends Widget
{
    protected string $view = 'filament.widgets.trip-board';

    protected int|string|array $columnSpan = 'full';

    protected static bool $isLazy = false;

    /** delivery, hub or warehouse */
    #[Locked]
    public string $kind = 'delivery';

    /** The trip resource, for links to the list and to each trip. */
    #[Locked]
    public string $resource = '';

    /** The card the list is filtered by (from the list page). */
    #[Reactive]
    public ?string $activeCard = null;

    public function board(): Board
    {
        $user = Auth::user();

        return Board::make($this->kind, (int) ($this->kind === 'warehouse' ? $user->warehouse_id : $user->logistichub_id));
    }

    public function canLock(): bool
    {
        return match ($this->kind) {
            'warehouse' => true,
            'delivery' => (bool) Auth::user()?->hasRole('super_admin'),
            default => false,
        };
    }

    public function cardUrl(string $card): string
    {
        return $this->resource::getUrl('index', $this->activeCard === $card ? [] : ['filters' => ['board' => ['value' => $card]]]);
    }

    public function tripUrl(int $tripId): string
    {
        return $this->resource::getUrl('edit', ['record' => $tripId]);
    }

    public function lockTrip(int $tripId): void
    {
        $trip = $this->board()->find($tripId);

        if (! $trip || ! $this->canLock()) {
            return;
        }

        $trip->update(['is_lock' => true]);
        Notification::make()->title("Trip {$trip->trip_number} locked")->success()->send();
    }

    public function releaseTruck(int $tripId): void
    {
        $trip = $this->board()->find($tripId);

        if (! $trip || $this->kind === 'warehouse' || ! $trip->is_current) {
            return;
        }

        \App\Support\TripFlow::release($trip, 'done');
        Notification::make()->title("Truck released from trip {$trip->trip_number}")->success()->send();
    }

    protected function getViewData(): array
    {
        $board = $this->board();
        $days = $board->perDay();
        $breakdown = $board->breakdown();

        return [
            'board' => $board,
            'cards' => $board->cards(),
            'attention' => $board->attention(),
            'days' => $days,
            'dayMax' => max(1, $days->max('boxes')),
            'breakdown' => $breakdown,
            'breakdownMax' => max(1, $breakdown->max('count') ?? 0),
        ];
    }
}
