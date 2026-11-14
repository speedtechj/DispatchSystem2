<?php

namespace App\Filament\Warehouse\Resources\Trucks\Pages;

use App\Filament\Shared\Widgets\ModuleBoard;
use App\Filament\Warehouse\Resources\Trucks\TruckResource;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ListRecords;

class ListTrucks extends ListRecords
{
    protected static string $resource = TruckResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make(),
        ];
    }

    protected function getHeaderWidgets(): array
    {
        return [
            ModuleBoard::make(['board' => 'vehicles', 'resource' => TruckResource::class]),
        ];
    }
}
