<?php

namespace App\Filament\Pages;

use App\Filament\Shared\MapsRoutesPage;
use Illuminate\Support\Facades\Auth;

/** Admin → Settings → Maps & routes: keys, switches and every pin. */
class MapsRoutes extends MapsRoutesPage
{
    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }
}
