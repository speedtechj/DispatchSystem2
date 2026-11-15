<?php

namespace App\Filament\Shared\Trips;

use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Support\TripFlow;
use App\Support\Tracking\Tracker;
use Filament\Actions\Action;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** One trip on one page: its step, truck, boxes, who took it, the crew, warnings, release and the next trip. */
class TripPage extends Page
{
    protected string $view = 'filament.trips.trip';

    protected static ?string $slug = 'trip';

    protected static bool $shouldRegisterNavigation = false;

    #[Url(as: 'trip')]
    public ?int $tripId = null;

    public static function canAccess(): bool
    {
        return TripFlow::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public static function urlFor(Deliverylog $trip): ?string
    {
        return static::canAccess() ? static::getUrl(['trip' => $trip->id]) : null;
    }

    public function mount(): void
    {
        abort_unless($this->trip(), 404);
    }

    public function trip(): ?Deliverylog
    {
        $hub = Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
        $trip = $this->tripId ? Deliverylog::with('truck', 'destination')->find($this->tripId) : null;
        if (! $trip || $hub === false) {
            return null;
        }

        return $hub === null || (int) $trip->logistichub_id === $hub || (int) $trip->assigned_to === $hub ? $trip : null;
    }

    public function getTitle(): string|Htmlable
    {
        $t = $this->trip();

        return 'Trip '.$t?->trip_number;
    }

    protected function getHeaderActions(): array
    {
        $trip = $this->trip();
        if (! $trip) {
            return [];
        }

        return [
            Action::make('lock')
                ->label('Lock trip · ready')
                ->icon(Heroicon::LockClosed)
                ->visible(fn () => $trip->is_active && ! $trip->is_lock && in_array(TripFlow::stage($trip), ['planned', 'loading'], true))
                ->requiresConfirmation()
                ->modalDescription('The leadman sees "Trip ready" and takes the trip.')
                ->action(function () use ($trip): void {
                    $trip->update(['is_lock' => true]);
                    Notification::make()->title('Trip '.$trip->trip_number.' is ready')->success()->send();
                }),
            TripActions::crew()->record($trip),
            TripActions::release()->record($trip),
            Action::make('boxes')
                ->label('Boxes & edit')
                ->color('gray')
                ->icon(Heroicon::PencilSquare)
                ->url(fn () => $this->editUrl($trip)),
        ];
    }

    protected function editUrl(Deliverylog $trip): ?string
    {
        $resource = collect(Filament::getCurrentPanel()?->getResources() ?? [])->first(fn ($r) => $r::getModel() === Deliverylog::class);

        return $resource && $resource::hasPage('edit') ? $resource::getUrl('edit', ['record' => $trip]) : null;
    }

    protected function getViewData(): array
    {
        $trip = $this->trip();
        $stage = TripFlow::stage($trip);
        $rows = TripFlow::boxes($trip);
        $total = (clone $rows)->count();
        $loaded = Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->count();
        $delivered = (clone $rows)->where('is_delivered', true)->count();
        $left = TripFlow::left($trip);
        $before = TripFlow::waitsFor($trip);
        $next = TripFlow::nextAfter($trip);
        $taker = $trip->taken_by ? \App\Models\User::find($trip->taken_by) : null;

        $warnings = [];
        if ($before) {
            $bl = TripFlow::left($before);
            $warnings[] = ['tone' => 'warn', 'text' => 'Truck '.$trip->truck?->plate_no.' is still on trip '.$before->trip_number.($bl ? ' ('.$bl.' '.str('box')->plural($bl).' not delivered or returned)' : '').'. '.$trip->trip_number.' starts when it closes.'];
        }
        if ($stage === 'ready' && $trip->ready_at?->lt(now()->subMinutes(30))) {
            $warnings[] = ['tone' => 'warn', 'text' => 'Ready since '.$trip->ready_at->format('g:i A').' · nobody took the trip yet.'];
        }
        if ($stage === 'back' && $left) {
            $warnings[] = ['tone' => 'warn', 'text' => $left.' '.str('box')->plural($left).' not returned yet: scan them back with Return boxes. Then the trip closes by itself.'];
        }
        if ($stage === 'closed') {
            $warnings[] = ['tone' => 'ok', 'text' => '✓ Closed'.($trip->closed_at ? ' '.$trip->closed_at->format('M j g:i A') : '').': '.($trip->release_reason === 'auto' ? 'every box delivered or returned. The truck was released by itself.' : 'released by the office · '.(TripFlow::RELEASE_REASONS[$trip->release_reason] ?? 'trip done').'.')];
        }

        $keys = array_keys(TripFlow::STAGES);
        $flow = array_values(array_diff($keys, ['waiting']));
        $at = array_search($stage === 'waiting' ? 'planned' : $stage, $flow, true);

        return [
            'trip' => $trip,
            'stage' => $stage,
            'steps' => collect($flow)->map(fn ($k, $i) => ['n' => $i + 1, 'label' => TripFlow::STAGES[$k][0], 'who' => TripFlow::STAGES[$k][1], 'state' => $stage === 'closed' || $i < $at ? 'done' : ($i === $at ? 'now' : 'todo')])->all(),
            'truckState' => match ($stage) {
                'waiting' => 'In use on '.$before?->trip_number,
                'closed' => $next ? 'On the next trip '.$next->trip_number : 'Free',
                'road' => 'On the road', 'back' => 'Back at the hub', default => 'On this trip',
            },
            'boxes' => match ($stage) {
                'planned', 'waiting' => $total.' on the trip',
                'loading', 'ready' => $loaded.' of '.$total.' loaded',
                'road' => $delivered.' of '.$total.' delivered',
                'back' => $delivered.' delivered · '.$left.' to return',
                default => $delivered.' delivered',
            },
            'took' => $trip->taken_at ? ($taker?->first_name ?? 'Crew').' · '.$trip->taken_at->format('g:i A').($trip->taken_boxes !== null ? ' · '.$trip->taken_boxes.' boxes' : '') : null,
            'crew' => TripFlow::crew($trip),
            'warnings' => $warnings,
            'next' => $next,
            'nextBoxes' => $next ? TripFlow::boxes($next)->count() : 0,
            'stageInfo' => TripFlow::STAGES[$stage],
        ];
    }
}
