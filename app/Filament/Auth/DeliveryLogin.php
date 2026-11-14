<?php

namespace App\Filament\Auth;

class DeliveryLogin extends BrandedLogin
{
    protected string $view = 'filament.auth.login-delivery';

    public function panelLabel(): string
    {
        return 'Delivery';
    }
}
