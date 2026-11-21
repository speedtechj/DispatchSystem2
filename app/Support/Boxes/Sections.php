<?php

namespace App\Support\Boxes;

use App\Models\AppSetting;
use App\Models\Boxes\WhSection;
use App\Models\Boxes\WhSpot;
use App\Models\Invoice;
use App\Support\Hubs\HubAreas;
use App\Support\Maps\Barangays;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Which section of the warehouse a box goes to, from the receiver's province.
 * Each warehouse sets its own sections (Admin → Settings → Warehouse sections);
 * sections with no warehouse are for every warehouse.
 */
class Sections
{
    /** @var array<int, Collection<int, WhSection>> */
    protected static array $memo = [];

    public static function ready(): bool
    {
        return Schema::hasTable('wh_sections');
    }

    /** The sections of a warehouse, in order. */
    public static function of(?int $warehouseId): Collection
    {
        if (! static::ready()) {
            return collect();
        }

        return static::$memo[spl_object_id(app()).':'.(int) $warehouseId] ??= WhSection::query()->with(array_merge(['hub:id,hub_name', 'toWarehouse:id,name'], Schema::hasTable('wh_spots') ? ['spots'] : []))
            ->where('is_active', true)
            ->where(fn ($q) => $q->whereNull('warehouse_id')->when($warehouseId, fn ($q) => $q->orWhere('warehouse_id', $warehouseId)))
            ->orderBy('sort')->orderBy('code')->get();
    }

    public static function forget(): void
    {
        static::$memo = [];
    }

    /** Does this warehouse use sections at all? */
    public static function used(?int $warehouseId): bool
    {
        return static::of($warehouseId)->where('kind', 'area')->isNotEmpty();
    }

    /** "Cebu" for "Province of Cebu", "cebu ", "CEBU PROV." */
    public static function clean(?string $province): string
    {
        $p = Str::lower(Str::squish((string) $province));
        $p = preg_replace('/\b(province of|prov\.?|province)\b/u', '', $p);
        $p = trim(preg_replace('/[^\p{L}\p{N} ]+/u', ' ', $p));
        $p = Str::squish($p);

        return match ($p) {
            'ncr', 'metro manila', 'national capital region', 'manila' => 'metro manila',
            default => $p,
        };
    }

    /** "province" (default) or "city": what the sections of this warehouse are chosen by (board 50b). */
    public static function by(?int $warehouseId): string
    {
        return AppSetting::get('sections.by.'.(int) $warehouseId) === 'city' ? 'city' : 'province';
    }

    public static function setBy(?int $warehouseId, string $by): void
    {
        AppSetting::put('sections.by.'.(int) $warehouseId, $by === 'city' ? 'city' : null);
    }

    /** "San Jose · Nueva Ecija": a city always with its province (two San Jose are two places). */
    public static function cityLabel(?string $city, ?string $province): string
    {
        return Str::title(Str::squish((string) $city)).' · '.Str::title(Str::squish((string) $province));
    }

    /** "san jose|nueva ecija" for a city label or a city and its province. */
    public static function cityKey(?string $city, ?string $province = null): string
    {
        if ($province === null && str_contains((string) $city, ' · ')) {
            [$city, $province] = explode(' · ', (string) $city, 2);
        }

        return Barangays::cityKey((string) $city).'|'.static::clean($province);
    }

    /** All provinces, A to Z. */
    public static function provinceOptions(): array
    {
        $all = collect(HubAreas::REGIONS)->flatten()->all();
        sort($all);

        return $all;
    }

    /** Cities and municipalities with their province, from the addresses of the boxes, A to Z. */
    public static function cityOptions(): array
    {
        return Cache::remember('sections.city-options', 600, fn () => Invoice::query()
            ->whereNotNull('receiver_city')->where('receiver_city', '!=', '')->whereNotNull('receiver_province')->where('receiver_province', '!=', '')
            ->distinct()->limit(5000)->get(['receiver_city', 'receiver_province'])
            ->map(fn ($r) => static::cityLabel($r->receiver_city, $r->receiver_province))
            ->unique(fn ($l) => static::cityKey($l))->sort()->values()->all());
    }

