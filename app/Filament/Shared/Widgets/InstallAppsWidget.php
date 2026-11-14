<?php

namespace App\Filament\Shared\Widgets;

use App\Support\InstallLinks;
use Filament\Widgets\Widget;
use Illuminate\Support\Facades\Auth;

/** Dashboard card: install the Scan app and the Driver app with a QR code. Each person can hide it. */
abstract class InstallAppsWidget extends Widget
{
    protected string $view = 'filament.widgets.install-apps';

    protected int|string|array $columnSpan = 'full';

    protected static ?int $sort = 50;

    protected static bool $isLazy = false;

    public static function canView(): bool
    {
        return ! InstallLinks::hiddenFor(Auth::user());
    }

    public function hide(): void
    {
        InstallLinks::hideFor(Auth::user());
        $this->redirect(request()->header('Referer') ?: url()->current(), navigate: false);
    }
}
