<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\Shipping\WrongHubPage;

/** Warehouse: boxes the partner hubs send back (view only). */
class ComingBack extends WrongHubPage
{
    protected static bool $comingBack = true;

    protected static ?string $navigationLabel = 'Boxes coming back';

    protected static ?string $title = 'Boxes coming back';

    protected static ?string $slug = 'coming-back';
}
