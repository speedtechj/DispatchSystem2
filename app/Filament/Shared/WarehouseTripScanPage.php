<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Invoice;
use App\Models\Whtripinvoice;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/**
 * Scan station for warehouse-to-warehouse trips.
 * Whloaded loads boxes at the origin, Whunloaded receives them at the destination.
 */
abstract class WarehouseTripScanPage extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scanload';

    /** true = receiving at the destination warehouse, false = loading at the origin. */
    protected static bool $unloading = false;

    abstract protected function tripOptionsQuery(): Builder;

    use \App\Filament\Concerns\BypassesTripRules;

    /** "Load it anyway" after "Not for this warehouse". */
    public bool $forceLoad = false;

    public ?array $wrongHub = null;

    public ?array $early = null;

    protected function tripKind(): string
    {
        return 'transfer';
    }

    public function mount(): void
    {
        $this->form->fill();
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('deliverylog_id')
                    ->label('Trip')
                    ->placeholder(static::$unloading ? 'Choose the arriving trip' : 'Choose the trip you are loading')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage'))
                    ->options(fn () => $this->tripOptionsQuery()->latest('id')->pluck('trip_number', 'id')),
            ]);
    }

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a trip';
    }

    protected function doneColumn(): string
    {
        return static::$unloading ? 'is_unloaded' : 'is_loaded';
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->tripOptionsQuery()->find($this->data['deliverylog_id'] ?? null);

        if (! $trip) {
            $this->scanResult('danger', 'That trip is not available any more.');

            return;
        }

        // two boxes with this number: the one on this trip and not done yet first (board 57)
        $matches = $this->invoicesMatching($code);
        $rows = $matches->isEmpty() ? collect() : Whtripinvoice::with('whdeliverylog:id,trip_number')->whereIn('invoice_id', $matches->pluck('id'))->latest('id')->get();
        $row = $rows->first(fn ($r) => (int) $r->whdeliverylog_id === (int) $trip->id && ! $r->{$this->doneColumn()})
            ?? $rows->first(fn ($r) => (int) $r->whdeliverylog_id === (int) $trip->id)
            ?? $rows->first();
        $invoice = $row ? $matches->firstWhere('id', $row->invoice_id) : $matches->first();

        if (! $row) {
            $this->scanResult('danger', "{$code} is not on any warehouse trip.", $invoice);

            return;
        }

        if ((int) $row->whdeliverylog_id !== (int) $trip->id) {
            $this->scanResult('danger', "{$code} belongs to trip {$row->whdeliverylog?->trip_number}, not {$trip->trip_number}.", $invoice);

            return;
        }

        // Two warehouses: only boxes that the destination warehouse delivers go on its transfer.
        $this->wrongHub = null;
        $this->bypass = null;
        if (! static::$unloading && ! $this->forceLoad && ! \App\Support\Trips\TripRules::isApproved('wrong_hub', $trip->id, $invoice->id)
            && ($home = \App\Support\Warehouses\Coverage::home($invoice)) && (int) $home !== (int) $trip->warehouse_id) {
            $dest = \App\Support\Warehouses\Coverage::name((int) $trip->warehouse_id);
            $place = \Illuminate\Support\Str::title(trim($invoice->receiver_city.', '.$invoice->receiver_province, ', '));
            $this->wrongHub = ['kind' => 'wh', 'code' => $code, 'for' => $place, 'section' => $invoice->whSection?->code ?? '—', 'color' => $invoice->whSection?->color,
                'trip' => $dest, 'home' => \App\Support\Warehouses\Coverage::name($home)];
            $this->scanResult('warning', "Not for {$dest}: {$code} is for {$place}, delivered from ".$this->wrongHub['home'].'.', $invoice);

            return;
        }
        $this->forceLoad = false;

        if (static::$unloading && ! $row->is_loaded) {
            $this->scanResult('warning', "{$code} was never scanned onto the truck. Check with the loading warehouse.", $invoice);

            return;
        }

        if ($row->{$this->doneColumn()}) {
            $who = ! static::$unloading && $row->loaded_by && $row->loaded_by !== Auth::id() ? \App\Models\User::find($row->loaded_by)?->first_name : null;
            $this->scanResult('warning', "{$code} was already ".(static::$unloading ? 'received' : 'loaded').($who ? " by {$who}" : '').'. Not counted again.', $invoice);

            return;
        }

        DB::transaction(function () use ($row, $invoice, $trip): void {
            $row->update([$this->doneColumn() => true] + (static::$unloading ? [] : ['loaded_by' => Auth::id(), 'loaded_at' => now()]));

            // The box now physically sits in the destination warehouse.
            if (static::$unloading) {
                $invoice->update(['warehouse_id' => $trip->warehouse_id]);
            }
        });

        $this->scanResult('success', "{$code} ".(static::$unloading ? 'received' : 'loaded').'.', $invoice);
    }

    /** @return array{loaded: int, total: int} */
    public function progress(): array
    {
        $tripId = $this->data['deliverylog_id'] ?? null;

        if (! $tripId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $query = Whtripinvoice::where('whdeliverylog_id', $tripId);

        return [
            'loaded' => (clone $query)->where($this->doneColumn(), true)->count(),
            'total' => $query->count(),
        ];
    }

    public function progressLabel(): string
    {
        return static::$unloading ? 'Boxes received from this trip' : 'Boxes loaded on this trip';
    }

    public function stationHeading(): string
    {
        return static::$unloading ? 'Receive boxes from the truck' : 'Scan boxes onto the truck';
    }

    public function stationDescription(): string
    {
        return static::$unloading
            ? 'Pick the arriving trip, then scan every box as it comes off.'
            : 'Pick the trip, then scan every box as it is loaded.';
    }

    public function stationIcon(): string
    {
        return static::$unloading ? 'heroicon-o-arrow-down-tray' : 'heroicon-o-arrow-up-tray';
    }

    public function household(): array
    {
        $tripId = (int) ($this->data['deliverylog_id'] ?? 0);

        return $this->householdRows($this->lastInvoice(), function (Invoice $box) use ($tripId): array {
            $row = Whtripinvoice::with('whdeliverylog:id,trip_number')->where('invoice_id', $box->id)->latest('id')->first();

            return [
                'trip' => $row?->whdeliverylog?->trip_number,
                'done' => (bool) ($row?->{$this->doneColumn()} && (int) $row->whdeliverylog_id === $tripId),
            ];
        });
    }

    public function photoStep(): ?string
    {
        return static::$unloading ? 'wh_unload' : 'wh_load';
    }

    public function photoContext(): array
    {
        return [
            'whdeliverylog_id' => $this->data['deliverylog_id'] ?? null,
            'warehouse_id' => Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        return $this->tripOptionsQuery()->latest('id')->limit(60)->get()
            ->map(fn ($t) => ['id' => $t->id, 'name' => 'WH trip '.$t->trip_number, 'active' => (bool) ($t->is_active ?? true), 'sub' => $t->departure_date ? 'Leaves '.$t->departure_date : null]);
    }
}
