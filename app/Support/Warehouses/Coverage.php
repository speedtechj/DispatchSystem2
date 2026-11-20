<?php

namespace App\Support\Warehouses;

use App\Models\Invoice;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Warehouses\CoverageRequest;
use App\Models\Warehouses\WarehouseCoverage;
use App\Support\Boxes\Sections;
use App\Support\Maps\Barangays;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Which warehouse delivers each province. A province has one warehouse; town exceptions win;
 * every other province belongs to the default warehouse. Nothing changes until coverage is set.
 */
class Coverage
{
    protected static ?array $memo = null;

    public static function ready(): bool
    {
        return Schema::hasTable('warehouse_coverages');
    }

    public static function forget(): void
    {
        static::$memo = null;
    }

    /** @return array{provinces: array<string,int>, towns: array<string,int>, default: ?int} */
    protected static function map(): array
    {
        if (static::$memo !== null) {
            return static::$memo;
        }
        if (! static::ready()) {
            return static::$memo = ['provinces' => [], 'towns' => [], 'default' => null];
        }
        $rows = WarehouseCoverage::all();

        return static::$memo = [
            'provinces' => $rows->whereNull('city_key')->mapWithKeys(fn ($r) => [$r->province_key => (int) $r->warehouse_id])->all(),
            'towns' => $rows->whereNotNull('city_key')->mapWithKeys(fn ($r) => [$r->province_key.'|'.$r->city_key => (int) $r->warehouse_id])->all(),
            'default' => static::defaultId(),
        ];
    }

    /** Coverage is in use once any province or town is set. */
    public static function active(): bool
    {
        $m = static::map();

        return $m['provinces'] !== [] || $m['towns'] !== [];
    }

    public static function defaultId(): ?int
    {
        if (! Schema::hasTable('warehouses')) {
            return null;
        }
        $q = Warehouse::query();

        return (Schema::hasColumn('warehouses', 'is_default') ? (clone $q)->where('is_default', true)->value('id') : null) ?? $q->orderBy('id')->value('id');
    }

    public static function key(?string $province): string
    {
        return Sections::clean($province);
    }

    /** The warehouse that delivers this place (null when coverage is not used). */
    public static function homeOf(?string $province, ?string $city = null): ?int
    {
        if (! static::active()) {
            return null;
        }
        $m = static::map();
        $pk = static::key($province);
        $ck = Barangays::cityKey($city);

        return $m['towns'][$pk.'|'.$ck] ?? $m['provinces'][$pk] ?? $m['default'];
    }

    public static function home(?Invoice $i): ?int
    {
        return $i ? static::homeOf($i->receiver_province, $i->receiver_city) : null;
    }

    /** The box is at the wrong warehouse: it must be transferred to its home. */
    public static function transferTo(?Invoice $i, ?int $here): ?int
    {
        $home = static::home($i);

        return $home && $here && $home !== (int) $here ? $home : null;
    }

    public static function name(?int $warehouseId): string
    {
        return $warehouseId ? (string) (Warehouse::find($warehouseId)?->name ?? 'warehouse #'.$warehouseId) : '';
    }

    /** Provinces seen in the manifests, for the add list. */
    public static function knownProvinces(): array
    {
        return DB::table('invoices')->where('receiver_province', '!=', '')->distinct()->limit(3000)->pluck('receiver_province')
            ->map(fn ($p) => Str::title(static::key($p)))->filter()->unique()->sort()->values()->all();
    }

    public static function log(?int $warehouseId, string $text, ?User $by): void
    {
        DB::table('coverage_log')->insert(['warehouse_id' => $warehouseId, 'text' => Str::limit($text, 195), 'user_id' => $by?->id, 'created_at' => now(), 'updated_at' => now()]);
    }

