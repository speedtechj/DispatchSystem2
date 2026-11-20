<?php

namespace App\Filament\Company\Resources\Deliverylogs\Pages;

use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Shared\Trips\ListsTrips;
use App\Filament\Shared\Widgets\TripBoard;
use Filament\Resources\Pages\ListRecords;

class ListDeliverylogs extends ListRecords
{
    use ListsTrips;

    protected static string $resource = DeliverylogResource::class;

    protected function getHeaderWidgets(): array
    {
        return [
            TripBoard::make(['kind' => 'hub', 'resource' => DeliverylogResource::class]),
        ];
    }

    public function getWidgetData(): array
    {
        return ['activeCard' => data_get($this->tableFilters, 'board.value')];
    }
}