    // ---------------------------------------------------------------- spots (optional, board 50)

    /** Spots inside sections are used in this warehouse. */
    public static function spotsOn(?int $warehouseId): bool
    {
        return (bool) AppSetting::get('sections.spots.'.(int) $warehouseId, false) && Schema::hasTable('wh_spots');
    }

    public static function setSpotsOn(?int $warehouseId, bool $on): void
    {
        AppSetting::put('sections.spots.'.(int) $warehouseId, $on ? '1' : null);
    }

    /** The spots of a section, when spots are on for its warehouse and this section uses them. */
    public static function spotsOf(?WhSection $s): Collection
    {
        if (! $s || ! $s->use_spots || ! static::spotsOn($s->warehouse_id)) {
            return collect();
        }

        return $s->relationLoaded('spots') ? $s->spots : $s->spots()->get();
    }

    /** The spot a spot-label QR names ("SPOT-7"), or null. */
    public static function spotFromCode(string $code): ?WhSpot
    {
        return preg_match('/^SPOT-(\d+)$/', $code, $m) && Schema::hasTable('wh_spots') ? WhSpot::find((int) $m[1]) : null;
    }

    /**
     * The section for a box: by its province, or by its city when the warehouse chose City.
     * A box with no province (or city), or one no section has, goes to Check address (when the warehouse has one).
     */
    public static function forInvoice(Invoice $invoice, ?int $warehouseId = null): ?WhSection
    {
        $wh = $warehouseId ?? $invoice->warehouse_id;
        $sections = static::of($wh);
        if ($sections->isEmpty()) {
            return null;
        }
        if (static::by($wh) === 'city') {
            if (filled($invoice->receiver_city)) {
                $key = static::cityKey($invoice->receiver_city, $invoice->receiver_province);
                foreach ($sections->where('kind', 'area') as $s) {
                    foreach ((array) $s->cities as $c) {
                        if (static::cityKey($c) === $key) {
                            return $s;
                        }
                    }
                }
            }

            return $sections->firstWhere('kind', 'check');
        }
        $province = static::clean($invoice->receiver_province);
        if ($province !== '') {
            foreach ($sections->where('kind', 'area') as $s) {
                foreach ((array) $s->provinces as $p) {
                    if (static::clean($p) === $province) {
                        return $s;
                    }
                }
            }
        }

        return $sections->firstWhere('kind', 'check');
    }

    /** Why a box went to Check address (shown in the Scan app). */
    public static function whyCheck(Invoice $invoice): string
    {
        if (static::by($invoice->warehouse_id) === 'city') {
            return blank($invoice->receiver_city) ? 'No city in the address.'
                : 'No section is set for "'.static::cityLabel($invoice->receiver_city, $invoice->receiver_province).'".';
        }

        return blank($invoice->receiver_province)
            ? 'No province in the address.'
            : 'No section is set for "'.Str::title($invoice->receiver_province).'".';
    }

    /** The section a section-label QR names ("SEC-12"), or null. */
    public static function fromCode(string $code): ?WhSection
    {
        return preg_match('/^SEC-(\d+)$/', $code, $m) && static::ready() ? WhSection::find((int) $m[1]) : null;
    }

    /** The section for boxes going to another warehouse (for "put in section instead"). */
    public static function forWarehouse(?int $warehouseId, int $toWarehouseId): ?WhSection
    {
        return static::of($warehouseId)->firstWhere('to_warehouse_id', $toWarehouseId);
    }

    /** Also scan the section label at unload? Off by default, set for each warehouse. */
    public static function labelScan(?int $warehouseId): bool
    {
        return (bool) AppSetting::get('sections.label_scan.'.(int) $warehouseId, false);
    }

    public static function setLabelScan(?int $warehouseId, bool $on): void
    {
        AppSetting::put('sections.label_scan.'.(int) $warehouseId, $on ? '1' : null);
    }

    /** For the Scan app: the big tile. */
    public static function tile(?WhSection $s): ?array
    {
        return $s ? ['code' => $s->code, 'name' => $s->name ?: $s->goesTo(), 'color' => $s->color, 'kind' => $s->kind] : null;
    }
}
