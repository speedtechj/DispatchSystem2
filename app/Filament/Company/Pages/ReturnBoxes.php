<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\ReturnBoxesPage;

/** Partner hub: scan undelivered boxes off one of the hub's own trucks. */
class ReturnBoxes extends ReturnBoxesPage
{
    protected static bool $atHub = true;

    protected static ?int $navigationSort = 3;
}
