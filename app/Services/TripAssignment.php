<?php

namespace App\Services;

use App\Enums\FailedDeliveryReason;
use App\Enums\UndoDeliveryReason;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\DeliveryReversal;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Support\Ai\PhotoCheck;
use DomainException;
use Filament\Notifications\Notification;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/**
 * All trip bookkeeping in one place: putting invoices on a trip, taking them
 * off, scanning them onto the truck and marking them delivered.
 *
 * Every write runs in a transaction so the trip row and the invoice flags
 * (is_assigned, wh_is_assigned, hub_assigned …) can never get out of sync.
 */
class TripAssignment
{
    /**
     * Put invoices on a delivery trip (hub → destination hub).
     *
     * @param  iterable<Invoice>  $invoices
     * @return int how many were added (invoices already on a trip are skipped)
     */
    public function addToDeliveryTrip(Deliverylog $trip, iterable $invoices): int
    {
        $this->ensureEditable($trip);

        return DB::transaction(function () use ($trip, $invoices): int {
            $added = 0;

            foreach ($invoices as $invoice) {
                $alreadyOnTrip = Tripinvoice::where('invoice_id', $invoice->id)->whereHas('deliverylog')->lockForUpdate()->exists();

                if ($alreadyOnTrip) {
                    continue;
                }

                // Leftover rows from a deleted trip would hide the box; drop them.
                Tripinvoice::where('invoice_id', $invoice->id)->whereDoesntHave('deliverylog')->delete();

                Tripinvoice::create([
                    'deliverylog_id' => $trip->id,
                    'logistichub_id' => $trip->assigned_to,
                    'invoice' => $invoice->invoice,
                    'invoice_id' => $invoice->id,
                ]);

                $invoice->update(['is_assigned' => true]);
                $added++;
            }

            return $added;
        });
    }

    /**
     * Put invoices on a warehouse trip.
     *
     * @param  iterable<Invoice>  $invoices
     */
    public function addToWarehouseTrip(Whdeliverylog $trip, iterable $invoices): int
    {
        $this->ensureEditable($trip);

        return DB::transaction(function () use ($trip, $invoices): int {
            $added = 0;

            foreach ($invoices as $invoice) {
                // Skip boxes already on a warehouse trip that has not been unloaded yet.
                $onTheMove = Whtripinvoice::where('invoice_id', $invoice->id)
                    ->whereHas('whdeliverylog')
                    ->where('is_unloaded', false)
                    ->lockForUpdate()
                    ->exists();

                if ($onTheMove) {
                    continue;
                }

                Whtripinvoice::where('invoice_id', $invoice->id)->whereDoesntHave('whdeliverylog')->delete();

                Whtripinvoice::create([
                    'whdeliverylog_id' => $trip->id,
                    'user_id' => Auth::id(),
                    'truck_id' => $trip->truck_id,
                    'warehouse_id' => Auth::user()?->warehouse_id ?? $trip->user_whid,
                    'invoice_id' => $invoice->id,
                ]);

                $invoice->update(['wh_is_assigned' => true]);
                $added++;
            }

            return $added;
        });
    }

    /**
     * A partner hub hands invoices it received over to one of its own trips.
     *
     * @param  iterable<Tripinvoice>  $tripinvoices
     */
    public function addToHubTrip(Deliverylog $hubTrip, iterable $tripinvoices): int
    {
        $this->ensureEditable($hubTrip);

        return DB::transaction(function () use ($hubTrip, $tripinvoices): int {
            $added = 0;

            foreach ($tripinvoices as $tripinvoice) {
                if ($tripinvoice->hub_assigned) {
                    continue;
                }

                $tripinvoice->update([
                    'hub_assigned' => true,
                    'deliveryloghub_id' => $hubTrip->id,
                ]);
                $added++;
            }

            return $added;
        });
    }

