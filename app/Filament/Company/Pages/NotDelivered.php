<?php

namespace App\Filament\Company\Pages;

use App\Enums\FailedDeliveryReason;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\HubDesk;
use BackedEnum;
use DomainException;
use Filament\Actions\Action;
use Filament\Forms\Components\Select;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;

/** Boxes the hub's drivers could not hand over, grouped by reason: put them on another trip or return them. */
class NotDelivered extends Page
{
    protected string $view = 'filament.company.pages.not-delivered';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowPathRoundedSquare;

    protected static ?string $navigationLabel = 'Not delivered';

    protected static ?string $title = 'Not delivered';

    protected static ?int $navigationSort = 5;

    public static function desk(): HubDesk
    {
        return new HubDesk((int) Auth::user()->logistichub_id);
    }

    public static function getNavigationBadge(): ?string
    {
        $count = static::desk()->retryList()->sum(fn ($g) => $g['boxes']->count());

        return $count ? (string) $count : null;
    }

    public static function getNavigationBadgeColor(): ?string
    {
        return 'warning';
    }

    public function getSubheading(): ?string
    {
        return 'Boxes your drivers could not hand over, grouped by reason. Put them on a trip or send them back.';
    }

    /** A box of this hub that is still not delivered. */
    protected function box(int $id): ?Tripinvoice
    {
        return static::desk()->ours()->whereKey($id)->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->first();
    }

    protected function tripField(): Select
    {
        return Select::make('trip')
            ->label('Trip')
            ->options(fn () => static::desk()->openTrips())
            ->required()
            ->helperText('Open, unlocked trips of your hub. Create a new one in Delivery Log or Incoming boxes.');
    }

    /** Move boxes onto a trip; returns how many moved. */
    protected function moveTo(Deliverylog $trip, iterable $boxes): int
    {
        $service = app(TripAssignment::class);
        $moved = 0;

        foreach ($boxes as $box) {
            if ($box->deliveryloghub_id == $trip->id) {
                continue;
            }
            $service->removeFromHubTrip($box);
            $moved += $service->addToHubTrip($trip, [$box->fresh()]);
        }

        return $moved;
    }

    public function moveAction(): Action
    {
        return Action::make('move')
            ->label('Put on a trip')
            ->size('sm')
            ->modalHeading(fn (array $arguments) => 'Put '.($this->box($arguments['box'] ?? 0)?->invoice ?? 'box').' on a trip')
            ->modalWidth('md')
            ->schema([$this->tripField()])
            ->action(function (array $data, array $arguments): void {
                $box = $this->box($arguments['box'] ?? 0);
                $trip = static::desk()->trips()->find($data['trip']);

                if (! $box || ! $trip) {
                    return;
                }

                try {
                    $this->moveTo($trip, [$box]);
                } catch (DomainException $e) {
                    Notification::make()->title($e->getMessage())->danger()->send();

                    return;
                }

                Notification::make()->title("{$box->invoice} is on trip {$trip->trip_number}")->success()->send();
            });
    }

    public function moveAllAction(): Action
    {
        return Action::make('moveAll')
            ->label(fn (array $arguments) => 'Put all on a trip')
            ->icon(Heroicon::OutlinedTruck)
            ->modalHeading(fn (array $arguments) => 'Put every "'.(FailedDeliveryReason::tryFrom($arguments['reason'] ?? '')?->getLabel() ?? 'Other').'" box on a trip')
            ->modalWidth('md')
            ->schema([$this->tripField()])
            ->action(function (array $data, array $arguments): void {
                $group = static::desk()->retryList()->first(fn ($g) => $g['reason']->value === ($arguments['reason'] ?? null));
                $trip = static::desk()->trips()->find($data['trip']);

                if (! $group || ! $trip) {
                    return;
                }

                try {
                    $moved = $this->moveTo($trip, Tripinvoice::whereKey($group['boxes']->pluck('id'))->get());
                } catch (DomainException $e) {
                    Notification::make()->title($e->getMessage())->danger()->send();

                    return;
                }

                Notification::make()->title("{$moved} boxes put on trip {$trip->trip_number}")->success()->send();
            });
    }

    public function returnAction(): Action
    {
        return Action::make('return')
            ->label('Return')
            ->size('sm')
            ->color('gray')
            ->requiresConfirmation()
            ->modalHeading(fn (array $arguments) => 'Return '.($this->box($arguments['box'] ?? 0)?->invoice ?? 'box').'?')
            ->modalDescription('It comes off its trip and is marked returned, so it shows in Return Boxes.')
            ->action(function (array $arguments): void {
                $box = $this->box($arguments['box'] ?? 0);

                if (! $box) {
                    return;
                }

                try {
                    app(TripAssignment::class)->returnToHubInventory($box);
                } catch (DomainException $e) {
                    Notification::make()->title($e->getMessage())->danger()->send();

                    return;
                }

                Notification::make()->title("{$box->invoice} returned")->success()->send();
            });
    }

    protected function getViewData(): array
    {
        return ['groups' => static::desk()->retryList()];
    }
}
