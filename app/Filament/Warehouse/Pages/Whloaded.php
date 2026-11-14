<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\WarehouseTripScanPage;
use App\Models\Whdeliverylog;
use BackedEnum;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Load boxes onto a truck leaving this warehouse. */
class Whloaded extends WarehouseTripScanPage
{
    protected static ?string $navigationLabel = 'Load Truck';

    protected static ?string $title = 'Load Truck';

    protected static string|UnitEnum|null $navigationGroup = 'Warehouse';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUpTray;

    protected function tripOptionsQuery(): Builder
    {
        return Whdeliverylog::query()
            ->where('user_whid', Auth::user()->warehouse_id)
            ->where('is_active', true);
    }
}
