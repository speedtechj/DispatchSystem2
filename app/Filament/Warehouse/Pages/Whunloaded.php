<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\WarehouseTripScanPage;
use App\Models\Whdeliverylog;
use BackedEnum;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Receive boxes from a truck arriving at this warehouse. */
class Whunloaded extends WarehouseTripScanPage
{
    protected static bool $unloading = true;

    protected static ?string $navigationLabel = 'Unload Truck';

    protected static ?string $title = 'Unload Truck';

    protected static string|UnitEnum|null $navigationGroup = 'Warehouse';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowDownTray;

    protected function tripOptionsQuery(): Builder
    {
        return Whdeliverylog::query()->where('warehouse_id', Auth::user()->warehouse_id);
    }
}
