<?php

namespace App\Filament\Pages;

use App\Filament\Shared\LoadTripPage;
use BezhanSalleh\FilamentShield\Traits\HasPageShield;
use UnitEnum;

/** Hub crew scans each box onto the truck of a delivery trip. */
class Scanload extends LoadTripPage
{
    use HasPageShield;

    protected static ?string $navigationLabel = 'Load Truck';

    protected static ?string $title = 'Load Truck';

    protected static string|UnitEnum|null $navigationGroup = 'Scanning';

    protected static ?int $navigationSort = 2;
}
