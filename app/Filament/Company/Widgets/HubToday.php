<?php

namespace App\Filament\Company\Widgets;

use App\Filament\Company\Pages\IncomingBoxes;
use App\Filament\Company\Pages\NotDelivered;
use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Company\Resources\Truckcrews\TruckcrewResource;
use App\Filament\Company\Resources\Trucks\TruckResource;
use App\Support\HubDesk;
use Filament\Widgets\Widget;
use Illuminate\Support\Facades\Auth;

/** Partner hub dashboard: each open trip with its driver and progress, and what needs attention. */
class HubToday extends Widget
{
    protected string $view = 'filament.company.widgets.hub-today';

    protected static ?int $sort = 2;

    protected int|string|array $columnSpan = 'full';

    protected static bool $isLazy = false;

    public function link(string $key): ?string
    {
        return match ($key) {
            'incoming' => IncomingBoxes::getUrl(),
            'retry' => NotDelivered::getUrl(),
            'trucks' => TruckResource::getUrl('index'),
            'crew' => class_exists(TruckcrewResource::class) ? TruckcrewResource::getUrl('index') : null,
            default => null,
        };
    }

    protected function getViewData(): array
    {
        $desk = new HubDesk((int) Auth::user()->logistichub_id);

        return [
            'drivers' => $desk->driversToday(),
            'attention' => $desk->attention(),
            'tripsUrl' => DeliverylogResource::getUrl('index'),
        ];
    }
}
