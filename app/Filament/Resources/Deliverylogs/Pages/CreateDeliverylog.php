<?php

namespace App\Filament\Resources\Deliverylogs\Pages;

use App\Filament\Pages\Routeinvoice;
use App\Filament\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Shared\Trips\NewTripRecord;

/** New trip by hand (board 44). */
class CreateDeliverylog extends NewTripRecord
{
    protected static string $resource = DeliverylogResource::class;

    protected static ?string $assignPage = Routeinvoice::class;
}
