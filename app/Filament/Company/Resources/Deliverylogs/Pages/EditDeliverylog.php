<?php

namespace App\Filament\Company\Resources\Deliverylogs\Pages;

use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Shared\Trips\EditsTrip;
use Filament\Actions\DeleteAction;
use Filament\Notifications\Notification;
use Filament\Resources\Pages\EditRecord;

class EditDeliverylog extends EditRecord
{
    use EditsTrip;

    protected function isHubTrip(): bool
    {
        return true;
    }

    protected static string $resource = DeliverylogResource::class;

    protected function extraHeaderActions(): array
    {
        return [
            DeleteAction::make()->label('Delete trip')
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

    protected function getRedirectUrl(): string
    {
        return $this->getResource()::getUrl('index');
    }
}
