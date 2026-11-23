<?php

namespace App\Support\Boxes;

use App\Models\Invoice;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;

/**
 * One invoice number on two boxes (board 57). Each sender company numbers its own boxes, so two boxes can
 * share a number. A box is the number plus its container. Rules:
 * - a scan inside a container or a trip only looks there; two of them there: they are counted (1 of 2, 2 of 2);
 * - delivered boxes are left out of every other look-up;
 * - still two: the person picks the receiver's name (nothing is guessed).
 */
class SameNumber
{
    /** @var array<string, int> */
    protected static array $counts = [];

    /** How many boxes carry this number (delivered ones too), once per request. */
    public static function count(string $code): int
    {
        $key = spl_object_id(app()).':'.$code;

        return static::$counts[$key] ??= (int) Invoice::where('invoice', $code)->count();
    }

    /** @param  list<string>  $codes  numbers shared by two or more boxes, in one database question */
    public static function shared(array $codes): array
    {
        $codes = array_values(array_unique(array_filter($codes)));
        if (! $codes) {
            return [];
        }
        $rows = Invoice::query()->whereIn('invoice', $codes)->select('invoice', DB::raw('count(*) as n'))->groupBy('invoice')->pluck('n', 'invoice');
        foreach ($rows as $c => $n) {
            static::$counts[spl_object_id(app()).':'.$c] = (int) $n;
        }

        return $rows->filter(fn ($n) => $n > 1)->map(fn ($n) => (int) $n)->all();
    }

    /** Boxes with this number that are not delivered: this warehouse first, then the newest. */
    public static function active(string $code, ?int $warehouseId = null): Collection
    {
        return Invoice::query()->with('container:id,container_no,batch_no')->where('invoice', $code)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->get()
            ->sortBy(fn (Invoice $i) => [$warehouseId && (int) $i->warehouse_id === $warehouseId ? 0 : 1, -$i->id])
            ->values();
    }

    /** The one box to use, or null when none or more than one is still open (then ask). */
    public static function only(string $code, ?int $warehouseId = null): ?Invoice
    {
        $open = static::active($code, $warehouseId);

        return $open->count() === 1 ? $open->first() : null;
    }

    /** All boxes with this number, open ones first (the newest first), for messages. */
    public static function best(string $code, ?int $warehouseId = null): ?Invoice
    {
        return static::active($code, $warehouseId)->first() ?? Invoice::where('invoice', $code)->latest('id')->first();
    }

    /** What to show on a "Which one?" choice: the receiver big, then where and from whom. */
    public static function choice(Invoice $i): array
    {
        $place = trim(collect([$i->receiver_city, $i->receiver_province])->filter()->map(fn ($p) => \Illuminate\Support\Str::title(\Illuminate\Support\Str::lower($p)))->join(', '));

        return ['id' => $i->id, 'name' => $i->receiver_name ?: 'No name', 'place' => $place, 'sender' => $i->sender_name,
            'container' => trim(($i->container?->container_no ?? '').($i->container?->batch_no ? ' · Batch '.$i->container->batch_no : ''))];
    }

    /** " · 1 of 2 with this number" when more than one box with this number is on the trip. */
    public static function suffix(int $done, int $total): string
    {
        return $total > 1 ? " · {$done} of {$total} with this number" : '';
    }
}
