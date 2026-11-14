<?php

namespace App\Filament\Auth;

class CompanyLogin extends BrandedLogin
{
    protected string $view = 'filament.auth.login-company';

    public function panelLabel(): string
    {
        return 'Partner hub';
    }
}
