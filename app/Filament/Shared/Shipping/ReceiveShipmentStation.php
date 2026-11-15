<?php

namespace App\Filament\Shared\Shipping;

use App\Models\Shipping\SeaShipment;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;

/** Scan app · Receive container: the partner hub scans every box of an arriving shipment. */
class ReceiveShipmentStation extends ShipmentScanStation
{
    protected static string $step = 'received';

    protected static bool $shouldRegisterNavigation = false;

    protected function shipments(): Builder
    {
        return SeaShipment::query()->with('hub:id,hub_name', 'trip:id,trip_number')
            ->where('logistichub_id', (int) Auth::user()?->logistichub_id)
            ->whereIn('status', ['sailed', 'arrived', 'picked_up']);
    }
}
