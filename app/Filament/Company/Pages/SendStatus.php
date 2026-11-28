<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\SendStatusPage;
use UnitEnum;

class SendStatus extends SendStatusPage
{
    protected static string|UnitEnum|null $navigationGroup = null;

    protected static ?int $navigationSort = 8;
}
