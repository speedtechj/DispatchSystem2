<?php

namespace App\Support;

use App\Filament\Company\Pages\LoadTruck as HubLoadTruck;
use App\Filament\Company\Pages\ReturnBoxes as HubReturnBoxesCompany;
use App\Filament\Pages\ReturnBoxes as AdminReturnBoxes;
use App\Filament\Pages\Scaninvoice as AdminUnload;
use App\Filament\Pages\Scanload as AdminLoad;
use App\Filament\Warehouse\Pages\Hubloaded as WarehouseLoad;
use App\Filament\Warehouse\Pages\HubReturnBoxes as WarehouseReturn;
use App\Filament\Warehouse\Pages\Unloadedcontainer as WarehouseUnload;
use App\Filament\Warehouse\Pages\Whloaded;
use App\Filament\Warehouse\Pages\Whunloaded;
use App\Filament\Shared\Shipping\PortCheckStation;
use App\Filament\Shared\Shipping\ReceiveShipmentStation;
use App\Models\User;

/**
 * Which scans a person gets in the Scan app, from the account type set on the user.
 * Each scan reuses an existing scan page (its rules, limits and photo step) behind the scenes.
 */
class ScanModes
{
    /** @return array<string, array{label: string, sub: string, icon: string, class: class-string, field: string, kind: string, ok: string, done: string}> */
    public static function for(?User $user): array
    {
        $code = $user?->panelcategory?->code;

        $unload = ['label' => 'Unload container', 'sub' => 'Boxes off the ship container', 'icon' => 'container', 'field' => 'container_id', 'kind' => 'container', 'ok' => 'Verified · off the container', 'done' => 'Container unloaded'];
        $load = ['label' => 'Load truck', 'sub' => 'Onto a delivery trip', 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Loaded on the truck', 'done' => 'Truck loaded'];
        $return = ['label' => 'Return boxes', 'sub' => 'Not delivered, back in', 'icon' => 'return', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Returned to inventory', 'done' => 'Returns done'];
        $sea = \App\Support\Shipping\Shipments::ready();
        $port = ['label' => 'Port check', 'sub' => 'Boxes handed over at the port', 'icon' => 'out', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Handed over at the port', 'done' => 'Port check done', 'class' => PortCheckStation::class];
        $count = ['label' => 'Count a section', 'sub' => 'Check a section, move boxes into it', 'icon' => 'container', 'field' => 'wh_section_id', 'kind' => 'section', 'ok' => 'Counted', 'done' => 'Section counted', 'class' => \App\Filament\Shared\SectionCountStation::class];
        $retReceive = ['label' => 'Receive returns', 'sub' => 'Boxes coming back from a hub', 'icon' => 'in', 'field' => 'return_shipment_id', 'kind' => 'return shipment', 'ok' => 'Back at the warehouse', 'done' => 'Returns received', 'class' => \App\Filament\Shared\Shipping\ReturnReceiveStation::class];
        $receive = ['label' => 'Receive container', 'sub' => 'Sea shipment arriving at your hub', 'icon' => 'in', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Received at your hub', 'done' => 'Container received', 'class' => ReceiveShipmentStation::class];

        return match ($code) {
            'whse' => [
                'unload' => $unload + ['class' => WarehouseUnload::class],
                'load' => $load + ['class' => WarehouseLoad::class],
                'wh_load' => ['label' => 'Warehouse load', 'sub' => 'To another warehouse', 'icon' => 'out', 'field' => 'deliverylog_id', 'kind' => 'transfer trip', 'ok' => 'Loaded for the transfer', 'done' => 'Transfer loaded', 'class' => Whloaded::class],
                'wh_unload' => ['label' => 'Warehouse unload', 'sub' => 'Arriving from another warehouse', 'icon' => 'in', 'field' => 'deliverylog_id', 'kind' => 'arriving transfer', 'ok' => 'Received · added to inventory', 'done' => 'Transfer received', 'class' => Whunloaded::class],
                'return' => $return + ['class' => WarehouseReturn::class],
            ] + ($sea ? ['port' => $port] : []) + (\App\Support\Shipping\Returns::ready() ? ['ret_receive' => $retReceive] : []) + (\App\Support\Boxes\SectionCount::ready() && \App\Support\Boxes\Sections::used($user?->warehouse_id) ? ['count' => $count] : []),
            'co' => [
                'hub_load' => ['label' => 'Hub load', 'sub' => "Onto your hub's own trucks", 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'hub trip', 'ok' => 'Loaded on the hub truck', 'done' => 'Hub truck loaded', 'class' => HubLoadTruck::class],
                'return' => $return + ['class' => HubReturnBoxesCompany::class, 'ok' => 'Back at your hub'],
            ] + ($sea ? ['ship_receive' => $receive] : []),
            'adm' => [
                'unload' => $unload + ['class' => AdminUnload::class],
                'load' => $load + ['class' => AdminLoad::class],
                'return' => $return + ['class' => AdminReturnBoxes::class],
            ] + ($sea ? ['port' => $port] : []),
            default => [],
        };
    }

    /** "Calgary Warehouse" or "Cebu Partner Hub" for the top of the app. */
    public static function place(?User $user): string
    {
        return match ($user?->panelcategory?->code) {
            'whse' => $user->warehouse?->name ?? 'Warehouse',
            'co' => $user->logistichub?->hub_name ?? 'Partner hub',
            'adm' => $user->logistichub?->hub_name ?? 'Main office',
            default => '',
        };
    }
}
