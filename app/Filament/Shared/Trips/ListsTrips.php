<?php

namespace App\Filament\Shared\Trips;

use App\Filament\Tables\TripList;
use App\Models\Deliverylog;
use Filament\Actions\Action;
use Filament\Actions\CreateAction;
use Filament\Facades\Filament;
use Illuminate\Contracts\Pagination\CursorPaginator;
use Illuminate\Contracts\Pagination\Paginator;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Delivery trips list (board 42): title, Plan trips, New trip by hand and the stage tabs. All three panels. */
trait ListsTrips
{
    protected ?int $tripsPrimedFor = null;

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

    /** Speed: load cities, crew, truck and hub for the whole page at once. */
    public function getTableRecords(): Collection|Paginator|CursorPaginator
    {
        $records = parent::getTableRecords();
        if ($this->tripsPrimedFor !== spl_object_id($records)) { // again only when Filament reloads the rows
            $this->tripsPrimedFor = spl_object_id($records);
            TripList::prime($records instanceof Paginator || $records instanceof CursorPaginator ? $records->items() : $records);
        }

        return $records;
    }

    public function getTabs(): array
    {
        return TripList::tabs(Deliverylog::query()->where('deliverylogs.logistichub_id', Auth::user()->logistichub_id));
    }
}
