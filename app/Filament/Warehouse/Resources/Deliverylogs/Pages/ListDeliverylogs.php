<?php

namespace App\Filament\Warehouse\Resources\Deliverylogs\Pages;

use App\Filament\Shared\Widgets\TripBoard;
use App\Filament\Warehouse\Resources\Deliverylogs\DeliverylogResource;
use Filament\Actions\CreateAction;
use Filament\Notifications\Notification;
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

    public function mount(): void
    {
        parent::mount();

        Notification::make()
            ->title('Please fill up and complete all active delivery logs before creating a new delivery log.')
         //    ->body(Str::markdown('<div style="color:#F5BA07;font-weight:bold;font-size:15px;">After typing, press Tab Key or Click Search icon to begin the search</div>'))
            ->persistent()
            ->success()
            ->send();
    }

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
