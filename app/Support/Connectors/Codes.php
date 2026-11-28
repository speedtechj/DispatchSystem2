<?php

namespace App\Support\Connectors;

use App\Models\Logistichub;
use App\Models\Warehouse;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * The events Dispatch System sends (docs/PROTOCOL.md of the connector). The
 * list is ours; each consolidator maps every one to their own status.
 */
class Codes
{
    /**
     * code => [label, group, place kind, when it is sent]
     * place kind: warehouse | hub | partner | island | null (no place)
     * when: hold (10-minute hold) | trip (when the trip leaves) | now
     */
    public const ALL = [
        'ds.unloaded' => ['Unload container', 'Warehouse', 'warehouse', 'hold'],
        'ds.transfer' => ['Transfer to warehouse / hub', 'Warehouse', 'hub', 'hold'],
        'ds.return_to_warehouse' => ['Return to warehouse', 'Warehouse', 'warehouse', 'hold'],
        'ds.to_port' => ['Sea shipment · to port', 'Sea shipment', 'island', 'hold'],
        'ds.sailing' => ['Sea shipment · sailing', 'Sea shipment', 'island', 'now'],
        'ds.arrived_port' => ['Sea shipment · arrived', 'Sea shipment', 'island', 'now'],
        'ds.partner_hub' => ['Arrived at partner hub', 'Partner hub', 'partner', 'hold'],
        'ds.load.1' => ['Load on truck · 1st try', 'Delivery', null, 'trip'],
        'ds.load.2' => ['Load on truck · 2nd try', 'Delivery', null, 'trip'],
        'ds.load.3' => ['Load on truck · 3rd try', 'Delivery', null, 'trip'],
        'ds.back_to_hub.2' => ['Not delivered · back to hub (2nd try next)', 'Delivery', null, 'hold'],
        'ds.back_to_hub.3' => ['Not delivered · back to hub (3rd try next)', 'Delivery', null, 'hold'],
        'ds.waiting_next_try' => ['Waiting at hub for next try', 'Delivery', null, 'hold'],
        'ds.delivered' => ['Delivered', 'Delivery', null, 'hold'],
        'ds.delivered_damaged' => ['Delivered · damaged (signed)', 'Delivery', null, 'hold'],
        'ds.correction' => ['Correction (rarely used: an undo when nothing was sent before)', 'Other', null, 'now'],
    ];

    /**
     * Dispatch System's standard status names (board 85): written for the customer,
     * the same at every consolidator. "Add our standard statuses" adds the missing ones.
     * Delivered · damaged is plain "Delivered" for the customer.
     */
    public const STANDARD = [
        'ds.unloaded' => 'Arrived at Philippine Warehouse',
        'ds.transfer' => 'In transit to provincial hub',
        'ds.return_to_warehouse' => 'Returned to warehouse',
        'ds.to_port' => 'Preparing for inter-island shipment',
        'ds.sailing' => 'Shipped to island (in transit by sea)',
        'ds.arrived_port' => 'Arrived at island port',
        'ds.partner_hub' => 'Arrived at local hub',
        'ds.load.1' => 'Out for delivery',
        'ds.load.2' => 'Out for delivery (2nd attempt)',
        'ds.load.3' => 'Out for delivery (3rd attempt)',
        'ds.back_to_hub.2' => 'Delivery rescheduled',
        'ds.back_to_hub.3' => 'Delivery rescheduled',
        'ds.waiting_next_try' => 'Waiting for next delivery schedule',
        'ds.delivered' => 'Delivered',
        'ds.delivered_damaged' => 'Delivered',
    ];

    public static function label(string $code, ?string $place = null): string
    {
        $l = static::ALL[$code][0] ?? $code;

        return $place ? $l.' · '.$place : $l;
    }

    public static function when(string $code): string
    {
        return static::ALL[$code][3] ?? 'hold';
    }

    /** The mapping key the connector uses: code, or code@place (place in lower case, spaces → _). */
    public static function key(string $code, ?string $place): string
    {
        $slug = $place === null ? '' : Str::slug($place, '_');

        return $slug === '' || $slug === 'any' ? $code : $code.'@'.$slug;
    }

    /** Places for a place kind (the rows of the mapping table). @return list<string> */
    public static function places(?string $kind): array
    {
        static $memo = [], $app = null;
        if ($kind === null) {
            return [];
        }
        if ($app !== spl_object_id(app())) { // a new app (worker restart, test) reads them again
            [$memo, $app] = [[], spl_object_id(app())];
        }

        return $memo[$kind] ??= match ($kind) {
            'warehouse' => Warehouse::query()->orderBy('name')->pluck('name')->filter()->values()->all(),
            'hub' => array_values(array_unique(array_merge(
                Warehouse::query()->orderBy('name')->pluck('name')->filter()->all(),
                Logistichub::query()->where('is_company', false)->orderBy('hub_name')->pluck('hub_name')->filter()->all(),
            ))),
            'partner' => Logistichub::query()->where('is_company', true)->orderBy('hub_name')->pluck('hub_name')->filter()->values()->all(),
            'island' => Schema::hasColumn('logistichubs', 'island')
                ? Logistichub::query()->whereNotNull('island')->distinct()->orderBy('island')->pluck('island')->map(fn ($i) => Str::title((string) $i))->filter()->values()->all()
                : [],
            default => [],
        };
    }

    /**
     * Every row of the mapping table: one "any place" row per code, plus one per place.
     *
     * @return list<array{key: string, code: string, place: ?string, label: string, group: string}>
     */
    public static function rows(): array
    {
        $rows = [];
        foreach (static::ALL as $code => [$label, $group, $kind]) {
            foreach (static::places($kind) as $p) {
                $rows[] = ['key' => static::key($code, $p), 'code' => $code, 'place' => $p, 'label' => $label, 'group' => $group];
            }
            $rows[] = ['key' => $code, 'code' => $code, 'place' => null, 'label' => $label, 'group' => $group];
        }

        return $rows;
    }
}
