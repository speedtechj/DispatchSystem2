<?php

namespace App\Filament\Warehouse\Resources\Inventories\Widgets;

use App\Models\Inventory;
use App\Models\Whtripinvoice;
use Filament\Widgets\StatsOverviewWidget;
use Filament\Widgets\StatsOverviewWidget\Stat;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Reactive;

class InventoryAllWidget extends StatsOverviewWidget
{
    #[Reactive]
    public array $provinces = [];

    protected ?string $heading = 'Warehouse Inventory Overview';

    protected static bool $isLazy = false;

    protected function getStats(): array
    {
        $query = Inventory::onFloor(Auth::user()->warehouse_id);

        if (! empty($this->provinces)) {
            $query->whereIn('receiver_province', $this->provinces);
        }

        // Loaded on a warehouse truck coming here, not unloaded yet: not counted until unloaded.
        $incoming = Whtripinvoice::query()
            ->whereHas('whdeliverylog', fn ($trip) => $trip->where('warehouse_id', Auth::user()->warehouse_id))
            ->where('is_loaded', true)
            ->where('is_unloaded', false)
            ->count();

        return [
            Stat::make('Total Boxes on Floor', number_format($query->count()))
                ->description('Unloaded here, not on a truck yet')
                ->color('success'),
            Stat::make('On the way here', number_format($incoming))
                ->description('Counted once you unload them')
                ->color('gray'),
        ];
    }
}
