<?php

namespace App\Filament\Shared\Shipping;

use App\Support\Shipping\Shipments;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;

/** Scan app · Port check: scan each box as it is handed over at the port (full scan shipments). */
class PortCheckStation extends ShipmentScanStation
{
    protected static string $step = 'port';

    protected static bool $shouldRegisterNavigation = false;

    protected function shipments(): Builder
    {
        $user = Auth::user();
        $hub = $user?->hasRole('super_admin') ? null : $user?->logistichub_id;

        return Shipments::visible($hub)->where('port_check', 'full')->whereIn('status', ['sealed', 'to_port', 'at_port']);
    }
}
