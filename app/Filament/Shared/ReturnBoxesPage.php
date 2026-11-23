<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station: when a truck comes back, staff scan every undelivered box off it.
 * Each box leaves the trip and goes back to the list of boxes waiting for a trip,
 * flagged "Returned", with the driver's reason kept.
 */
abstract class ReturnBoxesPage extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scanload';

    protected static string|\BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUturnLeft;

    protected static ?string $navigationLabel = 'Return Boxes';

    protected static ?string $title = 'Return Boxes';

    /** Partner hub mode: boxes on the hub's own trips (deliveryloghub_id). */
    protected static bool $atHub = false;

    /** How many boxes were returned on this screen since it was opened. */
    public int $returnedCount = 0;

    public function mount(): void
    {
        $this->form->fill();
    }

    protected function tripColumn(): string
    {
        return static::$atHub ? 'deliveryloghub_id' : 'deliverylog_id';
    }

    /** Trips of this hub that still have undelivered boxes on them (open or already closed). */
    protected function tripOptionsQuery(): Builder
    {
        return Deliverylog::query()
            ->where('logistichub_id', Auth::user()->logistichub_id)
            ->whereHas(static::$atHub ? 'hubTripinvoices' : 'tripinvoices', fn (Builder $query) => $query->where('is_delivered', false))
            ->latest('id');
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('deliverylog_id')
                    ->label('Trip')
                    ->placeholder('Choose the trip that came back')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage', 'returnedCount'))
                    ->options(fn () => $this->tripOptionsQuery()
                        ->withCount([(static::$atHub ? 'hubTripinvoices' : 'tripinvoices').' as left_count' => fn (Builder $query) => $query->where('is_delivered', false)])
                        ->get()
                        ->mapWithKeys(fn (Deliverylog $trip) => [
                            $trip->id => "{$trip->trip_number} · {$trip->left_count} not delivered",
                        ])),
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

    public function stationHeading(): string
    {
        return 'Return undelivered boxes';
    }

    public function stationDescription(): string
    {
        return 'Pick the trip that came back, then scan each box that was not delivered. It goes back to “Assign invoices” for the next trip.';
    }

    public function stationIcon(): string
    {
        return 'heroicon-o-arrow-uturn-left';
    }

    public function progressLabel(): string
    {
        return 'Undelivered boxes returned';
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->tripOptionsQuery()->find($this->data['deliverylog_id'] ?? null);

        if (! $trip) {
            $this->scanResult('warning', 'Every box on that trip is delivered or already returned.');

            return;
        }

        // two boxes with this number on the trip: one not delivered and not returned yet first (board 57)
        $box = Tripinvoice::with('invdata')
            ->where($this->tripColumn(), $trip->id)
            ->where('invoice', $code)
            ->latest('id')
            ->get()
            ->sortBy(fn ($r) => ($r->is_delivered ? 2 : 0) + ($r->invdata?->is_returned ? 1 : 0))
            ->first();

        if (! $box) {
            $invoice = $this->invoicesMatching($code)->first();

            $this->scanResult(
                $invoice?->is_returned ? 'warning' : 'danger',
                $invoice?->is_returned ? "{$code} was already returned." : "{$code} is not on trip {$trip->trip_number}.",
                $invoice,
            );

            return;
        }

        if ($box->is_delivered) {
            $this->scanResult('danger', "{$code} was delivered — keep it out of the warehouse stock.", $box->invdata);

            return;
        }

        $invoice = $box->invdata;
        $service = app(TripAssignment::class);
        static::$atHub ? $service->returnToHubInventory($box) : $service->returnToInventory($box);

        $this->returnedCount++;
        $this->scanResult('success', "{$code} returned to inventory.", $invoice);
    }

    /** @return array{loaded: int, total: int} */
    public function progress(): array
    {
        $tripId = $this->data['deliverylog_id'] ?? null;

        if (! $tripId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $stillOnTruck = Tripinvoice::where($this->tripColumn(), $tripId)->where('is_delivered', false)->count();

        return ['loaded' => $this->returnedCount, 'total' => $this->returnedCount + $stillOnTruck];
    }

    /** The driver's reason for the last scanned box, shown on the result card. */
    public function lastReason(): ?string
    {
        $attempt = $this->lastInvoice()?->latestDeliveryAttempt;

        return $attempt ? $attempt->reason->getLabel().($attempt->note ? " — “{$attempt->note}”" : '') : null;
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return 'return';
    }

    public function photoContext(): array
    {
        return [
            'deliverylog_id' => $this->data['deliverylog_id'] ?? null,
            'warehouse_id' => Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        // closed trips can still have boxes to return, so they always count as open here
        return $this->tripOptionsQuery()->limit(60)->get()
            ->map(fn ($t) => ['id' => $t->id, 'name' => 'Trip '.$t->trip_number, 'active' => true, 'sub' => $t->departure_date ? 'Left '.$t->departure_date : null]);
    }
}
