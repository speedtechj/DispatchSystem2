<?php

namespace App\Filament\Auth;

class AdminLogin extends BrandedLogin
{
    protected string $view = 'filament.auth.login-admin';

    public function panelLabel(): string
    {
        return 'Admin';
    }
}
