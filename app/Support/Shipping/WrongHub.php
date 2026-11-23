<?php

namespace App\Support\Shipping;

use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Shipping\WrongHubBox;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Throwable;

/**
 * Boxes at a partner hub that are not theirs (wrong hub), or could not be delivered and go back.
 * A wrong-hub box can go straight to the right partner hub; the rest go back to the warehouse.
 */
class WrongHub
{
    /** "Send to Davao hub direct" or "Back to the warehouse". */
    public static function suggestion(WrongHubBox $w): array
    {
        $right = $w->correctHub;
        if ($w->reason === 'wrong_hub' && $right?->is_company && (int) $right->id !== (int) $w->logistichub_id) {
            return ['way' => 'hub', 'text' => 'Send to '.$right->hub_name.' direct', 'why' => 'Faster and cheaper than through the warehouse.'];
        }

        return ['way' => 'back', 'text' => 'Back to the warehouse', 'why' => $w->reason === 'wrong_hub' ? 'The box belongs to a Luzon area or the main hub.' : 'It goes back with the next shipment or truck to the warehouse.'];
    }

    /** Add a box the hub found (refused, moved, wrong address…). */
    public static function add(int $hubId, string $code, string $reason, ?string $note = null, ?int $pin = null): ?WrongHubBox
    {
        $row = static::candidates($hubId, $code)->when($pin, fn ($c) => $c->where('invoice_id', $pin))->first();
        if (! $row || ! array_key_exists($reason, WrongHubBox::REASONS)) {
            return null;
        }

        return WrongHubBox::firstOrCreate(['invoice_id' => $row->invoice_id, 'logistichub_id' => $hubId, 'status' => 'waiting'], [
            'tripinvoice_id' => $row->id, 'reason' => $reason, 'note' => $note ? mb_substr($note, 0, 300) : null,
            'correct_hub_id' => $row->invdata?->whSection?->logistichub_id, 'created_by' => Auth::id(),
        ]);
    }

    /** Boxes at the hub with this number, not delivered (two can share a number, board 58). */
    public static function candidates(int $hubId, string $code): \Illuminate\Support\Collection
    {
        return Tripinvoice::with('invdata.whSection', 'invdata.container:id,container_no,batch_no')->where('logistichub_id', $hubId)->where('invoice', $code)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->latest('id')->get();
    }

    /** Hand the box over to the right partner hub (like a main truck handing it over). */
    public static function sendToHub(WrongHubBox $w): bool
    {
        $row = $w->tripinvoice ?? Tripinvoice::where('invoice_id', $w->invoice_id)->where('logistichub_id', $w->logistichub_id)->latest('id')->first();
        $right = $w->correctHub;
        if (! $row || ! $right?->is_company) {
            return false;
        }
        DB::transaction(function () use ($row, $right, $w) {
            if ($row->hub_assigned) {
                app(TripAssignment::class)->removeFromHubTrip($row);
            }
            $row->update(['logistichub_id' => $right->id, 'hub_assigned' => false]);
            $w->update(['status' => 'sent_hub', 'done_by' => Auth::id(), 'done_at' => now()]);
        });

        return true;
    }

    /** Back to the warehouse: off the trip, back in the pool (marked returned). */
    public static function sendBack(WrongHubBox $w): bool
    {
        $row = $w->tripinvoice ?? Tripinvoice::where('invoice_id', $w->invoice_id)->where('logistichub_id', $w->logistichub_id)->latest('id')->first();
        if (! $row) {
            return false;
        }
        try {
            DB::transaction(function () use ($row, $w) {
                if ($row->hub_assigned) {
                    app(TripAssignment::class)->removeFromHubTrip($row);
                }
                app(TripAssignment::class)->removeFromDeliveryTrip($row->fresh(), returned: true);
                $w->update(['status' => 'back', 'done_by' => Auth::id(), 'done_at' => now(), 'tripinvoice_id' => null]);
            });
        } catch (Throwable $e) {
            report($e);

            return false;
        }

        return true;
    }

    /** This month, by reason and by consolidator. */
    public static function report(?int $hubId): array
    {
        $rows = WrongHubBox::with('invoice.consolidator')->when($hubId, fn ($q) => $q->where('logistichub_id', $hubId))
            ->where('created_at', '>=', now()->startOfMonth())->get();

        return [
            'total' => $rows->count(),
            'byReason' => $rows->groupBy('reason')->map->count()->sortDesc()->mapWithKeys(fn ($n, $k) => [WrongHubBox::REASONS[$k] ?? $k => $n])->all(),
            'byConsolidator' => $rows->groupBy(fn ($w) => $w->invoice?->consolidator?->company_name ?? 'Not known')->map->count()->sortDesc()->all(),
        ];
    }
}
