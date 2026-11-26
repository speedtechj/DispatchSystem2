<?php

namespace App\Filament\Delivery\Resources\Invoices\Pages;

use App\Filament\Delivery\Resources\Invoices\InvoiceResource;
use App\Filament\Delivery\Resources\Invoices\Tables\InvoicesTable;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\InvoiceLookup;
use Filament\Actions\Action;
use Filament\Actions\CreateAction;
use Filament\Forms\Components\FileUpload;
use Filament\Notifications\Notification;
use Filament\Resources\Pages\ListRecords;
use Filament\Support\Icons\Heroicon;
use Livewire\Attributes\Locked;

class ListInvoices extends ListRecords
{
    protected static string $resource = InvoiceResource::class;

    // The Tripinvoice found by the scanner
    #[Locked]
    public ?int $scannedTripId = null;

    protected function getHeaderActions(): array
    {
        return [
            Action::make('scanBarcode')
                ->label('Scan barcode')
                ->icon('heroicon-o-qr-code')
                ->color('gray')
                ->modalHeading('Scan box barcode')
                ->modalWidth('lg')
                ->modalContent(view('filament.modals.scan-invoice'))
                ->modalSubmitAction(false)
                ->modalCancelActionLabel('Close'),

            //    CreateAction::make(),
        ];
    }

    /**
     * Called by the scanner in the "Scan barcode" modal.
     */
    public function openScannedInvoice(string $code): void
    {
        $deliveryId = InvoicesTable::currentDeliveryId();
        $code = InvoiceLookup::normalize($code);

        // Only boxes loaded on the driver's own current trip can be delivered from here.
        $trip = $deliveryId
            ? Tripinvoice::query()
                ->where('invoice', $code)
                ->whereIn('invoice', InvoicesTable::tripInvoiceNumbers($deliveryId))
                ->where(fn ($query) => $query->where('deliverylog_id', $deliveryId)->orWhere('deliveryloghub_id', $deliveryId))
                ->latest('id')
                ->first()
            : null;

        if (! $trip) {
            Notification::make()
                ->title('No invoice found')
                ->body('“'.$code.'” is not on your current trip.')
                ->danger()
                ->send();

            return;
        }

        $this->scannedTripId = $trip->getKey();

        // Close the scanner modal and open the upload picture modal
        $this->replaceMountedAction('uploadPicture');
    }

    protected function scannedTrip(): ?Tripinvoice
    {
        $deliveryId = InvoicesTable::currentDeliveryId();

        return $this->scannedTripId && $deliveryId
            ? Tripinvoice::with('invdata')
                ->where(fn ($query) => $query->where('deliverylog_id', $deliveryId)->orWhere('deliveryloghub_id', $deliveryId))
                ->find($this->scannedTripId)
            : null;
    }

    /**
     * Upload delivery picture modal (opened after a successful scan).
     */
    public function uploadPictureAction(): Action
    {
        return Action::make('uploadPicture')
            ->modalIcon(Heroicon::Camera)
            ->modalWidth('lg')
            ->modalHeading(function () {
                $trip = $this->scannedTrip();
                $number = ucwords((string) ($trip?->invdata?->invoice ?? $trip?->invoice));

                return $trip?->is_delivered
                    ? "Invoice {$number} — already delivered"
                    : "Deliver invoice {$number}";
            })
            ->modalDescription(function () {
                $data = $this->scannedTrip()?->invdata;

                return $data
                    ? ucwords(trim(($data->receiver_name ?? '').' — '.($data->receiver_province ?? ''), ' —'))
                    : null;
            })
            ->modalSubmitActionLabel(fn () => $this->scannedTrip()?->is_delivered ? 'Update pictures' : 'Mark as delivered')
            ->fillForm(fn (): array => [
                'delivery_picture' => $this->scannedTrip()?->delivery_picture,
            ])
            ->schema([
                FileUpload::make('delivery_picture')
                    ->label('Delivery Picture')
                    ->multiple()
                    ->panelLayout('grid')
                    ->uploadingMessage('Uploading ...')
                    ->image()
                    ->openable()
                    ->disk('public')
                    ->directory(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('delivery', $this->scannedTrip()?->invoice))
                    ->visibility('private')
                    ->required()
                    ->removeUploadedFileButtonPosition('right'),
            ])
            ->action(function (array $data): void {
                $trip = $this->scannedTrip();

                if (! $trip) {
                    Notification::make()->title('Invoice not found')->danger()->send();

                    return;
                }

                app(TripAssignment::class)->markDelivered($trip, (array) $data['delivery_picture']);

                Notification::make()
                    ->title('Invoice '.ucwords((string) ($trip->invdata?->invoice ?? $trip->invoice)).' delivered')
                    ->success()
                    ->send();

                $this->scannedTripId = null;
            });
    }
}
