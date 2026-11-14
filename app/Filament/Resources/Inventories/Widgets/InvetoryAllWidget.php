<?php

namespace App\Filament\Resources\Inventories\Widgets;

use App\Models\Inventory;
use App\Models\Warehouse;
use Filament\Widgets\StatsOverviewWidget;
use Filament\Widgets\StatsOverviewWidget\Stat;
use Livewire\Attributes\Reactive;

/** Boxes on the floor: the total, then one card per warehouse. */
class InvetoryAllWidget extends StatsOverviewWidget
{
    protected ?string $heading = 'Inventory Overview';

    protected static bool $isLazy = false;

    #[Reactive]
    public array $provinces = [];

    public array $warehouses = [];

    protected function getStats(): array
    {
        $perWarehouse = Inventory::onFloor()
            ->when($this->provinces, fn ($query) => $query->whereIn('receiver_province', $this->provinces))
            ->selectRaw('warehouse_id, COUNT(*) as boxes')
            ->groupBy('warehouse_id')
            ->pluck('boxes', 'warehouse_id');

        $warehouses = Warehouse::query()
            ->when($this->warehouses, fn ($query) => $query->whereIn('id', $this->warehouses))
            ->orderBy('name')
            ->get(['id', 'name']);

        $stats = [
            Stat::make('Total Boxes on Floor', number_format($perWarehouse->sum()))
                ->description('In every warehouse, not loaded on a truck')
                ->color('danger'),
        ];

        foreach ($warehouses as $warehouse) {
            $stats[] = Stat::make($warehouse->name.' - Boxes on Floor', number_format($perWarehouse[$warehouse->id] ?? 0))
                ->color('success');
        }

        return $stats;
    }
}
