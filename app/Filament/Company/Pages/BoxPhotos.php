<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\BoxPhotosPage;
use UnitEnum;

class BoxPhotos extends BoxPhotosPage
{
    protected static string|UnitEnum|null $navigationGroup = null;

    protected static ?int $navigationSort = 7;
}
