<?php

namespace App\Support\Boxes;

use App\Models\Boxes\SetSplit;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use Illuminate\Support\Collection;
use Illuminate\Support\Str;

/**
 * A set is all the boxes for one customer: the same receiver, phone and city,
 * not delivered yet. "Maria Santos · box 2 of 3".
 */
class BoxSets
{
    public static function keyFor(?string $name, ?string $phone, ?string $city): ?string
    {
        $name = Str::lower(Str::squish(preg_replace('/[^\p{L}\p{N} ]+/u', ' ', (string) $name)));
        if ($name === '') {
            return null;
        }
        $digits = substr(preg_replace('/\D/', '', (string) $phone), -10);
        $city = Str::lower(Str::squish((string) $city));

        return sha1($name.'|'.$digits.'|'.$city);
    }

    /** Every box of this box's set (itself included), oldest first. */
    public static function members(Invoice $invoice): Collection
    {
        if (! $invoice->set_key) {
            return collect([$invoice]);
        }

        return Invoice::query()->with('container:id,container_no')
            ->where('set_key', $invoice->set_key)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered')->orWhere('id', $invoice->id))
            ->where('created_at', '>=', ($invoice->created_at ?? now())->copy()->subDays(120))
            ->orderBy('id')->get();
    }

    /**
     * At unload: the box's place in its set, and where the other boxes are.
     *
     * @return array{n: int, of: int, name: string, text: string, kind: string}|null
     */
    public static function atUnload(Invoice $invoice): ?array
    {
        $all = static::members($invoice);
        if ($all->count() < 2) {
            return null;
        }
        $n = $all->search(fn ($b) => $b->id === $invoice->id) + 1;
        $here = $all->where('container_id', $invoice->container_id);
        $waiting = $here->where('id', '!=', $invoice->id)->filter(fn ($b) => ! $b->is_verified)->count();
        $elsewhere = $all->where('container_id', '!=', $invoice->container_id)->filter(fn ($b) => ! $b->is_verified)->count();
        $done = $all->filter(fn ($b) => $b->is_verified)->count();

        $text = match (true) {
            $waiting === 0 && $elsewhere === 0 => '✓ All '.$all->count().' boxes are off the container.',
            $elsewhere === 0 => $waiting.' more still in this container.',
            $waiting === 0 => $elsewhere.' '.($elsewhere === 1 ? 'is' : 'are').' in another container (not here yet).',
            default => $waiting.' more in this container, '.$elsewhere.' in another container.',
        };

        return ['n' => $n, 'of' => $all->count(), 'name' => Str::title((string) $invoice->receiver_name), 'text' => $text,
            'kind' => $elsewhere > 0 ? 'split' : ($waiting === 0 && $done === $all->count() ? 'done' : 'wait')];
    }

    /**
     * On a truck: how many of the set are loaded, and where the others are.
     *
     * @return array{n: int, of: int, name: string, text: string, kind: string}|null
     */
    public static function onTrip(Invoice $invoice, Deliverylog $trip, string $tripColumn = 'deliverylog_id', string $loadedColumn = 'is_loaded'): ?array
    {
        $all = static::members($invoice);
        if ($all->count() < 2) {
            return null;
        }
        $rows = Tripinvoice::whereIn('invoice_id', $all->pluck('id'))->where($tripColumn, $trip->id)->get()->keyBy('invoice_id');
        $loaded = $rows->filter(fn ($r) => $r->{$loadedColumn})->count();
        $left = $all->filter(fn ($b) => isset($rows[$b->id]) && ! $rows[$b->id]->{$loadedColumn});
        $off = $all->filter(fn ($b) => ! isset($rows[$b->id]));

        $parts = [];
        if ($left->isNotEmpty()) {
            $parts[] = 'Still to load: '.$left->map(fn ($b) => $b->invoice.($b->whSection ? ' ('.$b->whSection->code.')' : ''))->join(', ');
        }
        if ($off->isNotEmpty()) {
            $parts[] = $off->count().' not on this trip ('.$off->map(fn ($b) => $b->invoice)->join(', ').')';
        }

        return ['n' => $loaded, 'of' => $all->count(), 'name' => Str::title((string) $invoice->receiver_name),
            'text' => $parts ? implode(' · ', $parts) : '✓ Complete · all '.$all->count().' boxes loaded',
            'kind' => $off->isNotEmpty() ? 'split' : ($left->isEmpty() ? 'done' : 'wait')];
    }

    /**
     * Customers on a trip whose set is not complete on the truck, for the Done screen.
     *
     * @return list<array{key: string, name: string, have: int, of: int, missing: list<array{id: int, invoice: string, where: string}>, reason: ?string}>
     */
    public static function openOnTrip(Deliverylog $trip, string $tripColumn = 'deliverylog_id', string $loadedColumn = 'is_loaded'): array
    {
        $rows = Tripinvoice::with('invdata')->where($tripColumn, $trip->id)->get();
        $keys = $rows->pluck('invdata.set_key')->filter()->unique();
        if ($keys->isEmpty()) {
            return [];
        }
        $loadedIds = $rows->filter(fn ($r) => $r->{$loadedColumn})->pluck('invoice_id')->all();
        $boxes = Invoice::with(['whSection:id,code', 'container:id,container_no'])->whereIn('set_key', $keys)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->get()->groupBy('set_key');
        $reasons = SetSplit::where('deliverylog_id', $trip->id)->get()->keyBy('invoice_id');
        $onTrip = $rows->pluck('invoice_id')->all();

        $out = [];
        foreach ($boxes as $key => $set) {
            if ($set->count() < 2) {
                continue;
            }
            $missing = $set->reject(fn ($b) => in_array($b->id, $loadedIds, true));
            if ($missing->isEmpty() || $set->count() === $missing->count()) {
                continue; // complete, or none of it loaded yet
            }
            $first = $set->first();
            $out[] = [
                'key' => $key, 'name' => Str::title((string) $first->receiver_name), 'have' => $set->count() - $missing->count(), 'of' => $set->count(),
                'missing' => $missing->map(fn ($b) => ['id' => $b->id, 'invoice' => $b->invoice,
                    'where' => in_array($b->id, $onTrip, true) ? 'on this trip, not loaded'.($b->whSection ? ' · section '.$b->whSection->code : '')
                        : (! $b->is_verified ? 'not unloaded yet'.($b->container ? ' · container '.$b->container->container_no : '') : ($b->whSection ? 'section '.$b->whSection->code : 'in the warehouse')),
                    'reason' => $reasons[$b->id]->reason ?? null])->values()->all(),
            ];
        }

        return $out;
    }
}
