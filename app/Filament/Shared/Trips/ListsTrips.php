<?php

namespace App\Filament\Shared\Trips;

use App\Filament\Tables\TripList;
use App\Models\Deliverylog;
use Filament\Actions\Action;
use Filament\Actions\CreateAction;
use Filament\Facades\Filament;
use Illuminate\Support\Facades\Auth;

/** Delivery trips list (board 42): title, Plan trips, New trip by hand and the stage tabs. All three panels. */
trait ListsTrips
{
    protected function getHeaderActions(): array
    {
        $plan = collect(Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => is_subclass_of($p, PlanTripsPage::class));

        return array_values(array_filter([
            $plan ? Action::make('plan')->label('✦ Plan trips')->url(fn () => $plan::getUrl()) : null,
            CreateAction::make()->label('+ New trip by hand')->color('gray'),
        ]));
    }

    public function getTitle(): string
    {
        return 'Delivery trips';
    }

    public function getSubheading(): ?string
    {
        return 'Every trip, who made it and how far it is. Click a trip for the details.';
    }

    public function getBreadcrumbs(): array
    {
        return [];
    }

    public function getTabs(): array
    {
        return TripList::tabs(Deliverylog::query()->where('deliverylogs.logistichub_id', Auth::user()->logistichub_id));
    }
}
