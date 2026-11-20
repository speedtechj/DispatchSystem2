<?php

namespace App\Filament\Company\Resources\Deliverylogs\Pages;

use App\Filament\Company\Pages\Routeinvoice;
use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Shared\Trips\NewTripRecord;

/** New trip by hand (board 44). */
class CreateDeliverylog extends NewTripRecord
{
    protected static string $resource = DeliverylogResource::class;

    protected static ?string $assignPage = Routeinvoice::class;

    /** A partner hub's own trips go direct to its customers. */
    protected static bool $atHub = true;
}