    /**
     * Take an invoice off its delivery trip. When $returned is true the box
     * is flagged as returned so it shows up for re-delivery.
     */
    public function removeFromDeliveryTrip(Tripinvoice $tripinvoice, bool $returned = false): void
    {
        if ($tripinvoice->deliverylog) {
            $this->ensureEditable($tripinvoice->deliverylog);
        }

        DB::transaction(function () use ($tripinvoice, $returned): void {
            $changes = ['is_assigned' => false];

            if ($returned) {
                $changes['is_returned'] = true;
            }

            Invoice::whereKey($tripinvoice->invoice_id)->update($changes);
            $tripinvoice->delete();
        });
    }

    /** Release an invoice from a partner hub's trip (it stays on the original trip). */
    public function removeFromHubTrip(Tripinvoice $tripinvoice): void
    {
        $tripinvoice->update([
            'hub_assigned' => false,
            'deliveryloghub_id' => null,
            'is_loaded_hub' => false,
        ]);
    }

    /**
     * Record that a box was scanned onto the truck.
     * Once every box on the trip is loaded, the truck and trip are marked as on the road.
     */
    public function markLoaded(Tripinvoice $tripinvoice, bool $atHub = false): void
    {
        DB::transaction(function () use ($tripinvoice, $atHub): void {
            $tripinvoice->update([$atHub ? 'is_loaded_hub' : 'is_loaded' => true]);

            $tripId = $atHub ? $tripinvoice->deliveryloghub_id : $tripinvoice->deliverylog_id;

            if ($trip = Deliverylog::find($tripId)) {
                $this->refreshLoadStatus($trip, $atHub);
            }
        });
    }

    public function refreshLoadStatus(Deliverylog $trip, bool $atHub = false): void
    {
        $tripColumn = $atHub ? 'deliveryloghub_id' : 'deliverylog_id';
        $loadedColumn = $atHub ? 'is_loaded_hub' : 'is_loaded';

        $invoices = Tripinvoice::where($tripColumn, $trip->id);
        $total = (clone $invoices)->count();
        $loaded = (clone $invoices)->where($loadedColumn, true)->count();

        if ($total > 0 && $total === $loaded) {
            $trip->truck?->update(['is_assigned' => true]);
            $trip->update(['is_current' => true]);
        }
    }

    /**
     * Driver hands the box to the receiver.
     *
     * @param  array<int, string>  $pictures  stored photo paths
     */
    public function markDelivered(Tripinvoice $tripinvoice, array $pictures, ?User $by = null): void
    {
        DB::transaction(function () use ($tripinvoice, $pictures, $by): void {
            $alreadyDelivered = (bool) $tripinvoice->is_delivered;

            $tripinvoice->update([
                'delivery_picture' => array_values($pictures),
                'is_delivered' => true,
                // Updating the photos later must not restart the undo window.
                'delivered_at' => $alreadyDelivered ? $tripinvoice->delivered_at : now(),
                'delivered_by' => $alreadyDelivered ? $tripinvoice->delivered_by : ($by ?? Auth::user())?->getKey(),
            ]);

            Invoice::whereKey($tripinvoice->invoice_id)->update(['is_delivered' => true]);
        });

        if ($pictures) {
            PhotoCheck::queueDelivery($tripinvoice, $pictures);
        }
        // the driver's phone was at this receiver: their barangay and place are known for next time
        \App\Support\Maps\Barangays::learnFromDelivery($tripinvoice->fresh());
    }

    /** How long a driver can undo their own delivery. After that only the office can. */
    public const DRIVER_UNDO_MINUTES = 30;

    /** Minutes this driver has left to undo the delivery (null when they can't). */
    public function driverUndoMinutesLeft(Tripinvoice $tripinvoice, User $driver): ?int
    {
        if (! $tripinvoice->is_delivered || ! $tripinvoice->delivered_at || (int) $tripinvoice->delivered_by !== (int) $driver->getKey()) {
            return null;
        }

        $secondsLeft = self::DRIVER_UNDO_MINUTES * 60 - $tripinvoice->delivered_at->diffInSeconds(now());

        return $secondsLeft > 0 ? (int) ceil($secondsLeft / 60) : null;
    }

