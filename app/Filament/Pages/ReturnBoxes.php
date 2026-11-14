<?php

namespace App\Filament\Pages;

use App\Filament\Shared\ReturnBoxesPage;
use UnitEnum;

/** Main hub: scan undelivered boxes off a returning truck. */
class ReturnBoxes extends ReturnBoxesPage
{
    protected static string|UnitEnum|null $navigationGroup = 'Scanning';

    protected static ?int $navigationSort = 3;
}
