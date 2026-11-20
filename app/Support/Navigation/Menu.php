<?php

namespace App\Support\Navigation;

use App\Models\Shipping\WrongHubBox;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use App\Support\Trips\TripFill;
use Filament\Navigation\NavigationGroup;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;

/**
 * The side menu of the Admin, Warehouse and Partner hub panels, in one place:
 * the groups (in the order of the work of the day) and, per page, its group, name and place.
 * Pages not listed here keep their own group and name.
 */
class Menu
{
    /** Panel => [group name => folded at first]. */
    public const GROUPS = [
        'admin' => [
            'Boxes' => false, 'Trips & delivery' => false, 'Sea & partner hubs' => false, 'Money' => false,
            'AI helpers' => true, 'Scan on this computer' => false,
            'Settings · company & people' => true, 'Settings · places & routes' => true,
            'Settings · trucks & boxes' => true, 'Settings · messages & AI' => true, 'Help' => false,
        ],
        'warehouse' => [
            'Boxes' => false, 'Trips' => false, 'Sea & returns' => false, 'Scan on this computer' => false,
            'Trucks' => false, 'AI helpers' => true, 'Settings & help' => true,
        ],
        'company' => [
            'Coming in' => false, 'Delivery' => false, 'Returns' => false, 'Scan on this computer' => false,
            'Trucks & people' => false, 'AI helpers' => true, 'Settings & help' => true,
        ],
    ];

