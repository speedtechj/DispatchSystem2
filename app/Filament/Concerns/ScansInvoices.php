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

        $this->handleScan($code);
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
        return Invoice::query()->where('invoice', $code)->orderByDesc('id')->get();
    }
}
