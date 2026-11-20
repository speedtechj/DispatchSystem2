<?php

namespace App\Filament\Warehouse\Resources\Deliverylogs\Pages;

use App\Filament\Shared\Trips\ListsTrips;
use App\Filament\Shared\Widgets\TripBoard;
use App\Filament\Warehouse\Resources\Deliverylogs\DeliverylogResource;
use Filament\Resources\Pages\ListRecords;

class ListDeliverylogs extends ListRecords
{
    use ListsTrips;

    protected static string $resource = DeliverylogResource::class;

    protected function getHeaderWidgets(): array
    {
        return [
            TripBoard::make(['kind' => 'delivery', 'resource' => DeliverylogResource::class]),
        ];
    }

    public function getWidgetData(): array
    {
        return ['activeCard' => data_get($this->tableFilters, 'board.value')];
    }
}
