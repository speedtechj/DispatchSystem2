<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Tracking\DaySummaryPage;

class TruckDay extends DaySummaryPage
{
    protected static function truckPageClass(): string
    {
        return TruckDetail::class;
    }
}
