<?php

namespace App\Support\Boxes;

use App\Models\Boxes\SetSplit;
use App\Models\Invoice;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Throwable;

/**
 * A customer's boxes (same name, phone and city) on a transfer truck (warehouse to warehouse):
 * on the TRUCK screen, where the other boxes are and which can be brought now;
 * before the truck leaves, the customers not complete on it and why.
 */
class TruckSets
{
    /** Box in this warehouse, unloaded, on no trip: it can go on the truck now. */
    protected static function free(Invoice $b, ?int $warehouseId): bool
    {
        return $b->is_verified && ! $b->wh_is_assigned && ! $b->is_assigned && ! $b->is_delivered
            && (! $warehouseId || ! $b->warehouse_id || (int) $b->warehouse_id === $warehouseId);
    }

    /**
     * The set card on the TRUCK screen.
     *
     * @return array{n: int, of: int, name: string, text: string, kind: string, rows: list<array{i: string, t: string}>, add: list<array{id: int, invoice: string, section: ?string}>}|null
     */
    public static function card(Invoice $invoice, Whdeliverylog $trip, ?int $warehouseId): ?array
    {
        $all = BoxSets::members($invoice)->load('whSection:id,code');
        if ($all->count() < 2) {
            return null;
        }
        $rows = Whtripinvoice::where('whdeliverylog_id', $trip->id)->whereIn('invoice_id', $all->pluck('id'))->get()->keyBy('invoice_id');
        $add = [];
        $lines = [];
        foreach ($all->values() as $k => $b) {
            $label = 'Box '.($k + 1).' · '.$b->invoice;
            $row = $rows[$b->id] ?? null;
            if ($row && $row->is_loaded) {
                $lines[] = ['i' => '🚚', 't' => $label.': on the truck'.($b->id === $invoice->id ? ' (this one)' : '')];
            } elseif ($row) {
                $lines[] = ['i' => '📷', 't' => $label.': added, scan it at the truck door'.($b->whSection ? ' (section '.$b->whSection->code.')' : '')];
            } elseif (! $b->is_verified) {
                $lines[] = ['i' => '📦', 't' => $label.': '.((int) $b->container_id === (int) $invoice->container_id ? 'still in this container' : 'in another container'.($b->container ? ' '.$b->container->container_no : '').' (not here yet)')];
            } elseif (static::free($b, $warehouseId)) {
                $lines[] = ['i' => '🗂️', 't' => $label.': in section '.($b->whSection?->code ?? '?').'. Bring it to the truck too.'];
                $add[] = ['id' => $b->id, 'invoice' => $b->invoice, 'section' => $b->whSection?->code];
            } else {
                $lines[] = ['i' => '↪️', 't' => $label.': on another trip'];
            }
        }
        $loaded = $rows->filter->is_loaded->count();
        $n = $all->search(fn ($b) => $b->id === $invoice->id) + 1;

        return ['n' => $n, 'of' => $all->count(), 'name' => Str::title((string) $invoice->receiver_name),
            'text' => $loaded === $all->count() ? '✓ All '.$all->count().' boxes are on the truck.' : $loaded.' of '.$all->count().' on the truck.',
            'kind' => $loaded === $all->count() ? 'done' : ($add ? 'wait' : 'split'), 'rows' => $lines, 'add' => $add, 'loaded' => $loaded];
    }

    /** "Bring it to the truck too": put the box of the set on the trip (it is scanned at the truck door). */
    public static function add(Invoice $of, int $invoiceId, Whdeliverylog $trip, ?int $warehouseId): ?Invoice
    {
        $box = BoxSets::members($of)->firstWhere('id', $invoiceId);
        if (! $box || ! static::free($box, $warehouseId)) {
            return null;
        }
        try {
            app(TripAssignment::class)->addToWarehouseTrip($trip, [$box]);
        } catch (Throwable $e) {
            report($e);

            return null;
        }

        return Whtripinvoice::where('whdeliverylog_id', $trip->id)->where('invoice_id', $box->id)->exists() ? $box : null;
    }

