<?php

namespace App\Filament\Actions;

use App\Http\Controllers\InvoiceController;
use Filament\Actions\BulkAction;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Collection;

/** "Print selected": the delivery receipts of the ticked boxes in one PDF (at most the number set in Settings → Printing). */
class BulkPrintReceipts
{
    public static function make(): BulkAction
    {
        return BulkAction::make('printSelected')
            ->label(fn () => 'Print selected (max '.InvoiceController::bulkLimit().')')
            ->icon(Heroicon::OutlinedPrinter)
            ->color('primary')
            ->action(function (Collection $records, $livewire): void {
                $max = InvoiceController::bulkLimit();
                $ids = $records->pluck('invoice_id')->filter()->unique()->values();
                if ($ids->isEmpty()) {
                    return;
                }
                if ($ids->count() > $max) {
                    Notification::make()
                        ->title("You selected {$ids->count()} boxes")
                        ->body("Print at most {$max} at a time. Untick some and try again.")
                        ->warning()->send();

                    return;
                }
                $url = route('invoicepdf.bulk', ['ids' => $ids->join(',')]);
                $livewire->js('window.open('.json_encode($url).', "_blank")');
            })
            ->deselectRecordsAfterCompletion();
    }
}
