<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\Shipping\SeaShipmentsPage;

/** Partner hub: sea shipments coming to this hub. */
class IncomingShipments extends SeaShipmentsPage
{
    protected static bool $incoming = true;

    protected static ?string $navigationLabel = 'Incoming shipments';

    protected static ?string $title = 'Incoming shipments';

    protected static ?string $slug = 'incoming-shipments';
}
