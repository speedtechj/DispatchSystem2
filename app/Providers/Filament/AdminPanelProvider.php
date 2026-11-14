<?php

namespace App\Providers\Filament;

use App\Filament\Auth\AdminLogin;
use App\Providers\Filament\Concerns\ConfiguresDispatchPanel;
use BezhanSalleh\FilamentShield\FilamentShieldPlugin;
use Filament\Actions\Action;
use Filament\Navigation\NavigationGroup;
use Filament\Pages\Dashboard;
use Filament\Panel;
use Filament\PanelProvider;
use Filament\Support\Icons\Heroicon;

class AdminPanelProvider extends PanelProvider
{
    use ConfiguresDispatchPanel;

    public function panel(Panel $panel): Panel
    {
        return $this->dispatchPanel($panel, 'Admin', AdminLogin::class)
            ->default()
            ->id('admin')
            ->path('/')
            ->passwordReset()
            ->discoverResources(in: app_path('Filament/Resources'), for: 'App\\Filament\\Resources')
            ->discoverPages(in: app_path('Filament/Pages'), for: 'App\\Filament\\Pages')
            ->pages([
                Dashboard::class,
            ])
            ->discoverWidgets(in: app_path('Filament/Widgets'), for: 'App\\Filament\\Widgets')
            ->navigationGroups([
                NavigationGroup::make('Scanning')->icon(Heroicon::OutlinedQrCode),
                NavigationGroup::make('Settings')->icon(Heroicon::OutlinedCog6Tooth)->collapsed(),
            ])
            ->userMenuItems($this->partnerSystemLinks())
            ->plugins([
                FilamentShieldPlugin::make(),
            ]);
    }

    /** Quick links to the consolidators' own cargo systems. */
    protected function partnerSystemLinks(): array
    {
        return collect([
            ['Forex Calgary', 'https://cmsv4calgary.forexcargodeals.com/1224/login', Heroicon::OutlinedTruck],
            ['Forex Edmonton', 'https://cmsv4edmonton.forexcargo.ca/1224/login', Heroicon::OutlinedTruck],
            ['Star Express Calgary', 'https://cmscalgaryv4.starexpresskargo.com/1224/login', Heroicon::OutlinedStar],
            ['Star Express Edmonton', 'https://cmsedmontonv4.starexpresskargo.com/1224/login', Heroicon::OutlinedStar],
            ['Icargo Xpress', 'https://cmsv4.icargoxpress.com/1224', Heroicon::OutlinedBolt],
            ['Rc Padala Express', 'https://cms.rcpadalaexpress.com/1224/login', Heroicon::OutlinedCheckBadge],
        ])->map(fn (array $link) => Action::make(str($link[0])->slug()->toString())
            ->label($link[0])
            ->url($link[1], shouldOpenInNewTab: true)
            ->icon($link[2]))
            ->all();
    }
}
