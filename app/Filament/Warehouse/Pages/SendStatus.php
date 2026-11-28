<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\SendStatusPage;
use UnitEnum;

class SendStatus extends SendStatusPage
{
    protected static string|UnitEnum|null $navigationGroup = 'Warehouse';

    protected static ?int $navigationSort = 21;
}