    /**
     * Give a province (or a town of it) to a warehouse.
     *
     * @return array{ok: bool, owner: ?int} owner = the warehouse that has it now (when not ok)
     */
    public static function add(int $warehouseId, string $province, ?string $city, ?User $by, bool $force = false): array
    {
        $pk = static::key($province);
        if ($pk === '') {
            return ['ok' => false, 'owner' => null];
        }
        $ck = filled($city) ? Barangays::cityKey($city) : null;
        $existing = WarehouseCoverage::where('province_key', $pk)->where(fn ($q) => $ck ? $q->where('city_key', $ck) : $q->whereNull('city_key'))->first();
        if ($existing && (int) $existing->warehouse_id === $warehouseId) {
            return ['ok' => true, 'owner' => $warehouseId];
        }
        // a province belongs to someone else (explicitly, or as the default warehouse's): ask first
        $owner = $existing?->warehouse_id ?? (! $ck && static::active() && static::defaultId() !== $warehouseId && static::hasBoxes($pk) ? static::defaultId() : null);
        if ($owner && (int) $owner !== $warehouseId && ! $force) {
            return ['ok' => false, 'owner' => (int) $owner];
        }
        $existing?->delete();
        WarehouseCoverage::create(['warehouse_id' => $warehouseId, 'province' => Str::title($pk), 'province_key' => $pk,
            'city' => $ck ? Str::title(Str::squish($city)) : null, 'city_key' => $ck, 'user_id' => $by?->id]);
        static::log($warehouseId, static::name($warehouseId).': + '.($ck ? Str::title(Str::squish($city)).', ' : '').Str::title($pk), $by);
        static::forget();

        return ['ok' => true, 'owner' => null];
    }

    /** Only provinces that have boxes count as "the default warehouse's" when someone takes them. */
    protected static function hasBoxes(string $pk): bool
    {
        return DB::table('invoices')->where('receiver_province', 'like', '%'.Str::before($pk, ' ').'%')->exists();
    }

    public static function remove(WarehouseCoverage $row, ?User $by): void
    {
        static::log($row->warehouse_id, static::name($row->warehouse_id).': − '.($row->city ? $row->city.', ' : '').$row->province, $by);
        $row->delete();
        static::forget();
    }

    public static function request(int $warehouseId, string $province, int $from, ?User $by): CoverageRequest
    {
        return CoverageRequest::firstOrCreate(['warehouse_id' => $warehouseId, 'province_key' => static::key($province), 'status' => 'pending'],
            ['from_warehouse_id' => $from, 'province' => Str::title(static::key($province)), 'user_id' => $by?->id]);
    }

    public static function decide(CoverageRequest $r, bool $yes, ?User $by): void
    {
        if ($yes) {
            static::add($r->warehouse_id, $r->province, null, $by, true);
        }
        $r->update(['status' => $yes ? 'approved' : 'refused', 'decided_by' => $by?->id, 'decided_at' => now()]);
        static::log($r->warehouse_id, $r->province.' → '.static::name($r->warehouse_id).': '.($yes ? 'approved' : 'refused'), $by);
    }

    /** Boxes physically at $here that belong to another warehouse, waiting to be transferred. */
    public static function waitingTransfer(int $here): Collection
    {
        if (! static::active()) {
            return collect();
        }

        return Invoice::where('warehouse_id', $here)->where('is_verified', true)->where('is_delivered', false)
            ->where('is_assigned', false)->where('wh_is_assigned', false)
            ->get(['id', 'invoice', 'receiver_province', 'receiver_city', 'verified_at', 'created_at', 'container_id'])
            ->map(fn ($i) => ['inv' => $i, 'home' => static::home($i)])
            ->filter(fn ($x) => $x['home'] && $x['home'] !== $here)->values();
    }

    /** Boxes on a transfer coming to $wh, not received yet. */
    public static function arriving(int $wh): int
    {
        return DB::table('whtripinvoices as w')->join('whdeliverylogs as d', 'd.id', '=', 'w.whdeliverylog_id')
            ->where('d.warehouse_id', $wh)->where('w.is_unloaded', false)->count();
    }

    /** Boxes of a container by home warehouse: [warehouse_id => count]. */
    public static function containerSplit(int $containerId): array
    {
        return Invoice::where('container_id', $containerId)->get(['receiver_province', 'receiver_city'])
            ->countBy(fn ($i) => static::homeOf($i->receiver_province, $i->receiver_city) ?? 0)->all();
    }
}
