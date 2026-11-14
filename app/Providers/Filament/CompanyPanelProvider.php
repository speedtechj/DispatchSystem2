<?php

namespace App\Providers\Filament;

use App\Filament\Auth\CompanyLogin;
use App\Providers\Filament\Concerns\ConfiguresDispatchPanel;
use Filament\Pages\Dashboard;
use Filament\Panel;
use Filament\PanelProvider;

class CompanyPanelProvider extends PanelProvider
{
    use ConfiguresDispatchPanel;

    public function panel(Panel $panel): Panel
    {
        return $this->dispatchPanel($panel, 'Partner hub', CompanyLogin::class)
            ->id('company')
            ->path('company')
            ->discoverResources(in: app_path('Filament/Company/Resources'), for: 'App\\Filament\\Company\\Resources')
            ->discoverPages(in: app_path('Filament/Company/Pages'), for: 'App\\Filament\\Company\\Pages')
            ->pages([
                Dashboard::class,
            ])
            ->discoverWidgets(in: app_path('Filament/Company/Widgets'), for: 'App\\Filament\\Company\\Widgets');
    }
}