    /**
     * Before the truck leaves: customers with some boxes on it, others not.
     *
     * @return list<array{name: string, have: int, of: int, missing: list<array{id: int, invoice: string, where: string, reason: ?string}>}>
     */
    public static function open(Whdeliverylog $trip): array
    {
        $rows = Whtripinvoice::with('invoice:id,set_key')->where('whdeliverylog_id', $trip->id)->get();
        $keys = $rows->pluck('invoice.set_key')->filter()->unique();
        if ($keys->isEmpty()) {
            return [];
        }
        $loadedIds = $rows->filter->is_loaded->pluck('invoice_id')->all();
        $onTrip = $rows->pluck('invoice_id')->all();
        $reasons = static::ready() ? SetSplit::where('whdeliverylog_id', $trip->id)->get()->keyBy('invoice_id') : collect();
        $out = [];
        foreach (Invoice::with(['whSection:id,code', 'container:id,container_no'])->whereIn('set_key', $keys)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->orderBy('id')->get()->groupBy('set_key') as $set) {
            $missing = $set->reject(fn ($b) => in_array($b->id, $loadedIds, true));
            if ($set->count() < 2 || $missing->isEmpty() || $missing->count() === $set->count()) {
                continue;
            }
            $out[] = [
                'name' => Str::title((string) $set->first()->receiver_name).($set->first()->receiver_city ? ' · '.Str::title((string) $set->first()->receiver_city) : ''),
                'have' => $set->count() - $missing->count(), 'of' => $set->count(),
                'missing' => $missing->map(fn ($b) => ['id' => $b->id, 'invoice' => $b->invoice,
                    'where' => in_array($b->id, $onTrip, true) ? 'On this trip, not scanned at the truck yet'.($b->whSection ? ' · section '.$b->whSection->code : '')
                        : (! $b->is_verified ? 'In container '.($b->container?->container_no ?? '?').' (not unloaded yet)'
                            : ($b->wh_is_assigned || $b->is_assigned ? 'On another trip' : 'In section '.($b->whSection?->code ?? '?'))),
                    'reason' => $reasons[$b->id]->reason ?? null])->values()->all(),
            ];
        }

        return $out;
    }

    public static function ready(): bool
    {
        return Schema::hasColumn('set_splits', 'whdeliverylog_id');
    }

    /** @param array<int|string, string> $why invoice id => reason */
    public static function saveReasons(Whdeliverylog $trip, array $why): void
    {
        if (! static::ready()) {
            return;
        }
        $ids = collect(static::open($trip))->pluck('missing')->flatten(1)->pluck('id')->all();
        foreach ($why as $id => $reason) {
            if (in_array((int) $id, $ids, true) && array_key_exists($reason, SetSplit::REASONS)) {
                SetSplit::updateOrCreate(['invoice_id' => (int) $id, 'whdeliverylog_id' => $trip->id],
                    ['reason' => $reason, 'user_id' => Auth::id(), 'set_key' => Invoice::whereKey($id)->value('set_key')]);
            }
        }
    }

    /** The form for Lock trip / Truck left: one reason for each box left behind. */
    public static function reasonFields(Whdeliverylog $trip): array
    {
        $open = static::open($trip);
        if (! $open) {
            return [];
        }
        $fields = [\Filament\Schemas\Components\Text::make(count($open).' '.Str::plural('customer', count($open)).' not complete on this truck. Bring the boxes, or pick why each one stays behind.')];
        foreach ($open as $set) {
            foreach ($set['missing'] as $m) {
                $fields[] = \Filament\Forms\Components\ToggleButtons::make('why.'.$m['id'])
                    ->label($set['name'].' ('.$set['have'].' of '.$set['of'].' on the truck) · '.$m['invoice'])
                    ->helperText($m['where'])
                    ->options(SetSplit::REASONS)->inline()->required()->default($m['reason']);
            }
        }

        return $fields;
    }
}
