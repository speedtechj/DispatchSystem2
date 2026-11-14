<?php

namespace App\Filament\Warehouse\Resources\Deliverylogs\Pages;

use App\Filament\Warehouse\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Filament\Resources\Pages\EditRecord;
use Illuminate\Support\Facades\DB;

class EditDeliverylog extends EditRecord
{
    protected static string $resource = DeliverylogResource::class;

    /** Truck on the trip before this save, so we only swap when it actually changed. */
    protected ?int $previousTruckId = null;

    public function getTitle(): string
    {
        return 'Trip '.$this->record->trip_number;
    }

    protected function getRedirectUrl(): string
    {
        return $this->getResource()::getUrl('index');
    }

    protected function beforeSave(): void
    {
        $this->previousTruckId = $this->record->getOriginal('truck_id');
    }

    protected function afterSave(): void
    {
        DB::transaction(function (): void {
            app(TripAssignment::class)->swapTruck($this->previousTruckId, $this->record->truck_id);

            // Boxes on this trip now go to the (possibly new) destination hub.
            Tripinvoice::where('deliverylog_id', $this->record->id)
                ->update(['logistichub_id' => $this->record->assigned_to]);
        });
    }
}
