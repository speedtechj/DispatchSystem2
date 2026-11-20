<?php

namespace App\Filament\Warehouse\Resources\Deliverylogs\Pages;

use App\Filament\Shared\Trips\NewTripRecord;
use App\Filament\Warehouse\Pages\Hubroute;
use App\Filament\Warehouse\Resources\Deliverylogs\DeliverylogResource;

/** New trip by hand (board 44). */
class CreateDeliverylog extends NewTripRecord
{
    protected static string $resource = DeliverylogResource::class;

    protected static ?string $assignPage = Hubroute::class;
}
