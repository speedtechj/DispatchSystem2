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
        $hub = (int) Auth::user()?->logistichub_id;

        // This hub's turn: its stop is not received, and every stop before it is (one container, more hubs).
        return SeaShipment::query()->with('hub:id,hub_name', 'trip:id,trip_number')
            ->whereIn('status', ['sailed', 'arrived', 'picked_up'])
            ->when(! \App\Support\Shipping\Shipments::stopsReady(), fn ($q) => $q->where('logistichub_id', $hub))
            ->when(\App\Support\Shipping\Shipments::stopsReady(), fn ($q) => $q->whereIn('id', \App\Models\Shipping\SeaShipmentStop::query()->from('sea_shipment_stops as mine')
                ->where('mine.logistichub_id', $hub)->whereNull('mine.received_at')
                ->whereNotExists(fn ($e) => $e->from('sea_shipment_stops as before')->whereColumn('before.sea_shipment_id', 'mine.sea_shipment_id')
                    ->whereColumn('before.stop', '<', 'mine.stop')->whereNull('before.received_at'))
                ->select('mine.sea_shipment_id')));
    }
}
