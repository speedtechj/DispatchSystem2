<?php

namespace App\Support;

use App\Models\Boxes\BoxSize;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\Tripinvoice;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Schema;

/**
 * Space from real sizes: box dimensions give each box type its space (next to the normal box),
 * the truck's cargo box gives how many normal boxes fit (packed about 85% full), and a reserve
 * keeps room for odd items (bikes, TVs). At loading, room left can be topped up with more boxes.
 */
class TruckSpace
{
    public const FILL = 85;

    public static function ready(): bool
    {
        static $ready = null;

        return $ready ??= Schema::hasColumn('trucks', 'reserve_pct');
    }

    public static function volume(?int $l, ?int $w, ?int $h): ?float
    {
        return $l && $w && $h ? (float) $l * $w * $h : null;
    }

    public static function boxVolume(?BoxSize $s): ?float
    {
        return $s ? static::volume($s->length_cm, $s->width_cm, $s->height_cm) : null;
    }

    /** Space from dimensions, next to the normal box (rounded to a half). */
    public static function spaceFromDims(BoxSize $s): ?float
    {
        $base = static::boxVolume(BoxSizes::base());
        $v = static::boxVolume($s);

        return $base && $v ? max(0.5, BoxSizes::half($v / $base)) : null;
    }

    /** How many normal boxes fit in the truck's cargo box, packed fill% full. */
    public static function fit(Truck $t): ?int
    {
        $base = static::boxVolume(BoxSizes::base());
        $cargo = static::ready() ? static::volume($t->cargo_length_cm, $t->cargo_width_cm, $t->cargo_height_cm) : null;

        return $base && $cargo ? (int) floor($cargo * (($t->fill_pct ?: self::FILL) / 100) / $base) : null;
    }

    /** The truck's space: set by hand, else from its cargo box, else 50. */
    public static function capacity(Truck $t, int $default = 50): int
    {
        return (int) ($t->capacity ?: static::fit($t) ?: $default);
    }

    /** Space the planner may fill: capacity minus the reserve. */
    public static function usable(Truck $t, int $default = 50): int
    {
        $r = static::ready() ? (int) ($t->reserve_pct ?? 0) : 0;

        return max(1, (int) floor(static::capacity($t, $default) * (1 - min(90, $r) / 100)));
    }

    /**
     * Room left on a trip once its boxes are loaded, and waiting boxes that fit, same provinces first.
     *
     * @return array{room: float, cap: int, boxes: Collection}
     */
    public static function topUp(Deliverylog $trip, int $max = 8): array
    {
        $truck = $trip->truck;
        if (! $truck) {
            return ['room' => 0.0, 'cap' => 0, 'boxes' => collect()];
        }
        $rows = Tripinvoice::with('invdata:id,boxtype,receiver_province,warehouse_id')->where('deliverylog_id', $trip->id)->get();
        $used = $rows->sum(fn ($r) => BoxSizes::spaceOf($r->invdata?->boxtype));
        $cap = static::capacity($truck);
        $room = BoxSizes::half(max(0, $cap - $used));
        if ($room < 1) {
            return ['room' => $room, 'cap' => $cap, 'boxes' => collect()];
        }
        $provinces = $rows->pluck('invdata.receiver_province')->filter()->map(fn ($p) => mb_strtolower(trim($p)))->unique()->values();
        $wh = $rows->pluck('invdata.warehouse_id')->filter()->mode()[0] ?? null;
        $cands = Invoice::query()->where('is_verified', true)->where('is_assigned', false)->where('wh_is_assigned', false)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->when($wh, fn ($q) => $q->where('warehouse_id', $wh))
            ->when($provinces->isNotEmpty(), fn ($q) => $q->whereIn(\Illuminate\Support\Facades\DB::raw('lower(trim(receiver_province))'), $provinces->all()))
            ->orderByDesc('is_priority')->orderBy('id')->limit(60)->get();
        $out = collect();
        $left = $room;
        foreach ($cands as $b) {
            $sp = BoxSizes::spaceOf($b->boxtype);
            if ($sp <= $left) {
                $out->push(['id' => $b->id, 'invoice' => $b->invoice, 'name' => \Illuminate\Support\Str::title((string) $b->receiver_name),
                    'place' => collect([$b->receiver_city, $b->receiver_province])->filter()->join(', '), 'space' => $sp, 'section' => $b->whSection?->code]);
                $left -= $sp;
            }
            if ($out->count() >= $max) {
                break;
            }
        }

        return ['room' => $room, 'cap' => $cap, 'boxes' => $out];
    }
}
