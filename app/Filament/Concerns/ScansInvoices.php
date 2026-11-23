<?php

namespace App\Filament\Concerns;

use App\Models\Invoice;
use App\Support\InvoiceLookup;
use Filament\Notifications\Notification;
use Illuminate\Support\Collection;

/**
 * Shared behaviour for the scan stations (load truck, unload container …).
 *
 * The page's form holds the selection (trip / container) in $data; the
 * <x-barcode-scanner method="scan" /> component calls scan() with each code.
 */
trait ScansInvoices
{
    use TakesBoxPhotos;

    public ?array $data = [];

    /** id of the last scanned invoice, its outcome and a short message */
    public ?int $lastInvoiceId = null;

    public ?string $lastStatus = null;

    public ?string $lastMessage = null;

    /** Board 58: two boxes with the scanned number still to do here: ['code' => …, 'options' => [SameNumber::choice …]]. */
    public ?array $which = null;

    /** The box picked in Which one? (invoice id), used by the next handleScan() only. */
    public ?int $pinInvoice = null;

    /** Handle one scanned / typed code. */
    abstract protected function handleScan(string $code): void;

    public function scan(string $code): void
    {
        $code = InvoiceLookup::normalize($code);

        if ($code === '') {
            return;
        }

        $selectionField = $this->selectionField();

        if ($selectionField && blank($this->data[$selectionField] ?? null)) {
            $this->scanResult('warning', 'Select '.$this->selectionLabel().' first, then scan.', notify: true);

            return;
        }

        $this->which = null;
        $this->handleScan($code);
    }

    /** Which one? → the receiver was picked: scan that box. */
    public function chooseWhich(int $invoiceId): void
    {
        $w = $this->which;
        if (! $w || ! collect($w['options'] ?? [])->contains('id', $invoiceId)) {
            return;
        }
        $this->scanPinned($w['code'], $invoiceId);
    }

    /** Scan as if this exact box was scanned (Which one? on the Scan app). */
    public function scanPinned(string $code, int $invoiceId): void
    {
        $this->pinInvoice = $invoiceId;
        try {
            $this->scan($code);
        } finally {
            $this->pinInvoice = null;
        }
    }

    public function cancelWhich(): void
    {
        $this->which = null;
        $this->lastStatus = null;
        $this->lastMessage = null;
    }

    /**
     * Board 58: the row to use for this scan. Two or more still to do with this number: ask (returns false).
     * A picked box (pinInvoice) wins; one left to do: that one; none left: the first (for "already done").
     *
     * @param  callable(mixed): ?Invoice  $invoiceOf
     * @param  callable(mixed): bool  $done
     */
    protected function whichRow(string $code, Collection $rows, callable $invoiceOf, callable $done): mixed
    {
        if ($rows->isEmpty()) {
            return null;
        }
        if ($this->pinInvoice && ($hit = $rows->first(fn ($r) => (int) $invoiceOf($r)?->getKey() === $this->pinInvoice))) {
            return $hit;
        }
        $open = $rows->reject(fn ($r) => $done($r))->values();
        if ($open->count() > 1) {
            $this->askWhich($code, $open->map($invoiceOf)->filter());

            return false;
        }

        return $open->first() ?? $rows->first();
    }

    protected function askWhich(string $code, Collection $invoices): void
    {
        $invoices = \Illuminate\Database\Eloquent\Collection::make($invoices->values()->all())->loadMissing('container:id,container_no,batch_no');
        $this->which = ['code' => $code, 'options' => $invoices->map(fn (Invoice $i) => \App\Support\Boxes\SameNumber::choice($i))->values()->all()];
        $this->lastStatus = 'warning';
        $this->lastMessage = $invoices->count()." boxes have number {$code}. Which one? Look at the receiver on the sticker.";
        $this->lastInvoiceId = null;
        $this->dispatch('scan-result', status: 'which');
    }

    /** " · 1 of 2 · Ailene Gacita" after a pick among boxes with one number. */
    protected function whichSuffix(int $done, int $total, ?Invoice $invoice): string
    {
        return $total > 1 ? " · {$done} of {$total}".($invoice?->receiver_name ? ' · '.\Illuminate\Support\Str::title(\Illuminate\Support\Str::lower($invoice->receiver_name)) : '') : '';
    }

    public function stationHeading(): string
    {
        return 'Scan boxes onto the truck';
    }

    public function stationDescription(): string
    {
        return 'Pick the trip, then scan every box as it is loaded.';
    }

    public function stationIcon(): string
    {
        return 'heroicon-o-arrow-up-tray';
    }

    public function progressLabel(): string
    {
        return 'Boxes loaded on this trip';
    }

    /** Name of the form field that must be chosen before scanning (null = none). */
    protected function selectionField(): ?string
    {
        return null;
    }

    protected function selectionLabel(): string
    {
        return 'an option';
    }

    protected function scanResult(string $status, string $message, ?Invoice $invoice = null, bool $notify = true): void
    {
        $this->lastStatus = $status;
        $this->lastMessage = $message;
        $this->lastInvoiceId = $invoice?->getKey();
        $this->photoAfterScan($status);

        if ($notify) {
            Notification::make()
                ->title($message)
                ->status($status)
                ->duration($status === 'success' ? 2500 : 6000)
                ->send();
        }

        $this->dispatch('scan-result', status: $status);
    }

    public function lastInvoice(): ?Invoice
    {
        return $this->lastInvoiceId ? Invoice::with('consolidator', 'routearea')->find($this->lastInvoiceId) : null;
    }

    /**
     * Other boxes from the same sender to the same receiver in the same container,
     * so the crew can see at a glance whether the whole household is on the truck.
     *
     * @param  callable(Invoice): array{trip: ?string, done: bool}  $describe
     */
    protected function householdRows(?Invoice $invoice, callable $describe): array
    {
        if (! $invoice) {
            return [];
        }

        return Invoice::query()
            ->where('container_id', $invoice->container_id)
            ->where('receiver_name', $invoice->receiver_name)
            ->where('sender_name', $invoice->sender_name)
            ->orderBy('invoice')
            ->get()
            ->map(fn (Invoice $box) => ['invoice' => $box->invoice, 'box' => $box->boxtype] + $describe($box))
            ->all();
    }

    /** Newest invoices with this number (the code is already normalised by scan()). */
    protected function invoicesMatching(string $code): Collection
    {
        // boxes not delivered first (two boxes can share a number, board 57)
        return Invoice::query()->where('invoice', $code)->orderByRaw('coalesce(is_delivered, 0) asc')->orderByDesc('id')->get();
    }
}
