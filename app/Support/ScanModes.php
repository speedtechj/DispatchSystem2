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
        $pick = \App\Support\Trips\Picking::ready() ? ['pick' => ['label' => 'Pick boxes', 'sub' => 'From the sections, before Load truck', 'icon' => 'pick', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Picked', 'done' => 'All boxes picked', 'class' => \App\Filament\Shared\PickStation::class]] : [];
        $receive = ['label' => 'Receive container', 'sub' => 'Sea shipment arriving at your hub', 'icon' => 'in', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Received at your hub', 'done' => 'Container received', 'class' => ReceiveShipmentStation::class];

        return match ($code) {
            'whse' => [
                'unload' => $unload + ['class' => WarehouseUnload::class],
            ] + $pick + [
                'load' => $load + ['class' => WarehouseLoad::class],
                'wh_load' => ['label' => 'Warehouse load', 'sub' => 'To another warehouse', 'icon' => 'out', 'field' => 'deliverylog_id', 'kind' => 'transfer trip', 'ok' => 'Loaded for the transfer', 'done' => 'Transfer loaded', 'class' => Whloaded::class],
                'wh_unload' => ['label' => 'Warehouse unload', 'sub' => 'Arriving from another warehouse', 'icon' => 'in', 'field' => 'deliverylog_id', 'kind' => 'arriving transfer', 'ok' => 'Received · added to inventory', 'done' => 'Transfer received', 'class' => Whunloaded::class],
                'return' => $return + ['class' => WarehouseReturn::class],
            ] + ($sea ? ['port' => $port] : []) + (\App\Support\Shipping\Returns::ready() ? ['ret_receive' => $retReceive] : []) + (\App\Support\Boxes\SectionCount::ready() && \App\Support\Boxes\Sections::used($user?->warehouse_id) ? ['count' => $count] : []),
            'co' => $pick + [
                'hub_load' => ['label' => 'Hub load', 'sub' => "Onto your hub's own trucks", 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'hub trip', 'ok' => 'Loaded on the hub truck', 'done' => 'Hub truck loaded', 'class' => HubLoadTruck::class],
                'return' => $return + ['class' => HubReturnBoxesCompany::class, 'ok' => 'Back at your hub'],
            ] + static::hubReceive($user, $sea, $receive),
            'adm' => [
                'unload' => $unload + ['class' => AdminUnload::class],
                'load' => $load + ['class' => AdminLoad::class],
                'return' => $return + ['class' => AdminReturnBoxes::class],
            ] + ($sea ? ['port' => $port] : []),
            default => [],
        };
    }

    /**
     * Start screen (board 54): the group and colour of each scan's tile.
     *
     * @return array{group: string, color: string}
     */
    public static function look(string $key): array
    {
        $group = match ($key) {
            'wh_load', 'wh_unload' => 'Between warehouses',
            'port', 'ret_receive' => 'Port and hubs',
            'count' => 'In the warehouse',
            default => 'Daily work',
        };
        $color = match ($key) {
            'unload', 'ship_receive' => '#f6be00',
            'pick' => '#2ec4b6',
            'load', 'hub_load' => '#5aa8ff',
            'return' => '#f0a93b',
            'wh_load', 'wh_unload' => '#a78bfa',
            'port', 'truck_receive' => '#38bdf8',
            'ret_receive' => '#fb7185',
            'count' => '#34c38f',
            default => '#9fb0bc',
        };

        return ['group' => $group, 'color' => $color];
    }

    /**
     * Camera settings of the Scan app and the Driver app (board 51): the box stickers and receipts are Code 39,
     * section and spot labels are QR. A number counts when it is read twice the same; no scan for 2 minutes turns
     * the camera off; after 3 s of unclear reads the crew can type the number.
     */
    public static function scanner(string $method = 'scan', int $cooldown = 2500): array
    {
        return ['method' => $method, 'formats' => ['code_39', 'qr_code'], 'autoStart' => true, 'continuous' => true, 'cooldown' => $cooldown, 'beep' => true,
            'confirm' => 2, 'idleOff' => 120000, 'hardAfter' => 3000, 'startDelay' => 0];
    }

    /**
     * Partner hub: Receive container for hubs reached by sea, Receive truck for hubs reached by truck
     * (Settings · Hubs · island & sea). The other one shows only while something is arriving that way.
     */
    protected static function hubReceive(?User $user, bool $sea, array $receive): array
    {
        $hubId = (int) $user?->logistichub_id;
        $bySea = \App\Support\Shipping\Islands::ready() && $hubId ? (bool) \App\Models\Logistichub::whereKey($hubId)->value('by_sea') : null;
        $out = [];
        if ($sea && ($bySea !== false || \App\Models\Shipping\SeaShipment::whereIn('status', ['sailed', 'arrived', 'picked_up'])->where(fn ($q) => $q->where('logistichub_id', $hubId)
            ->when(\App\Support\Shipping\Shipments::stopsReady(), fn ($q) => $q->orWhereIn('id', \App\Models\Shipping\SeaShipmentStop::where('logistichub_id', $hubId)->whereNull('received_at')->select('sea_shipment_id'))))->exists())) {
            $out['ship_receive'] = $receive;
        }
        if (\App\Support\Shipping\TruckReceive::ready() && ($bySea !== true || \App\Support\Shipping\TruckReceive::trips($hubId)->isNotEmpty())) {
            $out['truck_receive'] = ['label' => 'Receive truck', 'sub' => 'Boxes from Manila arriving by truck', 'icon' => 'in', 'field' => 'deliverylog_id', 'kind' => 'truck',
                'ok' => 'Received at your hub', 'done' => 'Truck received', 'class' => \App\Filament\Shared\Shipping\TruckReceiveStation::class];
        }

        return $out;
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
