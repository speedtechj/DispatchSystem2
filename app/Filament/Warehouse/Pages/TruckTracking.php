<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\Tracking\TruckTrackingPage;

class TruckTracking extends TruckTrackingPage
{
    protected static function truckPageClass(): string
    {
        return TruckDetail::class;
    }
}
