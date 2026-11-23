<?php

namespace App\Support\Boxes;

use App\Models\Boxes\WhCount;
use App\Models\Boxes\WhCountScan;
use App\Models\Boxes\WhSection;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Whtripinvoice;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;

/**
 * Count a section: scan every box on it. Boxes that belong elsewhere are moved here
 * (the system now says they are in this section). Missing boxes are listed at the end.
 */
class SectionCount
{
    public static function ready(): bool
    {
        return Schema::hasTable('wh_counts');
    }

    /** Boxes the system says are in this section now (not on a loaded truck, not delivered). */
    public static function expected(WhSection $s): Builder
    {
        return Invoice::query()->where('wh_section_id', $s->id)->where('is_verified', true)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->whereNotIn('id', Tripinvoice::where('is_loaded', true)->select('invoice_id'))
            ->whereNotIn('id', Whtripinvoice::where('is_loaded', true)->where('is_unloaded', false)->select('invoice_id'));
    }

    /** The open count, if one was started. */
    public static function current(WhSection $s): ?WhCount
    {
        return WhCount::where('wh_section_id', $s->id)->whereNull('finished_at')->latest('id')->first();
    }

    /** The open count of the section (every phone joins the same one). */
    public static function open(WhSection $s): WhCount
    {
        return WhCount::where('wh_section_id', $s->id)->whereNull('finished_at')->latest('id')->first()
            ?? WhCount::create(['wh_section_id' => $s->id, 'user_id' => Auth::id()]);
    }

    /**
     * @return array{status: string, message: string, invoice: ?Invoice}
     */
    public static function scan(WhCount $count, string $code, ?int $warehouseId): array
    {
        $s = $count->section;
        // two boxes can share a number (board 57): the one meant for this section, not delivered, first
        $box = Invoice::with('whSection:id,code')->where('invoice', $code)
            ->when($warehouseId, fn ($q) => $q->where(fn ($q) => $q->where('warehouse_id', $warehouseId)->orWhereNull('warehouse_id')))
            ->orderByRaw('case when wh_section_id = ? then 0 else 1 end', [$s->id])
            ->orderByRaw('coalesce(is_delivered, 0) asc')
            ->latest('id')->first();
        if (! $box) {
            return ['status' => 'danger', 'message' => "{$code} is not in this warehouse.", 'invoice' => null];
        }
        if ($box->is_delivered) {
            return ['status' => 'warning', 'message' => "{$code} was already delivered. Take it out and tell the office.", 'invoice' => $box];
        }
        if (Tripinvoice::where('invoice_id', $box->id)->where('is_loaded', true)->exists()) {
            $trip = Tripinvoice::with('deliverylog:id,trip_number')->where('invoice_id', $box->id)->where('is_loaded', true)->latest('id')->first();

            return ['status' => 'warning', 'message' => "{$code} is loaded on trip {$trip?->deliverylog?->trip_number}. It should be on the truck.", 'invoice' => $box];
        }
        $prev = WhCountScan::where('wh_count_id', $count->id)->where('invoice_id', $box->id)->first();
        if ($prev) {
            return ['status' => 'warning', 'message' => "{$code} was already counted. Not counted again.", 'invoice' => $box];
        }
        $from = $box->wh_section_id && (int) $box->wh_section_id !== (int) $s->id ? $box->whSection : null;
        WhCountScan::create(['wh_count_id' => $count->id, 'invoice_id' => $box->id, 'user_id' => Auth::id(), 'moved_from' => $from?->id ?? ($box->wh_section_id ? null : 0), 'created_at' => now()]);
        if ((int) $box->wh_section_id !== (int) $s->id) {
            $box->forceFill(['wh_section_id' => $s->id, 'sectioned_at' => now(), 'is_verified' => true])->save();

            return ['status' => 'success', 'message' => "{$code} moved to section {$s->code}".($from ? " (it was in {$from->code})" : '').'.', 'invoice' => $box];
        }

        return ['status' => 'success', 'message' => "{$code} counted in section {$s->code}.", 'invoice' => $box];
    }

    /** @return array{expected: int, found: int, missing: list<string>, moved: int} */
    public static function result(WhCount $count): array
    {
        $scanned = WhCountScan::where('wh_count_id', $count->id)->pluck('invoice_id')->all();
        $missing = static::expected($count->section)->whereNotIn('id', $scanned ?: [0])->orderBy('invoice')->pluck('invoice')->all();
        $moved = WhCountScan::where('wh_count_id', $count->id)->whereNotNull('moved_from')->count();

        return ['expected' => count($scanned) - $moved + count($missing), 'found' => count($scanned), 'missing' => $missing, 'moved' => $moved];
    }

    public static function finish(WhCount $count): array
    {
        $r = static::result($count);
        $count->update(['expected' => $r['expected'], 'found' => $r['found'], 'missing' => count($r['missing']), 'moved_in' => $r['moved'], 'finished_at' => now()]);

        return $r;
    }
}
