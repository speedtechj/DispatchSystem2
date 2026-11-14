<?php

namespace App\Filament\Company\Resources\Deliverylogs\Pages;

use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Shared\Widgets\TripBoard;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ListRecords;

class ListDeliverylogs extends ListRecords
{
    protected static string $resource = DeliverylogResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make(),
        ];
    }

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
