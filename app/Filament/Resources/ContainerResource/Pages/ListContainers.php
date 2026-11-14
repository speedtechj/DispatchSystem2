<?php

namespace App\Filament\Resources\ContainerResource\Pages;

use App\Filament\Resources\ContainerResource;
use App\Filament\Shared\Widgets\ModuleBoard;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ListRecords;

class ListContainers extends ListRecords
{
    protected static string $resource = ContainerResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make(),
        ];
    }

    protected function getHeaderWidgets(): array
    {
        return [
            ModuleBoard::make(['board' => 'containers', 'resource' => ContainerResource::class]),
        ];
    }
}
