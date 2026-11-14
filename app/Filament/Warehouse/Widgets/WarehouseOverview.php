<?php

namespace App\Filament\Warehouse\Widgets;

use App\Models\Container;
use App\Models\Invoice;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use Filament\Support\Icons\Heroicon;
use Filament\Widgets\StatsOverviewWidget;
use Filament\Widgets\StatsOverviewWidget\Stat;
use Illuminate\Support\Facades\Auth;

class WarehouseOverview extends StatsOverviewWidget
{
    protected ?string $pollingInterval = '60s';

    protected function getStats(): array
    {
        $warehouseId = Auth::user()->warehouse_id;

        $containers = Container::where('warehouse_id', $warehouseId)->where('is_unloaded', false)->count();
        $unverified = Invoice::where('warehouse_id', $warehouseId)->where('is_verified', false)->count();
        $waiting = Invoice::where('warehouse_id', $warehouseId)->where('is_verified', true)->where('wh_is_assigned', false)->count();
        $outgoing = Whdeliverylog::where('user_whid', $warehouseId)->where('is_active', true)->select('id');
        $toLoad = Whtripinvoice::whereIn('whdeliverylog_id', $outgoing)->where('is_loaded', false)->count();
        $incoming = Whtripinvoice::whereIn('whdeliverylog_id', Whdeliverylog::where('warehouse_id', $warehouseId)->select('id'))
            ->where('is_loaded', true)->where('is_unloaded', false)->count();

        return [
            Stat::make('Containers to unload', number_format($containers))
                ->description(number_format($unverified).' boxes not scanned yet')
                ->icon(Heroicon::OutlinedArchiveBoxArrowDown)
                ->color($containers ? 'warning' : 'success'),
            Stat::make('Waiting for a trip', number_format($waiting))
                ->description('Verified boxes in this warehouse')
                ->icon(Heroicon::OutlinedInboxStack),
            Stat::make('To load', number_format($toLoad))
                ->description('On outgoing trips, not on the truck yet')
                ->icon(Heroicon::OutlinedArrowUpTray)
                ->color($toLoad ? 'info' : 'gray'),
            Stat::make('Arriving', number_format($incoming))
                ->description('On trucks heading here')
                ->icon(Heroicon::OutlinedArrowDownTray)
                ->color($incoming ? 'info' : 'gray'),
        ];
    }
}
