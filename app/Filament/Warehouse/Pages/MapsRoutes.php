<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\MapsRoutesPage;
use Illuminate\Support\Facades\Auth;

/** Warehouse → Maps & routes: what is used, your own start pin, and pins of your trips' addresses. Keys are set in Admin. */
class MapsRoutes extends MapsRoutesPage
{
    protected static bool $full = false;

    public static function canAccess(): bool
    {
        return (bool) Auth::user();
    }
}
