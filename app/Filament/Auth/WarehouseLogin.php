<?php

namespace App\Filament\Auth;

class WarehouseLogin extends BrandedLogin
{
    protected string $view = 'filament.auth.login-warehouse';

    public function panelLabel(): string
    {
        return 'Warehouse';
    }
}
