<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\LoadTripPage;
use UnitEnum;

/** Warehouse hub crew scans boxes onto the truck of a hub delivery trip. */
class Hubloaded extends LoadTripPage
{
    protected static ?string $navigationLabel = 'Hub Load Truck';

    protected static ?string $title = 'Hub Load Truck';

    protected static string|UnitEnum|null $navigationGroup = 'Hub';
}
