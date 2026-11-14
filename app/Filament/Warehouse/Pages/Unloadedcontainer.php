<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\UnloadContainerPage;
use App\Models\Container;
use BackedEnum;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Unload a container arriving at this warehouse. */
class Unloadedcontainer extends UnloadContainerPage
{
    protected static ?string $navigationLabel = 'Unload Container';

    protected static ?string $title = 'Unload Container';

    protected static string|UnitEnum|null $navigationGroup = 'Warehouse';

    protected static ?int $navigationSort = 1;

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedArchiveBoxArrowDown;

    protected function containerQuery(): Builder
    {
        return Container::query()->where('warehouse_id', Auth::user()->warehouse_id);
    }
}
