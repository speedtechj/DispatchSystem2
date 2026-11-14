<?php

namespace App\Providers\Filament;

use App\Filament\Auth\DeliveryLogin;
use App\Filament\Delivery\Pages\Dashboard;
use App\Providers\Filament\Concerns\ConfiguresDispatchPanel;
use App\Support\AppHooks;
use App\Support\Pwa;
use Filament\Panel;
use Filament\PanelProvider;
use Filament\View\PanelsRenderHook;

/**
 * Drivers use this on their phones. The home page is their trip for today.
 * It can be installed as an app ("Speedtech Driver"), see App\Support\Pwa.
 */
class DeliveryPanelProvider extends PanelProvider
{
    use ConfiguresDispatchPanel;

    public function panel(Panel $panel): Panel
    {
        return $this->dispatchPanel($panel, 'Delivery', DeliveryLogin::class)
            ->id('delivery')
            ->path('delivery')
            ->topNavigation()
            ->discoverResources(in: app_path('Filament/Delivery/Resources'), for: 'App\\Filament\\Delivery\\Resources')
            ->discoverPages(in: app_path('Filament/Delivery/Pages'), for: 'App\\Filament\\Delivery\\Pages')
            ->pages([
                Dashboard::class,
            ])
            ->discoverWidgets(in: app_path('Filament/Delivery/Widgets'), for: 'App\\Filament\\Delivery\\Widgets')
            // Install as an app (PWA): manifest and icon in <head>, Install item, iPhone tip, no-signal screen.
            ->renderHook(PanelsRenderHook::HEAD_END, fn (): string => view('pwa.head', $this->appData())->render())
            ->renderHook(PanelsRenderHook::BODY_END, fn (): string => view('pwa.body', $this->appData())->render())
            ->renderHook(PanelsRenderHook::USER_MENU_PROFILE_AFTER, fn (): string => view('pwa.menu-item')->render());
    }

    /** App-wide hooks (favicon for all panels, container unload time). See App\Support\AppHooks. */
    public function boot(): void
    {
        AppHooks::register();
    }

    /** @return array{panel: string, name: string, version: string} */
    protected function appData(): array
    {
        return ['panel' => 'delivery', 'name' => Pwa::name('delivery'), 'version' => Pwa::version()];
    }
}
