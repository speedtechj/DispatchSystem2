<?php

namespace App\Filament\Company\Resources\Deliverylogs\Pages;

use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use Filament\Actions\DeleteAction;
use Filament\Notifications\Notification;
use Filament\Resources\Pages\EditRecord;

class EditDeliverylog extends EditRecord
{
    protected static string $resource = DeliverylogResource::class;

    protected function getHeaderActions(): array
    {
        return [
            DeleteAction::make()
                ->before(function (DeleteAction $action): void {
                    $trip = $this->record;

                    if ($trip->tripinvoices()->exists() || $trip->hubTripinvoices()->exists()) {
                        Notification::make()
                            ->title('This trip still has invoices')
                            ->body('Remove its invoices first, then delete the trip.')
                            ->danger()
                            ->send();

                        $action->cancel();
                    }
                }),
        ];
    }

    public function getTitle(): string
    {

        return 'Edit'.' '.$this->record->trip_number;

    }
}
