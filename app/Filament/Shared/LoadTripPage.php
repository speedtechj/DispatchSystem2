<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Boxes\SetSplit;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Boxes\BoxSets;
use App\Support\Maps\LoadOrder;
use App\Support\Maps\TripSorter;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station: crew scans each box as it goes onto the truck of a trip.
 *
 * Used by the admin hub (Scanload), the warehouse hub (Hubloaded) and partner
 * hubs (LoadTruck, which loads boxes handed over to the hub's own trips).
 */
abstract class LoadTripPage extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scanload';

    protected static string|\BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUpTray;

    /** Partner-hub mode: invoices are linked via deliveryloghub_id / is_loaded_hub. */
    protected static bool $atHub = false;

    /** Set by "Load it anyway" after a "too early" warning. */
    public bool $forceLoad = false;

    /** The last box that was too early to load (see LoadOrder). */
    public ?array $early = null;

    /** Where the box just loaded goes: ['zone' => 'front', 'stop' => 7]. */
    public ?array $spot = null;

    /** The box is for another hub than the trip goes to. */
    public ?array $wrongHub = null;

    /** The box's set on this truck: "Maria Santos · 2 of 3 · still to load X-103 (C)". */
    public ?array $setInfo = null;

    public function mount(): void
    {
        $this->form->fill();
    }

    protected function tripColumn(): string
    {
        return static::$atHub ? 'deliveryloghub_id' : 'deliverylog_id';
    }

    protected function loadedColumn(): string
    {
        return static::$atHub ? 'is_loaded_hub' : 'is_loaded';
    }

    protected function tripOptionsQuery(): Builder
    {
        return Deliverylog::query()
            ->with('destination:id,hub_name')
            ->where('logistichub_id', Auth::user()->logistichub_id)
            ->whereNotNull('truck_id')
            ->where('is_active', true)
            ->latest('id');
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('deliverylog_id')
                    ->label('Trip')
                    ->placeholder('Choose the trip you are loading')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage'))
                    ->options(fn () => $this->tripOptionsQuery()
                        ->get()
                        ->mapWithKeys(fn (Deliverylog $trip) => [
                            $trip->id => $trip->trip_number.($trip->destination ? ' → '.$trip->destination->hub_name : ''),
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

    /** The selected trip, re-checked against what this user may load. */
    protected function selectedTrip(): ?Deliverylog
    {
        return $this->tripOptionsQuery()->find($this->data['deliverylog_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->selectedTrip();

        if (! $trip) {
            $this->scanResult('danger', 'That trip is no longer open for loading.');

            return;
        }

        $tripinvoice = Tripinvoice::with('invdata')
            ->where($this->tripColumn(), $trip->id)
            ->where('invoice', $code)
            ->latest('id')
            ->first();

        if (! $tripinvoice) {
            $elsewhere = Tripinvoice::with(['deliverylog:id,trip_number', 'invdata'])
                ->where('invoice', $code)
                ->latest('id')
                ->first();

            $this->scanResult(
                'danger',
                $elsewhere
                    ? "{$code} belongs to trip {$elsewhere->deliverylog?->trip_number}, not {$trip->trip_number}."
                    : "{$code} is not on trip {$trip->trip_number}.",
                $elsewhere?->invdata ?? $this->invoicesMatching($code)->first(),
            );

            return;
        }

        if (static::$atHub && \App\Support\Shipping\Shipments::ready() && ($sea = \App\Support\Shipping\Shipments::stillAtSea($tripinvoice))) {
            $this->scanResult('danger', "{$code} is still on sea shipment {$sea->code}".($sea->eta ? ' (arriving about '.$sea->eta->format('M j').')' : '').'. Receive the container first (Scan app → Receive container).', $tripinvoice->invdata);

            return;
        }

        if ($tripinvoice->{$this->loadedColumn()}) {
            $who = $tripinvoice->loaded_by && $tripinvoice->loaded_by !== Auth::id() ? User::find($tripinvoice->loaded_by)?->first_name : null;
            $when = $tripinvoice->loaded_at ? \Illuminate\Support\Carbon::parse($tripinvoice->loaded_at)->format('g:i A') : null;
            $this->scanResult('warning', "{$code} was already loaded".($who ? " by {$who}" : '').($when ? " at {$when}" : '').'. Not counted again.', $tripinvoice->invdata);

            return;
        }

        $this->early = null;
        $this->spot = null;
        $this->wrongHub = null;
        $this->setInfo = null;
        if (! $this->forceLoad && ($wrong = $this->wrongHubFor($trip, $tripinvoice))) {
            $this->wrongHub = $wrong;
            $this->scanResult('warning', "Wrong hub: {$code} is for {$wrong['for']} (section {$wrong['section']}). This trip goes to {$wrong['trip']}.", $tripinvoice->invdata);

            return;
        }
        if (! $this->forceLoad && ($early = LoadOrder::tooEarly($trip, $tripinvoice, static::$atHub))) {
            $this->early = $early;
            $this->scanResult('warning', "Too early: {$code} is for stop {$early['stop']}".($early['place'] ? " ({$early['place']})" : '').'. It goes in later, nearer the door. Load stop '.$early['nextStop'].' first.', $tripinvoice->invdata);

            return;
        }
        $this->forceLoad = false;

        app(TripAssignment::class)->markLoaded($tripinvoice, atHub: static::$atHub);
        $tripinvoice->forceFill(['loaded_by' => Auth::id(), 'loaded_at' => now()])->saveQuietly();
        $this->spot = TripSorter::zoneMap($trip)[$tripinvoice->id] ?? null;
        // One container, more hubs: the hub that unloads last goes deep inside.
        if (! $this->spot && ! static::$atHub && \App\Support\Shipping\Shipments::ready()) {
            $this->spot = \App\Support\Shipping\Shipments::loadZone($trip->id);
        }
        if ($tripinvoice->invdata) {
            $this->setInfo = BoxSets::onTrip($tripinvoice->invdata, $trip, $this->tripColumn(), $this->loadedColumn());
        }

        $this->scanResult('success', "{$code} loaded.", $tripinvoice->invdata);
    }

    /** The box's section is for another partner hub than the one this trip goes to. */
    protected function wrongHubFor(Deliverylog $trip, Tripinvoice $tripinvoice): ?array
    {
        $section = $tripinvoice->invdata?->whSection;
        $to = static::$atHub ? null : $trip->assigned_to;
        if (! $section || ! $section->logistichub_id || ! $to || (int) $section->logistichub_id === (int) $to) {
            return null;
        }

        return ['code' => $tripinvoice->invoice, 'for' => $section->name ?: $section->goesTo(), 'section' => $section->code, 'color' => $section->color,
            'trip' => $trip->destination?->hub_name ?? 'another hub'];
    }

    /** Customers whose boxes are not all on the truck, for the Done screen. */
    public function openSets(): array
    {
        $trip = $this->selectedTrip();

        return $trip ? BoxSets::openOnTrip($trip, $this->tripColumn(), $this->loadedColumn()) : [];
    }

    /** Why a box of a set stays behind. */
    public function recordSplit(int $invoiceId, string $reason): bool
    {
        $trip = $this->selectedTrip();
        if (! $trip || ! array_key_exists($reason, SetSplit::REASONS)) {
            return false;
        }
        $ok = collect($this->openSets())->pluck('missing')->flatten(1)->contains('id', $invoiceId);
        if (! $ok) {
            return false;
        }
        $split = SetSplit::updateOrCreate(['invoice_id' => $invoiceId, 'deliverylog_id' => $trip->id],
            ['reason' => $reason, 'user_id' => Auth::id(), 'set_key' => Invoice::whereKey($invoiceId)->value('set_key')]);
        if ($split->wasRecentlyCreated) {
            BoxSets::textRestFollows($split, $trip, $this->tripColumn(), $this->loadedColumn());
        }

        return true;
    }

    /** Who loaded how many boxes on this trip. */
    public function team(): array
    {
        $id = $this->data['deliverylog_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = Tripinvoice::where($this->tripColumn(), $id)->where($this->loadedColumn(), true)->whereNotNull('loaded_by')
            ->selectRaw('loaded_by, count(*) n')->groupBy('loaded_by')->pluck('n', 'loaded_by');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    /** After "too early" or "wrong hub": load that box anyway. */
    public function loadAnyway(): void
    {
        if ($code = $this->early['code'] ?? $this->wrongHub['code'] ?? null) {
            $this->forceLoad = true;
            $this->scan($code);
            $this->forceLoad = false;
        }
    }

    /** What to load next on the selected trip (null when the trip has no sorted stops). */
    public function loadNext(): ?array
    {
        $trip = $this->selectedTrip();

        return $trip ? LoadOrder::next($trip, static::$atHub) : null;
    }

    /** @return array{loaded: int, total: int} */
    public function progress(): array
    {
        $tripId = $this->data['deliverylog_id'] ?? null;

        if (! $tripId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $query = Tripinvoice::where($this->tripColumn(), $tripId);

        return [
            'loaded' => (clone $query)->where($this->loadedColumn(), true)->count(),
            'total' => $query->count(),
            'last' => (clone $query)->where($this->loadedColumn(), true)->max('updated_at'),
        ];
    }

    public function household(): array
    {
        $tripId = (int) ($this->data['deliverylog_id'] ?? 0);

        return $this->householdRows($this->lastInvoice(), function (Invoice $box) use ($tripId): array {
            $onTrip = Tripinvoice::with('deliverylog:id,trip_number')->where('invoice_id', $box->id)->latest('id')->first();

            return [
                'trip' => $onTrip?->deliverylog?->trip_number,
                'done' => (bool) ($onTrip?->{$this->loadedColumn()} && (int) $onTrip->{$this->tripColumn()} === $tripId),
            ];
        });
    }

    public function photoStep(): ?string
    {
        return static::$atHub ? 'hub_load' : 'load';
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
        return $this->tripOptionsQuery()->latest('id')->limit(60)->get()
            ->map(fn (Deliverylog $t) => ['id' => $t->id, 'name' => 'Trip '.$t->trip_number, 'active' => (bool) ($t->is_active ?? true),
                'sub' => $t->destination?->hub_name ? 'To '.$t->destination->hub_name : ($t->departure_date ? 'Leaves '.$t->departure_date : null)]);
    }
}
