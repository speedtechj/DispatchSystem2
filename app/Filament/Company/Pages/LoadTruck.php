<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\LoadTripPage;

/** Partner hub scans boxes it received onto one of its own delivery trips. */
class LoadTruck extends LoadTripPage
{
    protected static bool $atHub = true;

    protected static ?string $navigationLabel = 'Load Truck';

    protected static ?string $title = 'Load Truck';

    protected static ?int $navigationSort = 2;
}
