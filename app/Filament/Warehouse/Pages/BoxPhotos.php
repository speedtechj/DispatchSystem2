<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\BoxPhotosPage;
use UnitEnum;

class BoxPhotos extends BoxPhotosPage
{
    protected static string|UnitEnum|null $navigationGroup = 'Warehouse';

    protected static ?int $navigationSort = 20;
}