    /** Panel => [page or resource class (short, after the panel's namespace) => [group, name or null to keep, sort]]. */
    public const ITEMS = [
        'admin' => [
            'Resources\\ContainerResource' => ['Boxes', null, 1],
            'Resources\\Unmanifesteds\\UnmanifestedResource' => ['Boxes', null, 2],
            'Resources\\Inventories\\InventoryResource' => ['Boxes', 'Inventory', 3],
            'Pages\\WhereToUnload' => ['Boxes', null, 1],
            'Resources\\Boxsummaries\\BoxsummaryResource' => ['Boxes', 'Box summary', 4],
            'Resources\\Searchinvs\\SearchinvResource' => ['Boxes', 'Find a box', 5],
            'Resources\\Invoiceissues\\InvoiceissueResource' => ['Boxes', 'Box issues', 6],
            'Pages\\BoxPhotos' => ['Boxes', 'Box photos', 7],

            'Resources\\Deliverylogs\\DeliverylogResource' => ['Trips & delivery', 'Delivery trips', 1],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Trips & delivery', 'Delivery invoices', 2],
            'Pages\\PlanTrips' => ['Trips & delivery', null, 0],
            'Pages\\NewBoxes' => ['Trips & delivery', null, 0],
            'Pages\\AddressesToCheck' => ['Trips & delivery', null, 2],
            'Pages\\Overrides' => ['Trips & delivery', null, 2],
            'Pages\\WarehouseTransfers' => ['Trips & delivery', null, 2],
            'Pages\\CrewBoard' => ['Trips & delivery', null, 3],
            'Pages\\TruckTracking' => ['Trips & delivery', null, 4],
            'Pages\\TruckDay' => ['Trips & delivery', null, 5],

            'Pages\\SeaShipments' => ['Sea & partner hubs', null, 1],
            'Pages\\WrongHub' => ['Sea & partner hubs', null, 2],

            'Pages\\CostPerBox' => ['Money', null, 1],
            'Pages\\Fuel' => ['Money', null, 2],

            'Pages\\Scaninvoice' => ['Scan on this computer', 'Unload container', 1],
            'Pages\\Scanload' => ['Scan on this computer', 'Load truck', 2],
            'Pages\\ReturnBoxes' => ['Scan on this computer', 'Return boxes', 3],

            'Pages\\Companyinfo' => ['Settings · company & people', 'Company info', 1],
            'Pages\\AppIcons' => ['Settings · company & people', null, 2],
            'Pages\\PrintSettings' => ['Settings · company & people', null, 3],
            'Resources\\UserResource' => ['Settings · company & people', null, 4],
            '\\BezhanSalleh\\FilamentShield\\Resources\\Roles\\RoleResource' => ['Settings · company & people', null, 5],
            'Resources\\Workpositions\\WorkpositionResource' => ['Settings · company & people', 'Job positions', 6],
            'Resources\\PanelcategoryResource' => ['Settings · company & people', 'Account types', 7],

            'Resources\\Warehouses\\WarehouseResource' => ['Settings · places & routes', null, 1],
            'Pages\\WarehouseSections' => ['Settings · places & routes', null, 2],
            'Pages\\WarehouseCoverage' => ['Settings · places & routes', null, 2],
            'Pages\\HubAreas' => ['Settings · places & routes', null, 2],
            'Resources\\Logistichubs\\LogistichubResource' => ['Settings · places & routes', 'Logistic hubs', 3],
            'Pages\\HubIslands' => ['Settings · places & routes', null, 4],
            'Resources\\RouteareaResource' => ['Settings · places & routes', 'Route areas', 5],
            'Pages\\MapsRoutes' => ['Settings · places & routes', null, 6],

            'Pages\\Fleet' => ['Settings · trucks & boxes', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Settings · trucks & boxes', null, 1],
            'Resources\\Truckteams\\TruckteamResource' => ['Settings · trucks & boxes', 'Truck teams', 2],
            'Pages\\TrackingSettings' => ['Settings · trucks & boxes', 'Truck tracking settings', 3],
            'Pages\\FuelSettings' => ['Settings · trucks & boxes', 'Fuel settings', 4],
            'Pages\\BoxSizeSettings' => ['Settings · trucks & boxes', null, 5],
            'Pages\\TripRules' => ['Settings · trucks & boxes', null, 5],
            'Resources\\Boxissues\\BoxissueResource' => ['Settings · trucks & boxes', 'Box issue types', 6],
            'Pages\\BoxPhotoSettings' => ['Settings · trucks & boxes', 'Box photo settings', 7],
            'Pages\\AgingLimits' => ['Settings · trucks & boxes', null, 8],
            'Resources\\ConsolidatorResource' => ['Settings · trucks & boxes', null, 9],
            'Resources\\CompanyResource' => ['Settings · trucks & boxes', 'Agents', 10],

            'Pages\\SmsSettings' => ['Settings · messages & AI', null, 1],
            'Pages\\SmsLog' => ['Settings · messages & AI', null, 2],
            'Pages\\AiSettings' => ['Settings · messages & AI', 'AI settings', 3],
            'Pages\\AddressAi' => ['Settings · messages & AI', null, 4],
            'Resources\\HelpGuides\\HelpGuideResource' => ['Settings · messages & AI', 'Help guides (edit)', 4],

            'Pages\\HelpGuide' => ['Help', null, 1],
        ],
        'warehouse' => [
            'Resources\\Containers\\ContainerResource' => ['Boxes', null, 1],
            'Resources\\Inventories\\InventoryResource' => ['Boxes', 'Inventory', 2],
            'Pages\\Sections' => ['Boxes', null, 3],
            'Resources\\Searchinvs\\SearchinvResource' => ['Boxes', 'Find a box', 4],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Boxes', 'Delivery invoices', 5],
            'Resources\\Invoiceissues\\InvoiceissueResource' => ['Boxes', 'Box issues', 6],
            'Pages\\BoxPhotos' => ['Boxes', 'Box photos', 7],

            'Resources\\Deliverylogs\\DeliverylogResource' => ['Trips', 'Delivery trips', 1],
            'Resources\\Whdeliverylogs\\WhdeliverylogResource' => ['Trips', 'Transfers to other warehouses', 2],
            'Pages\\PlanTrips' => ['Trips', null, 0],
            'Pages\\NewBoxes' => ['Trips', null, 0],
            'Pages\\AddressesToCheck' => ['Trips', null, 2],
            'Pages\\Overrides' => ['Trips', null, 2],
            'Pages\\WarehouseTransfers' => ['Trips', null, 2],
            'Pages\\CrewBoard' => ['Trips', null, 3],
            'Pages\\TruckTracking' => ['Trips', null, 3],
            'Pages\\TruckDay' => ['Trips', null, 4],
            'Pages\\Fuel' => ['Trips', null, 5],

            'Pages\\SeaShipments' => ['Sea & returns', null, 1],
            'Pages\\ComingBack' => ['Sea & returns', null, 2],

            'Pages\\Unloadedcontainer' => ['Scan on this computer', 'Unload container', 1],
            'Pages\\Hubloaded' => ['Scan on this computer', 'Load delivery truck', 2],
            'Pages\\HubReturnBoxes' => ['Scan on this computer', 'Return boxes', 3],
            'Pages\\Whloaded' => ['Scan on this computer', 'Load transfer truck', 4],
            'Pages\\Whunloaded' => ['Scan on this computer', 'Receive transfer truck', 5],

            'Pages\\Fleet' => ['Trucks', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Trucks', null, 2],
            'Resources\\Truckteams\\TruckteamResource' => ['Trucks', 'Truck teams', 2],

            'Pages\\MapsRoutes' => ['Settings & help', null, 1],
            'Pages\\WarehouseCoverage' => ['Settings & help', null, 1],
            'Pages\\InstallApps' => ['Settings & help', null, 2],
            'Pages\\HelpGuide' => ['Settings & help', null, 3],
        ],
        'company' => [
            'Pages\\IncomingShipments' => ['Coming in', null, 1],
            'Pages\\IncomingBoxes' => ['Coming in', null, 2],

            'Pages\\PlanTrips' => ['Delivery', null, 0],
            'Resources\\Deliverylogs\\DeliverylogResource' => ['Delivery', 'Delivery trips', 1],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Delivery', 'Delivery invoices', 2],
            'Pages\\NotDelivered' => ['Delivery', null, 3],
            'Pages\\AddressesToCheck' => ['Delivery', null, 3],
            'Pages\\TrackBox' => ['Delivery', null, 4],
            'Pages\\MyArea' => ['Settings & help', 'My area', 0],

            'Pages\\WrongHub' => ['Returns', null, 1],

            'Pages\\LoadTruck' => ['Scan on this computer', 'Load truck', 1],
            'Pages\\ReturnBoxes' => ['Scan on this computer', 'Return boxes', 2],

            'Pages\\Fleet' => ['Trucks & people', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Trucks & people', null, 2],
            'Pages\\CrewBoard' => ['Trucks & people', null, 2],
            'Pages\\HubDrivers' => ['Trucks & people', null, 2],
            'Resources\\DriverResource' => ['Trucks & people', 'Crew', 3],
            'Pages\\TruckTracking' => ['Trucks & people', null, 4],
            'Pages\\TruckDay' => ['Trucks & people', null, 5],
            'Pages\\Fuel' => ['Trucks & people', null, 6],

            'Pages\\BoxPhotos' => ['Settings & help', 'Box photos', 1],
            'Pages\\MapsRoutes' => ['Settings & help', null, 2],
            'Pages\\InstallApps' => ['Settings & help', null, 3],
            'Pages\\HelpGuide' => ['Settings & help', null, 4],
        ],
    ];

    /** Pages with a number of what waits: panel => [short class => counter]. */
    public const BADGES = [
        'admin' => ['Pages\\SeaShipments' => 'sea', 'Pages\\WrongHub' => 'wrongHub', 'Pages\\NewBoxes' => 'newBoxes'],
        'warehouse' => ['Pages\\SeaShipments' => 'sea', 'Pages\\ComingBack' => 'comingBack', 'Pages\\NewBoxes' => 'newBoxes'],
        'company' => ['Pages\\IncomingShipments' => 'sea', 'Pages\\WrongHub' => 'wrongHub'],
    ];

    protected const BASE = ['admin' => 'App\\Filament\\', 'warehouse' => 'App\\Filament\\Warehouse\\', 'company' => 'App\\Filament\\Company\\'];

    public static function has(?string $panel): bool
    {
        return isset(self::GROUPS[$panel ?? '']);
    }

    /** @return array<NavigationGroup> */
    public static function groups(string $panel): array
    {
        return collect(self::GROUPS[$panel] ?? [])
            ->map(fn (bool $folded, string $name) => NavigationGroup::make($name)->collapsible()->collapsed($folded))
            ->values()->all();
    }

    protected static function full(string $panel, string $short): string
    {
        return str_starts_with($short, '\\') ? ltrim($short, '\\') : self::BASE[$panel].$short;
    }

    /** @return array<class-string, array{0: string, 1: ?string, 2: int}> */
    public static function items(string $panel): array
    {
        return collect(self::ITEMS[$panel] ?? [])->mapWithKeys(fn ($v, $k) => [static::full($panel, $k) => $v])->all();
    }

    /** @return array<class-string, string> */
    public static function badges(string $panel): array
    {
        return collect(self::BADGES[$panel] ?? [])->mapWithKeys(fn ($v, $k) => [static::full($panel, $k) => $v])->all();
    }

    /** The number shown beside a page, kept for a minute; null when nothing waits. */
    public static function count(string $panel, string $counter): ?string
    {
        $user = Auth::user();
        if (! $user) {
            return null;
        }
        try {
            $n = Cache::remember("menu:{$panel}:{$user->getKey()}:{$counter}", 60, function () use ($panel, $user, $counter): int {
                if ($counter === 'newBoxes') {
                    // new boxes of cities that already have a trip (board 45b)
                    return (int) collect(TripFill::newBoxes($user))->sum('n');
                }
                if (! Shipments::ready()) {
                    return 0;
                }
                $hub = Tracker::hubFor($user, $panel);
                if ($hub === false) {
                    return 0;
                }

                return match ($counter) {
                    'sea' => Shipments::visible($hub)->where('status', '!=', 'received')->count(),
                    'wrongHub' => WrongHubBox::query()->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->where('status', 'waiting')->count(),
                    'comingBack' => WrongHubBox::query()->where('status', 'returning')->count(),
                    default => 0,
                };
            });
        } catch (\Throwable) {
            return null;
        }

        return $n > 0 ? (string) $n : null;
    }
}
