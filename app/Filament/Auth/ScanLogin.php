<?php

namespace App\Filament\Auth;

class ScanLogin extends BrandedLogin
{
    protected string $view = 'filament.auth.login-scan';

    public function panelLabel(): string
    {
        return 'Scan';
    }
}
