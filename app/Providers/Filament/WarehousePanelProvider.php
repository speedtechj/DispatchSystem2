<?php

namespace App\Providers\Filament;

use App\Filament\Auth\WarehouseLogin;
use App\Providers\Filament\Concerns\ConfiguresDispatchPanel;
use Filament\Navigation\NavigationGroup;
use Filament\Pages\Dashboard;
use Filament\Panel;
use Filament\PanelProvider;
use Filament\Support\Icons\Heroicon;

class WarehousePanelProvider extends PanelProvider
{
    use ConfiguresDispatchPanel;

    public function panel(Panel $panel): Panel
    {
        return $this->dispatchPanel($panel, 'Warehouse', WarehouseLogin::class)
            ->id('warehouse')
            ->path('warehouse')
            ->discoverResources(in: app_path('Filament/Warehouse/Resources'), for: 'App\\Filament\\Warehouse\\Resources')
            ->discoverPages(in: app_path('Filament/Warehouse/Pages'), for: 'App\\Filament\\Warehouse\\Pages')
            ->pages([
                Dashboard::class,
            ])
            ->discoverWidgets(in: app_path('Filament/Warehouse/Widgets'), for: 'App\\Filament\\Warehouse\\Widgets')
            ->navigationGroups([
                NavigationGroup::make('Warehouse')->icon(Heroicon::OutlinedBuildingStorefront),
                NavigationGroup::make('Hub')->icon(Heroicon::OutlinedBuildingOffice2),
                NavigationGroup::make('Truck Management')->icon(Heroicon::OutlinedTruck),
                NavigationGroup::make('Invoice Management')->icon(Heroicon::OutlinedClipboardDocumentList),
            ]);
    }
}
