<?php

namespace App\Support\Boxes;

use App\Models\AppSetting;
use App\Models\Boxes\WhSection;
use App\Models\Invoice;
use Illuminate\Support\Collection;
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

        return static::$memo[(int) $warehouseId] ??= WhSection::query()->with(['hub:id,hub_name', 'toWarehouse:id,name'])
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

    /**
     * The section for a box. A box with no province, or a province no section has, goes to the
     * Check address section (when the warehouse has one).
     */
    public static function forInvoice(Invoice $invoice, ?int $warehouseId = null): ?WhSection
    {
        $sections = static::of($warehouseId ?? $invoice->warehouse_id);
        if ($sections->isEmpty()) {
            return null;
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
