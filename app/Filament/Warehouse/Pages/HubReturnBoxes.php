<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\ReturnBoxesPage;
use UnitEnum;

/** Warehouse hub: scan undelivered boxes off a returning truck. */
class HubReturnBoxes extends ReturnBoxesPage
{
    protected static ?string $navigationLabel = 'Hub Return Boxes';

    protected static ?string $title = 'Hub Return Boxes';

    protected static string|UnitEnum|null $navigationGroup = 'Hub';
}