    /**
     * Put a delivered box back on the driver's list. Drivers can only undo their own
     * deliveries within DRIVER_UNDO_MINUTES; the office can undo any time.
     * The photos and the reason are kept in the box's history.
     */
    public function undoDelivery(
        Tripinvoice $tripinvoice,
        User $by,
        UndoDeliveryReason $reason,
        ?string $note = null,
        bool $byOffice = false,
    ): DeliveryReversal {
        if (! $tripinvoice->is_delivered) {
            throw new DomainException("{$tripinvoice->invoice} is not marked as delivered.");
        }

        if (! $byOffice && $this->driverUndoMinutesLeft($tripinvoice, $by) === null) {
            throw new DomainException('It is too late to undo this delivery. Ask the office to change it.');
        }

        if ($reason->requiresNote() && blank($note)) {
            throw new DomainException('Please add a note for this reason.');
        }

        $reversal = DB::transaction(function () use ($tripinvoice, $by, $reason, $note, $byOffice): DeliveryReversal {
            $reversal = DeliveryReversal::create([
                'tripinvoice_id' => $tripinvoice->id,
                'invoice_id' => $tripinvoice->invoice_id,
                'deliverylog_id' => $tripinvoice->deliveryloghub_id ?: $tripinvoice->deliverylog_id,
                'user_id' => $by->getKey(),
                'delivered_by' => $tripinvoice->delivered_by,
                'delivered_at' => $tripinvoice->delivered_at ?? $tripinvoice->updated_at,
                'reason' => $reason,
                'note' => filled($note) ? trim($note) : null,
                'photos' => $tripinvoice->delivery_picture ?: null,
                'by_office' => $byOffice,
            ]);

            $tripinvoice->update([
                'is_delivered' => false,
                'delivered_at' => null,
                'delivered_by' => null,
                'delivery_picture' => null,
            ]);

            Invoice::whereKey($tripinvoice->invoice_id)->update(['is_delivered' => false]);

            return $reversal;
        });

        $this->notifyAboutUndo($reversal, $tripinvoice);

        return $reversal;
    }

    /** Office undid it → tell the driver. Driver undid it → tell the dispatcher. */
    protected function notifyAboutUndo(DeliveryReversal $reversal, Tripinvoice $tripinvoice): void
    {
        $recipient = $reversal->by_office
            ? User::find($reversal->delivered_by)
            : $reversal->deliverylog?->user;

        if (! $recipient || $recipient->is($reversal->user)) {
            return;
        }

        Notification::make()
            ->title("Delivery of {$tripinvoice->invoice} was undone")
            ->body(collect([
                $reversal->reason->getLabel(),
                ($reversal->by_office ? 'By the office: ' : 'By the driver: ').$reversal->user->full_name,
                $reversal->note,
            ])->filter()->join("\n"))
            ->icon('heroicon-o-arrow-uturn-left')
            ->warning()
            ->sendToDatabase($recipient);
    }

    /**
     * Driver could not hand the box over. The box stays on the truck; the
     * attempt is kept as history and the dispatcher who made the trip is told.
     *
     * @param  array<int, string>  $photos  stored photo paths
     */
    public function recordFailedAttempt(
        Tripinvoice $tripinvoice,
        User $driver,
        FailedDeliveryReason $reason,
        ?string $note = null,
        array $photos = [],
    ): DeliveryAttempt {
        if ($tripinvoice->is_delivered) {
            throw new DomainException("{$tripinvoice->invoice} is already delivered.");
        }

        if ($reason->requiresNote() && blank($note)) {
            throw new DomainException('Please add a note for this reason.');
        }

        if ($reason->requiresPhoto() && $photos === []) {
            throw new DomainException('Please add a photo for this reason.');
        }

        $attempt = DB::transaction(fn () => DeliveryAttempt::create([
            'tripinvoice_id' => $tripinvoice->id,
            'invoice_id' => $tripinvoice->invoice_id,
            'deliverylog_id' => $tripinvoice->deliveryloghub_id ?: $tripinvoice->deliverylog_id,
            'user_id' => $driver->id,
            'reason' => $reason,
            'note' => filled($note) ? trim($note) : null,
            'photos' => array_values($photos) ?: null,
        ]));

        $this->notifyDispatcher($attempt);

        return $attempt;
    }

