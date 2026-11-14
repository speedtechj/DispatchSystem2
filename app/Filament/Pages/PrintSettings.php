<?php

namespace App\Filament\Pages;

use App\Http\Controllers\InvoiceController;
use App\Models\AppSetting;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Admin → Settings → Printing: how many receipts one bulk print may hold. */
class PrintSettings extends Page
{
    protected string $view = 'filament.pages.print-settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedPrinter;

    protected static ?string $navigationLabel = 'Printing';

    protected static ?string $title = 'Printing';

    protected static ?string $slug = 'print-settings';

    public int $bulkLimit = 15;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        $this->bulkLimit = InvoiceController::bulkLimit();
    }

    public function save(): void
    {
        $this->validate(['bulkLimit' => 'required|integer|min:1|max:100'], [
            'bulkLimit.max' => 'At most 100: bigger PDFs take long to make and can time out.',
        ]);
        AppSetting::put('print.bulk_limit', $this->bulkLimit);
        Notification::make()->title("Bulk print now allows up to {$this->bulkLimit} receipts")->success()->send();
    }
}
