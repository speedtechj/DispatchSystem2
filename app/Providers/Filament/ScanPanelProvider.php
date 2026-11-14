<?php

namespace App\Providers\Filament;

use App\Filament\Auth\ScanLogin;
use App\Filament\Scan\Pages\ScanApp;
use App\Providers\Filament\Concerns\ConfiguresDispatchPanel;
use App\Support\Pwa;
use Filament\Panel;
use Filament\PanelProvider;
use Filament\View\PanelsRenderHook;

/**
 * The Scan app: one phone screen for loading and unloading crews.
 * Warehouse, partner hub and office accounts sign in here; each sees only its own scans.
 * It installs on the phone as its own app ("Speedtech Scan"), see App\Support\Pwa.
 */
class ScanPanelProvider extends PanelProvider
{
    use ConfiguresDispatchPanel;

    public function panel(Panel $panel): Panel
    {
        return $this->dispatchPanel($panel, 'Scan', ScanLogin::class)
            ->id('scan')
            ->path('scan')
            ->topbar(false)
            ->navigation(false)
            ->pages([ScanApp::class])
            ->renderHook(PanelsRenderHook::HEAD_END, fn (): string => view('pwa.head', $this->appData())->render())
            ->renderHook(PanelsRenderHook::BODY_END, fn (): string => view('pwa.body', $this->appData())->render());
    }

    /** @return array{panel: string, name: string, version: string} */
    protected function appData(): array
    {
        return ['panel' => 'scan', 'name' => Pwa::name('scan'), 'version' => Pwa::version()];
    }
}