    protected function notifyDispatcher(DeliveryAttempt $attempt): void
    {
        $dispatcher = $attempt->deliverylog?->user;

        if (! $dispatcher || $dispatcher->is($attempt->user)) {
            return;
        }

        $count = DeliveryAttempt::where('invoice_id', $attempt->invoice_id)->count();

        Notification::make()
            ->title("{$attempt->tripinvoice->invoice} not delivered")
            ->body(collect([
                $attempt->reason->getLabel().($count > 1 ? " (attempt {$count})" : ''),
                'Trip '.$attempt->deliverylog?->trip_number.' · '.$attempt->user->full_name,
                $attempt->note,
            ])->filter()->join("\n"))
            ->icon($attempt->reason->getIcon())
            ->warning()
            ->sendToDatabase($dispatcher);
    }

    /**
     * An undelivered box came back on the truck: take it off the trip and put it
     * back in the pool of boxes waiting for a trip, flagged as returned.
     * The driver's reasons and photos stay in the delivery attempts history.
     */
    public function returnToInventory(Tripinvoice $tripinvoice): void
    {
        if ($tripinvoice->is_delivered) {
            throw new DomainException("{$tripinvoice->invoice} was delivered — it can't be returned.");
        }

        DB::transaction(function () use ($tripinvoice): void {
            Invoice::whereKey($tripinvoice->invoice_id)->update([
                'is_assigned' => false,
                'is_returned' => true,
            ]);

            $tripinvoice->delete();
        });
    }

    /**
     * Partner hub version: the box leaves the hub's own trip and goes back to the
     * hub's list of boxes waiting for a trip (it stays assigned to the hub).
     */
    public function returnToHubInventory(Tripinvoice $tripinvoice): void
    {
        if ($tripinvoice->is_delivered) {
            throw new DomainException("{$tripinvoice->invoice} was delivered — it can't be returned.");
        }

        DB::transaction(function () use ($tripinvoice): void {
            $this->removeFromHubTrip($tripinvoice);
            Invoice::whereKey($tripinvoice->invoice_id)->update(['is_returned' => true]);
        });
    }

    /** Free the truck and close the trip. */
    public function releaseTruck(Deliverylog $trip): void
    {
        DB::transaction(function () use ($trip): void {
            $trip->truck?->update(['is_assigned' => false]);
            $trip->update(['is_current' => false, 'is_active' => false]);
        });
    }

    /**
     * Swap the truck on a trip: the old truck becomes available again,
     * the new one is marked as in use. Does nothing when the truck did not change.
     */
    public function swapTruck(?int $oldTruckId, ?int $newTruckId): void
    {
        if ($oldTruckId === $newTruckId) {
            return;
        }

        DB::transaction(function () use ($oldTruckId, $newTruckId): void {
            if ($oldTruckId) {
                Truck::whereKey($oldTruckId)->update(['is_assigned' => false]);
            }

            if ($newTruckId) {
                Truck::whereKey($newTruckId)->update(['is_assigned' => true]);
            }
        });
    }

    public function ensureEditable(Deliverylog|Whdeliverylog $trip): void
    {
        if ($trip->is_lock) {
            throw new DomainException("Trip {$trip->trip_number} is locked. Ask an administrator to unlock it first.");
        }
    }
}
