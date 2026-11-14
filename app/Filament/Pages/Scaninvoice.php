<?php

namespace App\Filament\Pages;

use App\Filament\Shared\UnloadContainerPage;
use App\Models\Container;
use BackedEnum;
use BezhanSalleh\FilamentShield\Traits\HasPageShield;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use UnitEnum;

/** Unload a container at the main hub and verify every box against the manifest. */
class Scaninvoice extends UnloadContainerPage
{
    use HasPageShield;

    protected static ?string $navigationLabel = 'Unload Container';

    protected static ?string $title = 'Unload Container';

    protected static string|UnitEnum|null $navigationGroup = 'Scanning';

    protected static ?int $navigationSort = 1;

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedArchiveBoxArrowDown;

    protected function containerQuery(): Builder
    {
        return Container::query()->where('is_unloaded', false);
    }
}
