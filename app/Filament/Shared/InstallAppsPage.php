<?php

namespace App\Filament\Shared;

use App\Support\InstallLinks;
use BackedEnum;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;

/** Warehouse and Partner hub: QR codes to install the Scan app and the Driver app. */
abstract class InstallAppsPage extends Page
{
    protected string $view = 'filament.shared.install-apps';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedQrCode;

    protected static ?string $navigationLabel = 'Install the apps';

    protected static ?string $title = 'Install the apps';

    protected static ?string $slug = 'install-apps';

    protected static ?int $navigationSort = 90;

    public function getSubheading(): ?string
    {
        return 'QR codes for your staff and drivers. Posters print with the name of '.InstallLinks::placeFor(auth()->user()).'.';
    }
}
