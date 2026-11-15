#!/usr/bin/env bash
#
# Dispatch System — Sea shipments
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/sea-shipments.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 34 files"

# ---------------------------------------------------------------- app/Filament/Company/Pages/IncomingShipments.php
mkdir -p 'app/Filament/Company/Pages'
cat > 'app/Filament/Company/Pages/IncomingShipments.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\Shipping\SeaShipmentsPage;

/** Partner hub: sea shipments coming to this hub. */
class IncomingShipments extends SeaShipmentsPage
{
    protected static bool $incoming = true;

    protected static ?string $navigationLabel = 'Incoming shipments';

    protected static ?string $title = 'Incoming shipments';

    protected static ?string $slug = 'incoming-shipments';
}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Company/Pages/SeaShipment.php
mkdir -p 'app/Filament/Company/Pages'
cat > 'app/Filament/Company/Pages/SeaShipment.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\Shipping\SeaShipmentPage;

class SeaShipment extends SeaShipmentPage
{
    protected static bool $hubSide = true;
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Company/Pages/WrongHub.php
mkdir -p 'app/Filament/Company/Pages'
cat > 'app/Filament/Company/Pages/WrongHub.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Company\Pages;

use App\Filament\Shared\Shipping\WrongHubPage;

class WrongHub extends WrongHubPage {}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Pages/SeaShipment.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/SeaShipment.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Shipping\SeaShipmentPage;

class SeaShipment extends SeaShipmentPage {}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Pages/SeaShipments.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/SeaShipments.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Shipping\SeaShipmentsPage;

class SeaShipments extends SeaShipmentsPage {}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Filament/Pages/WrongHub.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/WrongHub.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Shipping\WrongHubPage;

class WrongHub extends WrongHubPage {}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Filament/Shared/LoadTripPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/LoadTripPage.php' <<'DISPATCH_FILE_END_6'
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
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/PortCheckStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/PortCheckStation.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Filament\Shared\Shipping;

use App\Support\Shipping\Shipments;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;

/** Scan app · Port check: scan each box as it is handed over at the port (full scan shipments). */
class PortCheckStation extends ShipmentScanStation
{
    protected static string $step = 'port';

    protected static bool $shouldRegisterNavigation = false;

    protected function shipments(): Builder
    {
        $user = Auth::user();
        $hub = $user?->hasRole('super_admin') ? null : $user?->logistichub_id;

        return Shipments::visible($hub)->where('port_check', 'full')->whereIn('status', ['sealed', 'to_port', 'at_port']);
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/ReceiveShipmentStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/ReceiveShipmentStation.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Filament\Shared\Shipping;

use App\Models\Shipping\SeaShipment;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;

/** Scan app · Receive container: the partner hub scans every box of an arriving shipment. */
class ReceiveShipmentStation extends ShipmentScanStation
{
    protected static string $step = 'received';

    protected static bool $shouldRegisterNavigation = false;

    protected function shipments(): Builder
    {
        return SeaShipment::query()->with('hub:id,hub_name', 'trip:id,trip_number')
            ->where('logistichub_id', (int) Auth::user()?->logistichub_id)
            ->whereIn('status', ['sailed', 'arrived', 'picked_up']);
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/SeaShipmentPage.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/SeaShipmentPage.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Filament\Shared\Shipping;

use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\WrongHubBox;
use App\Support\Boxes\BoxSets;
use App\Support\Photos\PhotoShrinker;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;
use Livewire\WithFileUploads;

/** One sea shipment: its steps, details, port check, cost, and receiving at the partner hub. */
abstract class SeaShipmentPage extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.shipping.detail';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'sea-shipment';

    /** Partner hub panel: may only press Arrived, Picked up and finish receiving. */
    protected static bool $hubSide = false;

    #[Url(as: 'shipment')]
    #[Locked]
    public int $shipmentId = 0;

    public array $f = [];

    public $sealPhoto = null;

    public $receipt = null;

    public static function canAccess(): bool
    {
        return Shipments::ready() && parent::canAccess();
    }

    public function mount(): void
    {
        $this->shipmentId = (int) request()->query('shipment', $this->shipmentId);
        $s = $this->shipment();
        abort_unless($s, 404);
        $this->fillForm($s);
    }

    protected function shipment(): ?SeaShipment
    {
        $hub = Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
        $q = Shipments::visible($hub)->when(static::$hubSide, fn ($q) => $q->where('logistichub_id', (int) Auth::user()?->logistichub_id));

        return $q->find($this->shipmentId);
    }

    protected function fillForm(SeaShipment $s): void
    {
        foreach (['mode', 'van_no', 'van_size', 'seal_no', 'shipping_line', 'vessel', 'voyage', 'bl_no', 'port_from', 'port_to', 'port_check', 'port_count', 'port_reason', 'cost_freight', 'cost_trucking', 'cost_port', 'cost_other', 'note'] as $k) {
            $this->f[$k] = (string) ($s->{$k} ?? '');
        }
        $this->f['etd'] = $s->etd?->toDateString() ?? '';
        $this->f['eta'] = $s->eta?->toDateString() ?? '';
    }

    public function getTitle(): string|Htmlable
    {
        $s = $this->shipment();

        return $s ? $s->code.' → '.($s->hub?->hub_name ?? '') : 'Sea shipment';
    }

    public function save(): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        abort_unless($s, 404);
        foreach (['cost_freight', 'cost_trucking', 'cost_port', 'cost_other'] as $k) {
            $this->f[$k] = str_replace([',', '₱', ' '], '', (string) $this->f[$k]);
        }
        $this->validate([
            'f.mode' => 'required|in:'.implode(',', array_keys(Shipments::MODES)),
            'f.port_check' => 'required|in:'.implode(',', array_keys(Shipments::PORT_CHECKS)),
            'f.van_no' => 'nullable|string|max:20', 'f.van_size' => 'nullable|string|max:10', 'f.seal_no' => 'nullable|string|max:30',
            'f.shipping_line' => 'nullable|string|max:80', 'f.vessel' => 'nullable|string|max:80', 'f.voyage' => 'nullable|string|max:30', 'f.bl_no' => 'nullable|string|max:40',
            'f.port_from' => 'nullable|string|max:80', 'f.port_to' => 'nullable|string|max:80', 'f.etd' => 'nullable|date', 'f.eta' => 'nullable|date',
            'f.port_count' => 'nullable|integer|min:0|max:100000', 'f.port_reason' => 'nullable|string|max:200',
            'f.cost_freight' => 'nullable|numeric|min:0', 'f.cost_trucking' => 'nullable|numeric|min:0', 'f.cost_port' => 'nullable|numeric|min:0', 'f.cost_other' => 'nullable|numeric|min:0',
            'f.note' => 'nullable|string|max:500',
            'sealPhoto' => 'nullable|image|max:12288', 'receipt' => 'nullable|image|max:12288',
        ]);
        $data = collect($this->f)->map(fn ($v) => $v === '' ? null : $v)->all();
        if ($data['port_count'] !== null && (int) $data['port_count'] !== (int) $s->port_count) {
            $data['port_by'] = Auth::id();
            $data['port_at'] = now();
        }
        foreach (['sealPhoto' => 'seal_photo', 'receipt' => 'port_receipt'] as $prop => $col) {
            if ($this->{$prop}) {
                $path = $this->{$prop}->store('shipments/'.now()->format('Y-m'), 'public');
                PhotoShrinker::file('public', $path);
                $data[$col] = $path;
                $this->{$prop} = null;
            }
        }
        $s->update($data);
        Notification::make()->title('Saved')->success()->send();
    }

    public function advance(): void
    {
        $s = $this->shipment();
        abort_unless($s, 404);
        $to = Shipments::next($s);
        if (! $to || ($to === 'received')) {
            return;
        }
        if (static::$hubSide && ! in_array($to, ['arrived', 'picked_up'], true)) {
            abort(403);
        }
        if (! Shipments::move($s, $to)) {
            Notification::make()->title('Not yet')->body(implode(' ', Shipments::blockers($s, $to)))->warning()->send();

            return;
        }
        Notification::make()->title(Shipments::label($s->fresh(), $to))->success()->send();
    }

    public function finishReceiving(): void
    {
        $s = $this->shipment();
        abort_unless($s && in_array($s->status, ['sailed', 'arrived', 'picked_up'], true), 404);
        abort_unless(static::$hubSide || Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) === null, 403);
        $made = Shipments::finishReceiving($s);
        Notification::make()->title("{$s->code} received")->body($made ? "{$made} missing ".str('box')->plural($made).': an Invoice Issue was opened for each.' : 'Every box arrived.')->success()->send();
    }

    protected function getViewData(): array
    {
        $s = $this->shipment();
        $to = Shipments::next($s);

        return [
            's' => $s,
            'steps' => Shipments::steps($s),
            'stepKeys' => array_keys(Shipments::steps($s)),
            'next' => $to,
            'nextLabel' => $to ? Shipments::label($s, $to) : null,
            'blockers' => $to && $to !== 'received' ? Shipments::blockers($s, $to) : [],
            'counts' => Shipments::counts($s),
            'track' => Shipments::trackText($s),
            'openSets' => $s->trip ? BoxSets::openOnTrip($s->trip) : [],
            'wrong' => WrongHubBox::with('invoice', 'correctHub')->where('sea_shipment_id', $s->id)->get(),
            'modes' => Shipments::MODES,
            'checks' => Shipments::PORT_CHECKS,
            'hubSide' => static::$hubSide,
            'canPress' => $to && $to !== 'received' && (! static::$hubSide || in_array($to, ['arrived', 'picked_up'], true)),
            'canReceive' => in_array($s->status, ['sailed', 'arrived', 'picked_up'], true) && (static::$hubSide || Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) === null),
            'whenOf' => fn ($st) => Shipments::when($s, $st),
        ];
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/SeaShipmentsPage.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/SeaShipmentsPage.php' <<'DISPATCH_FILE_END_10'
<?php

namespace App\Filament\Shared\Shipping;

use App\Models\Deliverylog;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/**
 * Sea shipments: boxes going by sea (or RoRo) to a partner hub. Admin sees all, Warehouse its own
 * trips, the partner hub what is coming to it ("Incoming shipments").
 */
abstract class SeaShipmentsPage extends Page
{
    protected string $view = 'filament.shipping.list';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedGlobeAsiaAustralia;

    protected static ?string $navigationLabel = 'Sea shipments';

    protected static ?string $title = 'Sea shipments';

    protected static ?string $slug = 'sea-shipments';

    /** Partner hub panel: only what comes to us, no "new shipment". */
    protected static bool $incoming = false;

    #[Url]
    public string $show = 'open';

    public ?int $tripId = null;

    public string $mode = 'container';

    public string $portCheck = 'count';

    public static function canAccess(): bool
    {
        return Shipments::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    public function create(): void
    {
        abort_if(static::$incoming, 403);
        $trip = Shipments::tripsFor($this->hub())->firstWhere('id', $this->tripId);
        if (! $trip) {
            $this->addError('tripId', 'Pick the trip to the port.');

            return;
        }
        $s = Shipments::create($trip, $this->mode, $this->portCheck);
        Notification::make()->title("Sea shipment {$s->code} made")->body('Load the trip as usual (Scan app → Load truck), then fill the van and seal.')->success()->send();
        $this->redirect($this->detailUrl($s->id));
    }

    protected function detailUrl(int $id): string
    {
        $class = str_replace('SeaShipments', 'SeaShipment', static::class);
        $class = str_replace('IncomingShipments', 'SeaShipment', $class);

        return $class::getUrl(['shipment' => $id]);
    }

    protected function getViewData(): array
    {
        $q = Shipments::visible($this->hub())->when(static::$incoming, fn ($q) => $q->where('logistichub_id', (int) Auth::user()?->logistichub_id));
        $list = (clone $q)->when($this->show === 'open', fn ($q) => $q->where('status', '!=', 'received'))->latest('id')->limit(60)->get();

        return [
            'list' => $list->map(fn ($s) => ['s' => $s, 'label' => Shipments::label($s), 'counts' => Shipments::counts($s), 'url' => $this->detailUrl($s->id),
                'steps' => array_keys(Shipments::steps($s))]),
            'incoming' => static::$incoming,
            'trips' => static::$incoming ? collect() : Shipments::tripsFor($this->hub()),
            'modes' => Shipments::MODES,
            'checks' => Shipments::PORT_CHECKS,
            'done' => (clone $q)->where('status', 'received')->count(),
        ];
    }
}
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/ShipmentScanStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/ShipmentScanStation.php' <<'DISPATCH_FILE_END_11'
<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station for a sea shipment, used by the Scan app: Port check (the boxes handed over at
 * the port) or Receive (the partner hub scans the container in).
 */
abstract class ShipmentScanStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    /** port or received */
    protected static string $step = 'port';

    /** The box's set at the hub: "2 of 3 arrived · 1 still in Manila". */
    public ?array $setInfo = null;

    /** The box is for another hub (added to the Wrong hub list). */
    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'sea_shipment_id';
    }

    protected function selectionLabel(): string
    {
        return 'a shipment';
    }

    /** Shipments open for this scan. */
    abstract protected function shipments(): \Illuminate\Database\Eloquent\Builder;

    protected function selected(): ?SeaShipment
    {
        return $this->shipments()->find($this->data['sea_shipment_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $s = $this->selected();
        if (! $s) {
            $this->scanResult('danger', 'That shipment is not open for this scan any more.');

            return;
        }
        $row = Tripinvoice::with('invdata.whSection')->where('deliverylog_id', $s->deliverylog_id)->where('invoice', $code)->latest('id')->first();
        if (! $row) {
            $other = $this->invoicesMatching($code)->first();
            $this->scanResult('danger', "{$code} is not in shipment {$s->code}.", $other);

            return;
        }
        if (static::$step === 'port' && ! $row->is_loaded) {
            $this->scanResult('warning', "{$code} was never scanned onto trip {$s->trip?->trip_number} at the warehouse. Check where it came from.", $row->invdata);

            return;
        }
        $prev = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('invoice_id', $row->invoice_id)->where('step', static::$step)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', "{$code} was already scanned".($who ? " by {$who}" : '').($prev->created_at ? ' at '.\Illuminate\Support\Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

            return;
        }
        Shipments::scan($s, $row, static::$step);

        if (static::$step === 'received') {
            $this->setInfo = $row->invdata ? Shipments::setAtHub($s, $row->invdata) : null;
            if ($wrong = Shipments::checkWrongHub($s, $row)) {
                $this->route = ['kind' => 'wrong', 'code' => '⛔', 'name' => 'Not ours: for '.($wrong->correctHub?->hub_name ?? 'another hub'), 'color' => '#c8372d', 'why' => 'Put it aside. It is on the Wrong hub & returns list.'];
                $this->scanResult('warning', "{$code} is for ".($wrong->correctHub?->hub_name ?? 'another hub').'. Received, and put on the Wrong hub & returns list.', $row->invdata);

                return;
            }
        }
        $this->scanResult('success', "{$code} ".(static::$step === 'port' ? 'handed over at the port.' : 'received.'), $row->invdata);
    }

    public function progress(): array
    {
        $s = $this->selected();
        if (! $s) {
            return ['loaded' => 0, 'total' => 0];
        }

        return [
            'loaded' => SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', static::$step)->count(),
            'total' => Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->where('is_loaded', true)->count(),
        ];
    }

    public function team(): array
    {
        $id = $this->data['sea_shipment_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = SeaShipmentScan::where('sea_shipment_id', $id)->where('step', static::$step)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return null;
    }

    public function photoContext(): array
    {
        return [];
    }

    public function appChoices(): Collection
    {
        return $this->shipments()->latest('id')->limit(40)->get()->map(fn (SeaShipment $s) => [
            'id' => $s->id, 'name' => $s->code.' → '.($s->hub?->hub_name ?? ''), 'active' => true,
            'sub' => collect([$s->van_no ? 'Van '.$s->van_no : null, Shipments::label($s), $s->eta ? 'ETA '.$s->eta->format('M j') : null])->filter()->join(' · '),
        ]);
    }

    protected function hub(string $panel): int|false|null
    {
        return Tracker::hubFor(Auth::user(), $panel);
    }
}
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/WrongHubPage.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/WrongHubPage.php' <<'DISPATCH_FILE_END_12'
<?php

namespace App\Filament\Shared\Shipping;

use App\Models\Shipping\WrongHubBox;
use App\Support\Shipping\Shipments;
use App\Support\Shipping\WrongHub;
use App\Support\Tracking\Tracker;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Wrong hub & returns: boxes at a partner hub that are not theirs, or go back. Partner hub and Admin. */
abstract class WrongHubPage extends Page
{
    protected string $view = 'filament.shipping.wrong-hub';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUturnLeft;

    protected static ?string $navigationLabel = 'Wrong hub & returns';

    protected static ?string $title = 'Wrong hub & returns';

    protected static ?string $slug = 'wrong-hub';

    #[Url]
    public string $tab = 'list';

    public string $code = '';

    public string $reason = 'refused';

    public string $note = '';

    public static function canAccess(): bool
    {
        return Shipments::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    protected function hub(): ?int
    {
        $h = Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());

        return is_int($h) ? $h : null;
    }

    protected function find(int $id): ?WrongHubBox
    {
        return WrongHubBox::with('correctHub', 'tripinvoice')->when($this->hub(), fn ($q, $h) => $q->where('logistichub_id', $h))->find($id);
    }

    public function addBox(): void
    {
        $hub = $this->hub() ?? (int) Auth::user()?->logistichub_id;
        $this->validate(['code' => 'required|string|max:40', 'reason' => 'required|in:'.implode(',', array_keys(WrongHubBox::REASONS))]);
        $w = WrongHub::add($hub, mb_strtoupper(trim($this->code)), $this->reason, trim($this->note) ?: null);
        if (! $w) {
            $this->addError('code', 'That box is not at your hub (or it is already delivered).');

            return;
        }
        $this->reset('code', 'note');
        Notification::make()->title($w->invoice?->invoice.' added')->success()->send();
    }

    public function sendToHub(int $id): void
    {
        $w = $this->find($id);
        if ($w && $w->status === 'waiting' && WrongHub::sendToHub($w)) {
            Notification::make()->title('Handed over to '.$w->correctHub?->hub_name)->success()->send();
        }
    }

    public function sendBack(int $id): void
    {
        $w = $this->find($id);
        if ($w && $w->status === 'waiting') {
            WrongHub::sendBack($w)
                ? Notification::make()->title('Back to the warehouse: the box is in the pool again')->success()->send()
                : Notification::make()->title('Could not take it off its trip (the trip may be locked).')->warning()->send();
        }
    }

    public function setHub(int $id, ?int $hubId): void
    {
        $w = $this->find($id);
        if ($w && $w->status === 'waiting') {
            $w->update(['correct_hub_id' => $hubId ?: null]);
        }
    }

    protected function getViewData(): array
    {
        $hub = $this->hub();
        $list = WrongHubBox::with(['invoice', 'correctHub', 'hub', 'shipment'])->when($hub, fn ($q) => $q->where('logistichub_id', $hub))
            ->orderByRaw("case when status = 'waiting' then 0 else 1 end")->latest('id')->limit(100)->get();

        return [
            'list' => $list->map(fn ($w) => ['w' => $w, 'tip' => WrongHub::suggestion($w)]),
            'report' => $this->tab === 'report' ? WrongHub::report($hub) : null,
            'reasons' => WrongHubBox::REASONS,
            'hubs' => \App\Models\Logistichub::where('is_company', true)->orderBy('hub_name')->pluck('hub_name', 'id'),
            'isAdmin' => $hub === null,
        ];
    }
}
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- app/Filament/Warehouse/Pages/SeaShipment.php
mkdir -p 'app/Filament/Warehouse/Pages'
cat > 'app/Filament/Warehouse/Pages/SeaShipment.php' <<'DISPATCH_FILE_END_13'
<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\Shipping\SeaShipmentPage;

class SeaShipment extends SeaShipmentPage {}
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- app/Filament/Warehouse/Pages/SeaShipments.php
mkdir -p 'app/Filament/Warehouse/Pages'
cat > 'app/Filament/Warehouse/Pages/SeaShipments.php' <<'DISPATCH_FILE_END_14'
<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\Shipping\SeaShipmentsPage;

class SeaShipments extends SeaShipmentsPage {}
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- app/Models/Shipping/SeaShipment.php
mkdir -p 'app/Models/Shipping'
cat > 'app/Models/Shipping/SeaShipment.php' <<'DISPATCH_FILE_END_15'
<?php

namespace App\Models\Shipping;

use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Support\Facades\Storage;

/** A container van (or a RoRo truck) taking a trip's boxes by sea to a partner hub. */
class SeaShipment extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['status_log' => 'array', 'etd' => 'date', 'eta' => 'date', 'port_at' => 'datetime',
            'cost_freight' => 'float', 'cost_trucking' => 'float', 'cost_port' => 'float', 'cost_other' => 'float'];
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }

    public function scans(): HasMany
    {
        return $this->hasMany(SeaShipmentScan::class);
    }

    /** The boxes: the trip's boxes. */
    public function boxes(): HasMany
    {
        return $this->hasMany(Tripinvoice::class, 'deliverylog_id', 'deliverylog_id');
    }

    public function cost(): float
    {
        return (float) $this->cost_freight + (float) $this->cost_trucking + (float) $this->cost_port + (float) $this->cost_other;
    }

    public function fileUrl(?string $path): ?string
    {
        return $path ? Storage::disk('public')->url($path) : null;
    }
}
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- app/Models/Shipping/SeaShipmentScan.php
mkdir -p 'app/Models/Shipping'
cat > 'app/Models/Shipping/SeaShipmentScan.php' <<'DISPATCH_FILE_END_16'
<?php

namespace App\Models\Shipping;

use Illuminate\Database\Eloquent\Model;

class SeaShipmentScan extends Model
{
    public const UPDATED_AT = null;

    protected $guarded = [];
}
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- app/Models/Shipping/WrongHubBox.php
mkdir -p 'app/Models/Shipping'
cat > 'app/Models/Shipping/WrongHubBox.php' <<'DISPATCH_FILE_END_17'
<?php

namespace App\Models\Shipping;

use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A box at a partner hub that is not theirs, or could not be delivered and goes back. */
class WrongHubBox extends Model
{
    protected $guarded = [];

    public const REASONS = ['wrong_hub' => 'Wrong hub', 'refused' => 'Refused by receiver', 'moved' => 'Receiver moved', 'wrong_address' => 'Wrong address', 'other' => 'Other'];

    public const STATUS = ['waiting' => 'Waiting', 'sent_hub' => 'Sent to the right hub', 'back' => 'Back to the warehouse', 'done' => 'Done'];

    protected function casts(): array
    {
        return ['done_at' => 'datetime'];
    }

    public function invoice(): BelongsTo
    {
        return $this->belongsTo(Invoice::class);
    }

    public function tripinvoice(): BelongsTo
    {
        return $this->belongsTo(Tripinvoice::class);
    }

    public function hub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'logistichub_id');
    }

    public function correctHub(): BelongsTo
    {
        return $this->belongsTo(Logistichub::class, 'correct_hub_id');
    }

    public function shipment(): BelongsTo
    {
        return $this->belongsTo(SeaShipment::class, 'sea_shipment_id');
    }
}
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- app/Support/Boxes/BoxSets.php
mkdir -p 'app/Support/Boxes'
cat > 'app/Support/Boxes/BoxSets.php' <<'DISPATCH_FILE_END_18'
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

    /** Text the customer once per trip: some boxes are on the way, the rest follow (SMS kind "set_split", off by default). */
    public static function textRestFollows(SetSplit $split, Deliverylog $trip, string $tripColumn = 'deliverylog_id', string $loadedColumn = 'is_loaded'): void
    {
        try {
            if (! \App\Support\Sms\SmsSettings::on('set_split') || ! ($inv = $split->invoice)) {
                return;
            }
            $key = substr(sha1('split'.$trip->id.$inv->set_key), 0, 40);
            if (\App\Models\Sms\SmsMessage::where('kind', 'set_split')->where('receiver_key', $key)->exists()) {
                return;
            }
            $ids = static::members($inv)->pluck('id');
            $loaded = Tripinvoice::whereIn('invoice_id', $ids)->where($tripColumn, $trip->id)->where($loadedColumn, true)->count();
            $behind = SetSplit::where('deliverylog_id', $trip->id)->whereIn('invoice_id', $ids)->with('invoice')->get()->pluck('invoice.invoice')->filter();
            $lang = \App\Support\Sms\Templates::langFor($inv->receiver_province);
            $text = \App\Support\Sms\Templates::render(\App\Support\Sms\Templates::get('set_split', $lang), [
                'name' => \App\Support\Sms\SmsEvents::firstName($inv->receiver_name), 'box_count' => $loaded,
                'boxes' => \App\Support\Sms\SmsEvents::codes($behind->all()), 'hub_phone' => \App\Support\Sms\SmsSettings::officePhone(),
            ]);
            \App\Support\Sms\SmsSender::send('set_split', $inv->receiver_mobile_no, Str::title((string) $inv->receiver_name), $text,
                ['receiver_key' => $key, 'deliverylog_id' => $trip->id, 'invoice_ids' => $ids->all(), 'lang' => $lang]);
        } catch (\Throwable $e) {
            report($e);
        }
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
DISPATCH_FILE_END_18

# ---------------------------------------------------------------- app/Support/Help/DefaultGuides.php
mkdir -p 'app/Support/Help'
cat > 'app/Support/Help/DefaultGuides.php' <<'DISPATCH_FILE_END_19'
<?php

namespace App\Support\Help;

/**
 * The guides the system starts with, in English and Tagalog. They are copied into
 * the help_guides table once (missing slugs only), then Admin → Help guides can edit them.
 *
 * Apps: admin, warehouse, company (partner hub), scan (Scan app), driver (Driver app).
 * "pages" are route names without the panel part ("pages.scaninvoice", "resources.deliverylogs.*"):
 * the "?" on those pages opens this guide. "links" are where "Do it now" goes, per app.
 */
class DefaultGuides
{
    /** topic => [icon, English, Tagalog] */
    public const TOPICS = [
        'boxes' => ['📦', 'Boxes & inventory', 'Mga box at inventory'],
        'trips' => ['🚚', 'Trips & loading', 'Mga trip at pag-load'],
        'trucks' => ['📍', 'Trucks & tracking', 'Mga truck at tracking'],
        'receivers' => ['💬', 'Receivers & SMS', 'Mga receiver at SMS'],
        'apps' => ['📱', 'Phone apps', 'Mga app sa phone'],
        'settings' => ['⚙️', 'Settings & AI', 'Settings at AI'],
    ];

    public static function all(): array
    {
        $s = fn (string $te, string $xe, string $tt, string $xt, ?string $img = null) => ['title_en' => $te, 'text_en' => $xe, 'title_tl' => $tt, 'text_tl' => $xt, 'image' => $img];
        $p = fn (string $qe, string $ae, string $qt, string $at) => ['q_en' => $qe, 'a_en' => $ae, 'q_tl' => $qt, 'a_tl' => $at];
        $img = fn (string $name) => 'images/help/'.$name.'.jpg';

        return [
            // ───────────────────────────── boxes ─────────────────────────────
            [
                'slug' => 'unload-container', 'topic' => 'boxes', 'icon' => '📥', 'apps' => ['admin', 'warehouse', 'scan'],
                'title_en' => 'Unload a container', 'title_tl' => 'Mag-unload ng container',
                'summary_en' => 'Scan every box as it comes off the container. Each scanned box is checked and counted in the inventory.',
                'summary_tl' => 'I-scan ang bawat box pagbaba sa container. Ang na-scan na box ay checked at bilang na sa inventory.',
                'when_en' => 'A container arrived at the warehouse and the boxes are being taken off.',
                'when_tl' => 'Dumating ang container sa bodega at ibinababa na ang mga box.',
                'steps' => [
                    $s('Open Unload', 'In the Scan app tap Unload container. On a computer open Unload Container in the menu.', 'Buksan ang Unload', 'Sa Scan app, pindutin ang Unload container. Sa computer, buksan ang Unload Container sa menu.', $img('scan-home')),
                    $s('Choose the container', 'Pick the container number from the list. Only containers that are not finished are shown.', 'Piliin ang container', 'Piliin ang container number sa listahan. Ang lalabas lang ay mga container na hindi pa tapos.', $img('unload')),
                    $s('Scan each box', 'Scan the barcode on every box. Green means checked. Red tells you why (wrong container, already scanned, not on the list).', 'I-scan ang bawat box', 'I-scan ang barcode ng bawat box. Green ay okay. Kapag red, sasabihin kung bakit (ibang container, na-scan na, wala sa listahan).'),
                    $s('Take a photo if asked', 'If box photos are switched on, take the photo and mark damaged or wet boxes.', 'Mag-picture kung hinihingi', 'Kung naka-on ang box photos, mag-picture at markahan kung sira o basa ang box.'),
                    $s('Finish', 'When all boxes are scanned, press Finish. The boxes left over are listed as missing.', 'Tapusin', 'Kapag na-scan na lahat, pindutin ang Finish. Ang mga hindi na-scan ay ililista na missing.'),
                ],
                'result_en' => 'The boxes are now in the inventory and can be put on a trip.',
                'result_tl' => 'Nasa inventory na ang mga box at puwede nang ilagay sa trip.',
                'problems' => [
                    $p('The box is not on the list', 'It may be on another container or not on the manifest. Put it aside and tell the office; it shows in Unmanifested.', 'Wala sa listahan ang box', 'Baka nasa ibang container o wala sa manifest. Itabi muna at sabihan ang office; lalabas ito sa Unmanifested.'),
                    $p('It says already scanned', 'That box was scanned before. Nothing to do, go to the next box.', 'Sabi ay na-scan na', 'Na-scan na dati ang box. Wala nang gagawin, sunod na box na.'),
                ],
                'pages' => ['pages.scaninvoice', 'pages.unloadedcontainer', 'resources.containers.*', 'resources.unmanifesteds.*'],
                'links' => ['admin' => 'pages.scaninvoice', 'warehouse' => 'pages.unloadedcontainer'],
                'related' => ['inventory-count', 'box-photos', 'search-box'], 'sort' => 10,
            ],
            [
                'slug' => 'inventory-count', 'topic' => 'boxes', 'icon' => '🔢', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'How the inventory counts', 'title_tl' => 'Paano binibilang ang inventory',
                'summary_en' => 'A box is counted when it was scanned at Unload, is not delivered, and is not on a truck.',
                'summary_tl' => 'Bilang ang box kapag na-scan sa Unload, hindi pa na-deliver, at wala sa truck.',
                'when_en' => 'The number in Inventories looks too high or too low, or one box is missing from it.',
                'when_tl' => 'Mukhang sobra o kulang ang bilang sa Inventories, o may box na wala roon.',
                'steps' => [
                    $s('It goes in at Unload', 'A box is added when it is scanned at Unload Container (or received at Warehouse unload).', 'Pumapasok sa Unload', 'Nadadagdag ang box kapag na-scan sa Unload Container (o natanggap sa Warehouse unload).'),
                    $s('It goes out at Load Truck', 'When the box is scanned onto a truck it leaves the inventory, even before it is delivered.', 'Lumalabas sa Load Truck', 'Kapag na-scan na pasakay sa truck, bawas na ito sa inventory, kahit hindi pa na-deliver.'),
                    $s('It comes back at Return Boxes', 'A box that was not delivered is counted again only after it is scanned in Return Boxes.', 'Bumabalik sa Return Boxes', 'Ang box na hindi na-deliver ay bibilang ulit lang kapag na-scan sa Return Boxes.'),
                    $s('Delivered boxes never count', 'Once delivered, a box is gone from the inventory for good.', 'Ang na-deliver ay hindi na bilang', 'Kapag na-deliver na, wala na ito sa inventory.'),
                ],
                'result_en' => 'Inventory = scanned in, minus loaded on a truck, plus returned, minus delivered.',
                'result_tl' => 'Inventory = na-scan papasok, bawas ang naka-load sa truck, dagdag ang na-return, bawas ang na-deliver.',
                'problems' => [
                    $p('A box was not delivered but is not in inventory', 'It is still "on the truck". Scan it in Return Boxes and it is counted again.', 'Hindi na-deliver pero wala sa inventory', 'Naka-"on the truck" pa ito. I-scan sa Return Boxes at bibilang na ulit.'),
                    $p('A box is in inventory but not in the warehouse', 'It was never scanned onto the truck. Search the box to see its last scan.', 'Nasa inventory pero wala sa bodega', 'Hindi ito na-scan sa Load Truck. Hanapin ang box para makita ang huling scan.'),
                ],
                'pages' => ['resources.inventories.*', 'pages.dashboard'],
                'links' => ['admin' => 'resources.inventories.index', 'warehouse' => 'resources.inventories.index'],
                'related' => ['return-boxes', 'unload-container', 'search-box'], 'sort' => 20,
            ],
            [
                'slug' => 'search-box', 'topic' => 'boxes', 'icon' => '🔍', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Find a box and see where it is', 'title_tl' => 'Hanapin ang box at kung nasaan ito',
                'summary_en' => 'Type the invoice number to see every scan of the box: unload, trip, truck, delivered or not, with photos.',
                'summary_tl' => 'I-type ang invoice number para makita ang lahat ng scan ng box: unload, trip, truck, na-deliver o hindi, may photos.',
                'when_en' => 'A receiver or a consolidator asks where a box is.',
                'when_tl' => 'May receiver o consolidator na nagtatanong kung nasaan ang box.',
                'steps' => [
                    $s('Open the search', 'Open Search Invoice (Partner hub: Track a box).', 'Buksan ang search', 'Buksan ang Search Invoice (sa Partner hub: Track a box).'),
                    $s('Type the invoice number', 'Type all or part of the number and press Enter.', 'I-type ang invoice number', 'I-type ang buo o bahagi ng number at pindutin ang Enter.'),
                    $s('Read the history', 'The newest step is on top: which trip and truck, who scanned it and when, and the delivery photos.', 'Basahin ang history', 'Nasa itaas ang pinakabago: anong trip at truck, sino ang nag-scan at kailan, at ang delivery photos.'),
                ],
                'result_en' => 'You know where the box is and who had it last.',
                'result_tl' => 'Alam mo na kung nasaan ang box at sino ang huling may hawak.',
                'problems' => [
                    $p('Nothing found', 'Check the number on the label. If it was never unloaded it is not in the system yet; check Unmanifested.', 'Walang lumabas', 'Tingnan ulit ang number sa label. Kung hindi pa na-unload, wala pa sa system; tingnan ang Unmanifested.'),
                ],
                'pages' => ['resources.searchinvs.*', 'pages.track'],
                'links' => ['admin' => 'resources.searchinvs.index', 'warehouse' => 'resources.searchinvs.index', 'company' => 'pages.track'],
                'related' => ['inventory-count', 'box-photos'], 'sort' => 30,
            ],
            [
                'slug' => 'box-photos', 'topic' => 'boxes', 'icon' => '📷', 'apps' => ['admin', 'warehouse', 'company', 'scan'],
                'title_en' => 'Box photos', 'title_tl' => 'Mga photo ng box',
                'summary_en' => 'Photos taken at unload, loading, return and delivery are kept with the box. See them all in Box Photos.',
                'summary_tl' => 'Ang photos sa unload, loading, return at delivery ay nakatabi sa box. Makikita lahat sa Box Photos.',
                'when_en' => 'You need proof a box was fine, damaged, or delivered.',
                'when_tl' => 'Kailangan mo ng patunay na okay, sira, o na-deliver ang box.',
                'steps' => [
                    $s('Choose when photos are needed', 'Admin → Settings → Box photos: switch photos on for unload, load, return, and pick "every box" or "only damaged".', 'Piliin kung kailan kailangan ng photo', 'Admin → Settings → Box photos: i-on ang photos sa unload, load, return, at piliin kung "lahat ng box" o "sira lang".'),
                    $s('Take the photo while scanning', 'After the scan, the Scan app asks for the photo and the condition (good, damaged, wet, opened).', 'Mag-picture habang nag-i-scan', 'Pagkatapos ng scan, hihingi ang Scan app ng photo at kondisyon (okay, sira, basa, bukas).'),
                    $s('Look at them later', 'Open Box Photos, search the invoice, and open a photo to see it big.', 'Tingnan mamaya', 'Buksan ang Box Photos, hanapin ang invoice, at buksan ang photo para lumaki.'),
                ],
                'result_en' => 'Every photo is kept with the box and its scan.',
                'result_tl' => 'Nakatabi ang bawat photo kasama ng box at scan nito.',
                'problems' => [
                    $p('The photo did not upload', 'Weak signal. Tap the photo button again; the scan itself is already saved.', 'Hindi na-upload ang photo', 'Mahina ang signal. Pindutin ulit ang photo; naka-save na ang scan mismo.'),
                ],
                'pages' => ['pages.box-photos', 'pages.box-photo-settings'],
                'links' => ['admin' => 'pages.box-photos', 'warehouse' => 'pages.box-photos', 'company' => 'pages.box-photos'],
                'related' => ['unload-container', 'driver-deliver'], 'sort' => 40,
            ],
            [
                'slug' => 'return-boxes', 'topic' => 'boxes', 'icon' => '↩️', 'apps' => ['admin', 'warehouse', 'company', 'scan'],
                'title_en' => 'Return a box that was not delivered', 'title_tl' => 'I-return ang box na hindi na-deliver',
                'summary_en' => 'When the truck comes back, scan the boxes that were not delivered. They go back to the inventory.',
                'summary_tl' => 'Pagbalik ng truck, i-scan ang mga box na hindi na-deliver. Babalik sila sa inventory.',
                'when_en' => 'A truck is back with boxes the driver could not deliver.',
                'when_tl' => 'Bumalik ang truck na may mga box na hindi na-deliver ng driver.',
                'steps' => [
                    $s('Open Return Boxes', 'In the Scan app tap Return boxes. On a computer open Return Boxes (Warehouse: Hub Return Boxes).', 'Buksan ang Return Boxes', 'Sa Scan app, pindutin ang Return boxes. Sa computer, buksan ang Return Boxes (Warehouse: Hub Return Boxes).'),
                    $s('Choose the trip', 'Pick the trip the box was on. The list shows how many boxes are still out.', 'Piliin ang trip', 'Piliin ang trip kung saan nakasakay ang box. Makikita kung ilan pa ang nasa labas.', $img('return')),
                    $s('Scan each box', 'Scan every box that came back. Green means it is back in the inventory.', 'I-scan ang bawat box', 'I-scan ang bawat box na bumalik. Green ay balik na sa inventory.'),
                    $s('Finish', 'Press Finish. The returned boxes can be planned on a new trip.', 'Tapusin', 'Pindutin ang Finish. Puwede nang ilagay ulit sa bagong trip ang mga box.'),
                ],
                'result_en' => 'The boxes are counted in the inventory again, marked "returned".',
                'result_tl' => 'Bilang na ulit sa inventory ang mga box, may markang "returned".',
                'problems' => [
                    $p('It says the box was delivered', 'The driver pressed Deliver. If it was a mistake, the driver can Undo within 30 minutes; after that ask the office.', 'Sabi ay na-deliver na', 'Pinindot ng driver ang Deliver. Kung mali, puwedeng mag-Undo ang driver sa loob ng 30 minuto; pagkatapos noon, sa office na.'),
                ],
                'pages' => ['pages.return-boxes', 'pages.hub-return-boxes'],
                'links' => ['admin' => 'pages.return-boxes', 'warehouse' => 'pages.hub-return-boxes', 'company' => 'pages.return-boxes'],
                'related' => ['inventory-count', 'not-delivered-list', 'driver-cant-deliver'], 'sort' => 50,
            ],

            // ───────────────────────────── trips ─────────────────────────────
            [
                'slug' => 'create-trip', 'topic' => 'trips', 'icon' => '🗓️', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Make a delivery trip', 'title_tl' => 'Gumawa ng delivery trip',
                'summary_en' => 'A trip is one truck going out on one day. Make the trip, then add the boxes by area.',
                'summary_tl' => 'Ang trip ay isang truck na lalabas sa isang araw. Gawin ang trip, tapos idagdag ang mga box ayon sa area.',
                'when_en' => 'Boxes are in the inventory and a truck is free.',
                'when_tl' => 'May mga box sa inventory at may bakanteng truck.',
                'steps' => [
                    $s('New trip', 'Open Delivery Log and press New. Choose the truck and the date it leaves.', 'Bagong trip', 'Buksan ang Delivery Log at pindutin ang New. Piliin ang truck at petsa ng alis.', $img('create-trip')),
                    $s('Add the boxes', 'Open Assign invoices, choose the trip, pick the areas (province, city, barangay) and add the boxes.', 'Idagdag ang mga box', 'Buksan ang Assign invoices, piliin ang trip, piliin ang mga area (probinsya, siyudad, barangay) at idagdag ang mga box.'),
                    $s('Check the order', 'Press Stops & loading on the trip. The system puts the stops in order and says which boxes go to the front or back.', 'Tingnan ang order', 'Pindutin ang Stops & loading sa trip. Iaayos ng system ang mga stop at sasabihin kung aling box ang sa harap o likod.'),
                    $s('Load the truck', 'Scan the boxes in Load Truck. See the guide "Load a truck".', 'I-load ang truck', 'I-scan ang mga box sa Load Truck. Tingnan ang gabay na "Mag-load ng truck".'),
                ],
                'result_en' => 'The trip has its boxes and is ready to load. Partner hubs can also use Incoming boxes → Create trip.',
                'result_tl' => 'May mga box na ang trip at handa nang i-load. Sa Partner hub, puwede rin sa Incoming boxes → Create trip.',
                'problems' => [
                    $p('The truck is not in the list', 'The truck is already on an active trip, or it is switched off. Check Trucks.', 'Wala ang truck sa listahan', 'May active trip pa ang truck, o naka-off ito. Tingnan sa Trucks.'),
                    $p('Too many boxes for one truck', 'Make a second trip, or let the AI trip helper split them.', 'Sobra ang box para sa isang truck', 'Gumawa ng ikalawang trip, o hayaan ang AI trip helper na hatiin.'),
                ],
                'pages' => ['resources.deliverylogs.*', 'resources.whdeliverylogs.*', 'pages.routeinvoice', 'pages.hubroute', 'pages.incoming-boxes'],
                'links' => ['admin' => 'resources.deliverylogs.index', 'warehouse' => 'resources.deliverylogs.index', 'company' => 'pages.incoming-boxes'],
                'related' => ['ai-trip-helper', 'stops-loading', 'load-truck'], 'sort' => 10,
            ],
            [
                'slug' => 'ai-trip-helper', 'topic' => 'trips', 'icon' => '✨', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Let the AI draft the trips', 'title_tl' => 'Hayaan ang AI na gumawa ng draft ng trips',
                'summary_en' => 'The AI groups the ready boxes by area into your free trucks. You check, change, and press Create.',
                'summary_tl' => 'Igugrupo ng AI ang mga handang box ayon sa area sa mga bakanteng truck. Ikaw ang titingin, magbabago, at pipindot ng Create.',
                'when_en' => 'Many boxes are waiting and you want a quick first plan.',
                'when_tl' => 'Maraming box ang naghihintay at gusto mo ng mabilis na unang plano.',
                'steps' => [
                    $s('Open AI trip helper', 'Open AI trip helper in the menu. It must be switched on in Settings → AI.', 'Buksan ang AI trip helper', 'Buksan ang AI trip helper sa menu. Dapat naka-on ito sa Settings → AI.'),
                    $s('Press Draft trips', 'The AI keeps the same receiver together and puts priority and tried-before boxes first.', 'Pindutin ang Draft trips', 'Pinagsasama ng AI ang parehong receiver at inuuna ang priority at mga box na sinubukan na dati.'),
                    $s('Check and create', 'Move boxes or trucks if needed, then press Create. Trip numbers are given as usual.', 'Tingnan at i-create', 'Ilipat ang box o truck kung kailangan, tapos pindutin ang Create. Bibigyan ng trip number gaya ng dati.'),
                ],
                'result_en' => 'Real trips are made from the draft. Nothing is made until you press Create.',
                'result_tl' => 'Gagawa ng totoong trip mula sa draft. Walang mangyayari hangga\'t hindi pinipindot ang Create.',
                'problems' => [
                    $p('The page says AI is off', 'An admin switches it on in Settings → AI (an API key is needed).', 'Sabi ay naka-off ang AI', 'Ang admin ang mag-o-on sa Settings → AI (kailangan ng API key).'),
                ],
                'pages' => ['pages.ai-trips'],
                'links' => ['admin' => 'pages.ai-trips', 'warehouse' => 'pages.ai-trips', 'company' => 'pages.ai-trips'],
                'related' => ['create-trip', 'ai-settings'], 'sort' => 20,
            ],
            [
                'slug' => 'stops-loading', 'topic' => 'trips', 'icon' => '🧭', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Stops in order and the loading list', 'title_tl' => 'Pagkakasunod ng stops at ang loading list',
                'summary_en' => 'Each trip gets its stops in driving order and a loading list: the last stops go in FRONT (by the cab) first, the first stops go in the BACK (at the door) last.',
                'summary_tl' => 'Ang bawat trip ay may stops na naka-ayos sa daan at loading list: ang huling stops ay unang ipapasok sa HARAP (sa may cab), ang unang stops ay huli sa LIKOD (sa may pinto).',
                'when_en' => 'Before loading, so the first stops are easy to reach at the door.',
                'when_tl' => 'Bago mag-load, para madaling abutin sa pinto ang mga unang stop.',
                'steps' => [
                    $s('Open Stops & loading', 'In Delivery Log press Stops & loading on the trip row.', 'Buksan ang Stops & loading', 'Sa Delivery Log, pindutin ang Stops & loading sa row ng trip.', $img('stops')),
                    $s('Check the map', 'The stops are numbered on the map. Drag a stop to change the order, or press Sort again.', 'Tingnan ang mapa', 'May number ang mga stop sa mapa. I-drag para baguhin ang order, o pindutin ulit ang Sort.'),
                    $s('Print the loading list', 'Press Print loading list. It is grouped FRONT → MIDDLE → BACK, in the order to put the boxes in.', 'I-print ang loading list', 'Pindutin ang Print loading list. Naka-grupo ito HARAP → GITNA → LIKOD, ayon sa pagkakasunod ng pagpasok.'),
                ],
                'result_en' => 'The crew loads in the right order and the driver sees the same stops in the Driver app.',
                'result_tl' => 'Tama ang pagkaka-load ng crew at pareho ang stops na makikita ng driver sa Driver app.',
                'problems' => [
                    $p('A stop has no pin on the map', 'The address was not found. Fix it on the stop, or switch on AI address cleaning in Settings → Maps & routes.', 'Walang pin ang stop sa mapa', 'Hindi nahanap ang address. Ayusin sa stop, o i-on ang AI address cleaning sa Settings → Maps & routes.'),
                ],
                'pages' => ['pages.trip-stops', 'pages.maps-routes'],
                'links' => ['admin' => 'resources.deliverylogs.index', 'warehouse' => 'resources.deliverylogs.index', 'company' => 'resources.deliverylogs.index'],
                'related' => ['load-truck', 'maps-routes', 'driver-navigate'], 'sort' => 30,
            ],
            [
                'slug' => 'load-truck', 'topic' => 'trips', 'icon' => '🚛', 'apps' => ['admin', 'warehouse', 'company', 'scan'],
                'title_en' => 'Load a truck', 'title_tl' => 'Mag-load ng truck',
                'summary_en' => 'Scan each box as it goes on the truck. The screen says which spot it goes in: FRONT, MIDDLE or BACK.',
                'summary_tl' => 'I-scan ang bawat box pagsakay sa truck. Sasabihin ng screen kung saan ilalagay: HARAP, GITNA o LIKOD.',
                'when_en' => 'The trip has its boxes and the truck is at the loading bay.',
                'when_tl' => 'May mga box na ang trip at nasa loading bay na ang truck.',
                'steps' => [
                    $s('Open Load truck', 'In the Scan app tap Load truck (Partner hub: Hub load). On a computer open Load Truck.', 'Buksan ang Load truck', 'Sa Scan app, pindutin ang Load truck (Partner hub: Hub load). Sa computer, buksan ang Load Truck.'),
                    $s('Choose the trip', 'Pick the trip. You see how many boxes are left to load.', 'Piliin ang trip', 'Piliin ang trip. Makikita kung ilan pa ang hindi naka-load.', $img('load')),
                    $s('Scan and place', 'Scan each box and put it where the screen says. "Load next" shows which boxes to bring now.', 'I-scan at ilagay', 'I-scan ang bawat box at ilagay kung saan sinasabi ng screen. Ang "Load next" ay nagsasabi kung aling box ang susunod.'),
                    $s('Finish', 'Press Finish when all boxes are on. The driver can start the trip.', 'Tapusin', 'Pindutin ang Finish kapag nakasakay na lahat. Puwede nang umalis ang driver.'),
                ],
                'result_en' => 'The boxes are on the truck, out of the inventory, and in the Driver app.',
                'result_tl' => 'Nasa truck na ang mga box, bawas na sa inventory, at nasa Driver app na.',
                'problems' => [
                    $p('It says the box is on another trip', 'The box belongs to a different trip. Put it aside or ask the office to move it.', 'Sabi ay nasa ibang trip ang box', 'Sa ibang trip ang box. Itabi muna o ipalipat sa office.'),
                    $p('It says too early', 'That box is for an early stop and goes near the door, so load the boxes for later stops first. Press Load it anyway if you are sure.', 'Sabi ay masyadong maaga', 'Para sa maagang stop ang box at ilalagay sa may pinto, kaya unahin ang mga box ng huling stops. Pindutin ang Load it anyway kung sigurado ka.'),
                ],
                'pages' => ['pages.scanload', 'pages.whloaded', 'pages.hubloaded', 'pages.load-truck'],
                'links' => ['admin' => 'pages.scanload', 'warehouse' => 'pages.hubloaded', 'company' => 'pages.load-truck'],
                'related' => ['stops-loading', 'create-trip', 'inventory-count'], 'sort' => 40,
            ],
            [
                'slug' => 'warehouse-transfer', 'topic' => 'trips', 'icon' => '🔁', 'apps' => ['warehouse', 'scan'],
                'title_en' => 'Move boxes to another warehouse', 'title_tl' => 'Ilipat ang mga box sa ibang bodega',
                'summary_en' => 'Load the boxes at Warehouse load here, and the other warehouse scans them at Warehouse unload.',
                'summary_tl' => 'I-load ang mga box sa Warehouse load dito, at i-scan sila ng kabilang bodega sa Warehouse unload.',
                'when_en' => 'Boxes must go to another warehouse before delivery.',
                'when_tl' => 'Kailangang dalhin muna ang mga box sa ibang bodega bago i-deliver.',
                'steps' => [
                    $s('Make the transfer trip', 'Open WH Delivery Logs and press New. Choose the truck and the warehouse it goes to.', 'Gumawa ng transfer trip', 'Buksan ang WH Delivery Logs at pindutin ang New. Piliin ang truck at ang bodegang pupuntahan.'),
                    $s('Load', 'In the Scan app tap Warehouse load, choose the trip, scan each box.', 'Mag-load', 'Sa Scan app, pindutin ang Warehouse load, piliin ang trip, i-scan ang bawat box.'),
                    $s('Receive', 'At the other warehouse tap Warehouse unload, choose the arriving trip, scan each box.', 'Tanggapin', 'Sa kabilang bodega, pindutin ang Warehouse unload, piliin ang dumarating na trip, i-scan ang bawat box.'),
                ],
                'result_en' => 'The boxes are in the other warehouse\'s inventory.',
                'result_tl' => 'Nasa inventory na ng kabilang bodega ang mga box.',
                'problems' => [
                    $p('The boxes are in neither inventory', 'They were loaded but not yet received. They count again once scanned at Warehouse unload.', 'Wala sa dalawang inventory ang box', 'Na-load pero hindi pa natatanggap. Bibilang ulit kapag na-scan sa Warehouse unload.'),
                ],
                'pages' => ['pages.whloaded', 'pages.whunloaded', 'resources.whdeliverylogs.*'],
                'links' => ['warehouse' => 'pages.whloaded'],
                'related' => ['inventory-count', 'load-truck'], 'sort' => 50,
            ],
            [
                'slug' => 'hub-boxes', 'topic' => 'trips', 'icon' => '🏬', 'apps' => ['admin', 'company'],
                'title_en' => 'Boxes at each partner hub', 'title_tl' => 'Mga box sa bawat partner hub',
                'summary_en' => 'The dashboard shows, for each hub, the boxes coming, waiting, on a truck, delivered and not delivered.',
                'summary_tl' => 'Makikita sa dashboard, bawat hub, ang mga box na paparating, naghihintay, nasa truck, na-deliver at hindi na-deliver.',
                'when_en' => 'You want to know how busy a hub is or which boxes are stuck.',
                'when_tl' => 'Gusto mong malaman kung gaano ka-busy ang hub o aling box ang naiipit.',
                'steps' => [
                    $s('Open the dashboard', 'The hub boxes are on the dashboard. The numbers refresh every minute.', 'Buksan ang dashboard', 'Nasa dashboard ang hub boxes. Nag-a-update ang bilang bawat minuto.'),
                    $s('Open a number', 'Click a number to see those boxes.', 'Buksan ang isang bilang', 'I-click ang bilang para makita ang mga box na iyon.'),
                    $s('Partner hub: Incoming boxes', 'At the hub, Incoming boxes shows what is coming and lets you make your own trip.', 'Partner hub: Incoming boxes', 'Sa hub, ang Incoming boxes ay nagpapakita ng paparating at puwede kang gumawa ng sariling trip.'),
                ],
                'result_en' => 'You see where every hub\'s boxes are.',
                'result_tl' => 'Makikita mo kung nasaan ang mga box ng bawat hub.',
                'problems' => [],
                'pages' => ['pages.dashboard', 'resources.logistichubs.*', 'pages.incoming-boxes'],
                'links' => ['admin' => 'pages.dashboard', 'company' => 'pages.incoming-boxes'],
                'related' => ['not-delivered-list', 'create-trip'], 'sort' => 60,
            ],
            [
                'slug' => 'not-delivered-list', 'topic' => 'trips', 'icon' => '⚠️', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Not delivered: what to do next', 'title_tl' => 'Hindi na-deliver: ano ang susunod',
                'summary_en' => 'Boxes the driver could not deliver are listed with the reason, the note and the photo. Call, plan again, or return.',
                'summary_tl' => 'Nakalista ang mga box na hindi na-deliver kasama ang dahilan, note at photo. Tawagan, i-plano ulit, o i-return.',
                'when_en' => 'After a trip, some boxes came back.',
                'when_tl' => 'Pagkatapos ng trip, may mga box na bumalik.',
                'steps' => [
                    $s('Open the list', 'Partner hub: Not delivered. Admin and Warehouse: the trip in Delivery Log, tab Not delivered.', 'Buksan ang listahan', 'Partner hub: Not delivered. Admin at Warehouse: ang trip sa Delivery Log, tab na Not delivered.'),
                    $s('Read the reason', 'No one home, address not found, refused… The driver\'s note and photo are there.', 'Basahin ang dahilan', 'Walang tao, hindi mahanap ang address, tinanggihan… Nandoon ang note at photo ng driver.'),
                    $s('Return the box', 'Scan it in Return Boxes when the truck is back.', 'I-return ang box', 'I-scan sa Return Boxes pagbalik ng truck.'),
                    $s('Plan it again', 'The returned box can go on the next trip. Tried-before boxes are put first.', 'I-plano ulit', 'Puwedeng isakay sa susunod na trip ang box na na-return. Inuuna ang mga box na sinubukan na.'),
                ],
                'result_en' => 'The box is back in the inventory and goes out again.',
                'result_tl' => 'Balik sa inventory ang box at lalabas ulit.',
                'problems' => [
                    $p('The receiver says it was never tried', 'Open the box history: the time, the place on the map and the photo show the try.', 'Sabi ng receiver hindi sinubukan', 'Buksan ang history ng box: ang oras, lugar sa mapa at photo ang patunay.'),
                ],
                'pages' => ['pages.not-delivered'],
                'links' => ['company' => 'pages.not-delivered', 'admin' => 'resources.deliverylogs.index', 'warehouse' => 'resources.deliverylogs.index'],
                'related' => ['return-boxes', 'driver-cant-deliver', 'sms-setup'], 'sort' => 70,
            ],

            // ───────────────────────────── trucks ─────────────────────────────
            [
                'slug' => 'truck-tracking', 'topic' => 'trucks', 'icon' => '📍', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'See where the trucks are', 'title_tl' => 'Tingnan kung nasaan ang mga truck',
                'summary_en' => 'Truck tracking shows every truck on a trip on a map, its stops, speed, and alerts.',
                'summary_tl' => 'Ipinapakita ng Truck tracking ang bawat truck na nasa trip sa mapa, ang stops, bilis, at alerts.',
                'when_en' => 'You want to know if a truck is on the way, late, or stopped.',
                'when_tl' => 'Gusto mong malaman kung paparating, late, o nakatigil ang truck.',
                'steps' => [
                    $s('Open Truck tracking', 'Open Truck tracking in the menu. Trucks on a trip are listed on the left.', 'Buksan ang Truck tracking', 'Buksan ang Truck tracking sa menu. Nasa kaliwa ang mga truck na nasa trip.', $img('tracking')),
                    $s('Pick a truck', 'Click a truck to see it on the map with its stops. The map refreshes every 30 seconds.', 'Pumili ng truck', 'I-click ang truck para makita sa mapa kasama ang stops. Nag-a-update ang mapa bawat 30 segundo.'),
                    $s('Open the truck page', 'Press Open truck for the day\'s route, Replay, and the Alerts tab.', 'Buksan ang page ng truck', 'Pindutin ang Open truck para sa ruta ng araw, Replay, at tab na Alerts.'),
                ],
                'result_en' => 'You see each truck\'s last place and how its trip is going.',
                'result_tl' => 'Makikita mo ang huling lugar ng bawat truck at kung kumusta ang trip.',
                'problems' => [
                    $p('The truck has no location', 'The driver has not agreed to location yet, or the phone has no signal. See "Location in the Driver app".', 'Walang location ang truck', 'Hindi pa pumapayag sa location ang driver, o walang signal ang phone. Tingnan ang "Location sa Driver app".'),
                    $p('Using a GPS tracker instead', 'Admin → Settings → Truck tracking gives each truck a tracker link to paste in the tracker\'s settings.', 'Gamit ay GPS tracker', 'Sa Admin → Settings → Truck tracking, may tracker link ang bawat truck na ilalagay sa settings ng tracker.'),
                ],
                'pages' => ['pages.truck-tracking', 'pages.truck-tracking.truck', 'pages.tracking-settings'],
                'links' => ['admin' => 'pages.truck-tracking', 'warehouse' => 'pages.truck-tracking', 'company' => 'pages.truck-tracking'],
                'related' => ['end-of-day', 'driver-location'], 'sort' => 10,
            ],
            [
                'slug' => 'end-of-day', 'topic' => 'trucks', 'icon' => '🌙', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'End-of-day truck summary', 'title_tl' => 'Buod ng mga truck sa dulo ng araw',
                'summary_en' => 'After work, the day in short: for each truck what went well and what to look at. It can also be emailed.',
                'summary_tl' => 'Pagkatapos ng trabaho, ang buod ng araw: sa bawat truck, ano ang maganda at ano ang dapat tingnan. Puwede ring i-email.',
                'when_en' => 'At the end of the day, or the next morning.',
                'when_tl' => 'Sa dulo ng araw, o kinaumagahan.',
                'steps' => [
                    $s('Open the summary', 'Truck tracking → End of day.', 'Buksan ang buod', 'Truck tracking → End of day.'),
                    $s('Choose the day', 'Pick a date to see an older day.', 'Piliin ang araw', 'Pumili ng petsa para makita ang lumang araw.'),
                    $s('Email it every day', 'Admin → Settings → Truck tracking: type the emails for the daily summary (sent 6 PM).', 'I-email araw-araw', 'Admin → Settings → Truck tracking: i-type ang mga email para sa araw-araw na buod (ipinapadala 6 PM).'),
                ],
                'result_en' => 'You know which trucks had a good day and which need a talk.',
                'result_tl' => 'Alam mo kung aling truck ang maganda ang araw at alin ang kailangang kausapin.',
                'problems' => [
                    $p('The summary has no AI notes', 'Switch on "End-of-day truck summary" in Settings → AI.', 'Walang AI notes ang buod', 'I-on ang "End-of-day truck summary" sa Settings → AI.'),
                ],
                'pages' => ['pages.truck-tracking.end-of-day'],
                'links' => ['admin' => 'pages.truck-tracking.end-of-day', 'warehouse' => 'pages.truck-tracking.end-of-day', 'company' => 'pages.truck-tracking.end-of-day'],
                'related' => ['truck-tracking', 'ai-settings'], 'sort' => 20,
            ],

            // ───────────────────────────── receivers ─────────────────────────────
            [
                'slug' => 'sms-setup', 'topic' => 'receivers', 'icon' => '💬', 'apps' => ['admin'],
                'title_en' => 'Send SMS to receivers', 'title_tl' => 'Magpadala ng SMS sa mga receiver',
                'summary_en' => 'Receivers get a text when the box is out for delivery, when the driver is next, delivered, or not delivered.',
                'summary_tl' => 'Makakatanggap ng text ang receiver kapag palabas na ang box, kapag sila na ang susunod, na-deliver, o hindi na-deliver.',
                'when_en' => 'You want receivers to know when their box comes.',
                'when_tl' => 'Gusto mong malaman ng receiver kung kailan darating ang box.',
                'steps' => [
                    $s('Get an SMS account', 'Make an account at Semaphore (semaphore.co) and copy the API key. Twilio also works.', 'Kumuha ng SMS account', 'Gumawa ng account sa Semaphore (semaphore.co) at kopyahin ang API key. Puwede rin ang Twilio.', $img('sms')),
                    $s('Paste the key', 'Settings → SMS: choose the provider, paste the key and the sender name, press Send test.', 'Ilagay ang key', 'Settings → SMS: piliin ang provider, ilagay ang key at sender name, pindutin ang Send test.'),
                    $s('Choose the messages', 'Switch on the texts you want and edit the words. Tagalog and Bisaya are used by province.', 'Piliin ang mga mensahe', 'I-on ang mga text na gusto mo at baguhin ang salita. Tagalog at Bisaya ayon sa probinsya.'),
                    $s('Watch the SMS log', 'SMS log shows every text and if it was sent, a bad number, or the receiver replied STOP.', 'Tingnan ang SMS log', 'Makikita sa SMS log ang bawat text at kung na-send, mali ang number, o nag-reply ng STOP ang receiver.'),
                ],
                'result_en' => 'One text per receiver at each step, within your monthly limit.',
                'result_tl' => 'Isang text bawat receiver sa bawat hakbang, pasok sa monthly limit mo.',
                'problems' => [
                    $p('Status says Bad number', 'The receiver\'s mobile number on the invoice is wrong or too short. Fix it on the invoice.', 'Bad number ang status', 'Mali o kulang ang mobile number ng receiver sa invoice. Ayusin sa invoice.'),
                    $p('How much does it cost?', 'Semaphore is about ₱0.50 per SMS (160 characters). Set a monthly limit in Settings → SMS.', 'Magkano ang bayad?', 'Sa Semaphore mga ₱0.50 bawat SMS (160 characters). Maglagay ng monthly limit sa Settings → SMS.'),
                ],
                'pages' => ['pages.sms-settings', 'pages.sms-log'],
                'links' => ['admin' => 'pages.sms-settings'],
                'related' => ['not-delivered-list', 'ai-settings'], 'sort' => 10,
            ],

            // ───────────────────────────── apps ─────────────────────────────
            [
                'slug' => 'install-apps', 'topic' => 'apps', 'icon' => '📲', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Put the Scan app and Driver app on a phone', 'title_tl' => 'Ilagay ang Scan app at Driver app sa phone',
                'summary_en' => 'Open the link on the phone and add it to the home screen. It works like an app.',
                'summary_tl' => 'Buksan ang link sa phone at i-add sa home screen. Gagana itong parang app.',
                'when_en' => 'A new crew member or driver starts.',
                'when_tl' => 'May bagong crew o driver.',
                'steps' => [
                    $s('Open Install apps', 'Open Install apps. Each app has a QR code.', 'Buksan ang Install apps', 'Buksan ang Install apps. May QR code ang bawat app.'),
                    $s('Scan the QR with the phone', 'The crew scans the Scan app QR; drivers scan the Driver app QR.', 'I-scan ang QR gamit ang phone', 'Ang crew ay i-scan ang QR ng Scan app; ang driver ay QR ng Driver app.'),
                    $s('Add to home screen', 'Android: tap Install. iPhone: Share → Add to Home Screen.', 'I-add sa home screen', 'Android: pindutin ang Install. iPhone: Share → Add to Home Screen.'),
                    $s('Sign in', 'Sign in with their own email and password.', 'Mag-sign in', 'Mag-sign in gamit ang sariling email at password.'),
                ],
                'result_en' => 'The app is on the phone\'s home screen.',
                'result_tl' => 'Nasa home screen na ng phone ang app.',
                'problems' => [
                    $p('The crew sees "can\'t scan here"', 'Their account type is wrong. Set it to Warehouse or Company in Users.', 'Sabi ng crew "can\'t scan here"', 'Mali ang account type. Gawing Warehouse o Company sa Users.'),
                ],
                'pages' => ['pages.install-apps', 'pages.app-icons'],
                'links' => ['warehouse' => 'pages.install-apps', 'company' => 'pages.install-apps'],
                'related' => ['driver-location'], 'sort' => 10,
            ],
            [
                'slug' => 'scan-tips', 'topic' => 'apps', 'icon' => '📷', 'apps' => ['scan'],
                'title_en' => 'Scanning tips', 'title_tl' => 'Mga tip sa pag-scan',
                'summary_en' => 'Green is good, red tells you what is wrong. Every scan is saved right away.',
                'summary_tl' => 'Green ay okay, red ay may mali at sasabihin kung ano. Naka-save agad ang bawat scan.',
                'when_en' => 'You are new to the Scan app.',
                'when_tl' => 'Bago ka sa Scan app.',
                'steps' => [
                    $s('Pick what you are doing', 'On the home screen tap Unload, Load, Return, or Hub load.', 'Piliin ang gagawin', 'Sa home screen, pindutin ang Unload, Load, Return, o Hub load.', $img('scan-home')),
                    $s('Hold the barcode flat', 'Keep the label 15–20 cm from the camera, in good light.', 'Itapat nang maayos ang barcode', 'Ilayo ang label nang 15–20 cm sa camera, sa maliwanag na lugar.'),
                    $s('Type it if it will not scan', 'Type the invoice number in the box under the camera and press →.', 'I-type kung ayaw ma-scan', 'I-type ang invoice number sa box sa ilalim ng camera at pindutin ang →.'),
                    $s('Read red messages', 'Red says why: wrong trip, already scanned, not on the list. Put the box aside and go on.', 'Basahin ang red na mensahe', 'Sinasabi ng red kung bakit: ibang trip, na-scan na, wala sa listahan. Itabi ang box at tuloy lang.'),
                ],
                'result_en' => 'Fast scanning with fewer mistakes.',
                'result_tl' => 'Mabilis na pag-scan at mas kaunting mali.',
                'problems' => [
                    $p('The camera does not open', 'Allow the camera for this app in the phone settings, then open the app again.', 'Ayaw bumukas ng camera', 'Payagan ang camera para sa app sa settings ng phone, tapos buksan ulit ang app.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['unload-container', 'load-truck', 'return-boxes'], 'sort' => 5,
            ],

            // ───────────────────────────── driver ─────────────────────────────
            [
                'slug' => 'driver-deliver', 'topic' => 'apps', 'icon' => '✅', 'apps' => ['driver', 'admin', 'company'],
                'title_en' => 'Deliver a box', 'title_tl' => 'Mag-deliver ng box',
                'summary_en' => 'Scan the box, check the name, take the proof photo, press Deliver.',
                'summary_tl' => 'I-scan ang box, tingnan ang pangalan, kunan ng proof photo, pindutin ang Deliver.',
                'when_en' => 'You are at the receiver with the box.',
                'when_tl' => 'Nasa receiver ka na dala ang box.',
                'steps' => [
                    $s('Scan the box', 'Tap Scan and point at the label.', 'I-scan ang box', 'Pindutin ang Scan at itapat sa label.', $img('driver-home')),
                    $s('Check before handing over', 'Check the receiver\'s name and the box number on the screen.', 'Tingnan bago iabot', 'Tingnan ang pangalan ng receiver at box number sa screen.'),
                    $s('Take the proof photo', 'Take a photo of the box with the receiver or at the door. You can add more than one.', 'Kunan ng proof photo', 'Kunan ng photo ang box kasama ang receiver o sa pinto. Puwedeng higit sa isa.'),
                    $s('Press Deliver', 'Press Deliver this box. The receiver gets a text if SMS is on.', 'Pindutin ang Deliver', 'Pindutin ang Deliver this box. Makakatanggap ng text ang receiver kung naka-on ang SMS.'),
                ],
                'result_en' => 'The box is delivered, with the time, place and photo.',
                'result_tl' => 'Na-deliver na ang box, may oras, lugar at photo.',
                'problems' => [
                    $p('It says not this box', 'The box is not on your trip. Keep it on the truck and tell the office.', 'Sabi ay "Not this box"', 'Wala sa trip mo ang box. Iwan sa truck at sabihan ang office.'),
                    $p('No signal', 'Deliver anyway. It is saved on the phone and sent when there is signal.', 'Walang signal', 'Mag-deliver pa rin. Naka-save sa phone at ipapadala kapag may signal na.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-undo', 'driver-cant-deliver', 'driver-offline'], 'sort' => 20,
            ],
            [
                'slug' => 'driver-cant-deliver', 'topic' => 'apps', 'icon' => '🚫', 'apps' => ['driver'],
                'title_en' => 'Can\'t deliver', 'title_tl' => 'Hindi ma-deliver',
                'summary_en' => 'Choose the reason, take a photo, and keep the box on the truck.',
                'summary_tl' => 'Piliin ang dahilan, mag-picture, at iwan ang box sa truck.',
                'when_en' => 'No one is home, the address is wrong, or the receiver refused.',
                'when_tl' => 'Walang tao, mali ang address, o tinanggihan ng receiver.',
                'steps' => [
                    $s('Scan the box', 'Scan it like a delivery, then press Can\'t deliver.', 'I-scan ang box', 'I-scan gaya ng delivery, tapos pindutin ang Can\'t deliver.'),
                    $s('Choose the reason', 'No one home, address not found, phone unreachable, refused, and others.', 'Piliin ang dahilan', 'Walang tao, hindi mahanap ang address, hindi ma-contact, tinanggihan, at iba pa.'),
                    $s('Photo and note', 'Take a photo of the place and add a short note. With voice note on, just say what happened.', 'Photo at note', 'Kunan ng photo ang lugar at maglagay ng maikling note. Kung naka-on ang voice note, sabihin lang ang nangyari.'),
                    $s('Keep it on the truck', 'Bring it back. The office scans it in Return Boxes.', 'Iwan sa truck', 'Ibalik ito. I-scan ng office sa Return Boxes.'),
                ],
                'result_en' => 'The box is marked not delivered with the reason; the office plans it again.',
                'result_tl' => 'Minarkahan ang box na hindi na-deliver kasama ang dahilan; ipa-plano ulit ng office.',
                'problems' => [
                    $p('The receiver came back', 'Scan the box again and press Deliver.', 'Bumalik ang receiver', 'I-scan ulit ang box at pindutin ang Deliver.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-deliver', 'return-boxes'], 'sort' => 30,
            ],
            [
                'slug' => 'driver-undo', 'topic' => 'apps', 'icon' => '↶', 'apps' => ['driver'],
                'title_en' => 'Undo a delivery', 'title_tl' => 'I-undo ang delivery',
                'summary_en' => 'Pressed Deliver by mistake? Undo it within 30 minutes.',
                'summary_tl' => 'Napindot ang Deliver nang mali? I-undo sa loob ng 30 minuto.',
                'when_en' => 'Wrong box, or the receiver did not get it.',
                'when_tl' => 'Maling box, o hindi natanggap ng receiver.',
                'steps' => [
                    $s('Right away', 'Tap Undo on the green bar that shows after Deliver.', 'Agad-agad', 'Pindutin ang Undo sa green bar na lumalabas pagkatapos ng Deliver.'),
                    $s('Later', 'Boxes → Delivered, find the box, tap Undo and choose why.', 'Mamaya', 'Boxes → Delivered, hanapin ang box, pindutin ang Undo at piliin kung bakit.'),
                ],
                'result_en' => 'The box is back in your To deliver list.',
                'result_tl' => 'Balik ang box sa listahan ng To deliver.',
                'problems' => [
                    $p('There is no Undo button', 'More than 30 minutes passed. Ask the office to undo it.', 'Walang Undo button', 'Lumampas na ng 30 minuto. Ipa-undo sa office.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-deliver'], 'sort' => 40,
            ],
            [
                'slug' => 'driver-navigate', 'topic' => 'apps', 'icon' => '🗺️', 'apps' => ['driver'],
                'title_en' => 'Go to the next stop', 'title_tl' => 'Pumunta sa susunod na stop',
                'summary_en' => 'Where to go next shows the next stop. Tap Navigate and choose Waze, Google Maps or Apple Maps.',
                'summary_tl' => 'Ipinapakita ng Where to go next ang susunod na stop. Pindutin ang Navigate at piliin ang Waze, Google Maps o Apple Maps.',
                'when_en' => 'You finished a stop and want directions to the next one.',
                'when_tl' => 'Tapos ka sa isang stop at gusto mo ng direksyon sa susunod.',
                'steps' => [
                    $s('Look at the next stop', 'On Today, Where to go next shows the receiver, the address and the boxes.', 'Tingnan ang susunod na stop', 'Sa Today, ipinapakita ng Where to go next ang receiver, address at mga box.'),
                    $s('Tap Navigate', 'Choose Waze, Google Maps or Apple Maps. The app opens with the route from where you are.', 'Pindutin ang Navigate', 'Piliin ang Waze, Google Maps o Apple Maps. Bubukas ang app na may ruta mula kung nasaan ka.'),
                    $s('Call if needed', 'Tap Call to phone the receiver before you arrive.', 'Tumawag kung kailangan', 'Pindutin ang Call para tawagan ang receiver bago dumating.'),
                ],
                'result_en' => 'You drive the stops in the planned order.',
                'result_tl' => 'Sinusunod mo ang stops ayon sa plano.',
                'problems' => [
                    $p('The pin is in the wrong place', 'Call the receiver. Tell the office so the address is fixed for next time.', 'Mali ang lugar ng pin', 'Tawagan ang receiver. Sabihan ang office para maayos ang address sa susunod.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-offline', 'driver-location'], 'sort' => 10,
            ],
            [
                'slug' => 'driver-location', 'topic' => 'apps', 'icon' => '📡', 'apps' => ['driver', 'admin', 'warehouse', 'company'],
                'title_en' => 'Location in the Driver app', 'title_tl' => 'Location sa Driver app',
                'summary_en' => 'During a trip the app sends the truck\'s location so the office sees it on the map. Only during trips.',
                'summary_tl' => 'Habang may trip, ipinapadala ng app ang location ng truck para makita ng office sa mapa. Habang may trip lang.',
                'when_en' => 'The app asks to use your location, or the office cannot see your truck.',
                'when_tl' => 'Humihingi ang app ng location, o hindi makita ng office ang truck mo.',
                'steps' => [
                    $s('Agree once', 'On the first trip the app asks. Tap I agree.', 'Pumayag minsan', 'Sa unang trip, magtatanong ang app. Pindutin ang I agree.'),
                    $s('Allow location on the phone', 'When the phone asks, tap Allow (Android: "While using the app"; iPhone: "Allow While Using App").', 'Payagan ang location sa phone', 'Kapag nagtanong ang phone, pindutin ang Allow (Android: "While using the app"; iPhone: "Allow While Using App").'),
                    $s('Keep the app open', 'Keep the Driver app open on the screen while driving, with the phone charging.', 'Panatilihing bukas ang app', 'Iwanang bukas ang Driver app sa screen habang nagmamaneho, naka-charge ang phone.'),
                ],
                'result_en' => 'The office sees the truck move. It stops when the trip ends.',
                'result_tl' => 'Nakikita ng office ang galaw ng truck. Titigil kapag tapos ang trip.',
                'problems' => [
                    $p('I pressed Block by mistake', 'Phone Settings → the browser or the app → Location → Allow. Then open the app again.', 'Napindot ang Block', 'Settings ng phone → browser o app → Location → Allow. Tapos buksan ulit ang app.'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['truck-tracking', 'driver-navigate'], 'sort' => 50,
            ],
            [
                'slug' => 'driver-offline', 'topic' => 'apps', 'icon' => '📶', 'apps' => ['driver'],
                'title_en' => 'No signal', 'title_tl' => 'Walang signal',
                'summary_en' => 'The Driver app keeps working with no signal. Deliveries wait on the phone and are sent later.',
                'summary_tl' => 'Gumagana pa rin ang Driver app kahit walang signal. Naka-hold sa phone ang deliveries at ipapadala mamaya.',
                'when_en' => 'The top bar says No signal or waiting to send.',
                'when_tl' => 'Sabi sa itaas ay No signal o waiting to send.',
                'steps' => [
                    $s('Keep working', 'Scan, deliver and take photos as usual.', 'Tuloy lang ang trabaho', 'Mag-scan, mag-deliver at mag-picture gaya ng dati.'),
                    $s('Watch the top bar', 'It shows how many are waiting to send.', 'Tingnan ang bar sa itaas', 'Ipinapakita kung ilan ang naghihintay maipadala.'),
                    $s('Signal comes back', 'Everything is sent by itself. Do not sign out until it says all sent.', 'Bumalik ang signal', 'Kusang maipapadala lahat. Huwag mag-sign out hangga\'t hindi sinasabing all sent.'),
                ],
                'result_en' => 'Nothing is lost when there is no signal.',
                'result_tl' => 'Walang nawawala kahit walang signal.',
                'problems' => [
                    $p('It says needs attention', 'One delivery could not be saved (for example the box was moved). Tap it and follow what it says.', 'Sabi ay needs attention', 'May isang delivery na hindi ma-save (hal. nailipat ang box). Pindutin ito at sundin ang sinasabi.'),
                    $p('Maps with no signal', 'Download the area in Google Maps or Waze before the trip (offline maps).', 'Mapa kahit walang signal', 'I-download ang area sa Google Maps o Waze bago ang trip (offline maps).'),
                ],
                'pages' => [], 'links' => [],
                'related' => ['driver-deliver', 'driver-navigate'], 'sort' => 60,
            ],

            // ───────────────────────────── settings ─────────────────────────────
            [
                'slug' => 'ai-settings', 'topic' => 'settings', 'icon' => '✨', 'apps' => ['admin'],
                'title_en' => 'Switch on the AI helpers', 'title_tl' => 'I-on ang mga AI helper',
                'summary_en' => 'Each AI helper is switched on one by one in Settings → AI, with a monthly spending limit.',
                'summary_tl' => 'Isa-isang ino-on ang bawat AI helper sa Settings → AI, may monthly na limit sa gastos.',
                'when_en' => 'A page says the AI is off, or you want to try a helper.',
                'when_tl' => 'Sabi ng page ay naka-off ang AI, o gusto mong subukan ang isang helper.',
                'steps' => [
                    $s('Open Settings → AI', 'Only an admin can open it.', 'Buksan ang Settings → AI', 'Admin lang ang makakabukas.'),
                    $s('Paste the API key', 'Paste the Anthropic API key and set the monthly limit.', 'Ilagay ang API key', 'Ilagay ang Anthropic API key at itakda ang monthly limit.'),
                    $s('Switch helpers on', 'Tick each helper you want (trip helper, photo check, SMS writer, Help answers…) and Save.', 'I-on ang mga helper', 'I-check ang bawat helper na gusto mo (trip helper, photo check, SMS writer, Help answers…) at i-Save.'),
                ],
                'result_en' => 'The helpers show in their pages and menus.',
                'result_tl' => 'Lalabas ang mga helper sa kanilang mga page at menu.',
                'problems' => [],
                'pages' => ['pages.ai-settings'],
                'links' => ['admin' => 'pages.ai-settings'],
                'related' => ['ai-trip-helper', 'sms-setup', 'help-edit'], 'sort' => 10,
            ],
            [
                'slug' => 'maps-routes', 'topic' => 'settings', 'icon' => '🗺️', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Maps & routes settings', 'title_tl' => 'Settings ng Maps & routes',
                'summary_en' => 'Choose the map, where trucks start, how stops are sorted, and if messy addresses are fixed by AI.',
                'summary_tl' => 'Piliin ang mapa, kung saan nagsisimula ang truck, paano inaayos ang stops, at kung aayusin ng AI ang magulong address.',
                'when_en' => 'Setting up the system, or stops are not found on the map.',
                'when_tl' => 'Sine-set up ang system, o hindi mahanap ang stops sa mapa.',
                'steps' => [
                    $s('Open Maps & routes', 'Settings → Maps & routes.', 'Buksan ang Maps & routes', 'Settings → Maps & routes.'),
                    $s('Start point', 'Set where each hub\'s trucks leave from.', 'Simula', 'Itakda kung saan umaalis ang mga truck ng bawat hub.'),
                    $s('Address cleaning', 'Switch on AI address cleaning so more stops are found.', 'Paglilinis ng address', 'I-on ang AI address cleaning para mas maraming stop ang mahanap.'),
                ],
                'result_en' => 'New trips are sorted with these settings.',
                'result_tl' => 'Aayusin ang mga bagong trip gamit ang settings na ito.',
                'problems' => [],
                'pages' => ['pages.maps-routes'],
                'links' => ['admin' => 'pages.maps-routes', 'warehouse' => 'pages.maps-routes', 'company' => 'pages.maps-routes'],
                'related' => ['stops-loading'], 'sort' => 20,
            ],
            [
                'slug' => 'help-edit', 'topic' => 'settings', 'icon' => '📝', 'apps' => ['admin'],
                'title_en' => 'Edit the help guides', 'title_tl' => 'Baguhin ang mga gabay',
                'summary_en' => 'Admins can change any guide, add screenshots, and write new guides for your team.',
                'summary_tl' => 'Puwedeng baguhin ng admin ang kahit anong gabay, magdagdag ng screenshot, at gumawa ng bagong gabay.',
                'when_en' => 'A guide is out of date or your team does something its own way.',
                'when_tl' => 'Luma na ang gabay o may sariling paraan ang team ninyo.',
                'steps' => [
                    $s('Open Help guides', 'Settings → Help guides.', 'Buksan ang Help guides', 'Settings → Help guides.'),
                    $s('Edit or add', 'Change the words in English and Tagalog, add steps, upload a screenshot for a step.', 'Baguhin o magdagdag', 'Baguhin ang salita sa English at Tagalog, magdagdag ng hakbang, mag-upload ng screenshot.'),
                    $s('Choose who sees it', 'Tick the panels and apps it shows in, then Save.', 'Piliin kung sino ang makakakita', 'I-check ang mga panel at app kung saan lalabas, tapos i-Save.'),
                ],
                'result_en' => 'Everyone sees the new guide right away. "Was this helpful?" votes show which guides to improve.',
                'result_tl' => 'Makikita agad ng lahat ang bagong gabay. Ang mga boto sa "Nakatulong ba?" ay nagsasabi kung aling gabay ang dapat ayusin.',
                'problems' => [],
                'pages' => ['resources.help-guides.*'],
                'links' => ['admin' => 'resources.help-guides.index'],
                'related' => ['ai-settings'], 'sort' => 90,
            ],
            // ───────────────────────────── fuel ─────────────────────────────
            [
                'slug' => 'fuel-driver', 'topic' => 'apps', 'icon' => '⛽', 'apps' => ['driver'],
                'title_en' => 'Add a fuel fill', 'title_tl' => 'Mag-add ng karga ng fuel',
                'summary_en' => 'After every fill: photo of the receipt, check the numbers, card or cash, photo of the odometer.',
                'summary_tl' => 'Pagkatapos magpakarga: picture ng resibo, tingnan ang numbers, card o cash, picture ng odometer.',
                'when_en' => 'You just filled the truck at a station.',
                'when_tl' => 'Kakakarga mo lang ng truck sa gasolinahan.',
                'steps' => [
                    $s('Show the company card', 'For ₱1,000 and up, show the cashier the card with the company name and TIN so they write it on the receipt.', 'Ipakita ang company card', 'Kapag ₱1,000 pataas, ipakita sa cashier ang card na may pangalan at TIN ng kompanya para isulat sa resibo.'),
                    $s('Photo of the receipt', 'Today → ⛽ Add fuel → Take receipt photo. Lay the receipt flat, all of it in the photo.', 'Picture ng resibo', 'Today → ⛽ Add fuel → Take receipt photo. Ilapag ang resibo, buo dapat sa picture.'),
                    $s('Check and choose', 'Check diesel or gasoline, liters, price, total and VAT. Choose fuel card or cash.', 'Tingnan at piliin', 'Tingnan kung diesel o gasoline, liters, presyo, total at VAT. Piliin kung fuel card o cash.'),
                    $s('Photo of the odometer', 'Take a photo of the total km on the dashboard, check the number, press Save fill.', 'Picture ng odometer', 'Kunan ang total km sa dashboard, tingnan ang numero, pindutin ang Save fill.'),
                ],
                'result_en' => 'The office sees the fill, the km per liter and the receipt. Give the paper receipt to the office.',
                'result_tl' => 'Makikita ng office ang karga, km per liter at resibo. Ibigay ang papel na resibo sa office.',
                'problems' => [
                    $p('It says wrong fuel', 'The receipt says another fuel than the truck uses. Check the receipt and tell the office right away.', 'Sabi ay wrong fuel', 'Ibang fuel ang nasa resibo kaysa sa gamit ng truck. Tingnan ang resibo at sabihan agad ang office.'),
                    $p('The card does not work', 'Use the fuel cash from the office and choose Cash. Keep the receipt.', 'Ayaw ng card', 'Gamitin ang fuel cash galing office at piliin ang Cash. Itago ang resibo.'),
                ],
                'pages' => ['pages.fuel'], 'links' => ['driver' => 'pages.fuel'],
                'related' => ['driver-deliver'], 'sort' => 60,
            ],
            [
                'slug' => 'fuel-office', 'topic' => 'trucks', 'icon' => '⛽', 'apps' => ['admin', 'warehouse', 'company'],
                'title_en' => 'Fuel: fills, cards, cash and VAT', 'title_tl' => 'Fuel: karga, card, cash at VAT',
                'summary_en' => 'See what each truck used and spent, check alerts, match the fuel card statement, give and settle fuel cash, and export VAT.',
                'summary_tl' => 'Tingnan ang nagamit at gastos ng bawat truck, ang alerts, i-match ang fuel card statement, magbigay at mag-settle ng fuel cash, at i-export ang VAT.',
                'when_en' => 'Every week, when the fuel card statement comes, and before a long trip.',
                'when_tl' => 'Linggo-linggo, pagdating ng fuel card statement, at bago ang mahabang trip.',
                'steps' => [
                    $s('Set up once', 'Admin → Settings → Fuel: company TIN, fuel card, each truck\'s fuel, tank and card last 4. Settings → AI: switch on "Read fuel receipts".', 'I-set up minsan', 'Admin → Settings → Fuel: company TIN, fuel card, fuel, tank at card last 4 ng bawat truck. Settings → AI: i-on ang "Read fuel receipts".'),
                    $s('Check the alerts', 'Fuel → Alerts: wrong fuel, a fill bigger than the tank, filled away from the truck, km per liter dropping, odd price.', 'Tingnan ang alerts', 'Fuel → Alerts: maling fuel, kargang lampas sa tangke, nag-fill malayo sa truck, bumababang km per liter, kakaibang presyo.'),
                    $s('Match the card statement', 'Fuel → Fuel cards: import the CSV from the card website. Charges with no fill in the app are flagged.', 'I-match ang card statement', 'Fuel → Fuel cards: i-import ang CSV galing sa website ng card. Naka-flag ang charges na walang karga sa app.'),
                    $s('Fuel cash for a trip', 'Delivery Log → trip → Fuel: the estimate, give the cash, then settle the change when the truck is back.', 'Fuel cash para sa trip', 'Delivery Log → trip → Fuel: ang estimate, ibigay ang cash, tapos i-settle ang sukli pagbalik ng truck.'),
                    $s('VAT for the accountant', 'Fuel → VAT → Excel for the accountant. Keep the paper receipts.', 'VAT para sa accountant', 'Fuel → VAT → Excel for the accountant. Itago ang papel na resibo.'),
                ],
                'result_en' => 'You know what fuel costs per truck and per box, and what VAT you can claim.',
                'result_tl' => 'Alam mo ang gastos sa fuel bawat truck at bawat box, at ang VAT na puwedeng i-claim.',
                'problems' => [
                    $p('Charges say "Card or plate not known"', 'Put the card\'s last 4 digits on the truck in Settings → Fuel, then import again.', 'Sabi ay "Card or plate not known"', 'Ilagay ang last 4 digits ng card sa truck sa Settings → Fuel, tapos i-import ulit.'),
                    $p('No price this week', 'Prices come from this week\'s receipts. Until the first one, Admin can set the price in Fuel → Prices.', 'Walang presyo ngayong linggo', 'Galing sa mga resibo ngayong linggo ang presyo. Habang wala pa, puwedeng i-set ng Admin sa Fuel → Prices.'),
                ],
                'pages' => ['pages.fuel', 'pages.trip-fuel', 'pages.fuel-settings'],
                'links' => ['admin' => 'pages.fuel', 'warehouse' => 'pages.fuel', 'company' => 'pages.fuel'],
                'related' => ['truck-tracking', 'create-trip'], 'sort' => 40,
            ],
            // ───────────────────────────── warehouse sections ─────────────────────────────
            [
                'slug' => 'warehouse-sections', 'topic' => 'boxes', 'icon' => '🗂️', 'apps' => ['admin', 'warehouse', 'scan'],
                'title_en' => 'Warehouse sections, box sets and the waiting truck', 'title_tl' => 'Mga seksyon ng bodega, set ng box at truck na naghihintay',
                'summary_en' => 'At unload the Scan app shows the section of each box from the receiver\'s province, keeps a customer\'s boxes together, and can load boxes straight onto a waiting truck.',
                'summary_tl' => 'Sa unloading, ipinapakita ng Scan app ang seksyon ng bawat box ayon sa probinsya ng receiver, pinagsasama ang mga box ng isang customer, at puwedeng ikarga agad sa truck na naghihintay.',
                'when_en' => 'Every container unload and every truck you load.',
                'when_tl' => 'Sa bawat pag-unload ng container at bawat truck na kinakargahan.',
                'steps' => [
                    $s('Set the sections once', 'Admin → Settings → Warehouse sections: one section per destination, with its provinces. Print the QR labels if you use the label scan.', 'I-set ang mga seksyon minsan', 'Admin → Settings → Warehouse sections: isang seksyon bawat destinasyon, kasama ang mga probinsya. I-print ang QR labels kung gagamit ng label scan.'),
                    $s('Scan at the container door', 'Scan each box as it comes off. The big letter on the phone is its section: put the box there. X means check the address first.', 'Mag-scan sa pinto ng container', 'I-scan ang bawat box pagbaba. Ang malaking letra sa phone ang seksyon nito: doon ilagay. Ang X ay check address muna.'),
                    $s('Keep sets together', '"Box 2 of 3" shows where the customer\'s other boxes are: still in this container, or in another one.', 'Pagsamahin ang set', 'Ang "Box 2 of 3" ay nagsasabi kung nasaan ang ibang box ng customer: nasa container pa, o nasa ibang container.'),
                    $s('A truck is waiting', 'Tap "A truck is waiting" and pick the warehouse trip. Its boxes show 🚚: put them straight on the truck. "Put in section instead" keeps one box in its section.', 'May truck na naghihintay', 'Pindutin ang "A truck is waiting" at piliin ang warehouse trip. Ang mga box nito ay may 🚚: diretso sa truck. Ang "Put in section instead" ay itatabi ang box sa seksyon.'),
                    $s('Many phones at once', 'Several people can scan the same container or truck. The counter is shared; a box already scanned by someone else is not counted again.', 'Sabay-sabay ang maraming phone', 'Puwedeng sabay-sabay mag-scan ang ilang tao sa iisang container o truck. Iisa ang bilang; hindi na binibilang ulit ang box na na-scan na ng iba.'),
                ],
                'result_en' => 'Every box is in its section or on its truck, and a customer\'s boxes stay together.',
                'result_tl' => 'Nasa tamang seksyon o truck ang bawat box, at magkakasama ang mga box ng isang customer.',
                'problems' => [
                    $p('It says Wrong hub when loading', 'The box is for another partner hub than this trip. Put it back in its section and tell the office.', 'Sabi ay Wrong hub sa loading', 'Ang box ay para sa ibang partner hub. Ibalik sa seksyon nito at sabihan ang office.'),
                    $p('Customers missing boxes at the end', 'On the Done screen, find the boxes, or pick why each one stays behind (not arrived, damaged, cannot find, truck full).', 'May customer na kulang ang box sa dulo', 'Sa Done screen, hanapin ang box, o piliin kung bakit naiwan (wala pa, sira, hindi makita, puno ang truck).'),
                ],
                'pages' => ['pages.warehouse-sections', 'pages.scaninvoice', 'pages.unloadedcontainer'],
                'links' => ['admin' => 'pages.warehouse-sections'],
                'related' => ['unload-container', 'load-truck'], 'sort' => 25,
            ],
            // ───────────────────────────── sea shipments ─────────────────────────────
            [
                'slug' => 'sea-shipments', 'topic' => 'trucks', 'icon' => '🚢', 'apps' => ['admin', 'warehouse', 'company', 'scan'],
                'title_en' => 'Sea shipments to Visayas and Mindanao', 'title_tl' => 'Sea shipment papuntang Visayas at Mindanao',
                'summary_en' => 'A normal trip to the port, then the van and seal, the port check, the ship, and receiving at the partner hub. Container now, RoRo later.',
                'summary_tl' => 'Normal na trip papuntang port, tapos ang van at seal, port check, barko, at pag-receive sa partner hub. Container ngayon, RoRo sa susunod.',
                'when_en' => 'Every container or RoRo truck going to a partner hub by sea.',
                'when_tl' => 'Bawat container o RoRo truck na papunta sa partner hub sa dagat.',
                'steps' => [
                    $s('Make the trip and the shipment', 'Make a normal trip to the partner hub with its boxes (Delivery Log). Then Sea shipments → pick the trip → Make shipment.', 'Gawin ang trip at shipment', 'Gumawa ng normal na trip papunta sa partner hub kasama ang mga box (Delivery Log). Tapos Sea shipments → piliin ang trip → Make shipment.'),
                    $s('Load and seal', 'Scan app → Load truck: sets and wrong hub are checked. Type the seal number and press "Mark: Loaded & sealed".', 'I-load at i-seal', 'Scan app → Load truck: tinitingnan ang set at wrong hub. I-type ang seal number at pindutin ang "Mark: Loaded & sealed".'),
                    $s('Port check', 'Full scan (Scan app → Port check), count only with a photo of the receipt, or off with a reason.', 'Port check', 'Full scan (Scan app → Port check), bilang lang kasama ang picture ng resibo, o off na may dahilan.'),
                    $s('Ship details', 'Type the vessel, BL and ETA and press "Mark: Sailed". The receiver sees "On the way by sea".', 'Detalye ng barko', 'I-type ang vessel, BL at ETA at pindutin ang "Mark: Sailed". Makikita ng receiver ang "On the way by sea".'),
                    $s('Receive at the hub', 'Partner hub: Scan app → Receive container, then Incoming shipments → Finish receiving. Missing boxes get an Invoice Issue; boxes for another hub go to Wrong hub & returns.', 'I-receive sa hub', 'Partner hub: Scan app → Receive container, tapos Incoming shipments → Finish receiving. Ang nawawalang box ay may Invoice Issue; ang box ng ibang hub ay nasa Wrong hub & returns.'),
                ],
                'result_en' => 'You know where every box is from the warehouse to the hub, and what the shipment cost per box.',
                'result_tl' => 'Alam mo kung nasaan ang bawat box mula bodega hanggang hub, at magkano ang gastos bawat box.',
                'problems' => [
                    $p('The hub cannot load a box on its truck', 'The box is still on a sea shipment that was not received. Receive the container first.', 'Hindi ma-load ng hub ang box', 'Nasa sea shipment pa ang box na hindi pa na-receive. I-receive muna ang container.'),
                    $p('"Not handed over at the port"', 'Fewer boxes at the port than left the warehouse. Check the truck now; with a full scan the app lists which ones.', '"Not handed over at the port"', 'Mas kaunti ang box sa port kaysa umalis sa bodega. Tingnan agad ang truck; sa full scan, ililista ng app kung alin.'),
                ],
                'pages' => ['pages.sea-shipments', 'pages.sea-shipment', 'pages.incoming-shipments', 'pages.wrong-hub'],
                'links' => ['admin' => 'pages.sea-shipments', 'warehouse' => 'pages.sea-shipments', 'company' => 'pages.incoming-shipments'],
                'related' => ['warehouse-sections', 'load-truck'], 'sort' => 45,
            ],
        ];
    }
}
DISPATCH_FILE_END_19

# ---------------------------------------------------------------- app/Support/Help/Help.php
mkdir -p 'app/Support/Help'
cat > 'app/Support/Help/Help.php' <<'DISPATCH_FILE_END_20'
<?php

namespace App\Support\Help;

use App\Models\Help\HelpGuide;
use App\Support\Ai\Ai;
use Filament\Facades\Filament;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * The Help guide: guides for each app, search in English and Tagalog, the guide for the page
 * you are on, and "Ask in your own words" (AI that answers only from the guides).
 */
class Help
{
    /** Filament panel id => help app */
    public const APPS = ['admin' => 'admin', 'warehouse' => 'warehouse', 'company' => 'company', 'scan' => 'scan', 'delivery' => 'driver'];

    public const APP_NAMES = ['admin' => 'Admin', 'warehouse' => 'Warehouse', 'company' => 'Partner hub', 'scan' => 'Scan app', 'driver' => 'Driver app'];

    /** Words that say nothing about what you need. */
    protected const STOP = ['the', 'a', 'an', 'to', 'of', 'is', 'it', 'in', 'on', 'how', 'do', 'i', 'my', 'what', 'why', 'can', 'and', 'or', 'for', 'when', 'where', 'not', 'be', 'are', 'with', 'this', 'that', 'me',
        'ang', 'ng', 'sa', 'na', 'mga', 'ba', 'po', 'paano', 'bakit', 'ano', 'saan', 'kung', 'ko', 'ako', 'yung', 'yong', 'lang', 'naman', 'pa', 'ay', 'at', 'si', 'mag', 'para', 'kapag', 'pag', 'hindi', 'wala', 'walang', 'nang', 'yan', 'ito', 'iyon', 'ni', 'kay'];

    /** Taglish words people type => words in the guides. */
    protected const ALSO = [
        'ibalik' => 'return', 'bumalik' => 'return', 'balik' => 'return', 'sira' => 'damaged', 'basa' => 'wet', 'hanapin' => 'find', 'nawawala' => 'missing',
        'nasaan' => 'where', 'bilang' => 'inventory', 'bodega' => 'warehouse', 'kargahan' => 'load', 'karga' => 'load', 'baba' => 'unload', 'ibaba' => 'unload',
        'text' => 'sms', 'texts' => 'sms', 'mapa' => 'map', 'daan' => 'navigate', 'signal' => 'signal', 'litrato' => 'photo', 'picture' => 'photo', 'pic' => 'photo',
        'deliver' => 'deliver', 'delivered' => 'deliver', 'delivery' => 'deliver', 'undo' => 'undo', 'mali' => 'undo', 'trak' => 'truck', 'print' => 'print',
    ];

    protected static array $memo = [];

    protected static ?bool $ready = null;

    /** The help table is there (the migration has run). */
    public static function ready(): bool
    {
        return static::$ready ??= Schema::hasTable('help_guides');
    }

    public static function forget(): void
    {
        static::$memo = [];
        static::$ready = null;
        Cache::forget('help.version');
    }

    /** Copy the built-in guides into the table (only the ones not there yet). */
    public static function installDefaults(): int
    {
        if (! Schema::hasTable('help_guides')) {
            return 0;
        }
        $have = HelpGuide::pluck('slug')->all();
        $added = 0;
        foreach (DefaultGuides::all() as $g) {
            if (in_array($g['slug'], $have, true)) {
                continue;
            }
            HelpGuide::create($g + ['is_published' => true]);
            $added++;
        }
        static::forget();

        return $added;
    }

    /** The help app for the panel you are in. */
    public static function currentApp(): string
    {
        $id = Filament::getCurrentPanel()?->getId();

        return static::APPS[$id] ?? 'admin';
    }

    public static function lang(?string $lang = null): string
    {
        $lang ??= session('help.lang', 'en');

        return $lang === 'tl' ? 'tl' : 'en';
    }

    /** @return Collection<int, HelpGuide> */
    public static function guides(string $app): Collection
    {
        if (! static::ready()) {
            return collect();
        }

        return static::$memo[$app] ??= HelpGuide::query()->for($app)->orderBy('sort')->orderBy('id')->get();
    }

    public static function find(string $app, ?string $slug): ?HelpGuide
    {
        return $slug ? static::guides($app)->firstWhere('slug', $slug) : null;
    }

    /** Topics with their guides, in order. @return list<array{key: string, icon: string, name: string, guides: Collection}> */
    public static function topics(string $app, string $lang): array
    {
        $guides = static::guides($app)->groupBy('topic');
        $out = [];
        foreach (DefaultGuides::TOPICS as $key => [$icon, $en, $tl]) {
            if ($guides->has($key)) {
                $out[] = ['key' => $key, 'icon' => $icon, 'name' => $lang === 'tl' ? $tl : $en, 'guides' => $guides[$key]];
            }
        }
        foreach ($guides as $key => $list) {
            if (! isset(DefaultGuides::TOPICS[$key])) {
                $out[] = ['key' => $key, 'icon' => '📘', 'name' => Str::headline($key), 'guides' => $list];
            }
        }

        return $out;
    }

    /** The guides for the page you are on (route names without the panel part). @return Collection<int, HelpGuide> */
    public static function forRoute(?string $routeName, string $app): Collection
    {
        if (! $routeName) {
            return collect();
        }
        $rest = preg_replace('/^filament\.[^.]+\./', '', $routeName);

        return static::guides($app)->filter(fn (HelpGuide $g) => collect($g->pages ?? [])->contains(fn ($p) => $p && Str::is($p, $rest)))->values();
    }

    /** @return list<string> */
    public static function words(string $text): array
    {
        $text = Str::lower(Str::ascii($text));
        $words = preg_split('/[^a-z0-9]+/', $text, -1, PREG_SPLIT_NO_EMPTY) ?: [];
        $out = [];
        foreach ($words as $w) {
            if (strlen($w) < 2 || in_array($w, static::STOP, true)) {
                continue;
            }
            $out[] = $w;
            if (isset(static::ALSO[$w])) {
                $out[] = static::ALSO[$w];
            }
        }

        return array_values(array_unique($out));
    }

    /** Guides that match the words, best first. @return Collection<int, HelpGuide> */
    public static function search(string $q, string $app, int $limit = 8): Collection
    {
        $words = static::words($q);
        if (! $words) {
            return collect();
        }

        $guides = static::guides($app);
        // Each guide's words by place; rare words (in few guides) count more than common ones like "box".
        $docs = $guides->map(fn (HelpGuide $g) => [
            'g' => $g,
            'title' => static::words($g->title_en.' '.$g->title_tl.' '.str_replace('-', ' ', $g->slug)),
            'sum' => static::words($g->summary_en.' '.$g->summary_tl.' '.$g->when_en.' '.$g->when_tl),
            'steps' => static::words(collect($g->steps ?? [])->map(fn ($s) => ($s['title_en'] ?? '').' '.($s['title_tl'] ?? ''))->join(' ')),
            'body' => static::words(collect($g->steps ?? [])->map(fn ($s) => ($s['text_en'] ?? '').' '.($s['text_tl'] ?? ''))->join(' ')
                .' '.collect($g->problems ?? [])->map(fn ($p) => implode(' ', array_filter([$p['q_en'] ?? '', $p['q_tl'] ?? '', $p['a_en'] ?? '', $p['a_tl'] ?? ''])))->join(' ')
                .' '.$g->result_en.' '.$g->result_tl),
        ]);
        $n = max(1, $docs->count());
        $weight = [];
        foreach ($words as $w) {
            $df = $docs->filter(fn ($d) => static::hit($w, array_merge($d['title'], $d['sum'], $d['steps'], $d['body'])) > 0)->count();
            $weight[$w] = $df ? log(1 + $n / $df) : 0;
        }

        return $docs
            ->map(function ($d) use ($words, $weight) {
                $score = 0;
                foreach ($words as $w) {
                    $score += $weight[$w] * (static::hit($w, $d['title']) * 6 + static::hit($w, $d['sum']) * 3 + static::hit($w, $d['steps']) * 2 + static::hit($w, $d['body']));
                }

                return [$d['g'], $score];
            })
            ->filter(fn ($r) => $r[1] > 0)
            ->pipe(function ($rows) {
                $top = $rows->max(fn ($r) => $r[1]) ?: 0;

                return $rows->filter(fn ($r) => $r[1] >= $top * 0.35); // drop weak matches
            })
            ->sortByDesc(fn ($r) => $r[1] * 1000 - $r[0]->sort)
            ->take($limit)
            ->map(fn ($r) => $r[0])
            ->values();
    }

    /** 1 for the same word, 0.6 when one starts with the other (return / returned). */
    protected static function hit(string $w, array $list): float
    {
        if (in_array($w, $list, true)) {
            return 1;
        }
        if (strlen($w) >= 4) {
            foreach ($list as $x) {
                if (strlen($x) >= 4 && (str_starts_with($x, $w) || str_starts_with($w, $x))) {
                    return 0.6;
                }
            }
        }

        return 0;
    }

    public static function aiOn(): bool
    {
        try {
            return Ai::enabled('help_ask');
        } catch (\Throwable) {
            return false;
        }
    }

    /**
     * Ask in your own words. The AI answers only from this app's guides and names the guide to open.
     * Without AI (off, or it failed) the best search match is used.
     *
     * @return array{answer: string, guide: ?string, ai: bool}
     */
    public static function ask(string $q, string $app, string $lang): array
    {
        $q = trim(Str::limit($q, 300, ''));
        $best = static::search($q, $app, 1)->first();
        $fallback = [
            'answer' => $best ? $best->t('summary', $lang) : ($lang === 'tl' ? 'Walang gabay na tugma. Subukan ang ibang salita, o magtanong sa office.' : 'No guide matches. Try other words, or ask the office.'),
            'guide' => $best?->slug, 'ai' => false,
        ];
        if ($q === '' || ! static::aiOn()) {
            return $fallback;
        }

        $key = 'help.ask.'.md5($app.'|'.$lang.'|'.Str::lower($q).'|'.static::version());

        return Cache::remember($key, now()->addDay(), function () use ($q, $app, $lang, $fallback) {
            $guides = static::guides($app)->map(fn (HelpGuide $g) => [
                'slug' => $g->slug,
                'title' => $g->t('title', $lang),
                'summary' => $g->t('summary', $lang),
                'when' => $g->t('when', $lang),
                'steps' => collect($g->stepsIn($lang))->map(fn ($s, $i) => ($i + 1).'. '.$s['title'].': '.$s['text'])->all(),
                'result' => $g->t('result', $lang),
                'problems' => collect($g->problemsIn($lang))->map(fn ($p) => $p['q'].' → '.$p['a'])->all(),
            ])->values()->all();

            $system = 'You are the help desk inside a cargo delivery system (boxes from containers, trucks, trips, drivers) used in the Philippines. '
                .'Answer ONLY from the guides you are given. Do not invent pages, buttons or rules. '
                .'If the guides do not answer the question, say so in one sentence and suggest asking the office; then guide is null. '
                .'Answer in the language of the question: English, Tagalog or Taglish. Use plain words and at most 3 short sentences. Name the page or button to press. '
                .'Return {"answer": string, "guide": the slug of the one guide to open, or null}.';
            try {
                $out = Ai::json('help_ask', $system, 'App: '.(static::APP_NAMES[$app] ?? $app)."\n\nGuides:\n".json_encode($guides, JSON_UNESCAPED_UNICODE)."\n\nQuestion: ".$q, 'fast', 400);
            } catch (\Throwable $e) {
                return $fallback;
            }
            $answer = trim((string) ($out['answer'] ?? ''));
            if ($answer === '') {
                return $fallback;
            }
            $slug = $out['guide'] ?? null;
            $slug = is_string($slug) && static::find($app, $slug) ? $slug : null;

            return ['answer' => Str::limit($answer, 600), 'guide' => $slug, 'ai' => true];
        });
    }

    /** Changes when any guide is saved, so old AI answers are not reused. */
    protected static function version(): string
    {
        return Cache::rememberForever('help.version', fn () => (string) (HelpGuide::max('updated_at') ?? '0').'-'.HelpGuide::count());
    }

    /** "Was this helpful?" once per guide per sign-in. */
    public static function vote(HelpGuide $guide, bool $yes): bool
    {
        $key = 'help.voted.'.$guide->id;
        if (session()->has($key)) {
            return false;
        }
        session()->put($key, $yes);
        HelpGuide::whereKey($guide->id)->increment($yes ? 'helpful_yes' : 'helpful_no');

        return true;
    }

    public static function voted(HelpGuide $guide): ?bool
    {
        return session('help.voted.'.$guide->id);
    }

    public static function seen(HelpGuide $guide): void
    {
        $key = 'help.seen.'.$guide->id;
        if (! session()->has($key)) {
            session()->put($key, true);
            HelpGuide::whereKey($guide->id)->increment('views');
        }
    }

    /** "Do it now": the page for this guide in this app, if there is one. */
    public static function linkUrl(HelpGuide $guide, string $app): ?string
    {
        $rest = ($guide->links ?? [])[$app] ?? null;
        $panel = array_search($app, static::APPS, true);
        if (! $rest || ! $panel) {
            return null;
        }
        $name = "filament.{$panel}.{$rest}";
        if (! Route::has($name)) {
            return null;
        }
        try {
            return route($name);
        } catch (\Throwable) {
            return null;
        }
    }

    /** The Help Center page in this app (admin, warehouse, company). */
    public static function centerUrl(string $app, ?string $slug = null): ?string
    {
        $panel = array_search($app, static::APPS, true);
        $name = "filament.{$panel}.pages.help";

        return Route::has($name) ? route($name, $slug ? ['g' => $slug] : []) : null;
    }

    /** The guide to open for a Scan app mode. */
    public static function forScanMode(?string $mode): string
    {
        return match ($mode) {
            'unload' => 'unload-container',
            'load', 'hub_load' => 'load-truck',
            'return' => 'return-boxes',
            'wh_load', 'wh_unload' => 'warehouse-transfer',
            'port', 'ship_receive' => 'sea-shipments',
            default => 'scan-tips',
        };
    }
}
DISPATCH_FILE_END_20

# ---------------------------------------------------------------- app/Support/HubDesk.php
mkdir -p 'app/Support'
cat > 'app/Support/HubDesk.php' <<'DISPATCH_FILE_END_21'
<?php

namespace App\Support;

use App\Enums\FailedDeliveryReason;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\DeliveryReversal;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Storage;

/**
 * Everything the partner hub (Company) panel shows for one hub:
 * incoming boxes by area, drivers today, needs attention, the week,
 * the hub score, the drivers leaderboard, the retry list and box tracking.
 *
 * "Our boxes" = boxes handed to this hub (tripinvoices.logistichub_id)
 * or put on one of its own trips (tripinvoices.deliveryloghub_id).
 */
class HubDesk
{
    /** Boxes per truck when a truck has no capacity set. */
    public const DEFAULT_CAPACITY = 60;

    public const WAIT_DAYS = 2;

    public function __construct(public readonly int $hubId) {}

    // ----------------------------------------------------------------- building blocks

    public function trips(): Builder
    {
        return Deliverylog::query()->where('logistichub_id', $this->hubId);
    }

    public function ours(): Builder
    {
        return Tripinvoice::query()->where(fn (Builder $q) => $q
            ->where('logistichub_id', $this->hubId)
            ->orWhereIn('deliveryloghub_id', $this->trips()->select('id')));
    }

    /** Handed to this hub on a loaded main truck, not on a hub trip yet. */
    public function waiting(): Builder
    {
        return Tripinvoice::query()
            ->where('logistichub_id', $this->hubId)
            ->where('is_loaded', true)
            ->where(fn (Builder $q) => $q->where('hub_assigned', false)->orWhereNull('hub_assigned'))
            ->where(fn (Builder $q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'));
    }

    protected static function notDelivered(Builder $q): Builder
    {
        return $q->where(fn (Builder $q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'));
    }

    protected static function deliveredSince(Builder $q, Carbon $since): Builder
    {
        return $q->where('tripinvoices.is_delivered', true)->whereRaw('COALESCE(tripinvoices.delivered_at, tripinvoices.updated_at) >= ?', [$since]);
    }

    /** Users of this hub marked as crew (drivers and helpers). */
    public function crew(): Builder
    {
        return User::query()
            ->where('logistichub_id', $this->hubId)
            ->where(fn (Builder $q) => $q->where('is_crew', true)->orWhereHas('workposition', fn (Builder $w) => $w->where('is_crew', true)));
    }

    protected function days(?string $since): int
    {
        return $since ? max(0, (int) Carbon::parse($since)->startOfDay()->diffInDays(today())) : 0;
    }

    // ----------------------------------------------------------------- incoming boxes

    /** Waiting boxes grouped by receiver city. @return Collection<int, array{key: string, city: string, barangays: string, boxes: int, oldest: int, ids: list<int>}> */
    public function areas(): Collection
    {
        return $this->waiting()->with(['box:id,receiver_city,receiver_barangay', 'deliverylog:id,eta'])->get()
            ->groupBy(fn (Tripinvoice $t) => trim((string) $t->box?->receiver_city) ?: 'No city')
            ->map(fn (Collection $rows, string $city) => [
                'key' => md5($city),
                'city' => $city,
                'barangays' => $rows->map(fn ($t) => trim((string) $t->box?->receiver_barangay))->filter()->countBy()->sortDesc()->keys()->take(3)->join(', '),
                'boxes' => $rows->count(),
                'oldest' => $rows->max(fn ($t) => $this->days($t->deliverylog?->eta)),
                'ids' => $rows->modelKeys(),
            ])
            ->sortByDesc('boxes')
            ->values();
    }

    /** Waiting boxes, the longest-waiting first. */
    public function oldestWaiting(int $limit = 50): Collection
    {
        return $this->waiting()
            ->with(['box:id,invoice,receiver_name,receiver_city,receiver_barangay,boxtype', 'deliverylog:id,eta,trip_number'])
            ->get()
            ->sortBy(fn ($t) => $t->deliverylog?->eta ?? '9999')
            ->take($limit)
            ->map(fn (Tripinvoice $t) => [
                'id' => $t->id,
                'invoice' => $t->box?->invoice ?? $t->invoice,
                'receiver' => $t->box?->receiver_name,
                'area' => collect([$t->box?->receiver_barangay, $t->box?->receiver_city])->filter()->join(', '),
                'boxtype' => $t->box?->boxtype,
                'days' => $this->days($t->deliverylog?->eta),
            ])
            ->values();
    }

    public function freeTrucks(): Collection
    {
        return Truck::query()->where('logistichub_id', $this->hubId)->where('is_active', true)
            ->where(fn (Builder $q) => $q->where('is_assigned', false)->orWhereNull('is_assigned'))
            ->orderBy('plate_no')->get(['id', 'plate_no', 'capacity']);
    }

    public function capacity(): int
    {
        $sizes = $this->freeTrucks()->pluck('capacity')->filter();

        return (int) ($sizes->isNotEmpty() ? round($sizes->avg()) : self::DEFAULT_CAPACITY);
    }

    // ----------------------------------------------------------------- dashboard

    /** Open trips of this hub with progress and crew. */
    public function driversToday(int $limit = 8): Collection
    {
        $trips = $this->trips()->where('is_active', true)->with(['truck:id,plate_no', 'truck.truckcrews'])
            ->latest('id')->limit($limit)->get();

        // truckcrews.crew is the crew member (truckcrews.user_id is who added them)
        $people = User::whereIn('id', $trips->flatMap(fn ($t) => $t->truck?->truckcrews->pluck('crew') ?? []))->get()->keyBy('id');

        return $trips->map(function (Deliverylog $trip) use ($people) {
            $rows = Tripinvoice::where('deliveryloghub_id', $trip->id)->with('box:id,receiver_city')->get();
            $total = $rows->count();
            $loaded = $rows->where('is_loaded_hub', true)->count();
            $done = $rows->where('is_delivered', true)->count();
            $crew = $trip->truck?->truckcrews->map(fn ($c) => $people[$c->crew]?->full_name ?? null)->filter()->values() ?? collect();

            return [
                'trip' => $trip,
                'driver' => $crew->first() ?? 'No crew',
                'initials' => collect(explode(' ', (string) $crew->first()))->filter()->map(fn ($p) => mb_substr($p, 0, 1))->take(2)->join('') ?: '?',
                'truck' => $trip->truck?->plate_no,
                'areas' => $rows->map(fn ($r) => $r->box?->receiver_city)->filter()->countBy()->sortDesc()->keys()->take(2)->join(', '),
                'total' => $total,
                'done' => $done,
                'status' => $total === 0 ? 'empty' : ($done === $total ? 'done' : ($loaded < $total ? 'loading' : 'road')),
            ];
        })->filter(fn ($row) => $row['total'] > 0)->values();
    }

    /** @return Collection<int, array{tag: string, tone: string, detail: string, action: string, link: string}> */
    public function attention(): Collection
    {
        $items = collect();

        $late = HubBoxes::waitingTooLong($this->hubId, self::WAIT_DAYS);
        if ($late['count']) {
            $items->push(['tag' => "{$late['count']} waiting ".self::WAIT_DAYS.'+ days', 'tone' => 'bad',
                'detail' => "Oldest {$late['oldest']}, due ".Carbon::parse($late['since'])->format('M j'), 'action' => 'Plan a trip', 'link' => 'incoming']);
        }

        $failed = DeliveryAttempt::whereIn('deliverylog_id', $this->trips()->select('id'))->whereDate('created_at', today())->get(['reason']);
        if ($failed->isNotEmpty()) {
            $items->push(['tag' => $failed->count().' not delivered today', 'tone' => 'warn',
                'detail' => $failed->countBy(fn ($a) => $a->reason->getLabel())->map(fn ($n, $l) => $n > 1 ? "{$l} ×{$n}" : $l)->join(' · '),
                'action' => 'Retry list', 'link' => 'retry']);
        }

        foreach (Truck::where('logistichub_id', $this->hubId)->whereDate('date_expired', '<=', today()->addDays(30))->orderBy('date_expired')->limit(3)->get() as $truck) {
            $expired = Carbon::parse($truck->date_expired)->lt(today());
            $items->push(['tag' => $expired ? 'Registration expired' : 'Registration due', 'tone' => $expired ? 'bad' : 'warn',
                'detail' => "Truck {$truck->plate_no} ".($expired ? 'expired ' : 'expires ').Carbon::parse($truck->date_expired)->format('M j'), 'action' => 'Open truck', 'link' => 'trucks']);
        }

        $onCrew = Truckcrew::query()->select('crew');
        foreach ($this->crew()->whereNotIn('id', $onCrew)->limit(3)->get() as $user) {
            $items->push(['tag' => 'Driver without truck', 'tone' => 'gray', 'detail' => "{$user->full_name} is not on any crew", 'action' => 'Assign', 'link' => 'crew']);
        }

        return $items;
    }

    /** Delivered per day for the last $days days, oldest first. */
    public function week(int $days = 7): Collection
    {
        $from = today()->subDays($days - 1);
        $counts = static::deliveredSince($this->ours(), $from)
            ->selectRaw('date(COALESCE(delivered_at, updated_at)) as day, count(*) as n')->groupBy('day')->pluck('n', 'day');

        return collect(range(0, $days - 1))->map(fn ($i) => ['date' => $from->copy()->addDays($i), 'boxes' => (int) ($counts[$from->copy()->addDays($i)->toDateString()] ?? 0)]);
    }

    /** Hub score for the last 30 days. */
    public function score(): array
    {
        // 30-day numbers change slowly: kept 10 minutes so the dashboard opens fast
        return cache()->store('file')->remember('hubdesk.score.'.$this->hubId.'.'.today()->toDateString(), 600, fn () => $this->workScore());
    }

    protected function workScore(): array
    {
        $since = now()->subDays(30);

        // counted in the database (no long lists of ids): delivered boxes, and those that had a failed try first
        $firstTry = function (Builder $delivered): ?int {
            $all = (clone $delivered)->count();
            if (! $all) {
                return null;
            }
            $tried = (clone $delivered)->whereExists(fn ($q) => $q->selectRaw('1')->from('delivery_attempts')->whereColumn('delivery_attempts.invoice_id', 'tripinvoices.invoice_id'))->count();

            return (int) round(($all - $tried) / $all * 100);
        };

        $mine = $firstTry(static::deliveredSince($this->ours(), $since));
        $network = $firstTry(static::deliveredSince(Tripinvoice::query(), $since));

        // grouped in the database: one row per (delivered day, due day), not one per box
        $handed = static::deliveredSince(Tripinvoice::query()->where('tripinvoices.logistichub_id', $this->hubId), $since)
            ->join('deliverylogs as dl', 'dl.id', '=', 'tripinvoices.deliverylog_id')->whereNotNull('dl.eta')
            ->selectRaw('date(COALESCE(tripinvoices.delivered_at, tripinvoices.updated_at)) as done, date(dl.eta) as due, count(*) as n')
            ->groupBy('done', 'due')->toBase()->get();
        $total = (int) $handed->sum('n');
        $onTime = $total ? (int) round($handed->filter(fn ($r) => Carbon::parse($r->done)->lte(Carbon::parse($r->due)->addDays(self::WAIT_DAYS)))->sum('n') / $total * 100) : null;

        $wait = function (Carbon $from, Carbon $to): ?float {
            $rows = Tripinvoice::query()->where('tripinvoices.logistichub_id', $this->hubId)->whereNotNull('tripinvoices.deliveryloghub_id')
                ->whereBetween('tripinvoices.updated_at', [$from, $to])
                ->join('deliverylogs as dl', 'dl.id', '=', 'tripinvoices.deliverylog_id')
                ->join('deliverylogs as hl', 'hl.id', '=', 'tripinvoices.deliveryloghub_id')
                ->whereNotNull('dl.eta')->whereNotNull('hl.departure_date')
                ->selectRaw('date(dl.eta) as due, date(hl.departure_date) as left_on, count(*) as n')
                ->groupBy('due', 'left_on')->toBase()->get();
            $n = (int) $rows->sum('n');

            return $n ? $rows->sum(fn ($r) => max(0, Carbon::parse($r->due)->diffInDays(Carbon::parse($r->left_on), false)) * $r->n) / $n : null;
        };

        return [
            'firstTry' => $mine, 'network' => $network, 'onTime' => $onTime,
            'wait' => $wait($since, now()), 'waitBefore' => $wait(now()->subDays(60), $since),
        ];
    }

    // ----------------------------------------------------------------- drivers

    public function drivers(int $days = 30): Collection
    {
        $since = now()->subDays($days);

        $trucks = Truckcrew::with('truck:id,plate_no')->latest('id')->get()->unique('crew')->mapWithKeys(fn ($c) => [$c->crew => $c->truck?->plate_no]);

        return $this->crew()->get()
            ->map(function (User $user) use ($since, $trucks) {
                $delivered = static::deliveredSince(Tripinvoice::where('delivered_by', $user->id), $since)->pluck('invoice_id');
                $tried = $delivered->isEmpty() ? 0 : DeliveryAttempt::whereIn('invoice_id', $delivered)->distinct()->count('invoice_id');
                $attempts = DeliveryAttempt::where('user_id', $user->id)->where('created_at', '>=', $since)->get(['reason']);
                $top = $attempts->countBy(fn ($a) => $a->reason->getLabel())->sortDesc();

                return [
                    'user' => $user,
                    'name' => $user->full_name,
                    'initials' => mb_substr((string) $user->first_name, 0, 1).mb_substr((string) $user->last_name, 0, 1),
                    'truck' => $trucks[$user->id] ?? null,
                    'delivered' => $delivered->count(),
                    'firstTry' => $delivered->isEmpty() ? null : (int) round(($delivered->count() - $tried) / $delivered->count() * 100),
                    'failed' => $attempts->count(),
                    'reason' => $top->isEmpty() ? null : $top->keys()->first().($top->first() > 1 ? ' ×'.$top->first() : ''),
                ];
            })
            ->sortByDesc('delivered')->values();
    }

    // ----------------------------------------------------------------- not delivered

    /** Our boxes with a failed attempt, still not delivered and not returned, grouped by the latest reason. */
    public function retryList(): Collection
    {
        $rows = static::notDelivered($this->ours())
            ->whereHas('box', fn (Builder $q) => $q->where(fn ($q) => $q->where('is_returned', false)->orWhereNull('is_returned')))
            ->whereIn('invoice_id', DeliveryAttempt::query()->select('invoice_id'))
            ->with(['box:id,invoice,receiver_name,receiver_city,receiver_barangay', 'hubTrip:id,trip_number'])
            ->get();

        $attempts = DeliveryAttempt::whereIn('invoice_id', $rows->pluck('invoice_id'))->orderBy('id')->get(['invoice_id', 'reason', 'created_at'])->groupBy('invoice_id');

        return $rows->map(function (Tripinvoice $t) use ($attempts) {
            $mine = $attempts[$t->invoice_id] ?? collect();

            return [
                'id' => $t->id,
                'invoice' => $t->box?->invoice ?? $t->invoice,
                'receiver' => $t->box?->receiver_name,
                'area' => collect([$t->box?->receiver_barangay, $t->box?->receiver_city])->filter()->join(', '),
                'tries' => $mine->count(),
                'reason' => $mine->last()?->reason,
                'trip' => $t->hubTrip?->trip_number,
            ];
        })
            ->groupBy(fn ($r) => $r['reason']?->value ?? 'other')
            ->map(fn (Collection $boxes, string $reason) => [
                'reason' => FailedDeliveryReason::tryFrom($reason) ?? FailedDeliveryReason::Other,
                'boxes' => $boxes->sortByDesc('tries')->values(),
            ])
            ->sortByDesc(fn ($g) => $g['boxes']->count())
            ->values();
    }

    public static function retryTip(FailedDeliveryReason $reason): string
    {
        return match ($reason) {
            FailedDeliveryReason::NoOneHome => 'Try again on another day, earlier or later than last time.',
            FailedDeliveryReason::PhoneUnreachable => 'Text the receiver before the next trip.',
            FailedDeliveryReason::AddressNotFound => 'Ask the main hub for the correct address first.',
            FailedDeliveryReason::Refused => 'Usually goes back: check with the main hub before trying again.',
            FailedDeliveryReason::Rescheduled => 'Put it on a trip for the day the receiver asked for.',
            FailedDeliveryReason::AreaInaccessible => 'Plan it with a smaller vehicle or when the road is open.',
            FailedDeliveryReason::BoxDamaged => 'Report the damage before sending it out again.',
            FailedDeliveryReason::OutOfTime => 'Put it first on tomorrow\'s trip.',
            default => 'Read the driver\'s note before trying again.',
        };
    }

    /** Open, unlocked trips of this hub that boxes can still be added to. */
    public function openTrips(): Collection
    {
        return $this->trips()->where('is_active', true)->where(fn ($q) => $q->where('is_lock', false)->orWhereNull('is_lock'))
            ->with('truck:id,plate_no')->latest('id')->get()
            ->mapWithKeys(fn ($t) => [$t->id => $t->trip_number.($t->truck ? ' · '.$t->truck->plate_no : '').($t->departure_date ? ' · leaves '.Carbon::parse($t->departure_date)->format('M j') : '')]);
    }

    // ----------------------------------------------------------------- track a box

    /** The box's story, if it is one of this hub's boxes. */
    public function track(string $code): ?array
    {
        $code = trim($code);
        if ($code === '') {
            return null;
        }

        $row = $this->ours()->where(fn ($q) => $q->where('invoice', $code)->orWhereHas('box', fn ($i) => $i->where('invoice', $code)))
            ->with(['box.container:id,container_no', 'deliverylog:id,trip_number,eta,logistichub_id', 'hubTrip.truck:id,plate_no', 'deliverer'])
            ->latest('id')->first();

        if (! $row) {
            return null;
        }

        /** @var Invoice|null $box */
        $box = $row->box;
        $url = fn (?string $path) => $path && Storage::disk('public')->exists($path) ? Storage::disk('public')->url($path) : null;
        $events = collect();

        if ($box?->verified_at || $box?->is_verified) {
            $events->push(['at' => $box->verified_at, 'title' => 'Unloaded at the warehouse', 'detail' => $box->container?->container_no ? 'Container '.$box->container->container_no : null, 'tone' => null]);
        }
        if ($row->deliverylog) {
            $events->push(['at' => $row->deliverylog->eta, 'title' => 'Handed to your hub', 'detail' => 'Main trip '.$row->deliverylog->trip_number, 'tone' => null, 'dateOnly' => true]);
        }
        $sea = \App\Support\Shipping\Shipments::ready() && $row->deliverylog_id ? \App\Models\Shipping\SeaShipment::where('deliverylog_id', $row->deliverylog_id)->first() : null;
        if ($sea) {
            foreach ((array) $sea->status_log as $e) {
                if (in_array($e['status'] ?? '', ['sealed', 'sailed', 'arrived', 'received'], true)) {
                    $events->push(['at' => $e['at'], 'title' => \App\Support\Shipping\Shipments::label($sea, $e['status']), 'detail' => 'Sea shipment '.$sea->code.($e['status'] === 'sailed' && $sea->vessel ? ' · '.$sea->vessel : ''), 'tone' => null]);
                }
            }
        }
        if ($row->hubTrip) {
            $events->push(['at' => $row->hubTrip->departure_date, 'title' => 'Out for delivery', 'detail' => 'Trip '.$row->hubTrip->trip_number.($row->hubTrip->truck ? ' · truck '.$row->hubTrip->truck->plate_no : ''), 'tone' => null, 'dateOnly' => true]);
        }
        foreach (DeliveryAttempt::where('invoice_id', $row->invoice_id)->with('user')->get() as $a) {
            $events->push(['at' => $a->created_at, 'title' => 'Not delivered: '.$a->reason->getLabel(), 'detail' => trim(($a->user?->full_name ?? '').($a->note ? ' · "'.$a->note.'"' : ''), ' ·'),
                'tone' => 'warn', 'photo' => $url(collect($a->photos)->first())]);
        }
        foreach (DeliveryReversal::where('invoice_id', $row->invoice_id)->with('user')->get() as $r) {
            $events->push(['at' => $r->created_at, 'title' => 'Delivery undone: '.$r->reason->getLabel(), 'detail' => $r->user?->full_name, 'tone' => 'warn']);
        }
        if ($row->is_delivered) {
            $events->push(['at' => $row->delivered_at ?? $row->updated_at, 'title' => 'Delivered', 'detail' => $row->deliverer?->full_name, 'tone' => 'ok',
                'photo' => $url(collect($row->delivery_picture)->first())]);
        }

        return [
            'row' => $row,
            'box' => $box,
            'status' => $row->is_delivered ? 'Delivered' : ($row->hubTrip ? ($row->is_loaded_hub ? 'Out for delivery' : 'On a trip, loading')
                : ($sea && \App\Support\Shipping\Shipments::stillAtSea($row) ? \App\Support\Shipping\Shipments::trackText($sea) : 'Waiting at your hub')),
            'events' => $events->sortByDesc(fn ($e) => $e['at'] ? Carbon::parse($e['at'])->timestamp : 0)->values(),
        ];
    }
}
DISPATCH_FILE_END_21

# ---------------------------------------------------------------- app/Support/ScanModes.php
mkdir -p 'app/Support'
cat > 'app/Support/ScanModes.php' <<'DISPATCH_FILE_END_22'
<?php

namespace App\Support;

use App\Filament\Company\Pages\LoadTruck as HubLoadTruck;
use App\Filament\Company\Pages\ReturnBoxes as HubReturnBoxesCompany;
use App\Filament\Pages\ReturnBoxes as AdminReturnBoxes;
use App\Filament\Pages\Scaninvoice as AdminUnload;
use App\Filament\Pages\Scanload as AdminLoad;
use App\Filament\Warehouse\Pages\Hubloaded as WarehouseLoad;
use App\Filament\Warehouse\Pages\HubReturnBoxes as WarehouseReturn;
use App\Filament\Warehouse\Pages\Unloadedcontainer as WarehouseUnload;
use App\Filament\Warehouse\Pages\Whloaded;
use App\Filament\Warehouse\Pages\Whunloaded;
use App\Filament\Shared\Shipping\PortCheckStation;
use App\Filament\Shared\Shipping\ReceiveShipmentStation;
use App\Models\User;

/**
 * Which scans a person gets in the Scan app, from the account type set on the user.
 * Each scan reuses an existing scan page (its rules, limits and photo step) behind the scenes.
 */
class ScanModes
{
    /** @return array<string, array{label: string, sub: string, icon: string, class: class-string, field: string, kind: string, ok: string, done: string}> */
    public static function for(?User $user): array
    {
        $code = $user?->panelcategory?->code;

        $unload = ['label' => 'Unload container', 'sub' => 'Boxes off the ship container', 'icon' => 'container', 'field' => 'container_id', 'kind' => 'container', 'ok' => 'Verified · off the container', 'done' => 'Container unloaded'];
        $load = ['label' => 'Load truck', 'sub' => 'Onto a delivery trip', 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Loaded on the truck', 'done' => 'Truck loaded'];
        $return = ['label' => 'Return boxes', 'sub' => 'Not delivered, back in', 'icon' => 'return', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Returned to inventory', 'done' => 'Returns done'];
        $sea = \App\Support\Shipping\Shipments::ready();
        $port = ['label' => 'Port check', 'sub' => 'Boxes handed over at the port', 'icon' => 'out', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Handed over at the port', 'done' => 'Port check done', 'class' => PortCheckStation::class];
        $receive = ['label' => 'Receive container', 'sub' => 'Sea shipment arriving at your hub', 'icon' => 'in', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Received at your hub', 'done' => 'Container received', 'class' => ReceiveShipmentStation::class];

        return match ($code) {
            'whse' => [
                'unload' => $unload + ['class' => WarehouseUnload::class],
                'load' => $load + ['class' => WarehouseLoad::class],
                'wh_load' => ['label' => 'Warehouse load', 'sub' => 'To another warehouse', 'icon' => 'out', 'field' => 'deliverylog_id', 'kind' => 'transfer trip', 'ok' => 'Loaded for the transfer', 'done' => 'Transfer loaded', 'class' => Whloaded::class],
                'wh_unload' => ['label' => 'Warehouse unload', 'sub' => 'Arriving from another warehouse', 'icon' => 'in', 'field' => 'deliverylog_id', 'kind' => 'arriving transfer', 'ok' => 'Received · added to inventory', 'done' => 'Transfer received', 'class' => Whunloaded::class],
                'return' => $return + ['class' => WarehouseReturn::class],
            ] + ($sea ? ['port' => $port] : []),
            'co' => [
                'hub_load' => ['label' => 'Hub load', 'sub' => "Onto your hub's own trucks", 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'hub trip', 'ok' => 'Loaded on the hub truck', 'done' => 'Hub truck loaded', 'class' => HubLoadTruck::class],
                'return' => $return + ['class' => HubReturnBoxesCompany::class, 'ok' => 'Back at your hub'],
            ] + ($sea ? ['ship_receive' => $receive] : []),
            'adm' => [
                'unload' => $unload + ['class' => AdminUnload::class],
                'load' => $load + ['class' => AdminLoad::class],
                'return' => $return + ['class' => AdminReturnBoxes::class],
            ] + ($sea ? ['port' => $port] : []),
            default => [],
        };
    }

    /** "Calgary Warehouse" or "Cebu Partner Hub" for the top of the app. */
    public static function place(?User $user): string
    {
        return match ($user?->panelcategory?->code) {
            'whse' => $user->warehouse?->name ?? 'Warehouse',
            'co' => $user->logistichub?->hub_name ?? 'Partner hub',
            'adm' => $user->logistichub?->hub_name ?? 'Main office',
            default => '',
        };
    }
}
DISPATCH_FILE_END_22

# ---------------------------------------------------------------- app/Support/Shipping/Shipments.php
mkdir -p 'app/Support/Shipping'
cat > 'app/Support/Shipping/Shipments.php' <<'DISPATCH_FILE_END_23'
<?php

namespace App\Support\Shipping;

use App\Models\Boxes\SetSplit;
use App\Models\Boxissue;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentScan;
use App\Models\Shipping\WrongHubBox;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Boxes\BoxSets;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Sea shipments: a normal trip to the port (to a partner hub), then the van and seal,
 * the port check, the ship, and receiving at the partner hub.
 */
class Shipments
{
    public const MODES = ['container' => 'Container (truck to port → container)', 'roro' => 'RoRo (our truck rides the ferry)'];

    public const PORT_CHECKS = ['full' => 'Full scan at the port', 'count' => 'Count only + photo of the receipt', 'off' => 'Off (with a reason)'];

    /** status => [label for container, label for RoRo, what the receiver sees] */
    public const STATUSES = [
        'preparing' => ['Preparing', 'Preparing', 'Preparing to ship to {hub}'],
        'sealed' => ['Loaded & sealed', 'Loaded, truck door sealed', 'Loaded for {hub}'],
        'to_port' => ['Truck to port', 'Driving to port', 'On the way to the port'],
        'at_port' => ['At the port', null, 'At the port, waiting to sail'],
        'sailed' => ['Sailed', 'On the ferry', 'On the way to {hub} by sea{eta}'],
        'arrived' => ['Arrived port', 'Off the ferry', 'Arrived at {port}'],
        'picked_up' => ['Picked up', null, 'On the way to {hub}'],
        'received' => ['Received', 'Received', 'At {hub}'],
    ];

    public static function ready(): bool
    {
        return Schema::hasTable('sea_shipments');
    }

    /** The steps of this shipment, in order. */
    public static function steps(SeaShipment $s): array
    {
        $i = $s->mode === 'roro' ? 1 : 0;

        return collect(static::STATUSES)->map(fn ($v) => $v[$i])->filter()->all();
    }

    public static function label(SeaShipment $s, ?string $status = null): string
    {
        return static::steps($s)[$status ?? $s->status] ?? ucfirst((string) ($status ?? $s->status));
    }

    public static function next(SeaShipment $s): ?string
    {
        $keys = array_keys(static::steps($s));
        $i = array_search($s->status, $keys, true);

        return $i === false ? $keys[0] : ($keys[$i + 1] ?? null);
    }

    /** Which steps the partner hub presses (the office presses the others). */
    public static function hubStep(string $status): bool
    {
        return in_array($status, ['picked_up', 'received'], true);
    }

    /** What the receiver sees on tracking. */
    public static function trackText(SeaShipment $s): string
    {
        $t = static::STATUSES[$s->status][2] ?? '';

        return strtr($t, ['{hub}' => $s->hub?->hub_name ?? 'the hub', '{port}' => $s->port_to ?: 'the port',
            '{eta}' => $s->eta && $s->status === 'sailed' ? ' · arriving about '.$s->eta->format('M j') : '']);
    }

    /** "CEB-0007" */
    public static function newCode(Logistichub $hub): string
    {
        $prefix = strtoupper(preg_replace('/[^A-Za-z]/', '', (string) $hub->hub_code)) ?: 'SEA';
        $n = SeaShipment::where('code', 'like', $prefix.'-%')->count() + 1;
        do {
            $code = $prefix.'-'.str_pad((string) $n++, 4, '0', STR_PAD_LEFT);
        } while (SeaShipment::where('code', $code)->exists());

        return $code;
    }

    /** Open trips to a partner hub that are not a shipment yet. */
    public static function tripsFor(int|false|null $hub): Collection
    {
        if ($hub === false) {
            return collect();
        }

        return Deliverylog::with('destination:id,hub_name,is_company', 'truck:id,plate_no')
            ->where('is_active', true)
            ->whereHas('destination', fn ($q) => $q->where('is_company', true))
            ->whereNotIn('id', SeaShipment::select('deliverylog_id'))
            ->when($hub !== null, fn ($q) => $q->where('logistichub_id', $hub))
            ->latest('id')->limit(50)->get();
    }

    public static function create(Deliverylog $trip, string $mode = 'container', ?string $portCheck = null): SeaShipment
    {
        $hub = Logistichub::findOrFail($trip->assigned_to);

        return SeaShipment::create([
            'code' => static::newCode($hub), 'deliverylog_id' => $trip->id, 'logistichub_id' => $hub->id,
            'mode' => array_key_exists($mode, static::MODES) ? $mode : 'container',
            'port_check' => $mode === 'roro' ? 'off' : ($portCheck && isset(static::PORT_CHECKS[$portCheck]) ? $portCheck : 'count'),
            'port_reason' => $mode === 'roro' ? 'RoRo: the truck drives onto the ferry' : null,
            'status' => 'preparing', 'status_log' => [['status' => 'preparing', 'at' => now()->toIso8601String(), 'by' => Auth::id()]],
            'created_by' => Auth::id(),
        ]);
    }

    /** Shipments a person may see. null hub = all (Admin). */
    public static function visible(int|false|null $hub): Builder
    {
        return SeaShipment::query()->with(['hub:id,hub_name,hub_code', 'trip:id,trip_number,logistichub_id,truck_id', 'trip.truck:id,plate_no'])
            ->when($hub === false, fn ($q) => $q->whereRaw('1 = 0'))
            ->when(is_int($hub), fn ($q) => $q->where(fn ($q) => $q->where('logistichub_id', $hub)
                ->orWhereIn('deliverylog_id', Deliverylog::where('logistichub_id', $hub)->select('id'))));
    }

    // ------------------------------------------------------------------ counts

    /** @return array{onTrip: int, loaded: int, port: ?int, received: int, missingPort: Collection, missingHub: Collection, perBox: ?float} */
    public static function counts(SeaShipment $s): array
    {
        $rows = Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->get();
        $loaded = $rows->where('is_loaded', true);
        $scans = SeaShipmentScan::where('sea_shipment_id', $s->id)->get()->groupBy('step');
        $portIds = ($scans['port'] ?? collect())->pluck('invoice_id')->all();
        $recIds = ($scans['received'] ?? collect())->pluck('invoice_id')->all();
        $port = match ($s->port_check) { 'full' => count($portIds), 'count' => $s->port_count, default => null };
        $atHub = in_array($s->status, ['arrived', 'picked_up', 'received'], true) || count($recIds) > 0;

        return [
            'onTrip' => $rows->count(), 'loaded' => $loaded->count(), 'port' => $port, 'received' => count($recIds),
            'missingPort' => $s->port_check === 'full' && count($portIds) > 0 ? $loaded->reject(fn ($r) => in_array($r->invoice_id, $portIds, true))->pluck('invoice')->values() : collect(),
            'missingHub' => $atHub ? $loaded->reject(fn ($r) => in_array($r->invoice_id, $recIds, true))->pluck('invoice')->values() : collect(),
            'perBox' => $loaded->count() > 0 && $s->cost() > 0 ? round($s->cost() / $loaded->count(), 2) : null,
        ];
    }

    // ------------------------------------------------------------------ moving on

    /** What stops the shipment going to the next step (empty = can go). */
    public static function blockers(SeaShipment $s, ?string $to = null): array
    {
        $to ??= static::next($s);
        $out = [];
        $c = static::counts($s);
        if ($to === 'sealed') {
            if ($c['onTrip'] === 0) {
                $out[] = 'No boxes on trip '.$s->trip?->trip_number.' yet.';
            } elseif ($c['loaded'] < $c['onTrip']) {
                $out[] = ($c['onTrip'] - $c['loaded']).' boxes on the trip are not loaded (scanned) yet.';
            }
            $open = $s->trip ? collect(BoxSets::openOnTrip($s->trip))->filter(fn ($o) => collect($o['missing'])->contains(fn ($m) => ! $m['reason'])) : collect();
            if ($open->isNotEmpty()) {
                $out[] = $open->count().' '.str('customer')->plural($open->count()).' missing boxes without a reason: '.$open->take(3)->pluck('name')->join(', ').'.';
            }
            if (! $s->seal_no) {
                $out[] = 'Type the seal number.';
            }
        }
        if ($to === 'at_port' || ($to === 'sailed' && $s->mode === 'roro')) {
            $out = array_merge($out, match ($s->port_check) {
                'full' => $c['port'] ? [] : ['Scan the boxes at the port first (Scan app → Port check).'],
                'count' => $s->port_count !== null ? [] : ['Type how many boxes were handed over at the port.'],
                default => $s->port_reason ? [] : ['Say why the port check is off.'],
            });
        }
        if ($to === 'sailed' && (! $s->vessel || ! $s->eta)) {
            $out[] = 'Type the vessel and the arrival date (ETA).';
        }

        return $out;
    }

    public static function move(SeaShipment $s, string $to, ?User $by = null): bool
    {
        if ($to !== static::next($s) || static::blockers($s, $to)) {
            return false;
        }
        $log = (array) $s->status_log;
        $log[] = ['status' => $to, 'at' => now()->toIso8601String(), 'by' => ($by ?? Auth::user())?->id];
        $s->update(['status' => $to, 'status_log' => $log]);

        return true;
    }

    /** When a step was reached. */
    public static function when(SeaShipment $s, string $status): ?string
    {
        $e = collect((array) $s->status_log)->where('status', $status)->last();

        return $e ? \Illuminate\Support\Carbon::parse($e['at'])->format('M j · g:i A') : null;
    }

    // ------------------------------------------------------------------ boxes

    /** The open shipment a box is on (not received at the hub yet), if any. */
    public static function stillAtSea(Tripinvoice $row): ?SeaShipment
    {
        if (! static::ready() || ! $row->deliverylog_id) {
            return null;
        }
        $s = SeaShipment::where('deliverylog_id', $row->deliverylog_id)->first();
        if (! $s || $s->status === 'received') {
            return null;
        }

        return SeaShipmentScan::where('sea_shipment_id', $s->id)->where('invoice_id', $row->invoice_id)->where('step', 'received')->exists() ? null : $s;
    }

    /** Scan a box at the port, or at the partner hub. */
    public static function scan(SeaShipment $s, Tripinvoice $row, string $step): bool
    {
        $created = SeaShipmentScan::firstOrCreate(['sea_shipment_id' => $s->id, 'invoice_id' => $row->invoice_id, 'step' => $step], ['user_id' => Auth::id(), 'created_at' => now()]);

        return $created->wasRecentlyCreated;
    }

    /** The section of this box is for another partner hub: put it on the Wrong hub list. */
    public static function checkWrongHub(SeaShipment $s, Tripinvoice $row): ?WrongHubBox
    {
        $section = $row->invdata?->whSection;
        if (! $section?->logistichub_id || (int) $section->logistichub_id === (int) $s->logistichub_id) {
            return null;
        }

        return WrongHubBox::firstOrCreate(['invoice_id' => $row->invoice_id, 'logistichub_id' => $s->logistichub_id, 'status' => 'waiting'], [
            'tripinvoice_id' => $row->id, 'correct_hub_id' => $section->logistichub_id, 'sea_shipment_id' => $s->id,
            'reason' => 'wrong_hub', 'created_by' => Auth::id(),
        ]);
    }

    /** Partner hub finished receiving: missing boxes get an Invoice Issue each. */
    public static function finishReceiving(SeaShipment $s, ?User $by = null): int
    {
        $c = static::counts($s);
        $type = Boxissue::firstOrCreate(['issue_type' => 'Missing box']);
        $made = 0;
        DB::transaction(function () use ($s, $c, $type, $by, &$made) {
            foreach (Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->whereIn('invoice', $c['missingHub'])->get() as $row) {
                $inv = Invoice::find($row->invoice_id);
                $exists = Invoiceissue::where('invoice_id', $row->invoice_id)->where('boxissue_id', $type->id)->where('remarks', 'like', '%'.$s->code.'%')->exists();
                if (! $exists) {
                    Invoiceissue::create(['invoice' => $row->invoice, 'invoice_id' => $row->invoice_id, 'container_id' => $inv?->container_id, 'boxissue_id' => $type->id,
                        'remarks' => "Not in sea shipment {$s->code} when {$s->hub?->hub_name} received it.", 'user_id' => ($by ?? Auth::user())?->id]);
                    $made++;
                }
            }
            if ($s->status !== 'received') {
                $log = (array) $s->status_log;
                $log[] = ['status' => 'received', 'at' => now()->toIso8601String(), 'by' => ($by ?? Auth::user())?->id];
                $s->update(['status' => 'received', 'status_log' => $log]);
            }
        });

        return $made;
    }

    /** Set info for a box at the partner hub: "2 of 3 arrived · 1 still in Manila". */
    public static function setAtHub(SeaShipment $s, Invoice $invoice): ?array
    {
        $all = BoxSets::members($invoice);
        if ($all->count() < 2) {
            return null;
        }
        $rec = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', 'received')->whereIn('invoice_id', $all->pluck('id'))->pluck('invoice_id')->all();
        $onShip = Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->whereIn('invoice_id', $all->pluck('id'))->pluck('invoice_id')->all();
        $here = count($rec);
        $notShipped = $all->reject(fn ($b) => in_array($b->id, $onShip, true));
        $toScan = count($onShip) - $here;
        $reasons = SetSplit::whereIn('invoice_id', $notShipped->pluck('id'))->pluck('reason', 'invoice_id');
        $parts = [];
        if ($toScan > 0) {
            $parts[] = $toScan.' more in this container';
        }
        if ($notShipped->isNotEmpty()) {
            $parts[] = $notShipped->count().' still in Manila ('.$notShipped->map(fn ($b) => $b->invoice.(isset($reasons[$b->id]) ? ' · '.(SetSplit::REASONS[$reasons[$b->id]] ?? $reasons[$b->id]) : ''))->join(', ').'), it follows';
        }

        return ['n' => $here, 'of' => $all->count(), 'name' => \Illuminate\Support\Str::title((string) $invoice->receiver_name),
            'text' => $parts ? implode(' · ', $parts) : '✓ All '.$all->count().' boxes arrived', 'kind' => $notShipped->isNotEmpty() ? 'split' : ($toScan ? 'wait' : 'done')];
    }
}
DISPATCH_FILE_END_23

# ---------------------------------------------------------------- app/Support/Shipping/WrongHub.php
mkdir -p 'app/Support/Shipping'
cat > 'app/Support/Shipping/WrongHub.php' <<'DISPATCH_FILE_END_24'
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
    public static function add(int $hubId, string $code, string $reason, ?string $note = null): ?WrongHubBox
    {
        $row = Tripinvoice::with('invdata.whSection')->where('logistichub_id', $hubId)->where('invoice', $code)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->latest('id')->first();
        if (! $row || ! array_key_exists($reason, WrongHubBox::REASONS)) {
            return null;
        }

        return WrongHubBox::firstOrCreate(['invoice_id' => $row->invoice_id, 'logistichub_id' => $hubId, 'status' => 'waiting'], [
            'tripinvoice_id' => $row->id, 'reason' => $reason, 'note' => $note ? mb_substr($note, 0, 300) : null,
            'correct_hub_id' => $row->invdata?->whSection?->logistichub_id, 'created_by' => Auth::id(),
        ]);
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
DISPATCH_FILE_END_24

# ---------------------------------------------------------------- app/Support/Sms/SmsSettings.php
mkdir -p 'app/Support/Sms'
cat > 'app/Support/Sms/SmsSettings.php' <<'DISPATCH_FILE_END_25'
<?php

namespace App\Support\Sms;

use App\Models\AppSetting;
use App\Models\Sms\SmsMessage;
use Illuminate\Support\Facades\Crypt;
use Throwable;

/** Admin → Settings → SMS. Keys are saved encrypted. With no key nothing is sent. */
class SmsSettings
{
    public const PROVIDERS = [
        'semaphore' => ['Semaphore', 'Philippine company, used by many local businesses. Paste the API key from semaphore.co.', true],
        'twilio' => ['Twilio', 'International. Paste "Account SID:Auth Token"; the sender is your Twilio number or Messaging Service SID. Usually costs more.', true],
        'm360' => ['M360', 'Philippine SMS provider for businesses. Send us their API details and we connect it.', false],
        'itexmo' => ['iTexMo / Movider', 'Local and regional options. Send us their API details and we connect it.', false],
    ];

    public const KINDS = [
        'out_for_delivery' => ['Out for delivery', 'When the truck is loaded and the trip is on the road', true],
        'driver_next' => ['Driver is next', 'When the receiver is the next 1–2 stops', true],
        'delivered' => ['Delivered', 'When the last box of the receiver is delivered', true],
        'not_delivered' => ['Not delivered', 'When the driver marks it not delivered', true],
        'hub_arrived' => ['Arrived at partner hub', 'When the box is handed to a partner hub', false],
        'set_split' => ['Rest of the boxes follow', 'When some of a customer\'s boxes stay behind at loading', false],
    ];

    public static function provider(): string
    {
        $p = (string) AppSetting::get('sms.provider', 'semaphore');

        return isset(self::PROVIDERS[$p]) ? $p : 'semaphore';
    }

    public static function key(?string $provider = null): ?string
    {
        $v = AppSetting::get('sms.key.'.($provider ?? static::provider()));
        try {
            return $v ? Crypt::decryptString($v) : null;
        } catch (Throwable) {
            return null;
        }
    }

    public static function putKey(string $provider, ?string $key): void
    {
        AppSetting::put('sms.key.'.$provider, filled($key) ? Crypt::encryptString(trim($key)) : null);
    }

    public static function masked(string $provider): ?string
    {
        $k = static::key($provider);

        return $k ? substr($k, 0, 4).str_repeat('•', 10).substr($k, -3) : null;
    }

    public static function ready(): bool
    {
        return (bool) static::key() && (self::PROVIDERS[static::provider()][2] ?? false);
    }

    public static function sender(): string
    {
        return (string) AppSetting::get('sms.sender', '');
    }

    public static function limit(): int
    {
        return (int) AppSetting::get('sms.limit', 3000);
    }

    public static function on(string $kind): bool
    {
        return (bool) AppSetting::get('sms.on.'.$kind, self::KINDS[$kind][2] ?? false);
    }

    /** auto (by province), en, tl, ceb */
    public static function language(): string
    {
        return (string) AppSetting::get('sms.language', 'auto');
    }

    public static function officePhone(): string
    {
        return (string) AppSetting::get('sms.office_phone', '');
    }

    /** Texts (SMS parts) used this month. */
    public static function usedThisMonth(): int
    {
        return (int) SmsMessage::where('status', 'sent')->where('created_at', '>=', now()->startOfMonth())->sum('parts');
    }
}
DISPATCH_FILE_END_25

# ---------------------------------------------------------------- app/Support/Sms/Templates.php
mkdir -p 'app/Support/Sms'
cat > 'app/Support/Sms/Templates.php' <<'DISPATCH_FILE_END_26'
<?php

namespace App\Support\Sms;

use App\Models\AppSetting;
use Illuminate\Support\Str;

/** The text of each message, in English, Tagalog and Bisaya, with {blanks}. */
class Templates
{
    public const LANGS = ['en' => 'English', 'tl' => 'Tagalog', 'ceb' => 'Bisaya'];

    public const BLANKS = ['{name}', '{boxes}', '{box_count}', '{truck}', '{driver}', '{time}', '{minutes}', '{reason}', '{next_day}', '{hub}', '{hub_phone}'];

    public const DEFAULTS = [
        'out_for_delivery' => [
            'en' => 'Hi {name}, your {box_count} box(es) {boxes} are out for delivery today with truck {truck}. Driver: {driver}.',
            'tl' => 'Hi {name}, ang {box_count} box mo ({boxes}) ay ide-deliver ngayong araw, truck {truck}. Driver: {driver}.',
            'ceb' => 'Hi {name}, ang {box_count} ka box nimo ({boxes}) i-deliver karong adlawa, truck {truck}. Driver: {driver}.',
        ],
        'driver_next' => [
            'en' => 'Hi {name}, our driver is on the way. Expected in about {minutes} minutes. Please prepare an ID.',
            'tl' => 'Hi {name}, papunta na ang driver namin. Darating sa loob ng mga {minutes} minuto. Ihanda po ang ID.',
            'ceb' => 'Hi {name}, padulong na ang among driver. Moabot sa mga {minutes} ka minuto. Palihug andama ang ID.',
        ],
        'delivered' => [
            'en' => 'Hi {name}, box {boxes} was delivered at {time}. Thank you!',
            'tl' => 'Hi {name}, na-deliver na ang box {boxes} nang {time}. Salamat po!',
            'ceb' => 'Hi {name}, na-deliver na ang box {boxes} sa {time}. Salamat!',
        ],
        'not_delivered' => [
            'en' => 'Hi {name}, we tried to deliver box {boxes} but {reason}. We will try again on {next_day}. Call {hub_phone}.',
            'tl' => 'Hi {name}, sinubukan naming i-deliver ang box {boxes} pero {reason}. Babalik kami sa {next_day}. Tumawag sa {hub_phone}.',
            'ceb' => 'Hi {name}, gisulayan namo i-deliver ang box {boxes} pero {reason}. Mobalik mi sa {next_day}. Tawag sa {hub_phone}.',
        ],
        'hub_arrived' => [
            'en' => 'Hi {name}, your box {boxes} arrived at {hub} and will be delivered soon.',
            'tl' => 'Hi {name}, ang box mo ({boxes}) ay dumating na sa {hub} at ide-deliver na sa lalong madaling panahon.',
            'ceb' => 'Hi {name}, ang imong box ({boxes}) niabot na sa {hub} ug i-deliver dayon.',
        ],
        'set_split' => [
            'en' => 'Hi {name}, {box_count} of your boxes are on the way. Box {boxes} follows on the next trip. Call {hub_phone}.',
            'tl' => 'Hi {name}, papunta na ang {box_count} sa mga box mo. Ang box {boxes} ay susunod sa next trip. Tumawag sa {hub_phone}.',
            'ceb' => 'Hi {name}, padulong na ang {box_count} sa imong mga box. Ang box {boxes} mosunod sa sunod nga biyahe. Tawag sa {hub_phone}.',
        ],
    ];

    /** Provinces where receivers get Bisaya, and where they get Tagalog (else English). */
    public const BISAYA = ['cebu', 'bohol', 'siquijor', 'negros oriental', 'leyte', 'southern leyte', 'biliran', 'camiguin', 'misamis oriental', 'misamis occidental',
        'bukidnon', 'agusan del norte', 'agusan del sur', 'surigao del norte', 'surigao del sur', 'dinagat islands', 'davao del norte', 'davao del sur', 'davao oriental',
        'davao occidental', 'davao de oro', 'zamboanga del norte', 'zamboanga del sur', 'zamboanga sibugay', 'lanao del norte', 'samar', 'eastern samar', 'northern samar'];

    public const TAGALOG = ['metro manila', 'ncr', 'manila', 'national capital region', 'bulacan', 'cavite', 'laguna', 'batangas', 'rizal', 'quezon', 'nueva ecija',
        'bataan', 'pampanga', 'tarlac', 'zambales', 'aurora', 'marinduque', 'occidental mindoro', 'oriental mindoro', 'romblon', 'palawan'];

    public static function get(string $kind, string $lang): string
    {
        return (string) (AppSetting::get("sms.tpl.{$kind}.{$lang}") ?: (self::DEFAULTS[$kind][$lang] ?? self::DEFAULTS[$kind]['en'] ?? ''));
    }

    public static function put(string $kind, string $lang, ?string $text): void
    {
        $text = Str::squish((string) $text);
        AppSetting::put("sms.tpl.{$kind}.{$lang}", $text === '' || $text === (self::DEFAULTS[$kind][$lang] ?? null) ? null : $text);
    }

    public static function langFor(?string $province): string
    {
        $rule = SmsSettings::language();
        if ($rule !== 'auto') {
            return isset(self::LANGS[$rule]) ? $rule : 'en';
        }
        $p = Str::lower(Str::squish((string) $province));
        foreach (self::BISAYA as $b) {
            if ($p !== '' && str_contains($p, $b)) {
                return 'ceb';
            }
        }
        foreach (self::TAGALOG as $t) {
            if ($p !== '' && str_contains($p, $t)) {
                return 'tl';
            }
        }

        return 'en';
    }

    public static function render(string $text, array $vals): string
    {
        $out = $text;
        foreach ($vals as $k => $v) {
            $out = str_replace('{'.$k.'}', (string) $v, $out);
        }

        return Str::squish(preg_replace('/\{[a-z_]+\}/', '', $out));
    }

    /** How many SMS parts a text needs (160 / 153 plain, 70 / 67 with emojis or special letters). */
    public static function parts(string $text): int
    {
        $gsm = preg_match('/^[\x{0A}\x{0D}\x{20}-\x{7E}£¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¡ÄÖÑÜ§¿äöñüà€]*$/u', $text) === 1;
        $len = mb_strlen($text);
        [$one, $many] = $gsm ? [160, 153] : [70, 67];

        return $len <= $one ? 1 : (int) ceil($len / $many);
    }

    /** The blanks used in a text. @return list<string> */
    public static function blanksIn(string $text): array
    {
        preg_match_all('/\{[a-z_]+\}/', $text, $m);
        $b = array_values(array_unique($m[0]));
        sort($b);

        return $b;
    }
}
DISPATCH_FILE_END_26

# ---------------------------------------------------------------- database/migrations/2026_11_15_000024_create_sea_shipments.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_15_000024_create_sea_shipments.php' <<'DISPATCH_FILE_END_27'
<?php

use App\Support\Help\Help;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Sea shipments to partner hubs (Visayas, Mindanao): built on a normal trip to the port,
 * with the van, seal, ship, port check and receiving at the partner hub. Plus the
 * Wrong hub & returns list.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('sea_shipments', function (Blueprint $t) {
            $t->id();
            $t->string('code', 20)->unique();
            $t->foreignId('deliverylog_id')->unique();   // the trip to the port (a normal trip to the hub)
            $t->foreignId('logistichub_id')->index();     // the partner hub it goes to
            $t->string('mode', 12)->default('container'); // container, roro
            $t->string('status', 12)->default('preparing');
            $t->json('status_log')->nullable();
            $t->string('van_no', 20)->nullable();
            $t->string('van_size', 10)->nullable();
            $t->string('seal_no', 30)->nullable();
            $t->string('seal_photo')->nullable();
            $t->string('shipping_line', 80)->nullable();
            $t->string('vessel', 80)->nullable();
            $t->string('voyage', 30)->nullable();
            $t->string('bl_no', 40)->nullable();
            $t->string('port_from', 80)->nullable();
            $t->string('port_to', 80)->nullable();
            $t->date('etd')->nullable();
            $t->date('eta')->nullable();
            $t->string('port_check', 8)->default('count'); // full, count, off
            $t->unsignedInteger('port_count')->nullable();
            $t->string('port_receipt')->nullable();
            $t->string('port_reason', 200)->nullable();
            $t->foreignId('port_by')->nullable();
            $t->timestamp('port_at')->nullable();
            $t->decimal('cost_freight', 12, 2)->nullable();
            $t->decimal('cost_trucking', 12, 2)->nullable();
            $t->decimal('cost_port', 12, 2)->nullable();
            $t->decimal('cost_other', 12, 2)->nullable();
            $t->string('note', 500)->nullable();
            $t->foreignId('created_by')->nullable();
            $t->timestamps();
        });

        Schema::create('sea_shipment_scans', function (Blueprint $t) {
            $t->id();
            $t->foreignId('sea_shipment_id');
            $t->foreignId('invoice_id');
            $t->string('step', 10); // port, received
            $t->foreignId('user_id')->nullable();
            $t->timestamp('created_at')->nullable();
            $t->unique(['sea_shipment_id', 'invoice_id', 'step']);
        });

        Schema::create('wrong_hub_boxes', function (Blueprint $t) {
            $t->id();
            $t->foreignId('invoice_id')->index();
            $t->foreignId('tripinvoice_id')->nullable();
            $t->foreignId('logistichub_id')->index();   // where the box is now
            $t->foreignId('correct_hub_id')->nullable(); // where it should go
            $t->foreignId('sea_shipment_id')->nullable();
            $t->string('reason', 20);                    // wrong_hub, refused, moved, wrong_address, other
            $t->string('status', 12)->default('waiting');// waiting, sent_hub, back, done
            $t->string('note', 300)->nullable();
            $t->foreignId('created_by')->nullable();
            $t->foreignId('done_by')->nullable();
            $t->timestamp('done_at')->nullable();
            $t->timestamps();
        });

        Help::installDefaults();
    }

    public function down(): void
    {
        Schema::dropIfExists('wrong_hub_boxes');
        Schema::dropIfExists('sea_shipment_scans');
        Schema::dropIfExists('sea_shipments');
    }
};
DISPATCH_FILE_END_27

# ---------------------------------------------------------------- resources/css/filament/admin/theme.css
mkdir -p 'resources/css/filament/admin'
cat > 'resources/css/filament/admin/theme.css' <<'DISPATCH_FILE_END_28'
@import '../../../../vendor/filament/filament/resources/css/theme.css';

/* The Archivo font comes with the app (no internet needed): pages open fast even on a slow connection. */
@import '@fontsource/archivo/latin-400.css';
@import '@fontsource/archivo/latin-500.css';
@import '@fontsource/archivo/latin-600.css';
@import '@fontsource/archivo/latin-700.css';
@import '@fontsource/archivo/latin-800.css';
@import '@fontsource/archivo/latin-900.css';

@source '../../../../app/Filament/**/*';
@source '../../../../resources/views/filament/**/*';
@source '../../../../resources/views/components/**/*';

/*
 * Dispatch theme — "manifest & signal".
 * Harbour navy for the frame, signal yellow for action, colour only where it
 * carries meaning (scan outcomes, progress). Shared by all four panels.
 */
:root {
    --ds-navy: #0e2433;
    --ds-navy-2: #16334a;
    --ds-navy-3: #24465f;
    --ds-signal: #f6be00;
    --ds-steel: #5b6b78;
    --ds-deck: #f3f5f7;
    --ds-ok: #17895e;
    --ds-warn: #e08a00;
    --ds-bad: #cf3b3b;
    --ds-radius-lg: 0.875rem;
    --ds-radius: 0.625rem;
}

body {
    font-feature-settings: 'tnum' 1, 'ss01' 1;
}

/* ------------------------------------------------------------------ frame */

.fi-body {
    background: var(--ds-deck);
}

.dark .fi-body {
    background: #0a1a26;
}

.fi-sidebar {
    background: var(--ds-navy);
    border-inline-end: 0;
}

.fi-sidebar-header {
    background: var(--ds-navy);
    box-shadow: none;
    border-bottom: 1px solid rgb(255 255 255 / 0.06);
}

.fi-sidebar .fi-sidebar-group-label,
.fi-sidebar .fi-sidebar-group-btn {
    color: rgb(255 255 255 / 0.5);
}

.fi-sidebar .fi-sidebar-item-btn {
    color: rgb(255 255 255 / 0.78);
    border-radius: var(--ds-radius);
}

.fi-sidebar .fi-sidebar-item-icon {
    color: rgb(255 255 255 / 0.45);
}

.fi-sidebar .fi-sidebar-item-label {
    color: inherit;
}

.fi-sidebar .fi-sidebar-item-btn:hover,
.fi-sidebar .fi-sidebar-item-btn:focus-visible {
    background: var(--ds-navy-2);
    color: #fff;
}

/* Active item: a signal-yellow tab on the left edge, like a door stripe. */
.fi-sidebar .fi-sidebar-item.fi-active > .fi-sidebar-item-btn {
    background: var(--ds-navy-3);
    color: #fff;
    box-shadow: inset 3px 0 0 var(--ds-signal);
}

.fi-sidebar .fi-sidebar-item.fi-active .fi-sidebar-item-icon {
    color: var(--ds-signal);
}

.fi-sidebar .fi-sidebar-item-grouped-border-part {
    background: rgb(255 255 255 / 0.18);
}

.fi-sidebar-footer,
.ds-sidebar-footer {
    color: rgb(255 255 255 / 0.4);
    font-size: 0.75rem;
    padding: 0.75rem 1.25rem 1rem;
}

.fi-topbar > nav,
.fi-topbar {
    background: rgb(255 255 255 / 0.92);
    backdrop-filter: blur(8px);
    box-shadow: 0 1px 0 rgb(14 36 51 / 0.08);
}

.dark .fi-topbar > nav,
.dark .fi-topbar {
    background: rgb(14 36 51 / 0.92);
}

/* Brand mark */
.ds-brand {
    display: inline-flex;
    align-items: center;
    gap: 0.625rem;
    line-height: 1;
}

.ds-brand__mark {
    width: 2.1rem;
    height: 2.1rem;
    flex: none;
}

.ds-brand__text {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
}

.ds-brand__name {
    font-weight: 800;
    font-size: 1.05rem;
    letter-spacing: -0.01em;
    color: var(--ds-navy);
}

.ds-brand__area {
    font-size: 0.72rem;
    font-weight: 600;
    color: var(--ds-steel);
}

.fi-sidebar .ds-brand__name,
.dark .ds-brand__name {
    color: #fff;
}

.fi-sidebar .ds-brand__area,
.dark .ds-brand__area {
    color: var(--ds-signal);
}

.fi-sidebar .ds-brand__mark rect:first-child {
    fill: #23435b;
}

/* ---------------------------------------------------------------- content */

.fi-header-heading {
    letter-spacing: -0.02em;
    font-weight: 800;
}

.fi-section,
.fi-ta-ctn,
.fi-wi-stats-overview-stat {
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06);
}

.fi-ta-header-cell {
    font-weight: 600;
    color: var(--ds-steel);
}

.fi-wi-stats-overview-stat {
    position: relative;
    overflow: hidden;
}

.fi-wi-stats-overview-stat-value {
    font-weight: 800;
    letter-spacing: -0.02em;
}

/* --------------------------------------------------------------- sign-in */

.fi-simple-layout {
    background:
        repeating-linear-gradient(90deg, transparent 0 46px, rgb(255 255 255 / 0.035) 46px 48px),
        var(--ds-navy);
}

.fi-simple-main {
    border-radius: 1.25rem;
    box-shadow: 0 30px 60px -20px rgb(0 0 0 / 0.45);
    border-top: 6px solid var(--ds-signal);
}

/* ------------------------------------------------------------ scan station */

.ds-station {
    display: grid;
    gap: 1.25rem;
    align-items: start;
}

@media (min-width: 1100px) {
    .ds-station {
        grid-template-columns: minmax(22rem, 2fr) 3fr;
    }
}

.ds-station__panel,
.ds-station__result {
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
}

.ds-station__panel {
    background: #fff;
    border-radius: var(--ds-radius-lg);
    padding: 1.25rem;
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06), 0 0 0 1px rgb(14 36 51 / 0.05);
}

.dark .ds-station__panel {
    background: rgb(255 255 255 / 0.04);
    box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08);
}

.ds-station__title {
    display: flex;
    gap: 0.875rem;
    align-items: center;
}

.ds-station__title h2 {
    font-size: 1.125rem;
    font-weight: 750;
    color: var(--ds-navy);
}

.dark .ds-station__title h2 {
    color: #fff;
}

.ds-station__title p {
    font-size: 0.875rem;
    color: var(--ds-steel);
    max-width: 38ch;
}

.ds-station__badge {
    display: grid;
    place-items: center;
    width: 2.75rem;
    height: 2.75rem;
    border-radius: 0.75rem;
    background: var(--ds-navy);
    color: var(--ds-signal);
    flex: none;
}

/* Progress */
.ds-progress__head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 1rem;
    margin-bottom: 0.5rem;
    font-size: 0.875rem;
}

.ds-progress__label {
    color: var(--ds-steel);
    font-weight: 600;
}

.ds-progress__count strong {
    font-size: 1.5rem;
    font-weight: 800;
    color: var(--ds-navy);
}

.dark .ds-progress__count strong {
    color: #fff;
}

.ds-progress__pct {
    margin-inline-start: 0.5rem;
    color: var(--ds-steel);
}

.ds-progress__track {
    height: 0.75rem;
    border-radius: 999px;
    background: rgb(14 36 51 / 0.08);
    overflow: hidden;
}

.dark .ds-progress__track {
    background: rgb(255 255 255 / 0.1);
}

.ds-progress__bar {
    height: 100%;
    border-radius: inherit;
    background: var(--ds-signal);
    transition: width 0.35s ease;
}

.ds-progress.is-done .ds-progress__bar {
    background: var(--ds-ok);
}

.ds-progress__done {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    margin-top: 0.625rem;
    color: var(--ds-ok);
    font-weight: 600;
    font-size: 0.875rem;
}

/* Result card — the invoice number painted large, like on a container door. */
.ds-result {
    --ds-tone: var(--ds-ok);
    background: #fff;
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06), 0 0 0 1px rgb(14 36 51 / 0.05);
    border-inline-start: 0.6rem solid var(--ds-tone);
    padding: 1.25rem 1.5rem 1.5rem;
}

.dark .ds-result {
    background: rgb(255 255 255 / 0.04);
}

.ds-result--warning {
    --ds-tone: var(--ds-warn);
}

.ds-result--danger {
    --ds-tone: var(--ds-bad);
}

.ds-result__head {
    display: flex;
    align-items: center;
    gap: 1rem;
}

.ds-result__icon {
    color: var(--ds-tone);
    flex: none;
}

.ds-result__eyebrow {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--ds-tone);
}

.ds-result__invoice {
    font-size: clamp(2.25rem, 5vw, 3.5rem);
    line-height: 1;
    font-weight: 900;
    letter-spacing: 0.01em;
    color: var(--ds-navy);
    word-break: break-all;
}

.dark .ds-result__invoice {
    color: #fff;
}

.ds-result__message {
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-result__message {
    color: #fff;
}

.ds-result__chip {
    margin-inline-start: auto;
    align-self: flex-start;
    padding: 0.3rem 0.7rem;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-size: 0.8rem;
    font-weight: 700;
    white-space: nowrap;
}

.ds-result__grid {
    display: grid;
    gap: 0.875rem 1.5rem;
    margin-top: 1.25rem;
    padding-top: 1.25rem;
    border-top: 1px dashed rgb(14 36 51 / 0.15);
}

@media (min-width: 640px) {
    .ds-result__grid {
        grid-template-columns: 1fr 1fr;
    }
}

.ds-result__grid dt {
    font-size: 0.78rem;
    color: var(--ds-steel);
}

.ds-result__grid dd {
    font-size: 1rem;
    color: rgb(14 36 51 / 0.9);
}

.dark .ds-result__grid dd {
    color: rgb(255 255 255 / 0.88);
}

.ds-result__strong {
    font-size: 1.2rem !important;
    font-weight: 700;
}

.ds-result__actions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 1.25rem;
}

.ds-result__actions:empty {
    display: none;
}

/* Household list */
.ds-household {
    background: #fff;
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    padding: 1rem 1.25rem;
}

.dark .ds-household {
    background: rgb(255 255 255 / 0.04);
}

.ds-household__head {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-household__head {
    color: #fff;
}

.ds-household__sub {
    margin-inline-start: auto;
    font-weight: 500;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-household__list {
    margin-top: 0.75rem;
    display: grid;
    gap: 0.25rem;
}

.ds-household__list li {
    display: grid;
    grid-template-columns: auto 1fr auto auto;
    gap: 0.75rem;
    align-items: center;
    padding: 0.5rem 0.25rem;
    border-top: 1px solid rgb(14 36 51 / 0.06);
    color: var(--ds-steel);
    font-size: 0.9rem;
}

.ds-household__list li.is-done {
    color: var(--ds-ok);
}

.ds-household__invoice {
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-household__invoice {
    color: #fff;
}

/* Empty state */
.ds-empty {
    display: grid;
    justify-items: center;
    text-align: center;
    gap: 0.5rem;
    padding: 3.5rem 1.5rem;
    border-radius: var(--ds-radius-lg);
    border: 2px dashed rgb(14 36 51 / 0.14);
    color: var(--ds-steel);
}

.ds-empty__title {
    font-size: 1.125rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-empty__title {
    color: #fff;
}

.ds-empty__text {
    max-width: 36ch;
    font-size: 0.9rem;
}

/* Trip progress (dashboard table) */
.ds-trip-progress {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    min-width: 12rem;
    padding-inline: 0.75rem;
}

.ds-trip-progress__track {
    position: relative;
    flex: 1;
    height: 0.5rem;
    border-radius: 999px;
    background: rgb(14 36 51 / 0.08);
    overflow: hidden;
}

.ds-trip-progress__track > span {
    position: absolute;
    inset-block: 0;
    left: 0;
    border-radius: inherit;
}

.ds-trip-progress__loaded {
    background: var(--ds-signal);
}

.ds-trip-progress__delivered {
    background: var(--ds-ok);
}

.ds-trip-progress__nums {
    font-size: 0.85rem;
    font-weight: 700;
    white-space: nowrap;
}

.ds-trip-progress__nums span {
    font-weight: 400;
    color: var(--ds-steel);
}

@media (prefers-reduced-motion: reduce) {
    .ds-progress__bar {
        transition: none;
    }
}

/* Larger stat labels on the inventory widget (kept from the original theme). */
.fi-wi-stats-overview-stat-label {
    font-weight: 600;
}

/* The station's result card already shows the last scan (with the right colour). */
.ds-station .bb-scanner__last {
    display: none;
}

/* =================================================================
 * Sign-in pages — one design per panel (Admin, Partner hub,
 * Warehouse, Delivery). Filament's own form is placed inside.
 * ================================================================= */

.ds-auth-main {
    min-height: 100vh;
    min-height: 100dvh;
}

.ds-auth {
    --ds-input-h: 3.25rem;
    min-height: 100vh;
    min-height: 100dvh;
    color: var(--ds-navy);
    font-family: Archivo, ui-sans-serif, system-ui, sans-serif;
}

/* Company name + logo */
.ds-company {
    display: inline-flex;
    align-items: center;
    gap: 0.875rem;
}

.ds-company__logo {
    width: 3.25rem;
    height: 3.25rem;
    border-radius: 0.75rem;
    object-fit: contain;
    background: #fff;
    flex: none;
}

.ds-company__logo--initials {
    display: grid;
    place-items: center;
    background: var(--ds-signal);
    color: var(--ds-navy);
    font-weight: 900;
    font-size: 1.1rem;
}

.ds-company--sm .ds-company__logo {
    width: 2.5rem;
    height: 2.5rem;
    border-radius: 0.6rem;
    font-size: 0.9rem;
}

.ds-company--lg .ds-company__logo {
    width: 3.75rem;
    height: 3.75rem;
}

.ds-company__text {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
}

.ds-company__name {
    font-size: 1.2rem;
    font-weight: 800;
    letter-spacing: -0.01em;
    line-height: 1.15;
}

.ds-company--lg .ds-company__name {
    font-size: 1.75rem;
}

.ds-company--sm .ds-company__name {
    font-size: 1.05rem;
}

.ds-company__sub {
    font-size: 0.8rem;
    font-weight: 600;
    color: var(--ds-steel);
}

.ds-company--dark {
    color: #fff;
}

.ds-company--dark .ds-company__sub {
    color: #8fa3b3;
}

.ds-company__sub--accent,
.ds-company--dark .ds-company__sub--accent {
    color: var(--ds-signal);
}

/* Shared form styling */
.ds-auth__form {
    width: 100%;
    max-width: 26.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.ds-auth__chip {
    align-self: flex-start;
    font-size: 0.8rem;
    font-weight: 700;
    padding: 0.35rem 0.75rem;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
}

.ds-auth__title {
    margin: 0.5rem 0 0;
    font-size: 2.1rem;
    font-weight: 800;
    letter-spacing: -0.02em;
    line-height: 1.1;
}

.ds-auth__title--xl {
    font-size: clamp(2.2rem, 4vw, 2.75rem);
    letter-spacing: -0.03em;
}

.ds-auth__lead {
    margin: 0 0 1.25rem;
    font-size: 1rem;
    color: var(--ds-steel);
}

.ds-auth__help {
    margin: 1.25rem 0 0;
    font-size: 0.82rem;
    line-height: 1.5;
    color: var(--ds-steel);
    max-width: 26.5rem;
}

.ds-auth .fi-fo-field-label-content {
    font-weight: 600;
    color: var(--ds-navy);
}

.ds-auth .fi-input-wrp {
    min-height: var(--ds-input-h);
    border-radius: 0.65rem;
    align-items: center;
}

.ds-auth .fi-input {
    font-size: 1rem;
}

.ds-auth form .fi-btn {
    min-height: 3.4rem;
    border-radius: 0.65rem;
    font-size: 1.05rem;
    font-weight: 800;
}

.ds-auth--company form .fi-btn,
.ds-auth--warehouse form .fi-btn,
.ds-auth--delivery form .fi-btn {
    background: var(--ds-navy);
    color: #fff;
}

.ds-auth--company form .fi-btn:hover,
.ds-auth--warehouse form .fi-btn:hover,
.ds-auth--delivery form .fi-btn:hover {
    background: var(--ds-navy-3);
}

.ds-auth--company form .fi-btn,
.ds-auth--delivery form .fi-btn {
    border-radius: 999px;
}

/* ---------- Admin: navy story + form */
.ds-auth--admin {
    display: grid;
    background: var(--ds-deck);
}

@media (min-width: 1024px) {
    .ds-auth--admin {
        grid-template-columns: minmax(28rem, 44%) 1fr;
    }
}

.ds-auth-admin__story {
    position: relative;
    overflow: hidden;
    background: var(--ds-navy);
    color: #fff;
    padding: 2.5rem 1.75rem;
    display: flex;
    flex-direction: column;
    gap: 2rem;
}

@media (min-width: 1024px) {
    .ds-auth-admin__story {
        padding: 3.5rem 4rem;
        justify-content: space-between;
    }
}

.ds-auth-admin__pitch {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
}

.ds-auth-admin__pitch h1 {
    margin: 0;
    font-size: clamp(2.1rem, 4.2vw, 3.5rem);
    line-height: 1.03;
    font-weight: 800;
    letter-spacing: -0.03em;
    max-width: 14ch;
}

.ds-auth-admin__pitch p {
    margin: 0;
    font-size: 1.05rem;
    line-height: 1.55;
    color: #b7c4cf;
    max-width: 34ch;
}

.ds-auth-admin__foot {
    position: relative;
    z-index: 1;
    padding-top: 1.25rem;
    border-top: 1px solid rgb(255 255 255 / 0.12);
    font-size: 0.9rem;
    color: #8fa3b3;
}

.ds-auth-admin__ribs {
    position: absolute;
    right: -9rem;
    top: 7rem;
    width: 26rem;
    height: 35rem;
    border-radius: 1.75rem;
    background: repeating-linear-gradient(90deg, #12304a 0 34px, var(--ds-navy) 34px 46px);
    opacity: 0.7;
}

@media (max-width: 1023px) {
    .ds-auth-admin__foot,
    .ds-auth-admin__pitch p {
        display: none;
    }

    .ds-auth-admin__ribs {
        display: none;
    }
}

@media (max-width: 1023px) {
    /* On small screens the card already shows the company. */
    .ds-auth-warehouse__brand {
        display: none;
    }
}

.ds-auth__form-side {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2.5rem 1.75rem 3rem;
}

/* ---------- Partner hub: form + yellow steps */
.ds-auth--company {
    display: grid;
    background: var(--ds-signal);
}

@media (min-width: 1024px) {
    .ds-auth--company {
        grid-template-columns: minmax(30rem, 42%) 1fr;
    }
}

.ds-auth__form-side--white {
    background: #fff;
    flex-direction: column;
    align-items: stretch;
    justify-content: space-between;
    gap: 2.5rem;
}

@media (min-width: 1024px) {
    .ds-auth__form-side--white {
        padding: 4rem 5.5rem;
    }
}

.ds-auth-company__story {
    padding: 3rem 1.75rem;
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 2.5rem;
}

@media (min-width: 1024px) {
    .ds-auth-company__story {
        padding: 4.5rem 5rem;
    }
}

.ds-auth-company__story h1 {
    margin: 0;
    font-size: clamp(2.25rem, 4.5vw, 4rem);
    line-height: 0.98;
    font-weight: 900;
    letter-spacing: -0.035em;
    max-width: 14ch;
}

.ds-auth-company__steps {
    margin: 0;
    padding: 0;
    list-style: none;
    display: flex;
    flex-direction: column;
    max-width: 35rem;
}

.ds-auth-company__steps li {
    position: relative;
    display: grid;
    grid-template-columns: 2.75rem 1fr;
    gap: 1.25rem;
    padding-bottom: 1.6rem;
}

.ds-auth-company__steps li:not(:last-child)::before {
    content: '';
    position: absolute;
    left: calc(1.375rem - 1.5px);
    top: 2.9rem;
    bottom: 0.3rem;
    width: 3px;
    background: rgb(14 36 51 / 0.35);
}

.ds-auth-company__num {
    width: 2.75rem;
    height: 2.75rem;
    border-radius: 999px;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-weight: 800;
    font-size: 1.1rem;
}

.ds-auth-company__steps strong {
    display: block;
    padding-top: 0.45rem;
    font-size: 1.25rem;
    font-weight: 800;
}

.ds-auth-company__steps span:not(.ds-auth-company__num) {
    display: block;
    margin-top: 0.25rem;
    font-size: 0.95rem;
    color: #3b3000;
}

/* ---------- Warehouse: container side + card */
.ds-auth--warehouse {
    position: relative;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2rem;
    padding: 2.5rem 1.25rem;
    background: repeating-linear-gradient(90deg, var(--ds-navy) 0 52px, #12304a 52px 60px, #0b1f2d 60px 64px);
}

.ds-auth-warehouse__stripe {
    position: absolute;
    inset-block: 0;
    left: 0;
    width: 1.125rem;
    background: var(--ds-signal);
}

@media (min-width: 1024px) {
    .ds-auth-warehouse__brand {
        position: absolute;
        left: 4.5rem;
        top: 4rem;
    }
}

.ds-auth-warehouse__card {
    position: relative;
    width: 100%;
    max-width: 30rem;
    background: #fff;
    border-radius: 1.4rem;
    padding: 2.75rem 2rem 2.25rem;
    box-shadow: 0 40px 80px -30px rgb(0 0 0 / 0.6);
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

@media (min-width: 640px) {
    .ds-auth-warehouse__card {
        padding: 2.75rem 3rem 2.5rem;
    }
}

.ds-auth-warehouse__tab {
    position: absolute;
    left: 3rem;
    right: 3rem;
    top: 0;
    height: 6px;
    border-radius: 0 0 6px 6px;
    background: var(--ds-signal);
}

.ds-auth-warehouse__card .ds-auth__title {
    margin-bottom: 0.75rem;
    font-size: 1.6rem;
}

/* ---------- Delivery: phone first */
.ds-auth--delivery {
    display: flex;
    flex-direction: column;
    background: #fff;
    max-width: 34rem;
    margin-inline: auto;
}

@media (min-width: 640px) {
    .ds-auth-main:has(.ds-auth--delivery) {
        background: var(--ds-navy);
        padding: 3rem 1rem;
    }

    .ds-auth--delivery {
        min-height: auto;
        border-radius: 1.5rem;
        overflow: hidden;
        box-shadow: 0 40px 80px -30px rgb(0 0 0 / 0.6);
    }
}

.ds-auth-delivery__top {
    background: var(--ds-signal);
    padding: 2.25rem 1.75rem 2rem;
    display: flex;
    flex-direction: column;
    gap: 1.4rem;
}

.ds-auth-delivery__top .ds-company__sub {
    color: var(--ds-navy);
    font-weight: 700;
}

.ds-auth-delivery__top h1 {
    margin: 0;
    font-size: 2.25rem;
    line-height: 1;
    font-weight: 900;
    letter-spacing: -0.035em;
    max-width: 12ch;
}

.ds-auth-delivery__form {
    flex: 1;
    padding: 1.75rem 1.75rem 2.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.ds-auth-delivery__form .ds-auth__title {
    margin-top: 0;
    font-size: 1.75rem;
}

.ds-auth--delivery {
    --ds-input-h: 3.5rem;
}

.dark .ds-auth--admin .ds-auth__form-side,
.dark .ds-auth__form-side--white,
.dark .ds-auth-warehouse__card,
.dark .ds-auth--delivery {
    color-scheme: light;
}

/* On yellow backgrounds the initials badge flips to navy. */
.ds-auth-delivery__top .ds-company__logo--initials {
    background: var(--ds-navy);
    color: var(--ds-signal);
}

/* Sign-in pages are always light: readable text even if dark mode slips through. */
.ds-auth {
    color-scheme: light;
}

.ds-auth .fi-input-wrp {
    background-color: #fff;
}

.ds-auth .fi-input,
.ds-auth .fi-input-wrp input {
    color: var(--ds-navy);
    -webkit-text-fill-color: var(--ds-navy);
    caret-color: var(--ds-navy);
}

.ds-auth .fi-input::placeholder {
    color: #8b98a3;
    -webkit-text-fill-color: #8b98a3;
}

/* Safari / Chrome autofill keeps a readable white box. */
.ds-auth input:-webkit-autofill {
    -webkit-box-shadow: 0 0 0 1000px #fff inset;
    -webkit-text-fill-color: var(--ds-navy);
}

/* Uploaded company logo in the panel header. */
.ds-brand__mark--image {
    object-fit: contain;
    border-radius: 0.5rem;
    background: #fff;
}

.ds-brand__name {
    max-width: 11rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

/* Delivery attempts history (dispatcher view). */
.ds-attempts {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

.ds-attempts__item {
    padding: 0.875rem 1rem;
    border-radius: var(--ds-radius);
    background: rgb(14 36 51 / 0.04);
}

.dark .ds-attempts__item {
    background: rgb(255 255 255 / 0.05);
}

.ds-attempts__head {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
}

.ds-attempts__when,
.ds-attempts__who {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-attempts__who {
    margin-top: 0.4rem;
}

.ds-attempts__note {
    margin-top: 0.4rem;
    font-size: 0.95rem;
}

.ds-attempts__photos {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 0.6rem;
}

.ds-attempts__photos img {
    width: 6rem;
    height: 6rem;
    object-fit: cover;
    border-radius: 0.5rem;
}

/* =================================================================
 * Driver dashboard (Delivery panel) — phone first.
 * ================================================================= */
.ds-driver {
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
    max-width: 40rem;
    color: var(--ds-navy);
}

.dark .ds-driver {
    color: #fff;
}

.ds-driver h2 {
    margin: 0;
    font-size: 1.15rem;
    font-weight: 800;
    display: flex;
    align-items: center;
    gap: 0.5rem;
}

.ds-driver__muted {
    display: block;
    font-size: 0.78rem;
    color: #8fa3b3;
}

.ds-driver__soft {
    display: block;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

/* Trip card */
.ds-driver__trip {
    background: var(--ds-navy);
    color: #fff;
    border-radius: 1.1rem;
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-driver__trip .ds-driver__soft {
    color: #b7c4cf;
}

.ds-driver__trip-head {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 0.75rem;
}

.ds-driver__trip-no {
    display: block;
    font-size: 1.9rem;
    font-weight: 900;
    letter-spacing: 0.01em;
    line-height: 1.1;
}

.ds-driver__pill {
    padding: 0.35rem 0.8rem;
    border-radius: 999px;
    background: var(--ds-signal);
    color: var(--ds-navy);
    font-size: 0.8rem;
    font-weight: 800;
    white-space: nowrap;
}

.ds-driver__trip-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.75rem;
    font-size: 0.9rem;
}

.ds-driver__trip-grid strong {
    display: block;
    font-weight: 700;
}

.ds-driver__progress-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 0.5rem;
    color: #b7c4cf;
}

.ds-driver__progress-head strong {
    font-size: 1.75rem;
    font-weight: 900;
    color: #fff;
}

.ds-driver__left {
    font-weight: 700;
    color: var(--ds-signal);
}

.ds-driver__bar {
    height: 0.75rem;
    border-radius: 999px;
    background: rgb(255 255 255 / 0.12);
    overflow: hidden;
}

.ds-driver__bar > span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--ds-signal);
}

.ds-driver__warn {
    margin-top: 0.6rem;
    font-size: 0.85rem;
    color: #ffd7d7;
}

/* All delivered */
.ds-driver__trip--done {
    background: var(--ds-ok);
}

.ds-driver__trip--done .ds-driver__bar {
    background: rgb(255 255 255 / 0.25);
}

.ds-driver__trip--done .ds-driver__bar > span {
    background: #fff;
}

.ds-driver__done-title {
    font-size: 1.8rem;
    font-weight: 900;
    line-height: 1.05;
}

.ds-driver__done-sub {
    color: #d4f0e4;
}

.ds-driver__card {
    background: #fff;
    border-radius: 1rem;
    padding: 1.1rem;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
}

.dark .ds-driver__card {
    background: rgb(255 255 255 / 0.05);
}

/* Big buttons */
.ds-driver__actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.75rem;
}

.ds-driver__action {
    min-height: 4rem;
    border-radius: 0.9rem;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.6rem;
    font-weight: 800;
    font-size: 1rem;
    background: #fff;
    color: var(--ds-navy);
    box-shadow: inset 0 0 0 1.5px #d5dde3;
}

.ds-driver__action--primary {
    background: var(--ds-signal);
    box-shadow: none;
}

.ds-driver__action:focus-visible {
    outline: 3px solid var(--ds-navy);
    outline-offset: 2px;
}

/* Sections */
.ds-driver__section {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
}

.ds-driver__section-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 1rem;
}

.ds-driver__count {
    font-size: 0.8rem;
    padding: 0.1rem 0.55rem;
    border-radius: 999px;
    background: var(--ds-signal);
    color: var(--ds-navy);
}

/* Stop card */
.ds-stop {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.85rem 0.9rem;
    border-radius: 0.9rem;
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-stop {
    background: rgb(255 255 255 / 0.05);
}

.ds-stop--priority {
    background: #fff8db;
    box-shadow: inset 0 0 0 1.5px var(--ds-signal);
}

.ds-stop--problem {
    box-shadow: inset 0 0 0 1.5px #f2c4c4;
}

.ds-stop--soft {
    background: var(--ds-deck);
    box-shadow: none;
}

.dark .ds-stop--priority,
.dark .ds-stop--soft {
    background: rgb(255 255 255 / 0.06);
}

.ds-stop__text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
}

.ds-stop__label {
    font-size: 0.8rem;
    font-weight: 700;
    color: #b02e2e;
}

.ds-stop__invoice {
    font-weight: 900;
    font-size: 1.02rem;
    word-break: break-word;
}

.ds-stop__name {
    font-weight: 700;
}

.ds-stop__address,
.ds-stop__remark {
    font-size: 0.88rem;
    color: #4a5865;
}

.dark .ds-stop__address,
.dark .ds-stop__remark {
    color: #b7c4cf;
}

.ds-stop__count {
    font-size: 0.82rem;
    font-weight: 700;
    color: #2f6f9f;
}

.ds-stop__call {
    width: 3rem;
    height: 3rem;
    flex: none;
    border-radius: 999px;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: #fff;
}

/* Areas */
.ds-driver__areas {
    background: #fff;
    border-radius: 1rem;
    overflow: hidden;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-driver__areas {
    background: rgb(255 255 255 / 0.04);
}

.ds-driver__area + .ds-driver__area {
    border-top: 1px solid #e8edf1;
}

.ds-driver__area-btn {
    width: 100%;
    min-height: 4rem;
    padding: 0.75rem 1rem;
    display: flex;
    align-items: center;
    gap: 0.75rem;
    text-align: left;
}

.ds-driver__area-name {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.1rem;
}

.ds-driver__area-name span,
.ds-driver__area-count span {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-driver__area-count {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
}

.ds-driver__area-count strong {
    font-size: 1.15rem;
    font-weight: 900;
}

.ds-driver__chev {
    color: var(--ds-steel);
    transition: transform 0.2s;
}

.ds-driver__chev.is-open {
    transform: rotate(180deg);
}

.ds-driver__stops {
    padding: 0 1rem 0.9rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

/* Delivered today */
.ds-driver__list {
    background: #fff;
    border-radius: 1rem;
    padding: 0.25rem 1rem;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-driver__list {
    background: rgb(255 255 255 / 0.04);
}

.ds-driver__done-row {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.75rem 0;
}

.ds-driver__done-row + .ds-driver__done-row {
    border-top: 1px solid #e8edf1;
}

.ds-driver__done-row img,
.ds-driver__nophoto {
    width: 3.25rem;
    height: 3.25rem;
    border-radius: 0.6rem;
    object-fit: cover;
    flex: none;
}

.ds-driver__nophoto {
    display: grid;
    place-items: center;
    background: #e4e9ed;
    color: var(--ds-steel);
}

.ds-driver__done-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
}

.ds-driver__done-text span,
.ds-driver__done-when span:last-child {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-driver__done-when {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
}

.ds-driver__ok {
    font-size: 0.82rem;
    font-weight: 700;
    color: var(--ds-ok);
}

/* Not on a trip */
.ds-driver__empty {
    border: 2px dashed #c9d3da;
    border-radius: 1.1rem;
    padding: 2.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.85rem;
}

.ds-driver__empty h2 {
    font-size: 1.35rem;
}

.ds-driver__empty p {
    max-width: 30ch;
    color: #4a5865;
}

.dark .ds-driver__empty p {
    color: #b7c4cf;
}

.ds-driver__empty-icon {
    width: 4.5rem;
    height: 4.5rem;
    border-radius: 1.25rem;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: var(--ds-signal);
}

@media (prefers-reduced-motion: reduce) {
    .ds-driver__chev {
        transition: none;
    }
}

/* Undo on "Delivered today" */
.ds-driver__done-when {
    gap: 0.3rem;
}

.ds-driver__undo {
    display: flex;
    align-items: center;
    gap: 0.4rem;
}

.ds-driver__undo > span {
    font-size: 0.75rem;
    color: var(--ds-steel);
}

.ds-driver__locked {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    font-size: 0.78rem;
    color: var(--ds-steel);
}

.ds-attempts__item--undo {
    border-left: 3px solid var(--ds-warn, #e08a00);
}

/* ------------------------------------------------------------------ trip board (Delivery Log widgets) */

.ds-board {
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-board__cards {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0.875rem;
}

@media (max-width: 1024px) {
    .ds-board__cards { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

.ds-board__card {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    padding: 1rem 1.1rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    color: var(--ds-navy);
    text-decoration: none;
    transition: box-shadow 0.15s;
}

.ds-board__card:hover { box-shadow: 0 0 0 1px rgb(14 36 51 / 0.2); }
.ds-board__card:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }
.ds-board__card.is-active { box-shadow: inset 0 0 0 2px var(--ds-navy); }

.ds-board__card-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 0.875rem;
    font-weight: 600;
    color: #4a5865;
}

.ds-board__card-value {
    font-size: 2.1rem;
    font-weight: 800;
    line-height: 1;
}

.ds-board__card-sub,
.ds-board__muted {
    font-size: 0.8rem;
    color: var(--ds-steel);
}

.ds-board__dot { width: 0.6rem; height: 0.6rem; border-radius: 999px; }
.ds-board__dot--navy { background: var(--ds-navy); }
.ds-board__dot--yellow { background: var(--ds-signal); }
.ds-board__dot--ok { background: var(--ds-ok); }
.ds-board__dot--bad { background: var(--ds-bad); }

.ds-board__bar {
    display: block;
    width: 100%;
    height: 0.4rem;
    border-radius: 999px;
    background: #e8edf1;
    overflow: hidden;
}

.ds-board__bar-fill { display: block; height: 100%; border-radius: 999px; background: var(--ds-navy); }
.ds-board__bar-fill--yellow { background: var(--ds-signal); }
.ds-board__bar-fill--ok { background: var(--ds-ok); }
.ds-board__bar-fill--warn { background: var(--ds-warn); }

.ds-board__panel {
    padding: 1.1rem 1.25rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

.ds-board__panel-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
}

.ds-board__panel-head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-board__panel-head span { font-size: 0.8rem; color: var(--ds-steel); }

.ds-board__attention li {
    display: grid;
    grid-template-columns: 9.5rem minmax(0, 1fr) auto auto;
    gap: 1rem;
    align-items: center;
    padding: 0.7rem 0;
}

.ds-board__attention li + li { border-top: 1px solid #eef1f4; }

.ds-board__attention-text { font-size: 0.9rem; color: var(--ds-navy); }
.ds-board__detail { display: block; font-size: 0.8rem; color: #4a5865; }
.ds-board__truck { white-space: nowrap; }

@media (max-width: 768px) {
    .ds-board__attention li { grid-template-columns: 1fr auto; }
    .ds-board__attention-text { grid-column: 1 / -1; }
    .ds-board__truck { display: none; }
}

.ds-board__tag {
    padding: 0.2rem 0.6rem;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 700;
    text-align: center;
    background: #eef1f4;
    color: #4a5865;
}

.ds-board__tag--bad { background: #fdecea; color: var(--ds-bad); }
.ds-board__tag--warn { background: #fff1dc; color: #9a5b00; }

.ds-board__trends {
    display: grid;
    grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr);
    gap: 0.875rem;
}

@media (max-width: 1024px) {
    .ds-board__trends { grid-template-columns: 1fr; }
}

.ds-board__chart {
    display: flex;
    align-items: flex-end;
    gap: 0.4rem;
    height: 11rem;
}

.ds-board__col {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-end;
    gap: 0.25rem;
    height: 100%;
}

.ds-board__col-n,
.ds-board__col-day { font-size: 0.7rem; color: var(--ds-steel); }

.ds-board__col-bar {
    width: 100%;
    max-width: 1.75rem;
    border-radius: 4px 4px 0 0;
    background: var(--ds-navy);
}

.ds-board__col-bar.is-today { background: var(--ds-signal); }
.ds-board__col-bar.is-zero { background: #d5dde3; }

.ds-board__reason { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-board__reason .ds-board__bar { height: 0.5rem; background: #eef1f4; }
.ds-board__reason-row { display: flex; justify-content: space-between; font-size: 0.875rem; color: var(--ds-navy); }

.dark .ds-board__card,
.dark .ds-board__panel { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); color: #e6edf3; }
.dark .ds-board__card.is-active { box-shadow: inset 0 0 0 2px var(--ds-signal); }
.dark .ds-board__card-head,
.dark .ds-board__detail { color: #b7c4cf; }
.dark .ds-board__panel-head h2,
.dark .ds-board__attention-text,
.dark .ds-board__reason-row { color: #e6edf3; }
.dark .ds-board__attention li + li { border-color: rgb(255 255 255 / 0.08); }
.dark .ds-board__col-bar { background: #7fa3bf; }
.dark .ds-board__col-bar.is-today { background: var(--ds-signal); }

/* ------------------------------------------------------------------ install as an app (PWA) */

.ds-pwa-install { display: none; }
html[data-pwa-installable] .ds-pwa-install { display: block; }

.ds-pwa-sheet:not([hidden]) {
    position: fixed;
    inset: 0;
    z-index: 60;
    display: flex;
    align-items: flex-end;
    justify-content: center;
}

.ds-pwa-sheet__backdrop { position: absolute; inset: 0; background: rgb(14 36 51 / 0.45); }

.ds-pwa-sheet__panel {
    position: relative;
    width: 100%;
    max-width: 30rem;
    padding: 1.4rem 1.4rem calc(1.9rem + env(safe-area-inset-bottom));
    border-radius: 1.4rem 1.4rem 0 0;
    background: #fff;
    color: var(--ds-navy);
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-pwa-sheet__grip { align-self: center; width: 2.5rem; height: 0.3rem; border-radius: 999px; background: #d5dde3; }
.ds-pwa-sheet__head { display: flex; gap: 0.9rem; align-items: center; }
.ds-pwa-sheet__head img { width: 3.5rem; height: 3.5rem; border-radius: 0.9rem; flex: none; }
.ds-pwa-sheet__head > span { display: flex; flex-direction: column; gap: 0.15rem; }
.ds-pwa-sheet__head strong { font-size: 1.1rem; }
.ds-pwa-sheet__head span span { font-size: 0.875rem; color: #4a5865; }

.ds-pwa-sheet__steps { display: flex; flex-direction: column; gap: 0.6rem; }

.ds-pwa-sheet__steps li {
    display: flex;
    gap: 0.75rem;
    align-items: center;
    padding: 0.75rem 0.9rem;
    border-radius: 0.75rem;
    background: var(--ds-deck);
    font-size: 0.95rem;
}

.ds-pwa-sheet__steps li > span:first-child {
    width: 1.75rem;
    height: 1.75rem;
    flex: none;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-weight: 800;
    display: flex;
    align-items: center;
    justify-content: center;
}

.ds-pwa-share { display: inline-block; padding: 0 0.35rem; border: 1.5px solid #0a84ff; border-radius: 0.35rem; color: #0a84ff; font-size: 0.8rem; }

.ds-pwa-sheet__close,
.ds-pwa-offline button {
    height: 3.1rem;
    border-radius: 0.75rem;
    font: inherit;
    font-weight: 700;
    font-size: 1rem;
    cursor: pointer;
}

.ds-pwa-sheet__close { border: 1.5px solid #d5dde3; background: #fff; color: var(--ds-navy); }

.ds-pwa-offline:not([hidden]) {
    position: fixed;
    inset: 0;
    z-index: 70;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1.75rem;
    background: var(--ds-deck);
    color: var(--ds-navy);
}

.ds-pwa-offline__body { width: 100%; max-width: 28rem; display: flex; flex-direction: column; gap: 1.1rem; }

.ds-pwa-offline__icon {
    width: 4.5rem;
    height: 4.5rem;
    border-radius: 1.4rem;
    background: #fff1dc;
    color: var(--ds-warn);
    display: flex;
    align-items: center;
    justify-content: center;
}

.ds-pwa-offline h2 { font-size: 1.75rem; font-weight: 800; line-height: 1.15; }
.ds-pwa-offline p { font-size: 1rem; line-height: 1.5; color: #4a5865; }

.ds-pwa-offline ul {
    padding: 0.9rem 1rem;
    border-radius: 0.9rem;
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    font-size: 0.95rem;
}

.ds-pwa-offline li { display: flex; gap: 0.6rem; }
.ds-pwa-offline .is-ok { color: var(--ds-ok); font-weight: 800; }
.ds-pwa-offline .is-warn { color: var(--ds-warn); font-weight: 800; }
.ds-pwa-offline button { border: 0; background: var(--ds-signal); color: var(--ds-navy); font-weight: 800; height: 3.5rem; }
.ds-pwa-offline button[disabled] { background: #d5dde3; color: #4a5865; }

.ds-pwa-sheet button:focus-visible,
.ds-pwa-offline button:focus-visible { outline: 3px solid var(--ds-navy); outline-offset: 3px; }

/* App icon & favicon page */
.ds-icons-preview {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 1.25rem 2rem;
    padding: 1rem 1.25rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.ds-icons-preview__tab {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    min-width: 12rem;
    padding: 0.5rem 0.9rem;
    border-radius: 0.6rem 0.6rem 0 0;
    background: var(--ds-deck);
    font-size: 0.85rem;
    color: var(--ds-navy);
}

.ds-icons-preview__phone {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.4rem;
    padding: 0.9rem 1.2rem;
    border-radius: 1rem;
    background: linear-gradient(160deg, #2b4d66, #0e2433);
    color: #fff;
    font-size: 0.75rem;
}

.ds-icons-preview__phone img { border-radius: 0.9rem; }

.ds-icons-preview p {
    flex: 1 1 18rem;
    font-size: 0.85rem;
    line-height: 1.5;
    color: var(--ds-steel);
}

.dark .ds-icons-preview { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-icons-preview__tab { background: #0e2433; color: #e6edf3; }
.dark .ds-icons-preview p { color: #b7c4cf; }

/* Scan progress: left, last scan, problems */
.ds-progress__meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem 1rem;
    margin-top: 0.6rem;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-progress__left { font-weight: 700; color: var(--ds-navy); }
.dark .ds-progress__left { color: var(--ds-signal); }
.ds-progress__problems { color: var(--ds-bad); font-weight: 600; }

/* Module boards (Containers, Vehicles, Invoice Issue) — extend the trip board styles */
.ds-board__card--static:hover { box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); }
.ds-board__card-value.is-alert { color: var(--ds-bad); }
.ds-board__dot--steel { background: var(--ds-steel); }
.ds-board__dot--warn { background: var(--ds-warn); }
.ds-board__bar-fill--teal { background: #3fa7b9; }
.ds-board__bar-fill--bad { background: var(--ds-bad); }
.ds-board__trends--even { grid-template-columns: repeat(2, minmax(0, 1fr)); }

@media (max-width: 1024px) {
    .ds-board__trends--even { grid-template-columns: 1fr; }
}

.ds-board__photos {
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: 0.75rem;
}

@media (max-width: 1024px) {
    .ds-board__photos { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

.ds-board__photos figure { position: relative; display: flex; flex-direction: column; gap: 0.4rem; margin: 0; }
.ds-board__photos img,
.ds-board__photo-none { width: 100%; height: 7rem; border-radius: 0.6rem; object-fit: cover; background: var(--ds-deck); }
.ds-board__photo-none { display: flex; align-items: center; justify-content: center; font-size: 0.8rem; color: var(--ds-steel); }
.ds-board__photos .ds-board__tag { position: absolute; left: 0.4rem; top: 0.4rem; }
.ds-board__photos figcaption { display: flex; flex-direction: column; font-size: 0.8rem; color: var(--ds-steel); }
.ds-board__photos figcaption strong { font-size: 0.9rem; color: var(--ds-navy); }
.dark .ds-board__photos figcaption strong { color: #e6edf3; }

/* Open issues slider (Invoice Issue widget) */
.ds-slider { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-slider__viewport { overflow: hidden; margin: 0 -0.4rem; }
.ds-slider__track { display: flex; transition: transform 0.5s ease; }
.ds-slider__slide { flex: 0 0 25%; margin: 0; padding: 0 0.4rem; box-sizing: border-box; }

.ds-slider__card {
    height: 100%;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    padding: 0.6rem;
    border-radius: 0.8rem;
    background: var(--ds-deck);
}

.ds-slider__photo { position: relative; }
.ds-slider__photo img,
.ds-slider__photo .ds-board__photo-none { width: 100%; height: 8.5rem; border-radius: 0.6rem; object-fit: cover; background: #e3e8ec; display: flex; }
.ds-slider__photo .ds-board__tag { position: absolute; left: 0.4rem; top: 0.4rem; }
.ds-slider__card figcaption { display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.8rem; color: var(--ds-steel); flex: 1; }
.ds-slider__card figcaption strong { font-size: 0.95rem; color: var(--ds-navy); }
.ds-slider__note { color: #4a5865; line-height: 1.35; }

.ds-slider__controls { display: flex; align-items: center; justify-content: center; gap: 0.75rem; }

.ds-slider__arrow {
    width: 2.25rem;
    height: 2.25rem;
    border-radius: 999px;
    border: 1.5px solid #d5dde3;
    background: #fff;
    color: var(--ds-navy);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
}

.ds-slider__dots { display: flex; gap: 0.4rem; }
.ds-slider__dot { width: 0.55rem; height: 0.55rem; border-radius: 999px; border: 0; padding: 0; background: #d5dde3; cursor: pointer; }
.ds-slider__dot.is-active { width: 1.4rem; background: var(--ds-navy); }
.ds-slider__arrow:focus-visible,
.ds-slider__dot:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }

.ds-slider__empty { display: flex; align-items: center; gap: 0.5rem; font-size: 0.9rem; color: var(--ds-ok); }

@media (prefers-reduced-motion: reduce) {
    .ds-slider__track { transition: none; }
}

.dark .ds-slider__card { background: #0e2433; }
.dark .ds-slider__card figcaption strong { color: #e6edf3; }
.dark .ds-slider__note { color: #b7c4cf; }
.dark .ds-slider__arrow { background: #10283a; border-color: rgb(255 255 255 / 0.15); color: #e6edf3; }
.dark .ds-slider__dot.is-active { background: var(--ds-signal); }
.ds-slider__counter { min-width: 4.5rem; text-align: center; font-size: 0.85rem; font-weight: 700; color: var(--ds-navy); font-variant-numeric: tabular-nums; }
.dark .ds-slider__counter { color: #e6edf3; }

/* Boxes by hub (Admin dashboard) */
.ds-board__dot--teal { background: #3fa7b9; }
.ds-hubs__head { display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; flex-wrap: wrap; }
.ds-hubs__head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-hubs__legend { display: flex; flex-wrap: wrap; gap: 0.35rem 1rem; margin-top: 0.35rem; font-size: 0.8rem; color: #4a5865; }
.ds-hubs__legend span { display: inline-flex; align-items: center; gap: 0.35rem; }
.ds-hubs__legend i { width: 0.75rem; height: 0.75rem; border-radius: 3px; }
.ds-hubs .is-wait { background: #3fa7b9; }
.ds-hubs .is-load { background: var(--ds-signal); }
.ds-hubs .is-out { background: var(--ds-navy); }
.ds-hubs .is-done { background: var(--ds-ok); }
.ds-hubs__sort { display: flex; gap: 0.35rem; }
.ds-hubs__sort button { height: 2rem; padding: 0 0.75rem; border-radius: 0.5rem; border: 0; background: #eef1f4; color: #4a5865; font-size: 0.8rem; font-weight: 700; cursor: pointer; }
.ds-hubs__sort button.is-active { background: var(--ds-navy); color: #fff; }
.ds-hubs__sort button:focus-visible, .ds-hubs__row:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }

.ds-hubs__table { display: flex; flex-direction: column; overflow-x: auto; }
.ds-hubs__row {
    display: grid;
    grid-template-columns: 13rem minmax(8rem, 1fr) 5rem 5rem 5.5rem 5.5rem 6.5rem 5rem;
    align-items: center;
    min-width: 54rem;
    padding: 0.7rem 0.25rem;
    border-top: 1px solid #f0f3f5;
    font-size: 0.9rem;
    color: var(--ds-navy);
    text-decoration: none;
    font-variant-numeric: tabular-nums;
}
.ds-hubs__row > span:nth-child(n + 3) { text-align: right; }
a.ds-hubs__row:hover { background: #f8fafb; }
.ds-hubs__row--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }
.ds-hubs__row--total { font-weight: 800; background: #f8fafb; border-top: 1px solid #e8edf1; }
.ds-hubs__name { display: flex; flex-direction: column; }
.ds-hubs__name small { font-size: 0.75rem; color: var(--ds-steel); }
.ds-hubs__bar { display: flex; align-items: center; gap: 0.6rem; padding-right: 1rem; }
.ds-hubs__bar b { min-width: 2.5rem; text-align: right; font-size: 0.85rem; }
.ds-hubs__track { flex: 1; display: flex; height: 0.85rem; border-radius: 4px; overflow: hidden; background: var(--ds-deck); }
.ds-hubs__track span { display: block; height: 100%; }
.ds-hubs .is-good { color: var(--ds-ok); font-weight: 700; background: none; }
.ds-hubs .is-muted { color: #4a5865; }
.ds-hubs .is-bad { color: var(--ds-bad); font-weight: 700; }

.dark .ds-hubs__row { color: #e6edf3; border-color: rgb(255 255 255 / 0.08); }
.dark a.ds-hubs__row:hover, .dark .ds-hubs__row--total { background: #0e2433; }
.dark .ds-hubs__head h2 { color: #e6edf3; }
.dark .ds-hubs .is-out { background: #7fa3bf; }
.dark .ds-hubs__track { background: #0e2433; }
.dark .ds-hubs__sort button { background: #0e2433; color: #b7c4cf; }
.dark .ds-hubs__sort button.is-active { background: var(--ds-signal); color: var(--ds-navy); }
.dark .ds-hubs .is-muted { color: #b7c4cf; }

/* Partner hub: your boxes as steps */
.ds-hubsteps { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-hubsteps h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-hubsteps__row { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.75rem; counter-reset: step; }
@media (max-width: 900px) { .ds-hubsteps__row { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
.ds-hubsteps__step {
    display: flex; flex-direction: column; gap: 0.35rem;
    padding: 1rem 1.1rem; border-radius: var(--ds-radius-lg); background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); border-top: 4px solid var(--ds-navy);
}
.ds-hubsteps__step.is-wait { border-top-color: #3fa7b9; }
.ds-hubsteps__step.is-load { border-top-color: var(--ds-signal); }
.ds-hubsteps__step.is-done { border-top-color: var(--ds-ok); }
.ds-hubsteps__label { font-size: 0.85rem; font-weight: 600; color: #4a5865; }
.ds-hubsteps__value { font-size: 2rem; font-weight: 800; line-height: 1; color: var(--ds-navy); font-variant-numeric: tabular-nums; }
.ds-hubsteps__sub, .ds-hubsteps__note { font-size: 0.8rem; color: var(--ds-steel); }
.ds-hubsteps__alert {
    display: flex; align-items: center; gap: 1rem; padding: 1rem 1.1rem;
    border-radius: var(--ds-radius-lg); background: #fff8db; box-shadow: 0 0 0 1px #f3d77a; color: var(--ds-navy);
}
.ds-hubsteps__alert > span { flex: 1; display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.9rem; }
.ds-hubsteps__alert > span > span { color: #4a5865; }
@media (max-width: 640px) { .ds-hubsteps__alert { flex-wrap: wrap; } }
.dark .ds-hubsteps h2, .dark .ds-hubsteps__value { color: #e6edf3; }
.dark .ds-hubsteps__step { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-hubsteps__label { color: #b7c4cf; }
.dark .ds-hubsteps__alert { background: rgb(120 90 0 / 0.25); box-shadow: 0 0 0 1px rgb(243 215 122 / 0.4); color: #e6edf3; }
.dark .ds-hubsteps__alert > span > span { color: #d8c690; }

/* ------------------------------------------------------------------ partner hub (Company) panel */
.ds-co { display: flex; flex-direction: column; gap: 1rem; }
.ds-co__h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); margin-bottom: 1rem; }
.ds-co__link { font-size: 0.85rem; font-weight: 700; color: #2f6f9f; white-space: nowrap; }
.ds-co__num { font-variant-numeric: tabular-nums; }

.ds-co__tabs { display: flex; gap: 0.35rem; }
.ds-co__tabs button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.5rem; border: 0; background: #eef1f4; color: #4a5865; font-size: 0.85rem; font-weight: 700; cursor: pointer; }
.ds-co__tabs button.is-active { background: var(--ds-navy); color: #fff; }

.ds-co__empty { display: flex; flex-direction: column; align-items: center; gap: 0.35rem; padding: 2.5rem 1rem; border-radius: var(--ds-radius-lg); background: #fff; color: var(--ds-steel); text-align: center; box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); }
.ds-co__empty strong { color: var(--ds-navy); font-size: 1rem; }

/* incoming boxes */
.ds-co__areas { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-co__area {
    display: grid; grid-template-columns: 1.4rem minmax(0, 1fr) minmax(6rem, 12rem) 4rem 8.5rem; gap: 1rem; align-items: center;
    width: 100%; padding: 0.8rem 1rem; border: 0; border-radius: 0.8rem; background: #fff; color: var(--ds-navy); text-align: left; cursor: pointer;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}
.ds-co__area.is-on { background: #fff8db; box-shadow: inset 0 0 0 2px var(--ds-signal); }
.ds-co__area:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }
.ds-co__check { width: 1.4rem; height: 1.4rem; border-radius: 0.4rem; display: flex; align-items: center; justify-content: center; font-weight: 900; color: transparent; box-shadow: inset 0 0 0 2px #b7c4cf; }
.ds-co__area.is-on .ds-co__check { background: var(--ds-navy); color: var(--ds-signal); box-shadow: none; }
.ds-co__area-name { display: flex; flex-direction: column; min-width: 0; }
.ds-co__area-name small { font-size: 0.75rem; color: var(--ds-steel); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-co__age { justify-self: end; padding: 0.2rem 0.6rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; white-space: nowrap; }
.ds-co__age.is-ok { background: #e3f5ed; color: var(--ds-ok); }
.ds-co__age.is-warn { background: #fff1dc; color: #9a5b00; }
.ds-co__age.is-bad { background: #fdecea; color: var(--ds-bad); }
@media (max-width: 768px) { .ds-co__area { grid-template-columns: 1.4rem 1fr 3rem; } .ds-co__area .ds-board__bar, .ds-co__area .ds-co__age { display: none; } }

.ds-co__oldest { display: grid; grid-template-columns: 8rem 1fr 1.2fr 7rem 6rem; gap: 0.75rem; align-items: center; padding: 0.6rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__oldest--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }

.ds-co__tripbar {
    position: sticky; bottom: 0.75rem; z-index: 5; display: flex; align-items: center; gap: 0.75rem;
    padding: 0.9rem 1.1rem; border-radius: var(--ds-radius-lg); background: var(--ds-navy); color: #fff;
}
.ds-co__tripbar > span { flex: 1; display: flex; flex-direction: column; }
.ds-co__tripbar strong { font-size: 1.05rem; }
.ds-co__tripbar small { color: #b7c4cf; font-size: 0.8rem; }

/* drivers */
.ds-co__driver { display: grid; grid-template-columns: 2rem 2.5rem minmax(0, 1fr) 5.5rem 9rem 6.5rem minmax(0, 1fr); gap: 0.85rem; align-items: center; padding: 0.7rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__driver--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }
.ds-co__rank { font-weight: 800; color: #8a97a2; text-align: center; }
.ds-co__avatar { width: 2.5rem; height: 2.5rem; border-radius: 999px; background: #24465f; color: #fff; display: flex; align-items: center; justify-content: center; font-weight: 800; font-size: 0.85rem; text-transform: uppercase; }
.ds-co__rate { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-co__rate b.is-ok { color: var(--ds-ok); }
.ds-co__rate b.is-warn { color: var(--ds-warn); }
@media (max-width: 900px) { .ds-co__driver { grid-template-columns: 2rem 2.5rem 1fr 4rem; } .ds-co__driver > :nth-child(n + 5) { display: none; } }

/* not delivered */
.ds-co__group { border-left: 4px solid var(--ds-warn); }
.ds-co__group.is-danger { border-left-color: var(--ds-bad); }
.ds-co__group.is-info, .ds-co__group.is-gray { border-left-color: #3fa7b9; }
.ds-co__group-head { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-co__group-head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-co__group-head h2 span { font-weight: 600; font-size: 0.9rem; color: var(--ds-steel); }
.ds-co__tip { flex: 1; font-size: 0.85rem; color: #4a5865; }
.ds-co__retry { display: grid; grid-template-columns: 7.5rem minmax(0, 1fr) minmax(0, 1fr) 4.5rem 7.5rem auto; gap: 0.75rem; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__tries { font-size: 0.75rem; font-weight: 700; color: var(--ds-steel); }
.ds-co__tries.is-bad { color: var(--ds-bad); }
.ds-co__retry-actions { display: flex; gap: 0.4rem; justify-content: flex-end; }
@media (max-width: 900px) { .ds-co__retry { grid-template-columns: 1fr auto; } .ds-co__retry > :nth-child(n + 2):not(.ds-co__retry-actions) { display: none; } }

/* track a box */
.ds-co__search { display: flex; align-items: center; gap: 0.6rem; padding: 0.4rem 0.4rem 0.4rem 0.9rem; border-radius: 0.8rem; background: #fff; box-shadow: 0 0 0 2px var(--ds-signal); color: var(--ds-steel); }
.ds-co__search input { flex: 1; min-width: 0; border: 0; background: transparent; font-size: 1.05rem; font-weight: 600; color: var(--ds-navy); outline: none; box-shadow: none; }
.ds-co__search--small { box-shadow: 0 0 0 1px #d5dde3; padding: 0.15rem 0.75rem; width: 15rem; }
.ds-co__search--small input { font-size: 0.9rem; font-weight: 500; padding: 0.45rem 0; }
.ds-co__track { display: grid; grid-template-columns: minmax(0, 1fr) 20rem; gap: 1rem; align-items: start; }
@media (max-width: 1024px) { .ds-co__track { grid-template-columns: 1fr; } }
.ds-co__timeline { display: flex; flex-direction: column; }
.ds-co__timeline li { position: relative; display: grid; grid-template-columns: 1.6rem minmax(0, 1fr) auto; gap: 0.75rem; padding-bottom: 1.1rem; }
.ds-co__timeline li:not(:last-child)::before { content: ''; position: absolute; left: 0.5rem; top: 1.2rem; bottom: 0; width: 2px; background: #e3e8ec; }
.ds-co__dot { width: 1.1rem; height: 1.1rem; margin-top: 0.15rem; border-radius: 999px; background: #fff; box-shadow: inset 0 0 0 3px #b7c4cf; z-index: 1; }
.ds-co__timeline li.is-ok .ds-co__dot { background: var(--ds-ok); box-shadow: none; }
.ds-co__timeline li.is-warn .ds-co__dot { background: var(--ds-warn); box-shadow: none; }
.ds-co__event { display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.9rem; color: var(--ds-navy); }
.ds-co__event > span { color: #4a5865; font-size: 0.85rem; }
.ds-co__event img { margin-top: 0.4rem; width: 10rem; height: 6.5rem; object-fit: cover; border-radius: 0.6rem; }
.ds-co__timeline time { font-size: 0.8rem; white-space: nowrap; }
.ds-co__boxcard { gap: 0.4rem; }
.ds-co__boxno { font-size: 1.3rem; color: var(--ds-navy); }
.ds-co__boxcard dl { display: grid; gap: 0.2rem; margin-top: 0.5rem; padding-top: 0.75rem; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__boxcard dt { color: var(--ds-steel); font-size: 0.8rem; margin-top: 0.4rem; }
.ds-co__boxcard dd { color: var(--ds-navy); }
.ds-co__boxcard dd a { font-weight: 700; color: #2f6f9f; margin-left: 0.4rem; }
.ds-co__status { align-self: flex-start; padding: 0.2rem 0.7rem; border-radius: 999px; font-size: 0.8rem; font-weight: 800; background: #e6edf3; color: var(--ds-navy); white-space: nowrap; }
.ds-co__status.is-ok, .ds-co__status.is-done { background: #e3f5ed; color: var(--ds-ok); }
.ds-co__status.is-loading { background: #fff6d6; color: #8a6a00; }

/* dashboard */
.ds-co__hello { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; margin-bottom: 0.5rem; }
.ds-co__hello > div { flex: 1; min-width: 14rem; }
.ds-co__hello-title { font-size: 1.6rem; font-weight: 800; color: var(--ds-navy); line-height: 1.2; }
.ds-co__today { display: grid; grid-template-columns: minmax(0, 1.5fr) minmax(0, 1fr); gap: 0.875rem; align-items: start; }
.ds-co__today--even { grid-template-columns: repeat(2, minmax(0, 1fr)); }
@media (max-width: 1024px) { .ds-co__today, .ds-co__today--even { grid-template-columns: 1fr; } }
.ds-co__trip { display: grid; grid-template-columns: 2.5rem minmax(0, 1fr) 10rem 6.5rem; gap: 0.85rem; align-items: center; padding: 0.65rem 0; border-top: 1px solid #eef1f4; }
.ds-co__trip .ds-co__status { justify-self: end; }
@media (max-width: 640px) { .ds-co__trip { grid-template-columns: 2.5rem 1fr; } .ds-co__trip > :nth-child(n + 3) { grid-column: 2; justify-self: start; } }
.ds-co__attn { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 0.75rem; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; font-size: 0.85rem; }

.dark .ds-co__area, .dark .ds-co__empty { background: #10283a; color: #e6edf3; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-co__area.is-on { background: rgb(246 190 0 / 0.12); }
.dark .ds-co__hello-title, .dark .ds-co__h2, .dark .ds-co__group-head h2, .dark .ds-co__event, .dark .ds-co__boxno, .dark .ds-co__boxcard dd, .dark .ds-co__empty strong { color: #e6edf3; }
.dark .ds-co__search { background: #10283a; }
.dark .ds-co__search input { color: #e6edf3; }
.dark .ds-co__tabs button { background: #0e2433; color: #b7c4cf; }
.dark .ds-co__tabs button.is-active { background: var(--ds-signal); color: var(--ds-navy); }
.dark .ds-co__driver, .dark .ds-co__retry, .dark .ds-co__trip, .dark .ds-co__attn, .dark .ds-co__oldest { border-color: rgb(255 255 255 / 0.08); }
.ds-co__clear { height: 2.25rem; padding: 0 0.9rem; border-radius: 0.5rem; border: 1.5px solid rgb(255 255 255 / 0.35); background: transparent; color: #fff; font-weight: 700; font-size: 0.85rem; cursor: pointer; }
.ds-co__clear:hover { background: rgb(255 255 255 / 0.1); }

/* ------------------------------------------------------------------ box photos */
.ds-ph { display: flex; flex-direction: column; gap: 0.7rem; margin-top: 0.9rem; padding: 0.9rem 1rem; border-radius: var(--ds-radius); background: #fff; box-shadow: 0 0 0 1px rgb(14 36 51 / 0.08); }
.ds-ph__cond > span { display: block; font-size: 0.8rem; font-weight: 700; color: var(--ds-navy); margin-bottom: 0.4rem; }
.ds-ph__cond > div { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.4rem; }
.ds-ph__chip { min-height: 2.5rem; border-radius: 0.6rem; font-size: 0.85rem; font-weight: 700; background: #e3f5ed; color: #17895e; }
.ds-ph__chip.is-damaged { background: #fdecea; color: #cf3b3b; }
.ds-ph__chip.is-wet { background: #e3f0fb; color: #1f6fb2; }
.ds-ph__chip.is-open { background: #fff1dc; color: #9a5b00; }
.ds-ph__chip.is-on { color: #fff; background: #17895e; }
.ds-ph__chip.is-damaged.is-on { background: #cf3b3b; }
.ds-ph__chip.is-wet.is-on { background: #1f6fb2; }
.ds-ph__chip.is-open.is-on { background: #9a5b00; }
.ds-ph__tip { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fff8db; color: #6b4a00; font-size: 0.82rem; }
.ds-ph__note { width: 100%; border: 1px solid #d5dce2; border-radius: 0.6rem; padding: 0.5rem 0.7rem; font-size: 0.875rem; background: #fff; color: var(--ds-navy); }
.ds-ph__shots { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem; }
.ds-ph__shots img { width: 3.5rem; height: 3.5rem; object-fit: cover; border-radius: 0.5rem; }
.ds-ph__shots span { font-size: 0.78rem; color: var(--ds-steel); margin-left: 0.25rem; }
.ds-ph__add { display: flex; align-items: center; justify-content: center; gap: 0.5rem; min-height: 2.9rem; border-radius: 0.7rem; background: var(--ds-navy); color: #fff; font-weight: 700; }
.ds-ph__add:disabled { opacity: 0.7; }
.ds-ph__batch { display: flex; align-items: center; gap: 0.5rem; padding: 0.6rem 0.75rem; border-radius: 0.6rem; background: var(--ds-navy); color: #fff; font-size: 0.82rem; }
.ds-ph__batch span { flex: 1; }
.ds-ph__batch button { padding: 0.4rem 0.8rem; border-radius: 0.5rem; background: var(--ds-signal); color: var(--ds-navy); font-weight: 800; }
.ds-ph__batch button.is-skip { background: #24465f; color: #fff; }
.ds-ph__err { margin: 0; color: var(--ds-bad); font-size: 0.82rem; }
.ds-gm__status.is-good { color: var(--ds-ok); }
.ds-gm__status.is-damaged { color: var(--ds-bad); }
.ds-gm__status.is-wet { color: #1f6fb2; }
.ds-gm__status.is-open { color: var(--ds-warn); }
.ds-phs { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-phs__big { width: 100%; max-height: 26rem; object-fit: contain; border-radius: var(--ds-radius); background: #000; }
.ds-phs__thumbs { display: flex; flex-wrap: wrap; gap: 0.5rem; }
.ds-phs__thumbs button { width: 6rem; border-radius: 0.5rem; overflow: hidden; opacity: 0.7; text-align: left; font-size: 0.7rem; background: var(--ds-deck); }
.ds-phs__thumbs button.is-on { opacity: 1; box-shadow: 0 0 0 3px var(--ds-signal); }
.ds-phs__thumbs img { width: 100%; height: 4.2rem; object-fit: cover; }
.ds-phs__thumbs span { display: block; padding: 0.15rem 0.35rem; color: var(--ds-navy); }
.ds-ps__row { display: grid; grid-template-columns: auto 1fr auto; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; }
/* layout helpers used by the photo pages */
.ds-tp { display: flex; flex-direction: column; gap: 1rem; }
.ds-tp__recent { display: flex; flex-direction: column; margin: 0; padding: 0; list-style: none; }
.ds-tp__recent li { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); gap: 0.75rem; padding: 0.45rem 0; border-top: 1px solid #eef1f4; font-size: 0.85rem; }
.ds-gm input[type=number] { border: 1px solid #d5dce2; border-radius: 0.5rem; padding: 0.4rem 0.6rem; background: #fff; color: var(--ds-navy); font-size: 0.875rem; }
.ds-gm__field { display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.8rem; color: var(--ds-steel); }
.ds-gm__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr)); gap: 0.9rem; }
.ds-gm__check { display: flex; align-items: center; gap: 0.6rem; font-size: 0.875rem; }
.ds-gm__save { display: flex; justify-content: flex-end; }
.ds-gm__status { font-size: 0.78rem; font-weight: 600; color: var(--ds-steel); }

/* ------------------------------------------------------------------ Box Photos (v2) */
.ds-bp {
    --bp-bg: #f3f5f7; --bp-surf: #ffffff; --bp-raised: #f6f8fa; --bp-line: rgb(14 36 51 / 0.09);
    --bp-text: #0e2433; --bp-muted: #5b6b78; --bp-pill-on: #0e2433; --bp-pill-on-text: #ffffff;
    --bp-ok: #17895e; --bp-bad: #d64236; --bp-wet: #2f7fc4; --bp-warn: #b97412; --bp-gold: #f6be00;
    --bp-shadow: 0 18px 40px rgb(14 36 51 / 0.08);
    display: flex; flex-direction: column; gap: 1.1rem; color: var(--bp-text); padding-bottom: 6rem;
}
.dark .ds-bp {
    --bp-surf: #122230; --bp-raised: #172b3a; --bp-line: rgb(255 255 255 / 0.08);
    --bp-text: #e9eff3; --bp-muted: #8ea2b0; --bp-pill-on: #e9eff3; --bp-pill-on-text: #0b1620;
    --bp-ok: #2fb37f; --bp-bad: #ef5a4f; --bp-wet: #4f9be0; --bp-warn: #e8a33a; --bp-shadow: 0 18px 40px rgb(0 0 0 / 0.35);
}
.ds-bp__head { display: flex; align-items: flex-end; justify-content: space-between; gap: 1.25rem; flex-wrap: wrap; }
.ds-bp__head h1 { margin: 0; font-size: 2.1rem; font-weight: 900; letter-spacing: -0.02em; line-height: 1.1; }
.ds-bp__head p { margin: 0.35rem 0 0; color: var(--bp-muted); }
.ds-bp__stats { display: flex; gap: 0.5rem; }
.ds-bp__stats span { display: flex; flex-direction: column; align-items: flex-end; padding: 0.5rem 0.9rem; border-radius: 0.9rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__stats strong { font-size: 1.25rem; font-variant-numeric: tabular-nums; line-height: 1.1; }
.ds-bp__stats small { font-size: 0.72rem; color: var(--bp-muted); }
.ds-bp__stats .is-bad strong { color: var(--bp-bad); }
.ds-bp__stats .is-wet strong { color: var(--bp-wet); }
.ds-bp__search { display: flex; align-items: center; gap: 0.85rem; height: 3.9rem; padding: 0 1.2rem; border-radius: 1.1rem; background: var(--bp-surf); color: var(--bp-muted);
    box-shadow: inset 0 0 0 1px var(--bp-line), 0 0 0 4px rgb(246 190 0 / 0.12); }
.ds-bp__search:focus-within { box-shadow: inset 0 0 0 2px var(--bp-gold), 0 0 0 5px rgb(246 190 0 / 0.18); }
.ds-bp__search input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--bp-text); font-size: 1.15rem; font-weight: 700; letter-spacing: 0.01em; }
.ds-bp__search input::placeholder { color: var(--bp-muted); font-weight: 500; }
.ds-bp__search input::-webkit-search-cancel-button { display: none; }
.ds-bp__clear { width: 1.9rem; height: 1.9rem; border-radius: 50%; background: var(--bp-raised); color: var(--bp-muted); font-size: 0.75rem; }
.ds-bp__hint { font-size: 0.75rem; padding: 0.3rem 0.6rem; border-radius: 0.5rem; background: var(--bp-raised); white-space: nowrap; }
.ds-bp__empty { display: flex; flex-direction: column; align-items: center; gap: 0.6rem; padding: 4.5rem 1.25rem; border-radius: 1.5rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); text-align: center; }
.ds-bp__empty.is-small { padding: 2.5rem 1.25rem; }
.ds-bp__empty-icon { display: grid; place-items: center; width: 4rem; height: 4rem; border-radius: 1.25rem; background: var(--bp-raised); color: var(--bp-gold); margin-bottom: 0.4rem; }
.ds-bp__empty h2 { margin: 0; font-size: 1.35rem; font-weight: 800; letter-spacing: -0.01em; }
.ds-bp__empty p { margin: 0; max-width: 30rem; color: var(--bp-muted); line-height: 1.5; }
.ds-bp__recent { display: flex; flex-wrap: wrap; justify-content: center; align-items: center; gap: 0.45rem; margin-top: 0.5rem; }
.ds-bp__recent span { font-size: 0.8rem; color: var(--bp-muted); }
.ds-bp__recent button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.65rem; background: var(--bp-raised); box-shadow: inset 0 0 0 1px var(--bp-line); font-weight: 700; font-size: 0.85rem; color: var(--bp-text); }
.ds-bp__pills { display: flex; flex-wrap: wrap; align-items: center; gap: 0.45rem; }
.ds-bp__pills button { display: inline-flex; align-items: center; gap: 0.4rem; height: 2.2rem; padding: 0 0.9rem; border-radius: 999px; font-size: 0.82rem; font-weight: 700;
    background: var(--bp-surf); color: var(--bp-text); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__pills button.is-on { background: var(--bp-pill-on); color: var(--bp-pill-on-text); box-shadow: none; }
.ds-bp__sep { width: 1px; height: 1.4rem; margin: 0 0.3rem; background: var(--bp-line); }
.ds-bp__dot { display: inline-block; width: 0.55rem; height: 0.55rem; border-radius: 50%; background: var(--bp-muted); flex: none; }
.ds-bp__dot.is-ok { background: var(--bp-ok); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-ok) 22%, transparent); }
.ds-bp__dot.is-bad { background: var(--bp-bad); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-bad) 22%, transparent); }
.ds-bp__dot.is-wet { background: var(--bp-wet); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-wet) 22%, transparent); }
.ds-bp__dot.is-warn { background: var(--bp-warn); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-warn) 22%, transparent); }
.ds-bp__count { margin: 0; font-size: 0.82rem; color: var(--bp-muted); }
.ds-bp__layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(20rem, 29rem); gap: 1.25rem; align-items: start; }
.ds-bp__list { display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-bp__box { display: flex; flex-direction: column; gap: 0.9rem; padding: 1.1rem 1.25rem; border-radius: 1.15rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); transition: box-shadow 0.15s; }
.ds-bp__box.is-open { box-shadow: 0 0 0 2px var(--bp-gold), var(--bp-shadow); }
.ds-bp__boxhead { display: grid; grid-template-columns: auto auto auto 1fr; align-items: center; gap: 0.3rem 0.6rem; text-align: left; color: inherit; }
.ds-bp__inv { font-size: 1.3rem; font-weight: 800; letter-spacing: -0.01em; font-variant-numeric: tabular-nums; }
.ds-bp__n { justify-self: end; grid-column: 4; font-size: 0.78rem; color: var(--bp-muted); }
.ds-bp__who { grid-column: 1 / -1; font-size: 0.82rem; color: var(--bp-muted); }
.ds-bp__chip { display: inline-flex; align-items: center; padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.72rem; font-weight: 800; color: var(--bp-muted); background: var(--bp-raised); }
.ds-bp__chip.is-ok { color: var(--bp-ok); background: color-mix(in srgb, var(--bp-ok) 14%, transparent); }
.ds-bp__chip.is-bad { color: var(--bp-bad); background: color-mix(in srgb, var(--bp-bad) 14%, transparent); }
.ds-bp__chip.is-wet { color: var(--bp-wet); background: color-mix(in srgb, var(--bp-wet) 14%, transparent); }
.ds-bp__chip.is-warn { color: var(--bp-warn); background: color-mix(in srgb, var(--bp-warn) 14%, transparent); }
.ds-bp__journey { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem 0; margin: 0; padding: 0; list-style: none; }
.ds-bp__journey li { display: inline-flex; align-items: center; gap: 0.45rem; font-size: 0.76rem; font-weight: 600; color: var(--bp-muted); }
.ds-bp__journey li + li::before { content: ''; width: 1.4rem; height: 2px; margin: 0 0.45rem; background: var(--bp-line); border-radius: 2px; }
.ds-bp__thumbs { display: flex; flex-wrap: wrap; gap: 0.6rem; }
.ds-bp__thumb { position: relative; display: flex; flex-direction: column; gap: 0.3rem; width: 6.5rem; }
.ds-bp__img { position: relative; display: block; width: 6.5rem; height: 4.8rem; border-radius: 0.75rem; overflow: hidden; background: var(--bp-raised); }
.ds-bp__img img { width: 100%; height: 100%; object-fit: cover; }
.ds-bp__img .ds-bp__dot { position: absolute; left: 0.45rem; bottom: 0.45rem; }
.ds-bp__thumb.is-cur .ds-bp__img { outline: 2px solid var(--bp-gold); outline-offset: 2px; }
.ds-bp__thumb small { font-size: 0.68rem; color: var(--bp-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-bp__tick { position: absolute; right: 0.35rem; top: 0.35rem; display: grid; place-items: center; width: 1.4rem; height: 1.4rem; border-radius: 0.45rem; font-size: 0.75rem; font-weight: 900;
    background: rgb(11 22 32 / 0.5); color: transparent; box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / 0.85); }
.ds-bp__thumb.is-sel .ds-bp__tick { background: var(--bp-gold); color: #0e2433; box-shadow: none; }
.ds-bp__card { display: flex; flex-direction: column; gap: 0.75rem; padding: 0.85rem 0.95rem; border-radius: 0.95rem; }
.ds-bp__card.is-ok { --c: var(--bp-ok); }
.ds-bp__card.is-warn { --c: var(--bp-warn); }
.ds-bp__card { background: color-mix(in srgb, var(--c) 9%, transparent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--c) 35%, transparent); }
.ds-bp__cardhead { display: flex; align-items: center; gap: 0.7rem; }
.ds-bp__cardhead > span:nth-child(2) { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.ds-bp__cardhead strong { color: var(--c); font-size: 0.92rem; }
.ds-bp__cardhead small { font-size: 0.75rem; color: var(--bp-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-bp__cardhead em { font-style: normal; font-size: 0.75rem; color: var(--bp-muted); }
.ds-bp__badge { display: grid; place-items: center; width: 2rem; height: 2rem; border-radius: 0.65rem; background: var(--c); color: #0b1620; font-weight: 900; flex: none; }
.ds-bp__cardnote { margin: 0; font-size: 0.8rem; color: var(--bp-muted); font-style: italic; }
.ds-bp__viewer { position: sticky; top: 5rem; display: flex; flex-direction: column; gap: 0.85rem; padding: 0.9rem; border-radius: 1.35rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__big { position: relative; aspect-ratio: 4 / 3; border-radius: 0.9rem; overflow: hidden; background: #000; }
.ds-bp__big img { width: 100%; height: 100%; object-fit: contain; }
.ds-bp__pos { position: absolute; right: 0.6rem; top: 0.6rem; padding: 0.2rem 0.55rem; border-radius: 999px; background: rgb(14 36 51 / 0.72); color: #fff; font-size: 0.75rem; font-variant-numeric: tabular-nums; }
.ds-bp__nav { position: absolute; top: 50%; transform: translateY(-50%); width: 2.2rem; height: 2.2rem; border-radius: 50%; background: rgb(14 36 51 / 0.6); color: #fff; font-size: 1.3rem; line-height: 1; }
.ds-bp__nav.is-prev { left: 0.6rem; }
.ds-bp__nav.is-next { right: 0.6rem; }
.ds-bp__strip { display: flex; gap: 0.45rem; overflow-x: auto; }
.ds-bp__strip button { flex: none; width: 4.4rem; height: 3.3rem; border-radius: 0.6rem; overflow: hidden; opacity: 0.55; }
.ds-bp__strip button.is-on { opacity: 1; outline: 2px solid var(--bp-gold); outline-offset: 2px; }
.ds-bp__strip img { width: 100%; height: 100%; object-fit: cover; }
.ds-bp__vhead { display: flex; align-items: flex-start; justify-content: space-between; gap: 0.75rem; }
.ds-bp__vhead > span:first-child { display: flex; flex-direction: column; gap: 0.15rem; min-width: 0; }
.ds-bp__vhead strong { font-size: 1.05rem; }
.ds-bp__vhead small { font-size: 0.8rem; color: var(--bp-muted); }
.ds-bp__quote { margin: 0; padding: 0.6rem 0.85rem; border-radius: 0.7rem; background: var(--bp-raised); font-style: italic; font-size: 0.88rem; border-left: 3px solid var(--bp-gold); }
.ds-bp__meta { display: grid; grid-template-columns: 6rem 1fr; gap: 0.45rem 0.75rem; margin: 0; font-size: 0.85rem; }
.ds-bp__meta dt { color: var(--bp-muted); }
.ds-bp__meta dd { margin: 0; overflow-wrap: anywhere; }
.ds-bp__meta .is-mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.8rem; }
.ds-bp__vactions { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.ds-bp__vactions a, .ds-bp__vactions button { display: flex; align-items: center; justify-content: center; height: 2.6rem; border-radius: 0.75rem; font-size: 0.88rem; font-weight: 700;
    background: var(--bp-raised); color: var(--bp-text); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__del { align-self: flex-start; font-size: 0.8rem; color: var(--bp-bad); text-decoration: underline; }
.ds-bp__dock { position: fixed; left: 50%; bottom: 1.5rem; z-index: 40; transform: translateX(-50%); display: flex; align-items: center; gap: 0.6rem; padding: 0.55rem 0.55rem 0.55rem 0.85rem;
    border-radius: 1.25rem; background: #0e2433; color: #fff; box-shadow: 0 24px 60px rgb(0 0 0 / 0.4), inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-bp__dockn { display: grid; place-items: center; min-width: 1.9rem; height: 1.9rem; padding: 0 0.4rem; border-radius: 999px; background: var(--bp-gold); color: #0e2433; font-weight: 900; font-variant-numeric: tabular-nums; }
.ds-bp__docktext { display: flex; flex-direction: column; margin-right: 1rem; }
.ds-bp__docktext small { font-size: 0.72rem; color: #9fb3c1; }
.ds-bp__dock > button { height: 2.5rem; padding: 0 0.95rem; border-radius: 0.8rem; font-weight: 700; font-size: 0.88rem; }
.ds-bp__dock > .is-ghost { color: #9fb3c1; }
.ds-bp__dock > .is-dark { background: #24465f; color: #fff; }
.ds-bp__panel { padding: 1rem 1.2rem; border-radius: 1.15rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__panel h3 { margin: 0 0 0.4rem; font-size: 0.95rem; font-weight: 800; }
.ds-bp__mails { margin: 0; padding: 0; list-style: none; }
.ds-bp__mails li { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); gap: 0.75rem; padding: 0.5rem 0; border-top: 1px solid var(--bp-line); font-size: 0.85rem; }
.ds-bp__mails small { color: var(--bp-muted); text-align: right; }
@media (max-width: 64rem) { .ds-bp__layout { grid-template-columns: 1fr; } .ds-bp__viewer { position: static; order: -1; } }
@media (max-width: 40rem) { .ds-bp__hint, .ds-bp__stats { display: none; } .ds-bp__dock { left: 0.75rem; right: 0.75rem; transform: none; flex-wrap: wrap; } }
.ds-phs__link { font-size: 0.8rem; text-decoration: underline; }

/* ------------------------------------------------------------------ Scan app (/scan) */
.fi-panel-scan, .fi-panel-scan .fi-layout, .fi-panel-scan .fi-main-ctn { background: #0a1219; }
.fi-panel-scan .fi-main { padding: 0 !important; max-width: none !important; }
.fi-panel-scan .fi-page > .fi-header, .fi-panel-scan .fi-page-header-main-ctn > .fi-header { display: none; }
.fi-panel-scan .fi-page-content, .fi-panel-scan .fi-page-main { gap: 0 !important; }
.ds-sa {
    --sa-text: #eef3f6; --sa-muted: #7f93a1; --sa-line: rgb(255 255 255 / 0.07); --sa-glass: rgb(255 255 255 / 0.045);
    --sa-gold: #f6be00; --sa-ok: #34c38f; --sa-bad: #ff6b5e; --sa-wet: #5aa8ff; --sa-warn: #f0a93b;
    position: fixed; inset: 0; z-index: 20; overflow: hidden auto; color: var(--sa-text); font-feature-settings: 'tnum';
    background: radial-gradient(120% 70% at 0% 0%, #15293a 0%, #0a1219 55%);
    -webkit-tap-highlight-color: transparent;
}
.ds-sa button { cursor: pointer; }
.ds-sa__screen { min-height: 100%; box-sizing: border-box; display: flex; flex-direction: column; gap: 1.25rem; max-width: 34rem; margin: 0 auto;
    padding: calc(env(safe-area-inset-top) + 1.25rem) 1.35rem calc(env(safe-area-inset-bottom) + 1.5rem); animation: sa-in .35s ease-out; }
@keyframes sa-in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }
@keyframes sa-up { from { transform: translateY(100%); } to { transform: none; } }
@keyframes sa-pulse { from { box-shadow: 0 0 0 0 rgb(52 195 143 / 0.55); } to { box-shadow: 0 0 0 22px rgb(52 195 143 / 0); } }
@keyframes sa-shake { 0%,100% { transform: none; } 20% { transform: translateX(-8px); } 40% { transform: translateX(7px); } 60% { transform: translateX(-5px); } 80% { transform: translateX(3px); } }
@keyframes sa-sweep { 0% { top: 12%; opacity: 0; } 15%, 85% { opacity: 1; } 100% { top: 86%; opacity: 0; } }
@keyframes sa-ring { from { stroke-dashoffset: 302; } }
.ds-sa__hello { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
.ds-sa__hello > span:first-child { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-sa__hello small { font-size: 0.875rem; color: var(--sa-muted); }
.ds-sa__hello strong { font-size: 1.85rem; font-weight: 700; letter-spacing: -0.025em; line-height: 1.15; }
.ds-sa__avatar { display: grid; place-items: center; width: 2.75rem; height: 2.75rem; border-radius: 50%; flex: none; font-weight: 800; color: #0a1219; background: linear-gradient(135deg, #f6be00, #e08a00); }
.ds-sa__today { display: flex; align-items: center; gap: 1.1rem; padding: 1.1rem; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__today dl { flex: 1; display: grid; grid-template-columns: 1fr auto; gap: 0.6rem 0.75rem; margin: 0; font-size: 0.9rem; }
.ds-sa__today dt { color: var(--sa-muted); }
.ds-sa__today dd { margin: 0; font-weight: 700; }
.ds-sa .is-bad { color: #ff8a7e; }
.ds-sa__ring { position: relative; flex: none; width: 5.25rem; height: 5.25rem; }
.ds-sa__ring svg { width: 100%; height: 100%; transform: rotate(-90deg); }
.ds-sa__ring circle { fill: none; stroke-width: 9; }
.ds-sa__ring .is-track { stroke: rgb(255 255 255 / 0.08); }
.ds-sa__ring .is-fill { stroke: var(--sa-gold); stroke-linecap: round; stroke-dasharray: 289; transition: stroke-dashoffset .6s cubic-bezier(.2,.8,.2,1); }
.ds-sa__ring .is-fill.is-ok { stroke: var(--sa-ok); animation: sa-ring 1.1s cubic-bezier(.2,.8,.2,1); }
.ds-sa__ring > span { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; }
.ds-sa__ring > span strong { font-size: 1.35rem; letter-spacing: -0.02em; }
.ds-sa__ring > span small { font-size: 0.65rem; color: var(--sa-muted); }
.ds-sa__ring.is-small { width: 3.25rem; height: 3.25rem; }
.ds-sa__ring.is-small circle { stroke-width: 10; }
.ds-sa__ring.is-small b { font-size: 0.72rem; }
.ds-sa__ring.is-tiny { width: 3rem; height: 3rem; }
.ds-sa__ring.is-tiny circle { stroke-width: 11; }
.ds-sa__ring.is-big { width: 9.5rem; height: 9.5rem; align-self: center; margin-top: 1.5rem; }
.ds-sa__ring.is-big circle { stroke-width: 7; }
.ds-sa__ring.is-big i { display: grid; place-items: center; width: 4.75rem; height: 4.75rem; border-radius: 50%; background: rgb(52 195 143 / 0.14); color: var(--sa-ok); }
.ds-sa__ring.is-big i svg { width: 2.4rem; height: 2.4rem; transform: none; }
.ds-sa__label { margin: 0 0 -0.6rem; font-size: 0.8rem; font-weight: 600; color: var(--sa-muted); }
.ds-sa__list { display: flex; flex-direction: column; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); overflow: hidden; }
.ds-sa__row { display: flex; align-items: center; gap: 0.9rem; width: 100%; padding: 0.95rem 1rem; text-align: left; color: inherit; transition: background .2s, transform .12s; }
.ds-sa__row + .ds-sa__row { box-shadow: inset 0 1px 0 var(--sa-line); }
.ds-sa__row:active { background: rgb(255 255 255 / 0.05); transform: scale(.99); }
.ds-sa__chip { display: grid; place-items: center; width: 2.65rem; height: 2.65rem; border-radius: 0.9rem; flex: none; color: var(--sa-gold); background: rgb(246 190 0 / 0.1); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.18); }
.ds-sa__chip svg { width: 1.25rem; height: 1.25rem; }
.ds-sa__rowtext { flex: 1; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-sa__rowtext strong { font-size: 1rem; }
.ds-sa__rowtext small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__chev { font-size: 1.5rem; color: #4f6472; line-height: 1; }
.ds-sa__foot { margin-top: auto; display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__online { display: inline-flex; align-items: center; gap: 0.5rem; }
.ds-sa__online i { width: 0.45rem; height: 0.45rem; border-radius: 50%; background: var(--sa-ok); box-shadow: 0 0 0 4px rgb(52 195 143 / 0.18); }
.ds-sa__footlinks { display: flex; gap: 0.9rem; }
.ds-sa__footlinks button { color: var(--sa-muted); text-decoration: underline; }
.ds-sa__footlinks .ds-pwa-install { display: none; }
html[data-pwa-installable] .ds-sa__footlinks .ds-pwa-install { display: inline; }
.ds-sa__note { padding: 0.9rem 1rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.035); font-size: 0.875rem; color: #a9b8c2; line-height: 1.5; }
.ds-sa__pill { align-self: flex-start; display: inline-flex; align-items: center; gap: 0.4rem; height: 2.4rem; padding: 0 0.9rem 0 0.7rem; border-radius: 999px; background: rgb(255 255 255 / 0.06); color: inherit; font-weight: 600; font-size: 0.875rem; }
.ds-sa__title { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-sa__title small { font-size: 0.875rem; color: var(--sa-muted); }
.ds-sa__title strong { font-size: 1.75rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-sa__choice { display: flex; align-items: center; gap: 0.9rem; width: 100%; padding: 1.1rem; border-radius: 1.5rem; text-align: left; color: inherit; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); animation: sa-in .35s ease-out both; transition: transform .12s; }
.ds-sa__choice:active { transform: scale(.98); }
.ds-sa__choicetext { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.3rem; }
.ds-sa__choicetext strong { font-size: 1.1rem; letter-spacing: -0.01em; }
.ds-sa__choicetext small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__choicetext .is-num { color: #c9d5dc; }
.ds-sa__scan { padding: 0; max-width: none; gap: 0; position: relative; min-height: 100dvh; }
.ds-sa__cam { position: absolute; inset: 0; background: radial-gradient(90% 60% at 50% 38%, #2a3a45, #0b141b 75%); overflow: hidden; }
.ds-sa__cam video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.ds-sa__frame { position: absolute; left: 50%; top: 38%; width: min(72vw, 17rem); height: min(46vw, 11rem); transform: translate(-50%, -50%); }
.ds-sa__frame i { position: absolute; width: 2.1rem; height: 2.1rem; border: 3px solid #fff; transition: border-color .15s; }
.ds-sa__frame i:nth-child(1) { left: 0; top: 0; border-right: 0; border-bottom: 0; border-top-left-radius: 1.1rem; }
.ds-sa__frame i:nth-child(2) { right: 0; top: 0; border-left: 0; border-bottom: 0; border-top-right-radius: 1.1rem; }
.ds-sa__frame i:nth-child(3) { left: 0; bottom: 0; border-right: 0; border-top: 0; border-bottom-left-radius: 1.1rem; }
.ds-sa__frame i:nth-child(4) { right: 0; bottom: 0; border-left: 0; border-top: 0; border-bottom-right-radius: 1.1rem; }
.ds-sa__frame.is-hit i { border-color: var(--sa-ok); }
.ds-sa__sweep { position: absolute; left: 0.75rem; right: 0.75rem; height: 2px; border-radius: 2px; background: linear-gradient(90deg, transparent, var(--sa-gold), transparent); box-shadow: 0 0 14px var(--sa-gold); animation: sa-sweep 2.4s ease-in-out infinite; }
.ds-sa__camtext { position: absolute; left: 1.5rem; right: 1.5rem; top: 58%; margin: 0; text-align: center; font-size: 0.875rem; color: rgb(238 243 246 / 0.8); }
.ds-sa__camtext.is-error, .ds-sa__camtext.is-hint { top: 60%; padding: 0.6rem 0.8rem; border-radius: 0.8rem; background: rgb(10 18 25 / 0.75); color: #ffd8d3; }
.ds-sa__controls { position: absolute; left: 0; right: 0; bottom: 0; display: flex; flex-direction: column; gap: 1rem; padding: 1rem 1.25rem calc(env(safe-area-inset-bottom) + 1.6rem); background: linear-gradient(180deg, transparent, rgb(10 18 25 / 0.85) 40%); }
.ds-sa__type { display: flex; align-items: center; height: 3rem; padding: 0 0.35rem 0 1rem; border-radius: 1rem; background: rgb(10 18 25 / 0.6); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.1); }
.ds-sa__type input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--sa-text); font-size: 1rem; font-weight: 600; }
.ds-sa__type input::placeholder { color: var(--sa-muted); font-weight: 500; }
.ds-sa__type button { width: 2.4rem; height: 2.4rem; border-radius: 0.75rem; background: rgb(255 255 255 / 0.1); color: var(--sa-text); font-size: 1.1rem; }
.ds-sa__buttons { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; justify-items: center; }
.ds-sa__round { grid-column: 1; display: grid; place-items: center; width: 3.25rem; height: 3.25rem; border-radius: 50%; background: rgb(255 255 255 / 0.1); backdrop-filter: blur(10px); color: var(--sa-text); }
.ds-sa__round svg { width: 1.35rem; height: 1.35rem; }
.ds-sa__round.is-on { background: var(--sa-gold); color: #0a1219; }
.ds-sa__round.is-text { grid-column: 3; font-size: 0.78rem; font-weight: 700; }
.ds-sa__shutter { grid-column: 2; display: grid; place-items: center; width: 5.4rem; height: 5.4rem; border-radius: 50%; box-shadow: 0 0 0 4px rgb(255 255 255 / 0.9); transition: transform .12s; }
.ds-sa__shutter:active { transform: scale(.94); }
.ds-sa__shutter > span { display: grid; place-items: center; width: 4.4rem; height: 4.4rem; border-radius: 50%; background: rgb(255 255 255 / 0.15); color: #fff; transition: background .25s; }
.ds-sa__shutter > span.is-live { background: var(--sa-gold); color: #0a1219; }
.ds-sa__shutter svg { width: 1.75rem; height: 1.75rem; }
.ds-sa__bar { position: absolute; top: calc(env(safe-area-inset-top) + 0.75rem); left: 1rem; right: 1rem; z-index: 2; display: flex; align-items: center; gap: 0.75rem; padding: 0.5rem; border-radius: 1.5rem;
    background: rgb(10 18 25 / 0.55); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-sa__back { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; background: rgb(255 255 255 / 0.08); color: var(--sa-text); font-size: 1.3rem; }
.ds-sa__bartext { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.ds-sa__bartext small { font-size: 0.75rem; color: #9fb0bc; }
.ds-sa__bartext strong { font-size: 0.95rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-sa__count { display: flex; flex-direction: column; align-items: flex-end; padding-right: 0.5rem; }
.ds-sa__count strong { font-size: 1.05rem; }
.ds-sa__count small { font-size: 0.7rem; color: #9fb0bc; }
.ds-sa__sheet { position: fixed; left: 0; right: 0; bottom: 0; z-index: 25; max-width: 34rem; margin: 0 auto; display: flex; flex-direction: column; gap: 0.95rem; padding: 0.6rem 1.25rem calc(env(safe-area-inset-bottom) + 1.6rem);
    border-radius: 1.9rem 1.9rem 0 0; background: rgb(15 24 32 / 0.985); backdrop-filter: blur(24px); -webkit-backdrop-filter: blur(24px);
    box-shadow: 0 -20px 50px rgb(0 0 0 / 0.45), inset 0 1px 0 rgb(255 255 255 / 0.08); animation: sa-up .38s cubic-bezier(.2,.9,.2,1); }
.ds-sa__sheet.is-bad { background: rgb(32 16 18 / 0.985); box-shadow: 0 -20px 50px rgb(0 0 0 / 0.45), inset 0 1px 0 rgb(255 107 94 / 0.25); }
.ds-sa__sheet.is-warn { background: rgb(34 26 12 / 0.985); }
.ds-sa__grab { align-self: center; width: 2.5rem; height: 0.3rem; border-radius: 3px; background: rgb(255 255 255 / 0.2); }
.ds-sa__hit { display: flex; align-items: center; gap: 0.85rem; }
.ds-sa__hit > span:nth-child(2) { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-sa__hit strong { font-size: 1.7rem; letter-spacing: -0.02em; line-height: 1.05; overflow-wrap: anywhere; }
.ds-sa__hit small { font-size: 0.82rem; color: #6fd6ad; }
.ds-sa__sheet.is-bad .ds-sa__hit small { color: #ff9d93; }
.ds-sa__sheet.is-warn .ds-sa__hit small { color: #f3c98a; }
.ds-sa__hit em { font-style: normal; padding: 0.3rem 0.7rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); font-size: 0.75rem; font-weight: 600; color: #c9d5dc; }
.ds-sa__hit.is-shake { animation: sa-shake .45s ease-in-out .3s; }
.ds-sa__mark { display: grid; place-items: center; width: 3.1rem; height: 3.1rem; border-radius: 50%; flex: none; font-weight: 900; font-size: 1.4rem; }
.ds-sa__mark svg { width: 1.5rem; height: 1.5rem; }
.ds-sa__mark.is-ok { background: var(--sa-ok); color: #0a1219; animation: sa-pulse 1s ease-out; }
.ds-sa__mark.is-bad { background: var(--sa-bad); color: #fff; }
.ds-sa__mark.is-warn { background: var(--sa-warn); color: #0a1219; }
.ds-sa__msg { margin: 0; font-size: 0.95rem; line-height: 1.5; color: #e9cfcc; }
.ds-sa__who { display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 0.9rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.04); }
.ds-sa__who > span:first-child { display: grid; place-items: center; width: 2.25rem; height: 2.25rem; border-radius: 50%; flex: none; background: rgb(255 255 255 / 0.08); font-size: 0.8rem; font-weight: 700; }
.ds-sa__who > span:last-child { display: flex; flex-direction: column; min-width: 0; }
.ds-sa__who small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__seg { position: relative; display: grid; grid-template-columns: repeat(4, 1fr); padding: 4px; border-radius: 1rem; background: rgb(255 255 255 / 0.05); }
.ds-sa__segthumb { position: absolute; top: 4px; bottom: 4px; width: calc((100% - 8px) / 4); border-radius: 0.75rem; transition: left .28s cubic-bezier(.2,.9,.2,1), background .28s; background: var(--sa-ok); }
.ds-sa__segthumb.is-damaged { background: var(--sa-bad); }
.ds-sa__segthumb.is-wet { background: var(--sa-wet); }
.ds-sa__segthumb.is-open { background: var(--sa-warn); }
.ds-sa__seg button { position: relative; z-index: 1; display: flex; align-items: center; justify-content: center; gap: 0.35rem; height: 2.65rem; font-size: 0.8rem; font-weight: 700; color: #c9d5dc; transition: color .2s; }
.ds-sa__seg button.is-on { color: #0a1219; }
.ds-sa__seg i { width: 0.45rem; height: 0.45rem; border-radius: 50%; }
.ds-sa__seg i.is-good { background: var(--sa-ok); }
.ds-sa__seg i.is-damaged { background: var(--sa-bad); }
.ds-sa__seg i.is-wet { background: var(--sa-wet); }
.ds-sa__seg i.is-open { background: var(--sa-warn); }
.ds-sa__seg button.is-on i { background: #0a1219; }
.ds-sa__note-in { height: 2.9rem; padding: 0 1rem; border: 0; border-radius: 0.9rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-size: 0.95rem; box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-sa__photos { display: flex; flex-wrap: wrap; align-items: center; gap: 0.6rem; }
.ds-sa__shot img { width: 3.5rem; height: 3.5rem; border-radius: 0.9rem; object-fit: cover; box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.15); animation: sa-in .25s ease-out; }
.ds-sa__addphoto { flex: 1; min-width: 10rem; display: flex; align-items: center; justify-content: center; gap: 0.5rem; height: 3.5rem; border-radius: 1rem; background: rgb(255 255 255 / 0.06); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.1); color: var(--sa-text); font-weight: 600; }
.ds-sa__addphoto svg { width: 1.25rem; height: 1.25rem; }
.ds-sa__err { width: 100%; margin: 0; font-size: 0.8rem; color: #ff9d93; }
.ds-sa__primary { height: 3.6rem; border-radius: 1.15rem; background: var(--sa-gold); color: #0a1219; font-size: 1.05rem; font-weight: 700; transition: transform .12s; }
.ds-sa__secondary { height: 3rem; border-radius: 1rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-size: 0.95rem; font-weight: 600; }
.ds-sa__primary:active, .ds-sa__secondary:active { transform: scale(.98); }
.ds-sa__sheet .fi-btn { height: 3.4rem; border-radius: 1.1rem; }
.ds-sa__done { align-items: stretch; text-align: center; }
.ds-sa__done h2 { margin: 0.5rem 0 0; font-size: 1.75rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-sa__done > p { margin: 0; color: var(--sa-muted); }
.ds-sa__totals { display: grid; grid-template-columns: repeat(3, 1fr); margin-top: 0.75rem; border-radius: 1.4rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__totals span { display: flex; flex-direction: column; gap: 0.15rem; padding: 1rem 0.4rem; }
.ds-sa__totals span + span { box-shadow: inset 1px 0 0 var(--sa-line); }
.ds-sa__totals strong { font-size: 1.5rem; }
.ds-sa__totals small { font-size: 0.75rem; color: var(--sa-muted); }
.ds-sa__done .ds-sa__note { text-align: left; }
.ds-sa__done .ds-sa__primary { margin-top: auto; }
@media (prefers-reduced-motion: reduce) { .ds-sa *, .ds-sa *::before { animation: none !important; transition: none !important; } }
/* scan app sign-in */
.ds-auth--scan .ds-auth-delivery__top h1 { max-width: 14ch; }
.ds-sa__waiting { padding: 0.2rem 0.6rem; border-radius: 999px; font-size: 0.72rem; font-weight: 700; color: var(--sa-gold); background: rgb(246 190 0 / 0.12); white-space: nowrap; }
.ds-sa__waiting.is-none { color: var(--sa-muted); background: rgb(255 255 255 / 0.05); }
.ds-sa__choice.is-finished { opacity: 0.5; }
.ds-sa__choice.is-finished .ds-sa__ring .is-fill { stroke: var(--sa-ok); }
.ds-sa__more { align-self: center; padding: 0.5rem 1rem; border-radius: 999px; font-size: 0.85rem; font-weight: 600; color: var(--sa-muted); text-decoration: underline; }

/* ------------------------------------------------------------------ Driver app (delivery home) */
.fi-panel-delivery .fi-main:has(.ds-dr) { padding: 0 !important; max-width: none !important; }
.fi-panel-delivery .fi-page:has(.ds-dr) .fi-header { display: none; }
.ds-sa__avatar.is-green { background: linear-gradient(135deg, #34c38f, #1f9a6c); }
.ds-sa__ring.is-mid { width: 6rem; height: 6rem; }
.ds-sa__ring.is-mid > span strong { font-size: 1.5rem; }
.ds-sa__ring.is-mid > span small { font-size: 0.6rem; text-align: center; max-width: 4.5rem; line-height: 1.2; }
.ds-sa__ring .is-fill.is-green { stroke: var(--sa-ok); }
.ds-sa__today dd.is-ok { color: #6fd6ad; }
.ds-sa__today dd.is-warn { color: var(--sa-warn); }
.ds-dr__scanbtn { display: flex; align-items: center; justify-content: center; gap: 0.6rem; height: 4rem; border-radius: 1.4rem; font-size: 1.1rem; font-weight: 800; box-shadow: 0 14px 34px rgb(246 190 0 / 0.22); }
.ds-dr__scanbtn svg { width: 1.5rem; height: 1.5rem; }
.ds-dr__labelrow { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: -0.6rem; }
.ds-dr__labelrow .ds-sa__label { margin: 0; }
.ds-dr__labelrow button { color: var(--sa-gold); font-size: 0.82rem; font-weight: 700; }
.ds-sa__list.is-warn { box-shadow: inset 0 0 0 1px rgb(240 169 59 / 0.35); }
.ds-sa__list.is-warn .ds-sa__rowtext strong { color: #f3c98a; }
.ds-dr__done { cursor: default; }
.ds-dr__thumb { width: 2.6rem; height: 2.6rem; border-radius: 0.7rem; object-fit: cover; flex: none; }
.ds-dr__undo { padding: 0.45rem 0.7rem; border-radius: 0.7rem; background: rgb(255 255 255 / 0.08); color: var(--sa-text); font-size: 0.75rem; font-weight: 700; white-space: nowrap; }
.ds-dr__office { font-size: 0.72rem; color: var(--sa-muted); white-space: nowrap; }
.ds-dr__crew { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.75rem 0.9rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.035); font-size: 0.82rem; color: #a9b8c2; }
.ds-dr__crew span { display: flex; align-items: center; gap: 0.6rem; }
.ds-dr__crew i { display: grid; place-items: center; width: 1.9rem; height: 1.9rem; border-radius: 50%; background: rgb(255 255 255 / 0.08); font-style: normal; font-weight: 700; font-size: 0.7rem; color: var(--sa-text); }
.ds-dr__celebrate { display: flex; flex-direction: column; align-items: center; gap: 0.5rem; text-align: center; padding: 1rem 0; }
.ds-dr__celebrate strong { font-size: 1.5rem; letter-spacing: -0.02em; }
.ds-dr__celebrate p { margin: 0; color: var(--sa-muted); }
.ds-sa__empty { display: flex; flex-direction: column; align-items: center; gap: 0.6rem; padding: 3rem 1rem; text-align: center; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__empty-icon { display: grid; place-items: center; width: 3.5rem; height: 3.5rem; border-radius: 1.1rem; background: rgb(246 190 0 / 0.1); color: var(--sa-gold); }
.ds-sa__empty-icon svg { width: 1.6rem; height: 1.6rem; }
.ds-sa__empty strong { font-size: 1.2rem; }
.ds-sa__empty p { margin: 0; color: var(--sa-muted); font-size: 0.9rem; line-height: 1.5; }
.ds-dr__listhead { display: flex; align-items: center; gap: 0.7rem; }
.ds-dr__listhead strong { flex: 1; font-size: 1.6rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-dr__scanmini { display: grid; place-items: center; width: 2.75rem; height: 2.75rem; border-radius: 0.9rem; background: var(--sa-gold); color: #0a1219; }
.ds-dr__scanmini svg { width: 1.25rem; height: 1.25rem; }
.ds-dr__search { display: flex; align-items: center; gap: 0.6rem; height: 3rem; padding: 0 0.9rem; border-radius: 1rem; background: rgb(255 255 255 / 0.05); box-shadow: inset 0 0 0 1px var(--sa-line); color: var(--sa-muted); }
.ds-dr__search svg { width: 1.1rem; height: 1.1rem; flex: none; }
.ds-dr__search input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--sa-text); font-size: 1rem; }
.ds-dr__search input::-webkit-search-cancel-button { filter: invert(1); }
.ds-sa__seg.is-3 { grid-template-columns: repeat(3, 1fr); }
.ds-sa__seg.is-3 .ds-sa__segthumb { width: calc((100% - 8px) / 3); }
.ds-sa__segthumb.is-light { background: var(--sa-text); }
.ds-sa__seg.is-3 button { font-size: 0.74rem; }
.ds-dr__rows { display: flex; flex-direction: column; gap: 0.6rem; }
.ds-dr__card { display: flex; align-items: center; gap: 0.75rem; padding: 0.85rem 1rem; border-radius: 1.25rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); animation: sa-in .3s ease-out both; }
.ds-dr__cardmain { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; text-align: left; color: inherit; }
.ds-dr__cardtop { display: flex; align-items: baseline; gap: 0.5rem; }
.ds-dr__cardtop strong { font-size: 1rem; }
.ds-dr__cardtop em { font-style: normal; font-size: 0.7rem; font-weight: 700; padding: 0.1rem 0.5rem; border-radius: 999px; color: #c9d5dc; background: rgb(255 255 255 / 0.07); }
.ds-dr__cardtop em.is-ok { color: #6fd6ad; background: rgb(52 195 143 / 0.14); }
.ds-dr__cardtop em.is-warn { color: #f3c98a; background: rgb(240 169 59 / 0.14); }
.ds-dr__name { font-size: 0.9rem; }
.ds-dr__cardmain small { font-size: 0.75rem; color: var(--sa-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-dr__call { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; background: rgb(52 195 143 / 0.14); color: var(--sa-ok); }
.ds-dr__call svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__toast { position: fixed; top: calc(env(safe-area-inset-top) + 5.5rem); left: 1rem; right: 1rem; z-index: 26; max-width: 32rem; margin: 0 auto; display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 0.75rem 0.75rem 0.9rem; border-radius: 1.25rem;
    background: rgb(15 43 35 / 0.96); backdrop-filter: blur(18px); box-shadow: 0 16px 40px rgb(0 0 0 / 0.4), inset 0 0 0 1px rgb(52 195 143 / 0.4); animation: dr-toast .35s cubic-bezier(.2,.9,.2,1); }
@keyframes dr-toast { from { transform: translateY(-140%); } to { transform: none; } }
@keyframes dr-count { from { stroke-dashoffset: 0; } to { stroke-dashoffset: 113; } }
.ds-dr__toast .ds-sa__mark { width: 2.2rem; height: 2.2rem; }
.ds-dr__toast .ds-sa__mark svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__toast > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-dr__toast small { font-size: 0.75rem; color: #9fd8c0; }
.ds-dr__toast button { display: flex; align-items: center; gap: 0.45rem; height: 2.5rem; padding: 0 0.85rem 0 0.6rem; border-radius: 0.8rem; background: rgb(255 255 255 / 0.1); color: var(--sa-text); font-weight: 700; }
.ds-dr__toast button svg { width: 1.35rem; height: 1.35rem; transform: rotate(-90deg); }
.ds-dr__toast circle { fill: none; stroke-width: 4; }
.ds-dr__toast .is-track { stroke: rgb(255 255 255 / 0.15); }
.ds-dr__toast .is-fill { stroke: var(--sa-gold); stroke-dasharray: 113; animation: dr-count 15s linear forwards; }
.ds-dr__tags { display: flex; align-items: center; gap: 0.6rem; }
.ds-dr__ontruck { padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(52 195 143 / 0.14); color: #6fd6ad; font-size: 0.75rem; font-weight: 700; }
.ds-dr__tags strong { font-size: 0.95rem; color: #c9d5dc; }
.ds-dr__tags em { margin-left: auto; font-style: normal; padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); font-size: 0.75rem; font-weight: 600; color: #c9d5dc; }
.ds-dr__receiver { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-dr__receiver strong { font-size: 1.6rem; letter-spacing: -0.02em; line-height: 1.1; }
.ds-dr__receiver span { font-size: 0.9rem; color: #a9b8c2; line-height: 1.45; }
.ds-dr__two { display: grid; grid-template-columns: repeat(auto-fit, minmax(0, 1fr)); gap: 0.5rem; }
.ds-dr__two a { display: flex; align-items: center; justify-content: center; gap: 0.5rem; height: 3rem; border-radius: 0.9rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-weight: 600; font-size: 0.9rem; }
.ds-dr__two svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__meta { font-size: 0.8rem; color: var(--sa-muted); }
.ds-dr__prev { font-size: 0.8rem; color: #f3c98a; }
.ds-sa__primary.is-green { background: var(--sa-ok); }
.ds-sa__primary.is-amber { background: var(--sa-warn); }
.ds-sa__primary.is-off { background: rgb(255 255 255 / 0.08); color: var(--sa-muted); }
.ds-dr__link { height: 2.6rem; color: var(--sa-muted); font-weight: 600; }
.ds-dr__sheethead { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-dr__sheethead small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-dr__sheethead.is-warn small { color: #c9b08a; }
.ds-dr__sheethead strong { font-size: 1.45rem; letter-spacing: -0.02em; }
.ds-dr__sheethead > span { font-size: 0.88rem; color: #a9b8c2; }
.ds-dr__grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.6rem; }
.ds-dr__proof { position: relative; aspect-ratio: 1; border-radius: 1.1rem; overflow: hidden; animation: sa-in .25s ease-out; }
.ds-dr__proof img { width: 100%; height: 100%; object-fit: cover; }
.ds-dr__proof b { position: absolute; left: 0.45rem; bottom: 0.45rem; padding: 0.05rem 0.5rem; border-radius: 999px; background: rgb(10 18 25 / 0.75); font-size: 0.7rem; }
.ds-dr__proof button { position: absolute; right: 0.35rem; top: 0.35rem; width: 1.6rem; height: 1.6rem; border-radius: 50%; background: rgb(10 18 25 / 0.7); color: #fff; font-size: 0.7rem; }
.ds-dr__proof.is-small { width: 3.5rem; height: 3.5rem; aspect-ratio: auto; border-radius: 0.9rem; }
.ds-dr__add { aspect-ratio: 1; border-radius: 1.1rem; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 0.35rem; background: rgb(255 255 255 / 0.05); box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / 0.18); color: var(--sa-text); font-size: 0.8rem; font-weight: 600; }
.ds-dr__add svg { width: 1.6rem; height: 1.6rem; }
.ds-dr__chips { display: flex; flex-wrap: wrap; gap: 0.45rem; }
.ds-dr__chips button { height: 2.35rem; padding: 0 0.85rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); color: var(--sa-text); font-size: 0.8rem; font-weight: 700; transition: background .2s, color .2s; }
.ds-dr__chips button.is-on { background: var(--sa-warn); color: #0a1219; }
.ds-sa__sheet.is-warn .ds-sa__note-in { background: rgb(255 255 255 / 0.06); }
.ds-sa.ds-dr { z-index: 32; }

/* ===================================================================== AI helpers */
.ds-ai {
    --ai-surf: #fff; --ai-raised: #f6f8fa; --ai-line: #e8edf1; --ai-text: #0e2433; --ai-muted: #5b6b78;
    --ai-violet: #6c55d9; --ai-violet-soft: #f2efff; --ai-violet-text: #3f3380;
    --ai-ok: #17895e; --ai-ok-soft: #e5f6ee; --ai-bad: #c2382f; --ai-bad-soft: #fde8e6; --ai-warn: #a76400; --ai-warn-soft: #fff2d9;
    --ai-blue: #1f6fa5; --ai-blue-soft: #e5f1fa; --ai-gold: #d4a72c;
    display: flex; flex-direction: column; gap: 1rem; color: var(--ai-text);
}
.dark .ds-ai {
    --ai-surf: #142430; --ai-raised: #1a2d3b; --ai-line: rgb(255 255 255 / 0.08); --ai-text: #e9eff3; --ai-muted: #93a6b4;
    --ai-violet-soft: rgb(108 85 217 / 0.18); --ai-violet-text: #cdc3ff;
    --ai-ok-soft: rgb(23 137 94 / 0.2); --ai-bad-soft: rgb(194 56 47 / 0.2); --ai-warn-soft: rgb(167 100 0 / 0.22); --ai-blue-soft: rgb(31 111 165 / 0.22);
    --ai-ok: #4fd09d; --ai-bad: #ff8a7e; --ai-warn: #f3c06b; --ai-blue: #8cc4ff;
}
.ds-ai__card { background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 1rem 1.1rem; display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-ai__card-head { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; flex-wrap: wrap; }
.ds-ai__card-head b { font-size: 1rem; }
.ds-ai__bar { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; flex-wrap: wrap; }
.ds-ai__seg { display: inline-flex; flex-wrap: wrap; gap: 0.3rem; align-items: center; }
.ds-ai__seg button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.65rem; font-size: 0.85rem; font-weight: 700; color: var(--ai-text); background: var(--ai-surf); box-shadow: inset 0 0 0 1px var(--ai-line); }
.ds-ai__seg.is-small button { height: 1.85rem; padding: 0 0.65rem; font-size: 0.78rem; background: var(--ai-raised); box-shadow: none; }
.ds-ai__seg button.is-on { background: var(--ds-navy); color: #fff; box-shadow: none; }
.dark .ds-ai__seg button.is-on { background: #e9eff3; color: #0b1620; }
.ds-ai__seg button i { font-style: normal; margin-left: 0.3rem; padding: 0 0.4rem; border-radius: 999px; background: #f0a93b; color: #fff; font-size: 0.72rem; }
.ds-ai__stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr)); gap: 0.75rem; }
.ds-ai__stats > div { background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 0.85rem 1rem; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-ai__stats.is-small > div { background: var(--ai-raised); box-shadow: none; }
.ds-ai__stats small { font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__stats b { font-size: 1.6rem; font-weight: 900; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
.ds-ai__stats b span { font-size: 0.9rem; font-weight: 600; color: var(--ai-muted); }
.ds-ai__stats em { font-style: normal; font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai .is-red { color: var(--ai-bad); } .ds-ai .is-amber { color: var(--ai-warn); } .ds-ai .is-green { color: var(--ai-ok); }
.ds-ai__split { display: grid; grid-template-columns: minmax(0, 1fr) 24rem; gap: 1rem; align-items: start; }
.ds-ai__split.is-even { grid-template-columns: repeat(auto-fit, minmax(22rem, 1fr)); }
@media (max-width: 1100px) { .ds-ai__split { grid-template-columns: 1fr; } }
.ds-ai__list { padding: 0; gap: 0; overflow: hidden; }
.ds-ai__list > .ds-ai__card-head { padding: 0.8rem 1rem; border-bottom: 1px solid var(--ai-line); }
.ds-ai__row { width: 100%; display: flex; align-items: center; gap: 0.8rem; padding: 0.7rem 1rem; text-align: left; border-top: 1px solid var(--ai-line); background: var(--ai-surf); color: inherit; }
.ds-ai__row:first-of-type { border-top: 0; }
.ds-ai__row:hover { background: var(--ai-raised); }
.ds-ai__row.is-sel { background: var(--ai-warn-soft); box-shadow: inset 3px 0 0 var(--ai-gold); }
.ds-ai__row img { width: 4.2rem; height: 3.2rem; border-radius: 0.55rem; object-fit: cover; flex: none; background: var(--ai-raised); }
.ds-ai__row-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.85rem; }
.ds-ai__row-main b { font-size: 0.95rem; }
.ds-ai__row-main small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai__tag { display: inline-block; font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.72rem; font-weight: 800; background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__tag.is-damaged, .ds-ai__tag.is-no_box { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__tag.is-wet { background: var(--ai-blue-soft); color: var(--ai-blue); }
.ds-ai__tag.is-open { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__tag.is-blurry { background: var(--ai-violet-soft); color: var(--ai-violet-text); }
.ds-ai__tag.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__state { flex: none; padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__state.is-damaged, .ds-ai__state.is-removed { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__state.is-fine, .ds-ai__state.is-texted, .ds-ai__state.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__state.is-open { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__empty { padding: 1.5rem 1rem; color: var(--ai-muted); text-align: center; margin: 0; }
.ds-ai__detail { position: sticky; top: 5rem; }
.ds-ai__photo { position: relative; display: block; border-radius: 0.8rem; overflow: hidden; background: var(--ai-raised); }
.ds-ai__photo img { width: 100%; max-height: 18rem; object-fit: contain; display: block; }
.ds-ai__photo span { position: absolute; left: 0.6rem; top: 0.6rem; padding: 0.15rem 0.55rem; border-radius: 999px; background: rgb(14 36 51 / 0.75); color: #fff; font-size: 0.75rem; font-weight: 700; }
.ds-ai__detail-head { display: flex; align-items: baseline; justify-content: space-between; gap: 0.5rem; }
.ds-ai__detail-head b { font-size: 1.15rem; } .ds-ai__detail-head small { color: var(--ai-muted); font-size: 0.8rem; }
.ds-ai__said { display: flex; gap: 0.7rem; padding: 0.8rem 0.9rem; border-radius: 0.8rem; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.9rem; line-height: 1.5; }
.ds-ai__said > span:last-child { display: flex; flex-direction: column; gap: 0.35rem; flex: 1; min-width: 0; }
.ds-ai__said small { font-size: 0.85rem; opacity: 0.9; }
.ds-ai__badge { width: 1.7rem; height: 1.7rem; flex: none; border-radius: 0.5rem; background: var(--ai-violet); color: #fff; display: grid; place-items: center; font-size: 0.7rem; font-weight: 900; }
.ds-ai__two { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-ai__two > * { flex: 1 1 auto; }
.ds-ai__done { margin: 0; padding: 0.7rem 0.85rem; border-radius: 0.7rem; font-size: 0.85rem; font-weight: 600; }
.ds-ai__done.is-damaged { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__done.is-fine { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__link { color: var(--ai-violet); font-weight: 700; font-size: 0.8rem; margin-left: 0.4rem; text-decoration: none; }
.dark .ds-ai__link { color: #b9a8ff; }
.ds-ai__err { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: var(--ai-bad-soft, #fde8e6); color: var(--ai-bad, #b3261e); font-size: 0.85rem; }
.ds-ai__test { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; font-size: 0.9rem; font-weight: 600; }
.ds-ai__test.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__test.is-bad { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__paused { display: flex; gap: 0.6rem; align-items: center; padding: 0.7rem 0.9rem; border-radius: 0.8rem; background: var(--ai-warn-soft); color: var(--ai-warn); font-size: 0.9rem; }
.ds-ai__paused b { padding: 0.1rem 0.5rem; border-radius: 999px; background: #f0a93b; color: #fff; font-size: 0.75rem; }
.ds-ai__pill { padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.75rem !important; font-weight: 700; }
.ds-ai__pill.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok) !important; }
.ds-ai__pill.is-off { background: var(--ai-warn-soft); color: var(--ai-warn) !important; }
/* settings */
.ds-ai-set { gap: 1rem; }
.ds-ai-set__steps { margin: 0; padding-left: 1.2rem; display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.9rem; }
.ds-ai-set__steps a, .ds-ai-set__notes a { color: var(--ai-violet); font-weight: 700; }
.ds-ai-set__key { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-ai-set__key input { flex: 1 1 18rem; min-width: 0; height: 2.6rem; padding: 0 0.8rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); font-family: ui-monospace, monospace; }
.ds-ai-set__feat { display: grid; grid-template-columns: auto 1fr auto; gap: 0.8rem; align-items: start; padding: 0.75rem 0; border-top: 1px solid var(--ai-line); cursor: pointer; }
.ds-ai-set__feat input { margin-top: 0.25rem; }
.ds-ai-set__feat > span:nth-child(2) { display: flex; flex-direction: column; gap: 0.15rem; }
.ds-ai-set__feat small { font-size: 0.85rem; color: var(--ai-muted); }
.ds-ai-set__feat em { font-style: normal; font-size: 0.75rem; font-weight: 700; color: var(--ai-violet); }
.ds-ai-set__use { display: flex; flex-direction: column; align-items: flex-end; font-variant-numeric: tabular-nums; }
.ds-ai-set__use small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai-set__save { display: flex; justify-content: flex-end; }
.ds-ai-set__spend { display: flex; flex-direction: column; gap: 0.4rem; }
.ds-ai-set__spend i { display: block; height: 0.5rem; border-radius: 999px; background: var(--ai-raised); overflow: hidden; }
.ds-ai-set__spend s { display: block; height: 100%; background: var(--ai-ok); border-radius: 999px; text-decoration: none; }
.ds-ai-set__spend s.is-bad { background: var(--ai-bad); }
.ds-ai-set__notes { margin: 0; padding-left: 1.2rem; display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.9rem; }
.ds-ai-set code, .ds-ai-set__steps code { font-size: 0.85em; padding: 0.05rem 0.3rem; border-radius: 0.3rem; background: var(--ai-raised); }
/* ask */
.ds-ai__chat { padding: 0; gap: 0; min-height: 34rem; }
.ds-ai__msgs { flex: 1; max-height: 60vh; min-height: 22rem; overflow: auto; padding: 1.2rem 1.4rem; display: flex; flex-direction: column; gap: 0.8rem; }
.ds-ai__hello { margin: auto; text-align: center; display: flex; flex-direction: column; gap: 0.3rem; color: var(--ai-muted); }
.ds-ai__hello b { font-size: 1.1rem; color: var(--ai-text); }
.ds-ai__msg { align-self: flex-start; max-width: 46rem; padding: 0.7rem 0.95rem; border-radius: 1rem 1rem 1rem 0.25rem; background: var(--ai-raised); font-size: 0.95rem; line-height: 1.55; }
.ds-ai__msg.is-me { align-self: flex-end; background: var(--ds-navy); color: #fff; border-radius: 1rem 1rem 0.25rem 1rem; }
.ds-ai__typing { align-self: flex-start; align-items: center; gap: 0.3rem; padding: 0.6rem 0.9rem; border-radius: 1rem; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.85rem; }
.ds-ai__typing i { width: 0.4rem; height: 0.4rem; border-radius: 50%; background: var(--ai-violet); animation: ds-ai-dot 1s infinite; }
.ds-ai__typing i:nth-child(2) { animation-delay: 0.15s; } .ds-ai__typing i:nth-child(3) { animation-delay: 0.3s; }
.ds-ai__typing span { margin-left: 0.3rem; }
@keyframes ds-ai-dot { 0%, 80%, 100% { opacity: 0.25; } 40% { opacity: 1; } }
.ds-ai__ask { border-top: 1px solid var(--ai-line); padding: 0.8rem 1rem 1rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-ai__chips { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-ai__chips button { height: 1.9rem; padding: 0 0.75rem; border-radius: 999px; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.8rem; font-weight: 700; }
.ds-ai__chips button.is-plain { background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__askrow { display: flex; gap: 0.5rem; }
.ds-ai__askrow input, .ds-ai__text, .ds-ai__select { flex: 1; min-width: 0; height: 2.75rem; padding: 0 0.9rem; border-radius: 0.7rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); font-size: 0.95rem; }
.ds-ai__text { height: auto; padding: 0.7rem 0.9rem; line-height: 1.5; resize: vertical; }
.ds-ai__select { flex: 0 1 14rem; height: 2.2rem; }
/* manifest */
.ds-ai__upload { max-width: 44rem; }
.ds-ai__upload select { height: 2.6rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); padding: 0 0.7rem; }
.ds-ai__drop { display: flex; flex-direction: column; align-items: center; gap: 0.3rem; padding: 1.6rem 1rem; border-radius: 0.9rem; background: var(--ai-raised); box-shadow: inset 0 0 0 1.5px dashed var(--ai-line); border: 1.5px dashed #c9d3db; cursor: pointer; text-align: center; }
.ds-ai__drop input { max-width: 100%; font-size: 0.85rem; }
.ds-ai__drop small { color: var(--ai-muted); }
.ds-ai__table { overflow: auto; max-height: 62vh; border-radius: 0.7rem; box-shadow: 0 0 0 1px var(--ai-line); }
.ds-ai__tr { display: grid; grid-template-columns: 2rem 7rem minmax(10rem, 1.2fr) minmax(14rem, 2fr) 8rem 5rem minmax(12rem, 1.4fr); gap: 0.6rem; align-items: start; padding: 0.55rem 0.8rem; border-top: 1px solid var(--ai-line); font-size: 0.83rem; min-width: 64rem; }
.ds-ai__tr.is-head { position: sticky; top: 0; z-index: 1; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); border-top: 0; }
.ds-ai__tr small { display: block; color: var(--ai-muted); font-size: 0.73rem; }
.ds-ai__tr.is-off { opacity: 0.55; }
.ds-ai__tr.is-warn { background: var(--ai-warn-soft); }
.ds-ai__notes { display: flex; flex-direction: column; gap: 0.2rem; align-items: flex-start; }
.ds-ai__notes .ds-ai__tag { white-space: normal; }
.ds-ai__foot { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; }
.ds-ai__foot > span { flex: 1 1 20rem; font-size: 0.85rem; color: var(--ai-muted); }
/* risky */
.ds-ai__score { width: 3rem; height: 3rem; flex: none; border-radius: 0.8rem; display: grid; place-items: center; font-weight: 900; font-size: 0.9rem; background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__score.is-high { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__why { margin: 0; padding-left: 1.1rem; display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.88rem; }
.ds-ai__label { font-size: 0.85rem; }
.ds-ai__btn { display: inline-flex; align-items: center; justify-content: center; height: 2.25rem; padding: 0 0.9rem; border-radius: 0.55rem; font-weight: 700; font-size: 0.875rem; text-decoration: none; }
.ds-ai__btn.is-green { background: var(--ai-ok); color: #fff; }
/* alerts */
.ds-ai__alert { display: flex; gap: 0.85rem; align-items: flex-start; padding: 0.9rem 0.2rem; border-top: 1px solid var(--ai-line); }
.ds-ai__alert:first-child { border-top: 0; }
.ds-ai__alert-ic { width: 2.5rem; height: 2.5rem; flex: none; border-radius: 0.75rem; display: grid; place-items: center; font-size: 1.1rem; background: var(--ai-blue-soft); }
.ds-ai__alert.is-high .ds-ai__alert-ic { background: var(--ai-bad-soft); }
.ds-ai__alert.is-mid .ds-ai__alert-ic { background: var(--ai-warn-soft); }
.ds-ai__alert-act { display: flex; flex-direction: column; gap: 0.35rem; align-items: stretch; width: 9rem; flex: none; }
.ds-ai__alert-act small { color: var(--ai-muted); font-size: 0.75rem; text-align: center; }
/* insights */
.ds-ai__bars { display: flex; align-items: flex-end; gap: 0.35rem; height: 13rem; padding-top: 0.5rem; overflow-x: auto; }
.ds-ai__barcol { flex: 1 0 2.4rem; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; gap: 0.3rem; height: 100%; }
.ds-ai__barcol em { font-style: normal; font-size: 0.68rem; font-weight: 700; color: var(--ai-muted); font-variant-numeric: tabular-nums; }
.ds-ai__barcol i { position: relative; display: block; width: 1.3rem; border-radius: 0.3rem 0.3rem 0 0; min-height: 2px; }
.ds-ai__barcol i.is-past { background: #c9d3db; }
.dark .ds-ai__barcol i.is-past { background: #3a4f5f; }
.ds-ai__barcol i.is-next { background: #e9b730; }
.ds-ai__barcol i s { position: absolute; left: -0.25rem; right: -0.25rem; height: 2px; background: var(--ai-text); opacity: 0.55; }
.ds-ai__barcol small { font-size: 0.66rem; color: var(--ai-muted); white-space: nowrap; }
/* driver app + scan app */
.ds-dr__risk { display: flex; flex-direction: column; gap: 0.2rem; padding: 0.7rem 0.85rem; border-radius: 0.9rem; background: rgb(240 169 59 / 0.14); box-shadow: inset 0 0 0 1px rgb(240 169 59 / 0.4); color: #f3c98a; font-size: 0.82rem; line-height: 1.45; }
.ds-dr__risk b { color: #ffd28f; font-size: 0.85rem; }
.ds-dr__voice { display: flex; align-items: center; gap: 0.8rem; padding: 0.6rem 0.7rem; border-radius: 1rem; background: rgb(108 85 217 / 0.16); }
.ds-dr__voice button { width: 3.2rem; height: 3.2rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: #8b78ff; color: #fff; }
.ds-dr__voice button.is-on { background: #ff6b5e; animation: ds-ai-pulse 1s infinite; }
.ds-dr__voice button svg { width: 1.5rem; height: 1.5rem; }
.ds-dr__voice > span { display: flex; flex-direction: column; gap: 0.1rem; min-width: 0; }
.ds-dr__voice b { font-size: 0.9rem; } .ds-dr__voice small { font-size: 0.75rem; color: #c9c0ff; }
@keyframes ds-ai-pulse { 0% { box-shadow: 0 0 0 0 rgb(255 107 94 / 0.55); } 100% { box-shadow: 0 0 0 16px rgb(255 107 94 / 0); } }
.ds-sa__aiflag { position: relative; z-index: 6; display: flex; align-items: center; flex-wrap: wrap; gap: 0.6rem; margin: 0 0 0.6rem; padding: 0.7rem 0.8rem; border-radius: 1rem; background: rgb(108 85 217 / 0.2); box-shadow: inset 0 0 0 1px rgb(139 120 255 / 0.5); color: #eef3f6; }
.ds-sa__aiflag > span:nth-child(2) { flex: 1 1 10rem; display: flex; flex-direction: column; font-size: 0.85rem; }
.ds-sa__aiflag small { color: #c9c0ff; font-size: 0.75rem; }
.ds-sa__aiflag button { height: 2.3rem; padding: 0 0.8rem; border-radius: 0.7rem; background: #ff6b5e; color: #fff; font-weight: 800; font-size: 0.8rem; }
.ds-sa__aiflag button.is-plain { background: rgb(255 255 255 / 0.1); }
.ds-sa__aibadge { width: 1.8rem; height: 1.8rem; flex: none; border-radius: 0.55rem; display: grid; place-items: center; background: #8b78ff; color: #fff; font-size: 0.7rem; font-weight: 900; }
/* AI trip helper */
.ds-ai__plan { flex-direction: row; align-items: center; gap: 0.6rem; flex-wrap: wrap; padding: 0.6rem; }
.ds-ai__plan > input { flex: 1 1 18rem; min-width: 0; height: 2.5rem; padding: 0 0.8rem; border-radius: 0.6rem; border: 0; background: var(--ai-raised); color: var(--ai-text); }
.ds-ai__date { display: flex; align-items: center; gap: 0.4rem; font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__date input { height: 2.5rem; padding: 0 0.6rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); }
.ds-ai__split.is-trips { grid-template-columns: 20rem minmax(0, 1fr); }
@media (max-width: 1100px) { .ds-ai__split.is-trips { grid-template-columns: 1fr; } }
.ds-ai__tree { display: flex; flex-direction: column; gap: 0.7rem; max-height: 55vh; overflow: auto; }
.ds-ai__tree > div { display: flex; flex-direction: column; gap: 0.35rem; }
.ds-ai__tree > div > b { font-size: 0.85rem; }
.ds-ai__tree small { color: var(--ai-muted); font-weight: 600; }
.ds-ai__tree span { display: flex; flex-direction: column; gap: 0.1rem; padding-left: 0.6rem; border-left: 2px solid var(--ai-line); font-size: 0.82rem; }
.ds-ai__tree span small { font-weight: 400; line-height: 1.45; }
.ds-ai__two.is-left > * { flex: 0 0 auto; }
.ds-ai__tripcol { display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-ai__trips { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 0.8rem; }
.ds-ai__trip { display: flex; flex-direction: column; gap: 0.6rem; padding: 0.9rem; border-radius: 1rem; background: var(--ai-surf); box-shadow: 0 0 0 1px var(--ai-line); }
.ds-ai__trip.is-over { box-shadow: 0 0 0 1.5px var(--ai-bad); }
.ds-ai__select.is-full { flex: none; width: 100%; }
.ds-ai__dest { display: flex; align-items: center; gap: 0.5rem; font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__dest .ds-ai__select { flex: 1; }
.ds-ai__fill { display: flex; justify-content: space-between; font-size: 0.85rem; font-variant-numeric: tabular-nums; }
.ds-ai__meter { display: block; height: 0.45rem; border-radius: 999px; background: var(--ai-raised); overflow: hidden; }
.ds-ai__meter s { display: block; height: 100%; border-radius: 999px; background: var(--ai-ok); text-decoration: none; }
.ds-ai__meter s.is-warn { background: #e0a400; } .ds-ai__meter s.is-bad { background: var(--ai-bad); }
.ds-ai__place { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; padding: 0.45rem 0.65rem; border-radius: 0.6rem; background: var(--ai-raised); text-align: left; font-size: 0.85rem; color: var(--ai-text); }
.ds-ai__place:hover { box-shadow: inset 0 0 0 1px var(--ai-violet); }
.ds-ai__place > span:first-child { display: flex; flex-direction: column; min-width: 0; }
.ds-ai__place small { color: var(--ai-muted); font-size: 0.72rem; }
.ds-ai__place > span:last-child { color: var(--ai-muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
.ds-ai__why1 { color: var(--ai-violet); font-size: 0.78rem; line-height: 1.4; }
.dark .ds-ai__why1 { color: #b9a8ff; }
.ds-ai__chipbtn { height: 1.9rem; padding: 0 0.7rem; border-radius: 999px; background: var(--ai-raised); font-size: 0.8rem; font-weight: 700; color: var(--ai-text); }
.ds-ai__chipbtn.is-prio { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__made { display: flex; align-items: center; gap: 0.8rem; }
.ds-ai__made > span:first-child { width: 2.6rem; height: 2.6rem; border-radius: 50%; background: var(--ai-ok); color: #fff; display: grid; place-items: center; font-size: 1.2rem; font-weight: 900; }
.ds-ai__made > span:last-child { display: flex; flex-direction: column; }
.ds-ai__made b { font-size: 1.15rem; } .ds-ai__made small { color: var(--ai-muted); }
.ds-ai__madeRow { display: grid; grid-template-columns: 8rem 9rem 1fr auto; gap: 0.8rem; align-items: center; padding: 0.6rem 0.8rem; border-radius: 0.7rem; background: var(--ai-raised); font-size: 0.9rem; }
.ds-ai__madeRow small { grid-column: 1 / -1; }
.ds-ai__card.ds-ai__foot { flex-direction: row; flex-wrap: wrap; align-items: center; }
.ds-ai__card.ds-ai__foot > span { flex: 1 1 20rem; }
/* Box aging */
.ds-ag .ds-ai__stats > button { text-align: left; background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 0.85rem 1rem; display: flex; flex-direction: column; gap: 0.15rem; color: inherit; }
.ds-ag .ds-ai__stats > button:hover { box-shadow: 0 0 0 1.5px var(--ai-violet); }
.ds-ai__said > span:last-child > span { display: block; }
.ds-ag__table { padding: 0; gap: 0; overflow: auto; }
.ds-ag__tr { display: grid; grid-template-columns: minmax(15rem, 1.6fr) repeat(4, minmax(5rem, 1fr)) 6rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid var(--ai-line); min-width: 44rem; }
.ds-ag__tr.is-head { border-top: 0; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); }
.ds-ag__tr > span { display: flex; flex-direction: column; } .ds-ag__tr > span:not(:first-child) { align-items: center; }
.ds-ag__tr small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ag__cell { min-width: 3.4rem; height: 2rem; border-radius: 0.55rem; font-weight: 800; font-variant-numeric: tabular-nums; }
.ds-ag__cell.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ag__cell.is-warn { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ag__cell.is-late { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ag__cell.is-zero { color: var(--ai-muted); opacity: 0.45; }
.ds-ag__cell.is-sel { box-shadow: 0 0 0 2px var(--ai-text); }
.ds-ag__late { text-align: right; font-size: 1.1rem; font-variant-numeric: tabular-nums; }
.ds-ag__box { display: grid; grid-template-columns: 6.5rem 1fr 4.5rem; gap: 0.6rem; align-items: center; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: var(--ai-raised); font-size: 0.85rem; }
.ds-ag__box > span:nth-child(2) { display: flex; flex-direction: column; min-width: 0; }
.ds-ag__box small { color: var(--ai-muted); font-size: 0.72rem; }
.ds-ag__age { display: flex; flex-direction: column; align-items: flex-end; font-weight: 800; font-variant-numeric: tabular-nums; }
.ds-ag__age.is-late { color: var(--ai-bad); } .ds-ag__age.is-warn { color: var(--ai-warn); } .ds-ag__age.is-ok { color: var(--ai-ok); }
.ds-ag__bar { display: grid; grid-template-columns: 1fr 10rem 4.5rem; gap: 0.6rem; align-items: center; font-size: 0.85rem; }
.ds-ag__bar small { color: var(--ai-muted); }
.ds-ag__bar i { display: flex; height: 0.6rem; border-radius: 999px; overflow: hidden; background: var(--ai-raised); }
.ds-ag__bar s { display: block; height: 100%; text-decoration: none; }
.ds-ag__bar s.is-ok { background: #34c38f; } .ds-ag__bar s.is-warn { background: #f0a93b; } .ds-ag__bar s.is-late { background: #d9534a; }
.ds-ag__bar b { text-align: right; font-size: 0.8rem; }
.ds-agl__tr { display: grid; grid-template-columns: minmax(14rem, 1.5fr) 6rem 9rem 9rem minmax(14rem, 2fr); gap: 0.7rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid var(--ai-line); min-width: 56rem; }
.ds-agl__tr.is-head { border-top: 0; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); }
.ds-agl__tr.is-changed { background: var(--ai-warn-soft); }
.ds-agl__tr > span:first-child { display: flex; flex-direction: column; } .ds-agl__tr small { color: var(--ai-muted); font-size: 0.75rem; }
.ds-agl__num { display: flex; align-items: center; gap: 0.35rem; }
.ds-agl__num button { width: 1.7rem; height: 1.7rem; border-radius: 0.45rem; background: var(--ai-raised); font-weight: 800; }
.ds-agl__num b { min-width: 3.4rem; text-align: center; font-variant-numeric: tabular-nums; }
.ds-agl__why { font-size: 0.78rem; color: var(--ai-violet); line-height: 1.4; }
.dark .ds-agl__why { color: #b9a8ff; }
.ds-ai .ds-gm__field input { height: 2.4rem; padding: 0 0.7rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); }
/* Install QR codes */
.ds-qr { display: flex; flex-direction: column; gap: 0.8rem; }
.ds-qr__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(24rem, 1fr)); gap: 1rem; }
.ds-qr.is-compact .ds-qr__grid { grid-template-columns: repeat(auto-fit, minmax(20rem, 1fr)); }
.ds-qr__card { display: flex; gap: 1rem; align-items: center; padding: 1rem; border-radius: 1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; }
.dark .ds-qr__card { background: rgb(255 255 255 / 0.04); box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-qr__code { flex: none; padding: 10px; border-radius: 0.8rem; background: #fff; box-shadow: inset 0 0 0 1px #e6ebef; line-height: 0; }
.ds-qr__code svg { display: block; }
.ds-qr.is-off .ds-qr__code { opacity: 0.25; filter: grayscale(1); }
.ds-qr__info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.5rem; }
.ds-qr__title { display: flex; align-items: center; gap: 0.6rem; }
.ds-qr__title img { width: 36px; height: 36px; border-radius: 9px; }
.ds-qr__title b { font-size: 1.1rem; }
.ds-qr__info small { color: #5b6b78; font-size: 0.82rem; line-height: 1.45; }
.dark .ds-qr__info small { color: #93a6b4; }
.ds-qr__link { display: flex; align-items: center; gap: 0.5rem; padding: 0.4rem 0.4rem 0.4rem 0.7rem; border-radius: 0.6rem; background: #f3f5f7; }
.dark .ds-qr__link { background: rgb(255 255 255 / 0.06); }
.ds-qr__link code { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.8rem; }
.ds-qr__link button { padding: 0.25rem 0.6rem; border-radius: 0.45rem; background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; font-size: 0.75rem; font-weight: 700; color: #0e2433; }
.ds-qr__info ol { margin: 0; padding-left: 1.1rem; font-size: 0.82rem; line-height: 1.6; }
.ds-qr__actions { display: flex; flex-wrap: wrap; gap: 0.4rem; }
.ds-qr__actions a { padding: 0.45rem 0.8rem; border-radius: 0.6rem; background: #eef1f4; color: #0e2433; font-size: 0.82rem; font-weight: 700; text-decoration: none; }
.ds-qr__actions a.is-main { background: #d4a72c; color: #1d1600; }
.dark .ds-qr__actions a:not(.is-main) { background: rgb(255 255 255 / 0.08); color: #e9eff3; }
.ds-qr__warn { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: #fde8e6; color: #8f2a22; font-size: 0.85rem; }
.ds-qr__warn.is-amber { background: #fff2d9; color: #7a5200; }
.ds-qr__ok { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: #e5f6ee; color: #0f5c3f; font-size: 0.85rem; }
.ds-qr__note { color: #8a99a5; font-size: 0.78rem; }
.ds-qr__hide { font-size: 0.8rem; font-weight: 700; color: #5b6b78; }
.ds-qr-set { display: flex; flex-direction: column; gap: 0.8rem; }
.ds-qr-set__base { display: flex; gap: 0.6rem; align-items: flex-end; flex-wrap: wrap; }
.ds-qr-set__base .ds-gm__field { flex: 1 1 24rem; }
.ds-qr-set__base input { height: 2.5rem; padding: 0 0.7rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; width: 100%; }
.ds-qr__info ol { list-style: decimal; }

/* ============================================================ Maps & routes */
.ds-mp { display: flex; flex-direction: column; gap: 1rem; }
.ds-mp__chain { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.6rem; }
.ds-mp__step { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.75rem; border-radius: 0.8rem; background: #f3f5f7; color: #5b6b78; }
.ds-mp__step.is-on { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__stephead { display: flex; align-items: center; gap: 0.5rem; font-size: 0.9rem; }
.ds-mp__stephead i { width: 1.5rem; height: 1.5rem; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-style: normal; font-size: 0.75rem; font-weight: 900; color: #fff; background: #c9d1d8; }
.ds-mp__step.is-on .ds-mp__stephead i { background: #17895e; }
.ds-mp__step strong { font-size: 0.85rem; }
.ds-mp__step small { font-size: 0.78rem; line-height: 1.4; opacity: .85; }
.ds-mp__warn { margin: 0; padding: 0.5rem 0.75rem; border-radius: 0.6rem; background: #fff1d6; color: #7a5200; font-size: 0.85rem; }
.ds-mp__providers { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.75rem; }
.ds-mp__provider { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.9rem; border-radius: 0.9rem; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e6ebef; text-align: left; }
.ds-mp__provider.is-picked { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-mp__provhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
.ds-mp__provhead em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; background: #eef1f4; color: #6b7b88; }
.ds-mp__provhead em.is-on { background: #17895e; color: #fff; }
.ds-mp__provider small { font-size: 0.8rem; color: #5b6b78; line-height: 1.45; }
.ds-mp__provider code { font-size: 0.75rem; color: #33424e; }
.ds-mp__keyrow { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-mp__keyrow input, .ds-mp__testaddr input, .ds-mp__starts input, .ds-mp__fix input { flex: 1; min-width: 12rem; height: 2.5rem; padding: 0 0.75rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.9rem; }
.ds-mp__testaddr { display: flex; align-items: center; gap: 0.6rem; font-size: 0.85rem; color: #5b6b78; }
.ds-mp__result { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fde8e6; color: #8c1d18; font-size: 0.85rem; }
.ds-mp__result.is-ok { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__two { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
.ds-mp__two.is-one { grid-template-columns: minmax(0, 40rem); }
.ds-mp__toggle { align-self: flex-start; height: 2.3rem; padding: 0 0.9rem; border-radius: 0.6rem; font-weight: 800; font-size: 0.85rem; background: #eef1f4; color: #5b6b78; }
.ds-mp__toggle.is-on { background: #e5f6ee; color: #17895e; }
.ds-mp__starts { display: flex; flex-direction: column; gap: 0.45rem; }
.ds-mp__starts label { display: flex; align-items: center; gap: 0.6rem; font-size: 0.85rem; }
.ds-mp__starts label > span { width: 45%; font-weight: 700; }
.ds-mp__starts small { font-weight: 400; color: #8a99a5; }
.ds-mp__stats { display: flex; flex-wrap: wrap; gap: 0.5rem 1.5rem; font-size: 0.85rem; }
.ds-mp__stats small { color: #8a99a5; }
.ds-mp__fix { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-mp__fix > div { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; padding: 0.5rem 0.6rem; border-radius: 0.6rem; background: #f6f8fa; }
.ds-mp__fix > div > span { flex: 2; min-width: 14rem; display: flex; flex-direction: column; font-size: 0.85rem; }
.ds-mp__fix small { color: #6b7b88; }
.ds-mp__fix input { flex: 1; }

.ds-mp__badges { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-mp__badges > span:not(.ds-mp__badgeactions) { padding: 0.45rem 0.75rem; border-radius: 0.6rem; font-size: 0.82rem; font-weight: 700; background: #eef1f4; }
.ds-mp__badges .is-ok { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__badges .is-ai { background: #f2efff; color: #4b3aa8; }
.ds-mp__badges .is-warn { background: #fff1d6; color: #7a5200; }
.ds-mp__badgeactions { margin-left: auto; display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-mp__truck { flex-direction: row; align-items: stretch; gap: 0; padding: 0.75rem; }
.ds-mp__cab { width: 4rem; border-radius: 1rem 0.3rem 0.3rem 1rem; background: #0e2433; color: #f6be00; font-size: 0.75rem; font-weight: 900; display: flex; align-items: center; justify-content: center; }
.ds-mp__zone { flex: 1; display: flex; flex-direction: column; justify-content: center; gap: 0.15rem; padding: 0.6rem 0.8rem; min-height: 4.5rem; box-shadow: inset -2px 0 0 #fff; }
.ds-mp__zone b { font-size: 0.9rem; }
.ds-mp__zone small { font-size: 0.75rem; opacity: .85; }
.ds-mp__zone.is-front { background: #e7f0fb; color: #1f5f9e; }
.ds-mp__zone.is-middle { background: #f2efff; color: #4b3aa8; }
.ds-mp__zone.is-back { background: #fff1d6; color: #8a5a00; }
.ds-mp__door { width: 3.5rem; display: flex; align-items: center; justify-content: center; font-size: 0.7rem; font-weight: 800; color: #6b7b88; border-left: 4px dashed #0e2433; }
.ds-mp__grid { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(0, 1fr); gap: 1rem; align-items: start; }
.ds-mp__map { height: 30rem; border-radius: 0.8rem; overflow: hidden; background: #e8eef2; z-index: 0; }
.ds-mp__legend { margin: 0; display: flex; flex-wrap: wrap; gap: 0.4rem 1rem; font-size: 0.75rem; color: #5b6b78; }
.ds-mp__legend .is-ok { color: #17895e; } .ds-mp__legend .is-area { color: #9a6400; } .ds-mp__legend .is-prio { color: #b3261e; }
.ds-mp__stops { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 0.4rem; }
.ds-mp__stops li { display: grid; grid-template-columns: 1rem 1.8rem minmax(0, 1fr) auto auto auto auto; gap: 0.5rem; align-items: center; padding: 0.5rem 0.6rem; border-radius: 0.6rem; background: #f6f8fa; }
.ds-mp__stops li.is-over { box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-mp__grab { color: #a8b3bb; cursor: grab; }
.ds-mp__no { width: 1.7rem; height: 1.7rem; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-weight: 900; font-size: 0.78rem; }
.ds-mp__who { font-size: 0.85rem; min-width: 0; }
.ds-mp__tags { display: flex; gap: 0.25rem; flex-wrap: wrap; margin-top: 0.15rem; }
.ds-mp__tags em { font-style: normal; padding: 0 0.45rem; border-radius: 999px; font-size: 0.68rem; font-weight: 800; }
.ds-mp__tags .is-prio { background: #fde8e6; color: #b3261e; }
.ds-mp__tags .is-warn, .ds-mp__tags .is-area { background: #fff1d6; color: #9a6400; }
.ds-mp__n { font-size: 0.8rem; white-space: nowrap; }
.ds-mp__spot { padding: 0.15rem 0.55rem; border-radius: 999px; font-size: 0.7rem; font-weight: 900; }
.ds-mp__spot.is-front { background: #e7f0fb; color: #1f5f9e; } .ds-mp__spot.is-middle { background: #f2efff; color: #4b3aa8; } .ds-mp__spot.is-back { background: #fff1d6; color: #8a5a00; }
.ds-mp__load { font-size: 0.75rem; font-weight: 800; color: #1f6fa5; white-space: nowrap; }
.ds-mp__updown { display: flex; flex-direction: column; }
.ds-mp__updown button { font-size: 0.6rem; line-height: 1; padding: 0.1rem 0.3rem; color: #6b7b88; }
.ds-mp__updown button:disabled { opacity: .25; }
.ds-map__pin { display: flex !important; align-items: center; justify-content: center; border-radius: 50%; color: #fff; font: 900 13px/1 Archivo, sans-serif; border: 3px solid #fff; box-shadow: 0 1px 4px rgb(0 0 0 / .35); background: #17895e; }
.ds-map__pin.is-area { background: #f0a93b; } .ds-map__pin.is-prio { background: #d9534a; }
.ds-map__pin.is-start { border-radius: 0.5rem; background: #0e2433; color: #f6be00; font-size: 11px; }
.dark .ds-mp__step, .dark .ds-mp__provider, .dark .ds-mp__stops li, .dark .ds-mp__fix > div { background: rgb(255 255 255 / 0.05); color: #e6edf3; box-shadow: none; }
.dark .ds-mp__step.is-on { background: rgb(23 137 94 / .2); color: #8ee0bd; }
.dark .ds-mp__provider.is-picked { box-shadow: inset 0 0 0 2px #d4a72c; }
.dark .ds-mp__keyrow input, .dark .ds-mp__testaddr input, .dark .ds-mp__starts input, .dark .ds-mp__fix input { background: rgb(255 255 255 / .06); color: #e6edf3; box-shadow: inset 0 0 0 1px rgb(255 255 255 / .15); }
@media (max-width: 1024px) { .ds-mp__grid, .ds-mp__two, .ds-mp__chain, .ds-mp__providers { grid-template-columns: 1fr; } }

/* Load truck: what to load next, and "too early" */
.ds-ld__next { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.8rem 0.9rem; border-radius: 0.9rem; background: #eef4fb; box-shadow: inset 0 0 0 1px #c8dcf2; color: #0e2433; }
.ds-ld__next small { font-size: 0.72rem; font-weight: 800; letter-spacing: .04em; color: #1f5f9e; }
.ds-ld__next small b { padding: 0 0.4rem; border-radius: 999px; background: #1f5f9e; color: #fff; }
.ds-ld__next small b.is-middle { background: #4b3aa8; } .ds-ld__next small b.is-back { background: #8a5a00; }
.ds-ld__next strong { font-size: 1.15rem; }
.ds-ld__next > span { font-size: 0.85rem; opacity: .85; }
.ds-ld__bar { display: flex; gap: 0.25rem; margin-top: 0.2rem; }
.ds-ld__bar i { flex: 1; height: 0.45rem; border-radius: 999px; background: rgb(14 36 51 / .12); }
.ds-ld__bar i.is-done { background: #34c38f; } .ds-ld__bar i.is-now { background: #3b8fe0; }
.ds-ld__ends { display: flex; justify-content: space-between; font-size: 0.68rem; opacity: .7; }
.ds-ld__next.is-dark { position: absolute; top: calc(env(safe-area-inset-top) + 5.2rem); left: 1rem; right: 1rem; z-index: 3; background: rgb(10 18 25 / .82); box-shadow: inset 0 0 0 1px rgb(140 196 255 / .35); color: #eef3f6; backdrop-filter: blur(8px); }
.ds-ld__next.is-dark small { color: #8cc4ff; }
.ds-ld__next.is-dark .ds-ld__bar i { background: rgb(255 255 255 / .14); }
.ds-ld__next.is-dark .ds-ld__bar i.is-done { background: #34c38f; } .ds-ld__next.is-dark .ds-ld__bar i.is-now { background: #8cc4ff; }
.ds-ld__early { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem 0.8rem; padding: 0.7rem 0.9rem; border-radius: 0.8rem; background: #fff1d6; color: #7a5200; font-size: 0.9rem; }
.ds-ld__kicker { display: block; font-size: 0.72rem; font-weight: 900; letter-spacing: .06em; color: #f3c98a; }
.ds-ld__spot { display: flex; align-items: baseline; gap: 0.6rem; padding: 0.55rem 0.8rem; border-radius: 0.8rem; background: rgb(140 196 255 / .14); color: #8cc4ff; }
.ds-ld__spot strong { font-size: 1.4rem; font-weight: 900; letter-spacing: .02em; }
.ds-ld__spot span { font-size: 0.85rem; color: #c9d5dc; }
.ds-ld__spot.is-middle { background: rgb(176 160 255 / .14); color: #c2b6ff; }
.ds-ld__spot.is-back { background: rgb(240 169 59 / .14); color: #f3c98a; }

/* Driver app: your stops and Navigate */
.ds-nav { display: contents; }
.ds-nav__next { display: flex; align-items: center; gap: 0.7rem; padding: 0.8rem 0.9rem; border-radius: 1rem; background: rgb(246 190 0 / .1); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .35); }
.ds-nav__next > span { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.ds-nav__next small { font-size: 0.75rem; color: #f6d36b; font-weight: 700; }
.ds-nav__next strong { font-size: 1rem; }
.ds-nav__next em { font-style: normal; font-size: 0.8rem; color: #a9b8c2; }
.ds-nav__next button { height: 2.5rem; padding: 0 1rem; border-radius: 0.7rem; background: var(--sa-gold, #f6be00); color: #0a1219; font-weight: 800; }
.ds-nav__row { gap: 0.7rem; }
.ds-nav__no { width: 2rem; height: 2rem; flex: none; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: 900; font-size: 0.85rem; background: rgb(255 255 255 / .1); }
.ds-nav__no.is-next { background: #f6be00; color: #0a1219; }
.ds-nav__no.is-prio { box-shadow: 0 0 0 2px #d9534a; }
.ds-nav__who { flex: 1; padding: 0; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; text-align: left; }
.ds-nav__go { height: 2.1rem; padding: 0 0.75rem; border-radius: 0.6rem; background: rgb(140 196 255 / .14); color: #8cc4ff; font-size: 0.8rem; font-weight: 800; }
.ds-nav__hint { margin: 0; font-size: 0.78rem; color: #7f93a1; text-align: center; }
.ds-nav__hint button { color: #8cc4ff; font-weight: 700; }
.ds-nav__veil { position: fixed; inset: 0; z-index: 60; background: rgb(0 0 0 / .55); display: flex; align-items: flex-end; }
.ds-nav__sheet { width: 100%; max-width: 32rem; margin: 0 auto; padding: 1rem 1.1rem 1.6rem; border-radius: 1.6rem 1.6rem 0 0; background: #101c25; color: #eef3f6; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-nav__sheet > small { font-size: 0.75rem; color: #7f93a1; }
.ds-nav__sheet > strong { font-size: 1.3rem; }
.ds-nav__addr { font-size: 0.9rem; color: #c9d5dc; line-height: 1.45; }
.ds-nav__chips { display: flex; gap: 0.4rem; flex-wrap: wrap; }
.ds-nav__chips em { font-style: normal; padding: 0.2rem 0.6rem; border-radius: 999px; background: rgb(255 255 255 / .08); font-size: 0.78rem; }
.ds-nav__ask { margin-top: 0.3rem; font-size: 0.85rem; }
.ds-nav__app { display: flex; align-items: center; gap: 0.75rem; height: 3.6rem; padding: 0 0.9rem; border-radius: 0.9rem; background: rgb(255 255 255 / .07); color: #fff; text-align: left; font-size: 1.2rem; }
.ds-nav__app > span { flex: 1; display: flex; flex-direction: column; font-size: 1rem; }
.ds-nav__app small { font-size: 0.75rem; color: #a9b8c2; }
.ds-nav__app i { width: 2.4rem; height: 2.4rem; flex: none; border-radius: 0.7rem; display: flex; align-items: center; justify-content: center; font-style: normal; font-weight: 900; font-size: 1.1rem; }
.ds-nav__app .is-waze { background: #33ccff; color: #0a1219; } .ds-nav__app .is-google { background: #fff; color: #1a73e8; } .ds-nav__app .is-apple { background: #e9eef2; color: #0e2433; }
.ds-nav__remember { display: flex; align-items: center; gap: 0.5rem; font-size: 0.82rem; color: #a9b8c2; }
.ds-nav__two { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.ds-nav__soft { height: 2.8rem; border-radius: 0.8rem; background: rgb(140 196 255 / .12); color: #8cc4ff; font-weight: 800; font-size: 0.88rem; display: flex; align-items: center; justify-content: center; }
.ds-nav__soft.is-warn { background: rgb(240 169 59 / .14); color: #f3c98a; }
.ds-nav__back { display: flex; flex-direction: column; gap: 0.5rem; padding: 1rem; border-radius: 1.2rem; background: rgb(52 195 143 / .1); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .4); }
.ds-nav__back small { font-size: 0.78rem; font-weight: 800; color: #6fe0b5; }
.ds-nav__back strong { font-size: 1.2rem; }
.ds-nav__back > span { font-size: 0.85rem; color: #c9d5dc; }
.ds-nav__link { font-size: 0.8rem; color: #7f93a1; }

/* ============================================================ Truck tracking */
.ds-tm { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-tm__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-tm__tabs { display: inline-flex; gap: 0.25rem; padding: 0.25rem; border-radius: 0.75rem; background: #e6ebef; }
.ds-tm__tabs button { height: 2rem; padding: 0 0.9rem; border-radius: 0.55rem; font-size: 0.82rem; font-weight: 800; color: #5b6b78; }
.ds-tm__tabs button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 2px rgb(0 0 0 / .12); }
.ds-mp__badges .is-bad { background: #fde8e6; color: #8c1d18; }
.ds-tm__grid { display: grid; grid-template-columns: minmax(0, 1fr) 22rem; gap: 0.9rem; align-items: start; }
.ds-tm__map { height: 36rem; border-radius: 0.8rem; overflow: hidden; background: #e8eef2; z-index: 0; }
.ds-tm__map.is-small { height: 30rem; }
.ds-tm__side { display: flex; flex-direction: column; gap: 0.75rem; min-width: 0; }
.ds-tm__list { padding: 0.5rem; gap: 0.3rem; max-height: 22rem; overflow: auto; }
.ds-tm__row { display: flex; flex-direction: column; align-items: flex-start; gap: 0.15rem; width: 100%; padding: 0.55rem 0.65rem; border-radius: 0.6rem; background: #f6f8fa; text-align: left; }
.ds-tm__row.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-tm__row > span { display: flex; justify-content: space-between; gap: 0.5rem; width: 100%; font-size: 0.85rem; }
.ds-tm__row small { font-size: 0.75rem; color: #5b6b78; }
.ds-tm em.is-ok, .ds-tm em.is-warn, .ds-tm em.is-bad { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; white-space: nowrap; }
.ds-tm em.is-ok { background: #e5f6ee; color: #17895e; } .ds-tm em.is-warn { background: #fff1d6; color: #9a6400; } .ds-tm em.is-bad { background: #fde8e6; color: #b3261e; }
.ds-tm__cardhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 0.95rem; }
.ds-tm__crew { font-size: 0.82rem; color: #33424e; }
.ds-tm__facts { display: grid; grid-template-columns: 1fr 1fr; gap: 0.4rem; }
.ds-tm__facts span { display: flex; flex-direction: column; padding: 0.5rem 0.6rem; border-radius: 0.55rem; background: #f6f8fa; font-size: 0.72rem; color: #6b7b88; }
.ds-tm__facts b { font-size: 0.82rem; color: #0e2433; }
.ds-tm__btns { display: flex; gap: 0.4rem; flex-wrap: wrap; }
.ds-tm__replay { display: flex; align-items: center; gap: 0.7rem; padding: 0.2rem 0.3rem; }
.ds-tm__replay button { width: 2.1rem; height: 2.1rem; border-radius: 50%; background: #0e2433; color: #fff; flex: none; }
.ds-tm__replay input { flex: 1; accent-color: #1f6fa5; }
.ds-tm__replay small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__who { display: flex; align-items: center; gap: 0.8rem; }
.ds-tm__who b { font-size: 1.15rem; }
.ds-tm__who small { color: #5b6b78; font-size: 0.82rem; }
.ds-tm__who small b { font-size: 0.82rem; color: #0e2433; }
.ds-tm__icon { width: 3rem; height: 3rem; border-radius: 0.9rem; background: #0e2433; display: grid; place-items: center; font-size: 1.4rem; flex: none; }
.ds-tm__stats { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 0.5rem; }
.ds-tm__stats.is-four { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.ds-tm__stats > span { padding: 0.65rem 0.8rem; gap: 0.1rem; }
.ds-tm__stats small { font-size: 0.72rem; color: #6b7b88; }
.ds-tm__stats b { font-size: 1.2rem; }
.ds-tm__stats b.is-ok { color: #17895e; }
.ds-tm__stats em { font-style: normal; font-size: 0.7rem; color: #8a99a5; }
.ds-tm__now { margin: 0; font-size: 0.85rem; line-height: 1.6; }
.ds-tm__events { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; }
.ds-tm__events li { display: grid; grid-template-columns: 2.6rem 0.8rem 1fr; gap: 0.5rem; align-items: start; min-height: 2rem; font-size: 0.8rem; line-height: 1.35; }
.ds-tm__events small { color: #6b7b88; font-size: 0.75rem; }
.ds-tm__events i { width: 0.7rem; height: 0.7rem; margin-top: 0.2rem; border-radius: 50%; background: #c9d1d8; box-shadow: 0 0 0 3px #fff; }
.ds-tm__events .is-start i { background: #0e2433; } .ds-tm__events .is-ok i { background: #17895e; } .ds-tm__events .is-warn i { background: #f0a93b; }
.ds-tm__events .is-bad i { background: #d9534a; } .ds-tm__events .is-now i { background: #1f6fa5; }
.ds-tm__table { display: flex; flex-direction: column; gap: 0.35rem; }
.ds-tm__table > div { display: grid; grid-template-columns: 6rem 6rem 9rem 4rem 5rem 5.5rem minmax(0, 1fr) 5.5rem; gap: 0.5rem; align-items: center; padding: 0.55rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; font-size: 0.82rem; }
.ds-tm__table > div.is-head { background: none; font-size: 0.72rem; font-weight: 800; color: #6b7b88; padding-top: 0; padding-bottom: 0; }
.ds-tm__table > div.is-sel { box-shadow: inset 0 0 0 2px #1f6fa5; }
.ds-tm__table .is-ok { color: #17895e; font-weight: 800; } .ds-tm__table .is-warn { color: #9a6400; font-weight: 800; }
.ds-tm__table small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__table button { color: #1f6fa5; font-weight: 800; font-size: 0.8rem; }
.ds-tm__alerts { display: flex; flex-direction: column; gap: 0.45rem; }
.ds-tm__alerts > div { display: flex; align-items: center; gap: 0.7rem; flex-wrap: wrap; padding: 0.65rem 0.75rem; border-radius: 0.7rem; background: #f6f8fa; }
.ds-tm__aicon { font-size: 1.1rem; }
.ds-tm__atext { flex: 1; min-width: 14rem; display: flex; flex-direction: column; gap: 0.1rem; font-size: 0.85rem; }
.ds-tm__atext small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__when { color: #6b7b88; font-size: 0.75rem; white-space: nowrap; }
.ds-tm__alerts input { height: 2.1rem; min-width: 12rem; padding: 0 0.6rem; border-radius: 0.5rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.8rem; }
.ds-tm__srcs { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.4rem; }
.ds-tm__srcs label, .ds-tm__form label { display: flex; justify-content: space-between; align-items: center; gap: 0.6rem; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; font-size: 0.85rem; }
.ds-tm__srcs small { color: #8a99a5; }
.ds-tm__srcs select, .ds-tm__form select, .ds-tm__form input { height: 2.1rem; padding: 0 0.5rem; border-radius: 0.5rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.82rem; }
.ds-tm__form .is-ok, .ds-tm__srcs .is-ok { color: #17895e; }
.ds-tm__link { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.75rem; border-radius: 0.7rem; background: #f3f5f7; font-size: 0.82rem; }
.ds-tm__link code { font-size: 0.75rem; word-break: break-all; }
.ds-tm__pin { display: flex !important; align-items: center; justify-content: center; border-radius: 999px; color: #fff; font: 900 12px/1 Archivo, sans-serif; border: 2px solid #fff; box-shadow: 0 1px 4px rgb(0 0 0 / .35); background: #0e2433; white-space: nowrap; }
.ds-tm__pin.is-done { background: #17895e; } .ds-tm__pin.is-mark { background: #f0a93b; }
.ds-tm__pin.is-start { border-radius: 0.5rem; color: #f6be00; font-size: 11px; }
.ds-tm__pin.is-truck { padding: 0 0.5rem; font-size: 12px; }
.ds-tm__pin.is-truck.is-warn { background: #9a6400; } .ds-tm__pin.is-truck.is-bad { background: #b3261e; }
.ds-tm__pin.is-truck.is-sel { box-shadow: 0 0 0 3px #f6be00, 0 2px 6px rgb(0 0 0 / .3); z-index: 1000 !important; }
.ds-tm__pin.is-ghost { background: #1f6fa5; font-size: 16px; }
.dark .ds-tm__row, .dark .ds-tm__facts span, .dark .ds-tm__table > div:not(.is-head), .dark .ds-tm__alerts > div, .dark .ds-tm__srcs label, .dark .ds-tm__form label, .dark .ds-tm__link { background: rgb(255 255 255 / .05); color: #e6edf3; }
.dark .ds-tm__facts b { color: #e6edf3; }
@media (max-width: 1100px) { .ds-tm__grid { grid-template-columns: 1fr; } .ds-tm__stats { grid-template-columns: repeat(3, 1fr); } .ds-tm__table > div { grid-template-columns: repeat(4, 1fr); } }

/* Driver app: tracking */
.ds-trk__ask { display: flex; flex-direction: column; gap: 0.7rem; margin: 0 0 1rem; padding: 1.2rem; border-radius: 1.5rem; background: rgb(140 196 255 / .07); box-shadow: inset 0 0 0 1px rgb(140 196 255 / .25); }
.ds-trk__pin { width: 3.2rem; height: 3.2rem; border-radius: 1rem; background: rgb(140 196 255 / .14); display: grid; place-items: center; font-size: 1.5rem; }
.ds-trk__ask strong { font-size: 1.35rem; letter-spacing: -0.02em; }
.ds-trk__ask p { margin: 0; font-size: 0.9rem; color: #c9d5dc; line-height: 1.5; }
.ds-trk__ask ul { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 0.4rem; }
.ds-trk__ask li { display: flex; gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 0.8rem; background: rgb(255 255 255 / .05); font-size: 0.85rem; }
.ds-trk__ask li b { color: #6fe0b5; } .ds-trk__ask li i { color: #8cc4ff; font-style: normal; font-weight: 900; }
.ds-trk__ask small { font-size: 0.75rem; color: #7f93a1; text-align: center; }
.ds-trk__bar { display: flex; align-items: center; gap: 0.6rem; width: 100%; margin: 0 0 0.8rem; padding: 0.55rem 0.8rem; border-radius: 0.9rem; background: rgb(52 195 143 / .1); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .35); text-align: left; color: inherit; }
.ds-trk__bar i { width: 0.6rem; height: 0.6rem; flex: none; border-radius: 50%; background: #34c38f; box-shadow: 0 0 0 4px rgb(52 195 143 / .2); }
.ds-trk__bar > span { display: flex; flex-direction: column; }
.ds-trk__bar b { font-size: 0.82rem; } .ds-trk__bar small { font-size: 0.72rem; color: #a9b8c2; }
.ds-trk__bar.is-off { background: rgb(240 169 59 / .1); box-shadow: inset 0 0 0 1px rgb(240 169 59 / .4); }
.ds-trk__bar.is-off i { background: #f0a93b; box-shadow: 0 0 0 4px rgb(240 169 59 / .2); }

/* ============================================================ SMS + AI helpers */
.ds-sms__providers { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.ds-sms__fields { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: 0.6rem; }
.ds-sms__fields label { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.8rem; font-weight: 700; }
.ds-sms__fields small { font-weight: 400; }
.ds-sms__fields small.is-ok { color: #17895e; font-weight: 700; }
.ds-sms__fields input, .ds-sms__fields select, .ds-sms__test input, .ds-sms__text { height: 2.5rem; padding: 0 0.75rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.88rem; font-weight: 400; }
.ds-sms__test { display: inline-flex; gap: 0.4rem; margin-left: auto; }
.ds-sms__grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.15fr); gap: 1rem; align-items: start; }
.ds-sms__kind { display: flex; align-items: center; gap: 0.7rem; padding: 0.65rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; }
.ds-sms__kind.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-sms__kind > small { color: #6b7b88; font-size: 0.75rem; white-space: nowrap; }
.ds-sms__kindtext { flex: 1; display: flex; flex-direction: column; text-align: left; font-size: 0.88rem; }
.ds-sms__kindtext small { color: #5b6b78; font-size: 0.75rem; }
.ds-sms__switch { width: 2.5rem; height: 1.5rem; flex: none; padding: 0.15rem; border-radius: 999px; background: #c9d1d8; display: flex; justify-content: flex-start; }
.ds-sms__switch.is-on { background: #17895e; justify-content: flex-end; }
.ds-sms__switch i { width: 1.2rem; height: 1.2rem; border-radius: 50%; background: #fff; box-shadow: 0 1px 2px rgb(0 0 0 / .2); }
.ds-sms__text { height: auto; padding: 0.7rem 0.8rem; line-height: 1.5; font-family: ui-monospace, Menlo, monospace; resize: vertical; width: 100%; }
.ds-sms__blanks { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-sms__blanks em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; background: #f2efff; color: #4b3aa8; font-size: 0.7rem; font-weight: 800; }
.ds-sms__ai { display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: center; }
.ds-sms__ai button { height: 2.1rem; padding: 0 0.75rem; border-radius: 0.55rem; background: #f2efff; color: #4b3aa8; font-weight: 800; font-size: 0.8rem; }
.ds-sms__ai small { color: #6b7b88; font-size: 0.75rem; }
.ds-sms__ainote { display: flex; align-items: center; gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 0.65rem; background: #f2efff; color: #4b3aa8; font-size: 0.82rem; font-weight: 700; }
.ds-sms__ainote button { margin-left: auto; padding: 0.25rem 0.6rem; border-radius: 0.45rem; background: #fff; font-weight: 800; }
.ds-sms__checks { display: flex; flex-direction: column; gap: 0.3rem; }
.ds-sms__checks span { padding: 0.4rem 0.6rem; border-radius: 0.5rem; font-size: 0.8rem; }
.ds-sms__checks .is-ok { background: #e5f6ee; color: #0f5c3f; } .ds-sms__checks .is-warn { background: #fff1d6; color: #7a5200; }
.ds-sms__label { font-size: 0.82rem; margin-top: 0.3rem; }
.ds-sms__phone { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.8rem; border-radius: 1rem; background: #eef1f4; }
.ds-sms__phone small { text-align: center; font-size: 0.7rem; color: #6b7b88; }
.ds-sms__phone span { align-self: flex-start; max-width: 92%; padding: 0.6rem 0.75rem; border-radius: 1rem 1rem 1rem 0.3rem; background: #fff; font-size: 0.88rem; line-height: 1.45; color: #0e2433; }
.ds-sms__other { display: grid; grid-template-columns: 5rem 1fr; gap: 0.6rem; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; text-align: left; font-size: 0.8rem; }
.ds-sms__other span { color: #33424e; }
.ds-tm__stats.is-five { grid-template-columns: repeat(5, minmax(0, 1fr)); }
.ds-tm__stats b em { font-style: normal; font-size: 0.75rem; color: #6b7b88; font-weight: 400; }
.ds-tm__stats b.is-bad { color: #b3261e; }
.ds-tm__ainote { display: flex; flex-direction: column; gap: 0.1rem; margin-top: 0.3rem; padding: 0.5rem 0.65rem; border-radius: 0.55rem; background: #f2efff; color: #2c2470; font-size: 0.8rem; line-height: 1.45; }
.ds-tm__ainote small { color: #4b3aa8; font-weight: 800; font-size: 0.7rem; }
.ds-tm__aiacts { display: flex; flex-wrap: wrap; gap: 0.3rem; margin-top: 0.25rem; }
.ds-tm__aiacts i { font-style: normal; padding: 0.15rem 0.5rem; border-radius: 0.4rem; background: #eef1f4; font-size: 0.72rem; font-weight: 700; }
.ds-tm__daytext { background: #f2efff; }
.ds-tm__daytext small { color: #4b3aa8; font-weight: 800; font-size: 0.75rem; }
.ds-tm__daytext p { margin: 0; font-size: 0.98rem; line-height: 1.55; color: #2c2470; }
.ds-tm__daygrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 0.6rem; }
.ds-tm__daycard { display: flex; flex-direction: column; align-items: flex-start; gap: 0.25rem; padding: 0.8rem; border-radius: 0.9rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; text-align: left; }
.ds-tm__daycard.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-tm__daycard > span:first-child { display: flex; justify-content: space-between; width: 100%; }
.ds-tm__daycard small { color: #5b6b78; font-size: 0.78rem; }
.ds-tm__daycard em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; }
.ds-tm__daycard em.is-ok { background: #e5f6ee; color: #17895e; } .ds-tm__daycard em.is-mid { background: #eef4fb; color: #1f5f9e; } .ds-tm__daycard em.is-warn { background: #fff1d6; color: #9a6400; }
.ds-tm__daynums { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.25rem; width: 100%; margin-top: 0.2rem; }
.ds-tm__daynums i { font-style: normal; display: flex; flex-direction: column; padding: 0.35rem; border-radius: 0.45rem; background: #f6f8fa; font-size: 0.65rem; color: #6b7b88; }
.ds-tm__daynums b { font-size: 0.85rem; color: #0e2433; }
.ds-tm__aibox { margin: 0; display: flex; flex-direction: column; gap: 0.15rem; padding: 0.7rem 0.85rem; border-radius: 0.7rem; background: #f2efff; color: #2c2470; line-height: 1.55; }
.ds-tm__aibox small { color: #4b3aa8; font-weight: 800; font-size: 0.7rem; }
.ds-tm__goodbad { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-tm__goodbad span { display: flex; flex-direction: column; padding: 0.6rem 0.75rem; border-radius: 0.6rem; font-size: 0.82rem; line-height: 1.45; }
.ds-tm__goodbad .is-ok { background: #e5f6ee; color: #0f5c3f; } .ds-tm__goodbad .is-warn { background: #fff1d6; color: #7a5200; }
.dark .ds-sms__kind, .dark .ds-sms__other, .dark .ds-tm__daycard, .dark .ds-tm__daynums i { background: rgb(255 255 255 / .05); color: #e6edf3; box-shadow: none; }
.dark .ds-sms__fields input, .dark .ds-sms__fields select, .dark .ds-sms__test input, .dark .ds-sms__text { background: rgb(255 255 255 / .06); color: #e6edf3; }
@media (max-width: 1100px) { .ds-sms__grid, .ds-sms__providers { grid-template-columns: 1fr; } .ds-tm__stats.is-five { grid-template-columns: repeat(2, 1fr); } }

/* ============================== Help guide ============================== */
.ds-help { --h-ink: var(--ds-navy); --h-muted: #5b6b77; --h-card: #fff; --h-line: rgb(14 36 51 / 0.1); --h-soft: #f3f6f8; --h-accent: var(--ds-signal);
    display: flex; flex-direction: column; gap: 1rem; color: var(--h-ink); max-width: 60rem; }
.dark .ds-help { --h-ink: #e6edf3; --h-muted: #93a5b3; --h-card: #10283a; --h-line: rgb(255 255 255 / 0.09); --h-soft: rgb(255 255 255 / 0.04); }
.ds-help button { cursor: pointer; }
.ds-help__hero { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.ds-help__hero h1 { font-size: 1.75rem; font-weight: 800; letter-spacing: -0.02em; line-height: 1.15; margin: 0; }
.ds-help__hero p { margin: 0.3rem 0 0; color: var(--h-muted); }
.ds-help__lang { display: inline-flex; padding: 0.2rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); flex: none; }
.ds-help__lang button { padding: 0.3rem 0.8rem; border-radius: 999px; font-size: 0.8rem; font-weight: 700; color: var(--h-muted); }
.ds-help__lang button.is-on { background: var(--ds-navy); color: #fff; }
.dark .ds-help__lang button.is-on { background: var(--ds-signal); color: #0e2433; }
.ds-help__search { display: flex; align-items: center; gap: 0.5rem; padding: 0.4rem 0.4rem 0.4rem 0.9rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line), 0 6px 20px -12px rgb(14 36 51 / 0.35); }
.ds-help__search:focus-within { box-shadow: 0 0 0 2px var(--ds-signal), 0 6px 20px -12px rgb(14 36 51 / 0.35); }
.ds-help__search-icon { color: var(--h-muted); display: flex; }
.ds-help__search input { flex: 1; min-width: 0; border: 0; background: transparent; font-size: 1rem; padding: 0.55rem 0; color: inherit; outline: none; box-shadow: none; }
.ds-help__search input::-webkit-search-cancel-button { display: none; }
.ds-help__clear { width: 2rem; height: 2rem; border-radius: 50%; color: var(--h-muted); font-size: 1.2rem; }
.ds-help__ask { padding: 0.6rem 1.1rem; border-radius: 0.75rem; font-weight: 800; background: var(--ds-navy); color: #fff; white-space: nowrap; }
.dark .ds-help__ask { background: var(--ds-signal); color: #0e2433; }
.ds-help__tries { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem; margin: -0.25rem 0 0; font-size: 0.85rem; color: var(--h-muted); }
.ds-help__tries button { padding: 0.3rem 0.7rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); color: var(--h-ink); }
.ds-help__tries button:hover { box-shadow: inset 0 0 0 1px var(--ds-signal); }
.ds-help__ai { display: flex; gap: 0.85rem; align-items: flex-start; padding: 1rem 1.1rem; border-radius: 1rem; background: linear-gradient(120deg, rgb(246 190 0 / 0.16), rgb(246 190 0 / 0.04)); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.45); }
.ds-help__ai.is-off { background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); }
.ds-help__ai-icon { font-size: 1.4rem; line-height: 1; }
.ds-help__ai strong { display: block; font-weight: 800; }
.ds-help__ai p { margin: 0.2rem 0 0; color: var(--h-muted); font-size: 0.9rem; }
.ds-help__answer { padding: 1rem 1.1rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); }
.ds-help__answer.is-ai { box-shadow: inset 4px 0 0 var(--ds-signal), 0 0 0 1px var(--h-line); }
.ds-help__answer small { font-size: 0.75rem; font-weight: 800; color: var(--h-muted); }
.ds-help__answer p { margin: 0.35rem 0 0.6rem; font-size: 1.02rem; line-height: 1.5; }
.ds-help__answer-open { font-weight: 800; color: var(--ds-navy); text-decoration: underline; text-underline-offset: 3px; text-align: left; }
.dark .ds-help__answer-open { color: var(--ds-signal); }
.ds-help__results, .ds-help__related { display: flex; flex-direction: column; gap: 0.4rem; }
.ds-help h3 { font-size: 0.85rem; font-weight: 800; color: var(--h-muted); margin: 0.25rem 0; }
.ds-help__muted { color: var(--h-muted); font-size: 0.9rem; margin: 0; }
.ds-help__row { display: flex; align-items: center; gap: 0.8rem; width: 100%; padding: 0.75rem 0.9rem; border-radius: 0.9rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); text-align: left; color: inherit; }
.ds-help__row:hover { box-shadow: 0 0 0 1px var(--ds-signal); }
.ds-help__row-icon { width: 2.25rem; height: 2.25rem; display: grid; place-items: center; border-radius: 0.7rem; background: var(--h-soft); flex: none; font-size: 1.1rem; }
.ds-help__row-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-help__row-text strong { font-weight: 750; }
.ds-help__row-text small { color: var(--h-muted); font-size: 0.82rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-help__row-n { font-size: 0.75rem; color: var(--h-muted); white-space: nowrap; }
.ds-help__chev { color: var(--h-muted); font-size: 1.2rem; }
.ds-help__topics { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.75rem; }
.ds-help__topic { padding: 1rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); }
.ds-help__topic h3 { display: flex; align-items: center; gap: 0.45rem; color: var(--h-ink); font-size: 0.95rem; margin: 0 0 0.5rem; }
.ds-help__topic h3 small { margin-left: auto; font-size: 0.75rem; color: var(--h-muted); font-weight: 700; }
.ds-help__topic ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; }
.ds-help__topic li button { width: 100%; text-align: left; padding: 0.35rem 0; font-size: 0.9rem; color: inherit; border-top: 1px solid var(--h-line); }
.ds-help__topic li:first-child button { border-top: 0; }
.ds-help__topic li button:hover { color: #b48800; }
.dark .ds-help__topic li button:hover { color: var(--ds-signal); }
.ds-help__bar { display: flex; align-items: center; gap: 0.6rem; }
.ds-help__bar > .ds-help__lang { margin-left: auto; }
.ds-help__bar-title { font-size: 1.15rem; font-weight: 800; }
.ds-help__back { font-weight: 800; color: var(--h-ink); padding: 0.35rem 0.2rem; }
.ds-help__x { width: 2.2rem; height: 2.2rem; border-radius: 50%; background: var(--h-soft); font-size: 1.3rem; line-height: 1; color: var(--h-ink); }
.ds-help__guide { display: flex; flex-direction: column; gap: 1rem; }
.ds-help__ghead { display: flex; align-items: flex-start; gap: 0.9rem; flex-wrap: wrap; }
.ds-help__ghead > div { flex: 1; min-width: 14rem; }
.ds-help__gicon { width: 3rem; height: 3rem; display: grid; place-items: center; border-radius: 0.9rem; font-size: 1.5rem; background: rgb(246 190 0 / 0.18); flex: none; }
.ds-help__ghead h2 { font-size: 1.45rem; font-weight: 800; letter-spacing: -0.015em; line-height: 1.2; margin: 0; }
.ds-help__ghead p { margin: 0.3rem 0 0; color: var(--h-muted); line-height: 1.5; }
.ds-help__doit { padding: 0.6rem 1rem; border-radius: 0.75rem; background: var(--ds-signal); color: #0e2433; font-weight: 800; white-space: nowrap; }
.ds-help__when, .ds-help__result { margin: 0; padding: 0.75rem 0.9rem; border-radius: 0.8rem; background: var(--h-soft); line-height: 1.5; }
.ds-help__when strong, .ds-help__result strong { display: block; font-size: 0.8rem; color: var(--h-muted); }
.ds-help__result { background: rgb(23 137 94 / 0.1); }
.ds-help__result strong { color: var(--ds-ok); }
.ds-help__steps { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 0; }
.ds-help__steps li { display: flex; gap: 0.9rem; padding-bottom: 1.1rem; position: relative; }
.ds-help__steps li:not(:last-child)::before { content: ''; position: absolute; left: 0.95rem; top: 2.1rem; bottom: 0.2rem; width: 2px; background: var(--h-line); }
.ds-help__n { width: 1.9rem; height: 1.9rem; flex: none; display: grid; place-items: center; border-radius: 50%; background: var(--ds-navy); color: #fff; font-weight: 800; font-size: 0.9rem; }
.dark .ds-help__n { background: var(--ds-signal); color: #0e2433; }
.ds-help__steps strong { display: block; font-weight: 800; margin-top: 0.2rem; }
.ds-help__steps p { margin: 0.2rem 0 0; line-height: 1.55; max-width: 40rem; }
.ds-help__shot { display: block; width: fit-content; margin-top: 0.6rem; max-width: min(100%, 26rem); border-radius: 0.8rem; overflow: hidden; box-shadow: 0 0 0 1px var(--h-line), 0 8px 24px -14px rgb(0 0 0 / 0.5); }
.ds-help__shot img { display: block; max-width: 100%; max-height: 30rem; width: auto; height: auto; }
.ds-help__problems details { border-radius: 0.8rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); margin-bottom: 0.4rem; }
.ds-help__problems summary { padding: 0.7rem 0.9rem; font-weight: 700; cursor: pointer; }
.ds-help__problems details p { margin: 0; padding: 0 0.9rem 0.8rem; line-height: 1.5; color: var(--h-muted); }
.ds-help__vote { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; padding-top: 0.75rem; border-top: 1px solid var(--h-line); font-size: 0.9rem; color: var(--h-muted); }
.ds-help__vote button { padding: 0.35rem 0.8rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); color: var(--h-ink); font-weight: 700; }
.ds-help__center-link { margin-top: auto; padding-top: 0.75rem; font-weight: 800; font-size: 0.9rem; color: var(--h-muted); }
/* "?" in the top bar */
.ds-help-q { width: 2.1rem; height: 2.1rem; border-radius: 50%; display: grid; place-items: center; font-weight: 900; font-size: 1rem; color: var(--ds-navy); background: rgb(246 190 0 / 0.25); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.7); margin-right: 0.35rem; }
.ds-help-q:hover { background: var(--ds-signal); }
.dark .ds-help-q { color: var(--ds-signal); background: rgb(246 190 0 / 0.12); }
/* the panel that "?" opens */
.ds-help-drawer { position: fixed; inset: 0; z-index: 60; display: flex; justify-content: flex-end; }
.ds-help-drawer__shade { position: absolute; inset: 0; background: rgb(6 16 24 / 0.45); border: 0; }
.ds-help-drawer__panel { position: relative; width: min(30rem, 100%); max-width: none; height: 100%; overflow-y: auto; box-sizing: border-box; padding: 1.1rem 1.2rem 1.5rem; background: #f7f9fa; box-shadow: -20px 0 50px -20px rgb(0 0 0 / 0.45); animation: help-in .22s ease-out; }
.dark .ds-help-drawer__panel { background: #0b1c28; }
@keyframes help-in { from { transform: translateX(24px); opacity: 0; } to { transform: none; opacity: 1; } }
.ds-help-drawer__panel .ds-help__topics { grid-template-columns: 1fr; }
.ds-help-drawer__panel .ds-help__shot { max-width: 100%; }
/* Scan app and Driver app: the whole phone screen, dark like the apps */
.ds-help-drawer.is-phone .ds-help-drawer__panel { width: 100%; max-width: 34rem; margin: 0 auto; box-shadow: none; animation: sa-up .25s ease-out;
    padding: calc(env(safe-area-inset-top) + 1rem) 1.2rem calc(env(safe-area-inset-bottom) + 1.5rem);
    --h-ink: #eef3f6; --h-muted: #8fa3b1; --h-card: rgb(255 255 255 / 0.05); --h-line: rgb(255 255 255 / 0.08); --h-soft: rgb(255 255 255 / 0.05); }
.ds-help-drawer.is-phone { background: radial-gradient(120% 70% at 0% 0%, #15293a 0%, #0a1219 55%); justify-content: center; }
.ds-help-drawer.is-phone .ds-help-drawer__panel { background: transparent; }
.ds-help-drawer.is-phone .ds-help__lang button.is-on, .ds-help-drawer.is-phone .ds-help__ask, .ds-help-drawer.is-phone .ds-help__n { background: var(--ds-signal); color: #0a1219; }
.ds-help-drawer.is-phone .ds-help__answer-open { color: var(--ds-signal); }
.ds-help-drawer.is-phone .ds-help__search { box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.12); }
.ds-help-drawer.is-phone .ds-help__row, .ds-help-drawer.is-phone .ds-help__topic li button { min-height: 2.75rem; }
.ds-help-drawer.is-phone .ds-help__topic li button:hover { color: var(--ds-signal); }
.ds-help-drawer.is-phone .ds-help__row-text small { white-space: normal; }
.ds-sa__help { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; font-weight: 900; font-size: 1.05rem; color: var(--sa-gold); background: rgb(246 190 0 / 0.12); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.35); }
.ds-sa__hello .ds-sa__help { margin-left: auto; margin-right: -0.4rem; }
.ds-sa__title--help { flex-direction: row; align-items: center; justify-content: space-between; }
.ds-sa__title--help > span { display: flex; flex-direction: column; gap: 0.25rem; }
@media (max-width: 40rem) { .ds-help__row-n { display: none; } .ds-help__hero h1 { font-size: 1.45rem; } }
@media (prefers-reduced-motion: reduce) { .ds-help-drawer__panel { animation: none !important; } }

/* ------------------------------------------------------------------ Fuel (office) */
.ds-fu { display: flex; flex-direction: column; gap: 1rem; }
.ds-fu__top { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 0.75rem; }
.ds-fu__month, .ds-fu__form select, .ds-fu__form input[type=text], .ds-fu__tr select, .ds-fu__tr input { height: 2.25rem; padding: 0 0.7rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; }
.dark .ds-fu__month, .dark .ds-fu__form select, .dark .ds-fu__form input[type=text], .dark .ds-fu__tr select, .dark .ds-fu__tr input { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-fu .ds-tm__stats em { display: block; }
.ds-fu .is-bad { color: #c8372d; }
.ds-fu .is-ok { color: #17895e; }
.dark .ds-fu .is-bad { color: #ff8a7e; }
.dark .ds-fu .is-ok { color: #4fd3a0; }
.ds-fu__alertbar { text-align: left; padding: 0.7rem 1rem; border-radius: 0.75rem; background: #fff4e0; color: #7a4a00; font-weight: 700; font-size: 0.88rem; }
.dark .ds-fu__alertbar { background: rgb(240 169 59 / .14); color: #f6c46b; }
.ds-fu__table { padding: 0.25rem 0; overflow-x: auto; }
.ds-fu__tr { display: grid; gap: 0.75rem; align-items: center; width: 100%; padding: 0.65rem 1rem; text-align: left; font-size: 0.88rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 40rem; }
.dark .ds-fu__tr { border-color: rgb(255 255 255 / .07); }
.ds-fu__tr.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
button.ds-fu__tr:hover { background: rgb(0 0 0 / .025); }
.dark button.ds-fu__tr:hover { background: rgb(255 255 255 / .03); }
.ds-fu__tr small { display: block; font-size: 0.74rem; color: #6b7b88; }
.ds-fu__tr.is-trucks { grid-template-columns: 2fr 1fr 1fr 1.2fr 1fr 1.6fr; }
.ds-fu__tr.is-weeks { grid-template-columns: 1fr 1fr 1fr; min-width: 0; }
.ds-fu__tr.is-vat { grid-template-columns: 0.7fr 2fr 1fr 1fr 1fr 1fr 1fr; }
.ds-fu__tr.is-set { grid-template-columns: 2fr 1fr 1fr 1fr; }
.ds-fu__chg { margin-left: 0.35rem; font-style: normal; font-size: 0.74rem; font-weight: 700; color: #6b7b88; }
.ds-fu__filter { margin: 0; font-size: 0.88rem; }
.ds-fu__filter button, .ds-fu__link { text-decoration: underline; color: #1d6fb8; }
.ds-fu__fills { display: flex; flex-direction: column; gap: 0.6rem; }
.ds-fu__fill { display: grid; grid-template-columns: 4.5rem 1fr auto; gap: 1rem; align-items: center; padding: 0.75rem 1rem; }
.ds-fu__photo { width: 4.5rem; height: 4.5rem; border-radius: 0.6rem; overflow: hidden; background: #eef2f5; display: grid; place-items: center; font-size: 0.7rem; color: #8a99a5; }
.dark .ds-fu__photo { background: rgb(255 255 255 / .05); }
.ds-fu__photo img { width: 100%; height: 100%; object-fit: cover; }
.ds-fu__fillmain { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
.ds-fu__fillmain small { color: #6b7b88; font-size: 0.78rem; }
.ds-fu__chips { display: flex; flex-wrap: wrap; gap: 0.3rem; margin-top: 0.2rem; }
.ds-fu__chips em, .ds-fu__line em { font-style: normal; font-size: 0.72rem; font-weight: 700; padding: 0.15rem 0.5rem; border-radius: 999px; background: #eef2f5; color: #3d4f5c; }
.dark .ds-fu__chips em, .dark .ds-fu__line em { background: rgb(255 255 255 / .06); color: #c9d5de; }
.ds-fu__chips em.is-bad, .ds-fu__line em.is-bad { background: #fde8e6; }
.ds-fu__chips em.is-ok, .ds-fu__line em.is-ok { background: #e2f5ec; }
.dark .ds-fu__chips em.is-bad, .dark .ds-fu__line em.is-bad { background: rgb(255 107 94 / .14); }
.dark .ds-fu__chips em.is-ok, .dark .ds-fu__line em.is-ok { background: rgb(52 195 143 / .14); }
.ds-fu__fillnums { display: flex; flex-direction: column; align-items: flex-end; gap: 0.1rem; font-size: 0.8rem; color: #6b7b88; }
.ds-fu__fillnums b { font-size: 1.05rem; color: inherit; }
.ds-fu__fillnums b { color: #0e2433; }
.dark .ds-fu__fillnums b { color: #e6edf3; }
.ds-fu__alerts { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-fu__alert { display: grid; grid-template-columns: 2.25rem 1fr auto; gap: 0.75rem; align-items: start; padding: 0.8rem 1rem; border-radius: 0.8rem; background: #fff8ec; box-shadow: inset 3px 0 0 #f0a93b; }
.ds-fu__alert.is-red { background: #fff1ef; box-shadow: inset 3px 0 0 #e0473b; }
.dark .ds-fu__alert { background: rgb(240 169 59 / .08); }
.dark .ds-fu__alert.is-red { background: rgb(255 107 94 / .09); }
.ds-fu__alert b { display: block; font-size: 0.9rem; }
.ds-fu__alert small { display: block; font-size: 0.8rem; color: #5b6b78; margin-top: 0.15rem; }
.dark .ds-fu__alert small { color: #a9b8c3; }
.ds-fu__alerticon { font-size: 1.25rem; line-height: 1.5rem; }
.ds-fu__when { white-space: nowrap; font-size: 0.74rem; color: #8a99a5; }
.ds-fu__two { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr); gap: 1rem; align-items: start; }
.ds-fu__two > section, .ds-fu__steps > section { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.7rem; }
.ds-fu h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-fu__where { margin: 0; padding-left: 1.1rem; font-size: 0.82rem; list-style: disc; display: flex; flex-direction: column; gap: 0.2rem; }
.ds-fu__form { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-fu__form input[type=file] { font-size: 0.8rem; max-width: 100%; }
.ds-fu__form.is-stack { flex-direction: column; align-items: stretch; }
.ds-fu__form.is-stack label { display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.78rem; color: #6b7b88; }
.ds-fu__err { margin: 0; color: #c8372d; font-size: 0.8rem; }
.ds-fu__counts { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-fu__counts button { padding: 0.25rem 0.65rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; background: #eef2f5; color: #3d4f5c; }
.ds-fu__counts button.is-on { background: #0e2433; color: #fff; }
.dark .ds-fu__counts button { background: rgb(255 255 255 / .06); color: #c9d5de; }
.dark .ds-fu__counts button.is-on { background: #e6edf3; color: #0e2433; }
.ds-fu__lines { display: flex; flex-direction: column; max-height: 32rem; overflow-y: auto; }
.ds-fu__line { display: grid; grid-template-columns: 1fr auto auto; gap: 0.75rem; align-items: center; padding: 0.5rem 0; border-top: 1px solid rgb(0 0 0 / .06); font-size: 0.84rem; }
.dark .ds-fu__line { border-color: rgb(255 255 255 / .07); }
.ds-fu__line small { color: #6b7b88; font-size: 0.75rem; }
.ds-fu__prices { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-fu__prices span { display: flex; flex-direction: column; padding: 0.75rem; border-radius: 0.7rem; background: #f3f6f8; }
.dark .ds-fu__prices span { background: rgb(255 255 255 / .04); }
.ds-fu__prices small, .ds-fu__prices em { font-size: 0.74rem; color: #6b7b88; font-style: normal; }
.ds-fu__prices b { font-size: 1.4rem; }
.ds-fu__vat { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)) auto; gap: 0.6rem; align-items: stretch; }
.ds-fu__vat > span { padding: 0.7rem 0.9rem; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-fu__vat small, .ds-fu__vat em { font-size: 0.74rem; color: #6b7b88; font-style: normal; }
.ds-fu__vat b { font-size: 1.2rem; }
.ds-fu__vat > span.is-ok b { color: #17895e; }
.ds-fu__vat > span.is-bad b { color: #c8372d; }
.ds-fu__export { display: grid; place-items: center; padding: 0 1.1rem; border-radius: 0.75rem; background: #17895e; color: #fff; font-weight: 800; font-size: 0.88rem; }
.ds-fu__steps { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.8rem; align-items: start; }
.ds-fu__num { display: inline-grid; place-items: center; width: 1.5rem; height: 1.5rem; margin-right: 0.35rem; border-radius: 50%; background: #0e2433; color: #fff; font-size: 0.75rem; }
.dark .ds-fu__num { background: #e6edf3; color: #0e2433; }
.ds-fu__calc { display: grid; grid-template-columns: auto 1fr; gap: 0.35rem 0.75rem; margin: 0; font-size: 0.84rem; }
.ds-fu__calc dt { color: #6b7b88; }
.ds-fu__calc dd { margin: 0; text-align: right; }
.ds-fu__calc small { display: block; font-size: 0.7rem; color: #8a99a5; }
.ds-fu__big { margin: 0; font-size: 1.9rem; font-weight: 800; letter-spacing: -0.02em; }
.ds-fu__hint { margin: 0; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #eef5fb; font-size: 0.8rem; }
.dark .ds-fu__hint { background: rgb(90 168 255 / .1); }
@media (max-width: 1100px) { .ds-fu__two, .ds-fu__steps { grid-template-columns: 1fr; } .ds-fu__vat { grid-template-columns: 1fr 1fr; } }
@media (max-width: 640px) { .ds-fu__fill { grid-template-columns: 3.5rem 1fr; } .ds-fu__fillnums { grid-column: 2; align-items: flex-start; } .ds-fu__photo { width: 3.5rem; height: 3.5rem; } }

/* ------------------------------------------------------------------ Fuel (Driver app) */
.ds-fd__home { display: grid; grid-template-columns: 2.6rem 1fr auto; gap: 0.8rem; align-items: center; padding: 0.85rem 1rem; border-radius: 1.2rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); color: var(--sa-text); }
.ds-fd__home > span:first-child { display: grid; place-items: center; width: 2.6rem; height: 2.6rem; border-radius: 0.8rem; background: rgb(246 190 0 / .14); font-size: 1.3rem; }
.ds-fd__home b { display: block; font-size: 1rem; }
.ds-fd__home small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-fd__top { display: grid; grid-template-columns: 2.5rem 1fr auto; gap: 0.75rem; align-items: center; }
.ds-fd__top > span:nth-child(2) { display: flex; flex-direction: column; }
.ds-fd__top small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-fd__top strong { font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; }
.ds-fd__back { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; background: rgb(255 255 255 / .06); color: var(--sa-text); font-size: 1.6rem; line-height: 1; }
.ds-fd__dots { display: flex; gap: 0.3rem; }
.ds-fd__dots i { width: 0.5rem; height: 0.5rem; border-radius: 50%; background: rgb(255 255 255 / .15); }
.ds-fd__dots i.is-done { background: var(--sa-ok); }
.ds-fd__dots i.is-on { background: var(--sa-gold); width: 1.3rem; border-radius: 999px; }
.ds-fd__cash { padding: 0.75rem 0.95rem; border-radius: 1rem; background: rgb(52 195 143 / .1); font-size: 0.9rem; }
.ds-fd__cash small { display: block; color: var(--sa-muted); font-size: 0.76rem; margin-top: 0.15rem; }
.ds-fd__intro { display: flex; flex-direction: column; align-items: center; text-align: center; gap: 0.5rem; margin-top: 1.5rem; }
.ds-fd__intro strong { font-size: 1.35rem; }
.ds-fd__intro p { margin: 0; color: var(--sa-muted); font-size: 0.92rem; max-width: 26rem; }
.ds-fd__big { display: grid; place-items: center; width: 5rem; height: 5rem; border-radius: 50%; background: rgb(255 255 255 / .06); font-size: 2.3rem; }
.ds-fd__big.is-ok { background: rgb(52 195 143 / .16); color: var(--sa-ok); font-weight: 800; }
.ds-fd__tin { padding: 0.6rem 0.8rem; border-radius: 0.8rem; background: rgb(246 190 0 / .1); color: var(--sa-text) !important; }
.ds-fd__actions { display: flex; flex-direction: column; gap: 0.6rem; margin-top: auto; }
.ds-fd__actions .ds-sa__primary, .ds-fd__actions .ds-sa__secondary { width: 100%; }
.ds-fd__thumb { display: grid; grid-template-columns: 4rem 1fr; gap: 0.8rem; align-items: center; padding: 0.5rem; border-radius: 1rem; background: var(--sa-glass); color: var(--sa-muted); font-size: 0.85rem; }
.ds-fd__thumb img { width: 4rem; height: 4rem; object-fit: cover; border-radius: 0.65rem; }
.ds-fd__odo { width: 100%; max-height: 14rem; object-fit: cover; border-radius: 1rem; }
.ds-fd__warn { padding: 0.7rem 0.9rem; border-radius: 0.9rem; background: rgb(240 169 59 / .14); color: #f6c46b; font-size: 0.88rem; }
.ds-fd__warn.is-bad { background: rgb(255 107 94 / .15); color: #ff9d93; }
.ds-fd__seg { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 0.3rem; padding: 0.3rem; border-radius: 1rem; background: rgb(255 255 255 / .05); }
.ds-fd__seg button { height: 2.9rem; border-radius: 0.75rem; color: var(--sa-muted); font-weight: 700; }
.ds-fd__seg button.is-on { background: var(--sa-gold); color: #0a1219; }
.ds-fd__seg.is-small button { height: 2.3rem; padding: 0 0.8rem; font-size: 0.85rem; }
.ds-fd__form { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-fd__form label { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-fd__form label.is-wide, .ds-fd__form .ds-sa__err { grid-column: 1 / -1; }
.ds-fd__form small { font-size: 0.76rem; color: var(--sa-muted); }
.ds-fd__form input { height: 3rem; padding: 0 0.85rem; border-radius: 0.85rem; border: 0; background: rgb(255 255 255 / .07); color: var(--sa-text); font-size: 1rem; color-scheme: dark; }
.ds-fd__form input:focus { outline: 2px solid var(--sa-gold); }
.ds-fd__form .is-total input { height: 3.4rem; font-size: 1.35rem; font-weight: 700; }
.ds-fd__ask { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; font-size: 0.9rem; }
.ds-fd__kml { display: grid; grid-template-columns: 1fr 1fr; border-radius: 1rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-fd__kml span { display: flex; flex-direction: column; padding: 0.8rem 1rem; }
.ds-fd__kml span + span { box-shadow: inset 1px 0 0 var(--sa-line); }
.ds-fd__kml small { color: var(--sa-muted); font-size: 0.76rem; }
.ds-fd__kml b { font-size: 1.4rem; }
.ds-fd__btn { display: grid; place-items: center; margin-top: auto; }

/* ------------------------------------------------------------------ Warehouse sections, sets, truck waiting (Scan app) */
.ds-sx__tile { display: flex; flex-direction: column; align-items: center; gap: 0.15rem; padding: 0.9rem 1rem; border-radius: 1.2rem; background: var(--sx, #1d6fb8); color: #fff; text-align: center; animation: ds-sx-in .2s ease-out; }
.ds-sx__tile small { font-size: 0.8rem; font-weight: 700; opacity: .85; }
.ds-sx__tile strong { font-size: 3.6rem; line-height: 1; font-weight: 900; letter-spacing: -0.02em; }
.ds-sx__tile span { font-size: 1.05rem; font-weight: 800; }
.ds-sx__tile em { font-style: normal; font-size: 0.8rem; opacity: .9; }
.ds-sx__tile.is-truck strong { font-size: 2.8rem; }
@keyframes ds-sx-in { from { transform: scale(.96); opacity: .4; } to { transform: none; opacity: 1; } }
@media (prefers-reduced-motion: reduce) { .ds-sx__tile { animation: none; } }
.ds-sx__set { display: flex; flex-direction: column; gap: 0.35rem; padding: 0.7rem 0.9rem; border-radius: 1rem; background: rgb(255 255 255 / .06); font-size: 0.92rem; }
.ds-sx__set small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-sx__set.is-done { background: rgb(52 195 143 / .14); }
.ds-sx__set.is-split { background: rgb(240 169 59 / .14); }
.ds-sx__set.is-split small { color: #f6c46b; }
.ds-sx__dots { display: flex; gap: 0.25rem; }
.ds-sx__dots i { flex: 1; max-width: 2.2rem; height: 0.4rem; border-radius: 999px; background: rgb(255 255 255 / .15); }
.ds-sx__dots i.is-on { background: var(--sa-ok); }
.ds-sx__link { align-self: center; padding: 0.35rem 0.6rem; color: var(--sa-gold); font-size: 0.88rem; font-weight: 700; text-decoration: underline; text-underline-offset: 3px; }
.ds-sx__team { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-sx__team span { padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(255 255 255 / .06); font-size: 0.8rem; color: var(--sa-muted); }
.ds-sx__team span.is-me { color: var(--sa-gold); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .4); }
.ds-sx__team b { color: var(--sa-text); margin-left: 0.2rem; }
.ds-sx__truck { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.75rem 0.9rem; border-radius: 1rem; background: rgb(232 89 12 / .16); box-shadow: inset 0 0 0 1px rgb(232 89 12 / .5); }
.ds-sx__truck.is-paused { background: rgb(255 255 255 / .05); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sx__truckhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 0.9rem; }
.ds-sx__truckhead button { padding: 0.3rem 0.6rem; border-radius: 0.6rem; background: rgb(255 255 255 / .1); color: var(--sa-text); font-size: 0.78rem; font-weight: 700; margin-left: 0.25rem; }
.ds-sx__truckn { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.4rem; font-size: 0.74rem; color: var(--sa-muted); }
.ds-sx__truckn b { display: block; font-size: 1.15rem; color: var(--sa-text); }
.ds-sx__picker { display: flex; flex-direction: column; gap: 0.45rem; padding: 0.8rem; border-radius: 1rem; background: rgb(255 255 255 / .05); }
.ds-sx__picker > button:not(.ds-sx__link) { display: flex; flex-direction: column; align-items: flex-start; padding: 0.65rem 0.8rem; border-radius: 0.8rem; background: rgb(255 255 255 / .07); color: var(--sa-text); text-align: left; }
.ds-sx__picker small, .ds-sx__picker p { color: var(--sa-muted); font-size: 0.8rem; margin: 0; }
.ds-sx__open { display: flex; flex-direction: column; gap: 0.6rem; width: 100%; padding: 0.9rem; border-radius: 1rem; background: rgb(240 169 59 / .1); box-shadow: inset 0 0 0 1px rgb(240 169 59 / .4); text-align: left; }
.ds-sx__open > small { color: var(--sa-muted); font-size: 0.78rem; }
.ds-sx__openrow { display: flex; flex-direction: column; gap: 0.35rem; font-size: 0.9rem; }
.ds-sx__miss { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.5rem 0.6rem; border-radius: 0.7rem; background: rgb(255 255 255 / .05); }
.ds-sx__miss small { color: var(--sa-muted); }
.ds-sx__why { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-sx__why button { padding: 0.3rem 0.55rem; border-radius: 999px; background: rgb(255 255 255 / .08); color: var(--sa-muted); font-size: 0.74rem; font-weight: 700; }
.ds-sx__why button.is-on { background: var(--sa-gold); color: #0a1219; }

/* ------------------------------------------------------------------ Settings · Warehouse sections */
.ds-ws { display: flex; flex-direction: column; gap: 1rem; }
.ds-ws__top { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end; gap: 0.75rem; }
.ds-ws__wh { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.8rem; color: #6b7b88; }
.ds-ws__acts { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-ws select, .ds-ws input[type=text], .ds-ws textarea { min-height: 2.25rem; padding: 0.35rem 0.6rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; width: 100%; box-sizing: border-box; }
.dark .ds-ws select, .dark .ds-ws input[type=text], .dark .ds-ws textarea { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-ws__list { padding: 0.25rem 0; overflow-x: auto; }
.ds-ws__row { display: grid; grid-template-columns: 7.5rem 1.2fr 0.9fr 1.3fr 2fr 4rem 2rem; gap: 0.6rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 62rem; }
.dark .ds-ws__row { border-color: rgb(255 255 255 / .07); }
.ds-ws__row.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
.ds-ws__code { display: grid; grid-template-columns: 2.6rem 1fr; gap: 0.3rem; align-items: center; }
.ds-ws__code input { text-align: center; font-weight: 900; font-size: 1.05rem !important; color: #fff !important; background: var(--c) !important; border-color: var(--c) !important; }
.ds-ws__code select { font-size: 0.7rem !important; padding: 0.2rem !important; }
.ds-ws__muted { color: #6b7b88; font-size: 0.8rem; margin: 0; }
.ds-ws__del { width: 2rem; height: 2rem; border-radius: 0.5rem; color: #c8372d; }
.ds-ws__del:hover { background: #fde8e6; }
.ds-ws__empty { padding: 1.25rem; display: flex; flex-direction: column; align-items: flex-start; gap: 0.75rem; }
.ds-ws__empty p { margin: 0; color: #6b7b88; }
.ds-ws__err { margin: 0.5rem 1rem; color: #c8372d; font-size: 0.85rem; }
.ds-ws__two { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
.ds-ws__box { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-ws__box h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-ws__toggle { display: flex; gap: 0.7rem; align-items: flex-start; cursor: pointer; }
.ds-ws__toggle input { margin-top: 0.25rem; width: 1.1rem; height: 1.1rem; }
.ds-ws__toggle small { display: block; color: #6b7b88; font-size: 0.8rem; margin-top: 0.15rem; }
@media (max-width: 900px) { .ds-ws__two { grid-template-columns: 1fr; } }
.ds-ws__result { display: flex; gap: 0.9rem; align-items: center; margin-top: 0.75rem; padding: 0.75rem 1rem; border-radius: 0.9rem; background: color-mix(in srgb, var(--c) 12%, transparent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--c) 40%, transparent); }
.ds-ws__result > strong { display: grid; place-items: center; min-width: 3rem; height: 3rem; padding: 0 0.4rem; border-radius: 0.7rem; background: var(--c); color: #fff; font-size: 1.6rem; font-weight: 900; }
.ds-ws__result small { display: block; color: #6b7b88; font-size: 0.8rem; }

/* ------------------------------------------------------------------ Sea shipments, wrong hub & returns */
.ds-sp { display: flex; flex-direction: column; gap: 1rem; }
.ds-sp h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-sp select, .ds-sp input[type=text], .ds-sp input[type=number], .ds-sp input[type=date] { min-height: 2.25rem; padding: 0.35rem 0.6rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; box-sizing: border-box; }
.dark .ds-sp select, .dark .ds-sp input[type=text], .dark .ds-sp input[type=number], .dark .ds-sp input[type=date] { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-sp__new { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-sp__newrow { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-sp__newrow select, .ds-sp__newrow input { flex: 1 1 12rem; }
.ds-sp__err { margin: 0; color: #c8372d; font-size: 0.85rem; }
.ds-sp__filter { display: flex; gap: 0.35rem; }
.ds-sp__filter button { padding: 0.35rem 0.85rem; border-radius: 999px; font-size: 0.8rem; font-weight: 700; background: #eef2f5; color: #3d4f5c; }
.ds-sp__filter button.is-on { background: #0e2433; color: #fff; }
.dark .ds-sp__filter button { background: rgb(255 255 255 / .06); color: #c9d5de; }
.dark .ds-sp__filter button.is-on { background: #e6edf3; color: #0e2433; }
.ds-sp__list { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-sp__item { display: grid; grid-template-columns: 2.5rem 1fr auto auto; gap: 1rem; align-items: center; padding: 0.8rem 1rem; }
.ds-sp__icon { font-size: 1.5rem; }
.ds-sp__main { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
.ds-sp__main small, .ds-sp__nums small { color: #6b7b88; font-size: 0.78rem; }
.ds-sp__bar { display: flex; gap: 0.2rem; margin-top: 0.25rem; max-width: 20rem; }
.ds-sp__bar i { flex: 1; height: 0.35rem; border-radius: 999px; background: #dfe5ea; }
.ds-sp__bar i.is-done { background: #17895e; }
.ds-sp__bar i.is-now { background: #f6be00; }
.dark .ds-sp__bar i { background: rgb(255 255 255 / .1); }
.ds-sp__nums { display: flex; flex-direction: column; align-items: flex-end; }
.ds-sp__nums b { font-size: 1.2rem; }
.ds-sp__state { padding: 0.25rem 0.7rem; border-radius: 999px; font-size: 0.75rem; font-weight: 800; background: #eef5fb; color: #1d6fb8; white-space: nowrap; }
.ds-sp__state.is-received { background: #e2f5ec; color: #17895e; }
.ds-sp__state.is-preparing { background: #eef2f5; color: #3d4f5c; }
.ds-sp__steps { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 0.5rem; padding: 1rem; overflow-x: auto; }
.ds-sp__step { display: flex; flex-direction: column; gap: 0.3rem; min-width: 6rem; font-size: 0.85rem; color: #8a99a5; }
.ds-sp__step i { height: 0.4rem; border-radius: 999px; background: #dfe5ea; }
.ds-sp__step.is-done { color: inherit; }
.ds-sp__step.is-done i { background: #17895e; }
.ds-sp__step.is-now { color: inherit; }
.ds-sp__step.is-now i { background: #f6be00; }
.ds-sp__step small { font-size: 0.72rem; color: #8a99a5; }
.ds-sp__head { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 0.75rem; }
.ds-sp__track { display: flex; gap: 0.75rem; align-items: center; font-size: 1rem; }
.ds-sp__track > span:first-child { font-size: 1.6rem; }
.ds-sp__track small { display: block; color: #6b7b88; font-size: 0.78rem; }
.ds-sp__acts { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-sp__block { display: flex; flex-direction: column; gap: 0.25rem; padding: 0.7rem 1rem; border-radius: 0.75rem; background: #fff4e0; color: #7a4a00; font-size: 0.88rem; }
.dark .ds-sp__block { background: rgb(240 169 59 / .14); color: #f6c46b; }
.ds-sp__grid { display: grid; grid-template-columns: 1.4fr 1fr; gap: 1rem; align-items: start; }
.ds-sp__box { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.7rem; }
.ds-sp__nums4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.5rem; }
.ds-sp__nums4 span { display: flex; flex-direction: column; padding: 0.7rem; border-radius: 0.7rem; background: #f3f6f8; }
.dark .ds-sp__nums4 span { background: rgb(255 255 255 / .04); }
.ds-sp__nums4 small { font-size: 0.72rem; color: #6b7b88; }
.ds-sp__nums4 b { font-size: 1.4rem; }
.ds-sp__nums4 .is-bad b { color: #c8372d; }
.ds-sp__warn { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fde8e6; color: #a3281f; font-size: 0.85rem; }
.dark .ds-sp__warn { background: rgb(255 107 94 / .12); color: #ff9d93; }
.ds-sp__sets { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.85rem; padding: 0.6rem 0.75rem; border-radius: 0.6rem; background: #eef5fb; }
.dark .ds-sp__sets { background: rgb(90 168 255 / .08); }
.ds-sp__dl { display: grid; grid-template-columns: 1fr auto; gap: 0.35rem 0.75rem; margin: 0; font-size: 0.88rem; }
.ds-sp__dl dt { color: #6b7b88; }
.ds-sp__dl dd { margin: 0; text-align: right; font-variant-numeric: tabular-nums; }
.ds-sp__perbox { display: flex; justify-content: space-between; align-items: baseline; margin: 0; padding: 0.7rem 0.9rem; border-radius: 0.7rem; background: #eef5fb; font-weight: 800; }
.ds-sp__perbox b { font-size: 1.4rem; }
.dark .ds-sp__perbox { background: rgb(90 168 255 / .08); }
.ds-sp__pics { display: flex; gap: 0.5rem; }
.ds-sp__pics a { display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.72rem; color: #6b7b88; }
.ds-sp__pics img { width: 5rem; height: 5rem; object-fit: cover; border-radius: 0.6rem; }
.ds-sp__form { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.8rem; }
.ds-sp__fields { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.6rem; }
.ds-sp__fields label { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.75rem; color: #6b7b88; }
.ds-sp__fields .is-wide { grid-column: span 2; }
.ds-sp__fields input[type=file] { font-size: 0.78rem; }
.ds-sp__table { padding: 0.25rem 0; overflow-x: auto; }
.ds-sp__tr { display: grid; grid-template-columns: 1.4fr 1fr 1.6fr auto; gap: 0.8rem; align-items: center; padding: 0.7rem 1rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 46rem; font-size: 0.88rem; }
.dark .ds-sp__tr { border-color: rgb(255 255 255 / .07); }
.ds-sp__tr.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
.ds-sp__tr > span { display: flex; flex-direction: column; gap: 0.2rem; }
.ds-sp__tr small { color: #6b7b88; font-size: 0.76rem; }
.ds-sp__tr select { font-size: 0.75rem; min-height: 1.9rem; }
.ds-sp__tag { align-self: flex-start; font-style: normal; font-size: 0.72rem; font-weight: 800; padding: 0.15rem 0.55rem; border-radius: 999px; background: #eef2f5; color: #3d4f5c; }
.ds-sp__tag.is-bad { background: #fde8e6; color: #a3281f; }
.ds-sp__ok { color: #17895e; }
.ds-sp__btns { flex-direction: row !important; gap: 0.35rem; flex-wrap: wrap; justify-content: flex-end; }
.ds-sp__pad { padding: 1rem; }
.ds-sp__barrow { display: grid; grid-template-columns: 11rem 1fr 2.5rem; gap: 0.6rem; align-items: center; font-size: 0.86rem; }
.ds-sp__barrow i { height: 0.7rem; border-radius: 999px; background: #eef2f5; overflow: hidden; }
.ds-sp__barrow i b { display: block; height: 100%; background: #1d6fb8; border-radius: 999px; }
@media (max-width: 1000px) { .ds-sp__grid { grid-template-columns: 1fr; } .ds-sp__fields { grid-template-columns: 1fr 1fr; } .ds-sp__nums4 { grid-template-columns: 1fr 1fr; } }
DISPATCH_FILE_END_28

# ---------------------------------------------------------------- resources/views/filament/shipping/detail.blade.php
mkdir -p 'resources/views/filament/shipping'
cat > 'resources/views/filament/shipping/detail.blade.php' <<'DISPATCH_FILE_END_29'
@php
    $peso = fn ($n) => '₱'.number_format((float) $n, 2);
@endphp
<x-filament-panels::page>
<div class="ds-sp">
    <section class="ds-board__panel ds-sp__steps">
        @foreach ($steps as $k => $label)
            @php
                $i = array_search($k, $stepKeys);
                $now = array_search($s->status, $stepKeys);
            @endphp
            <span @class(['ds-sp__step', 'is-done' => $i < $now, 'is-now' => $i === $now])><i></i><b>{{ $label }}</b><small>{{ $whenOf($k) ?? '' }}</small></span>
        @endforeach
    </section>

    <div class="ds-sp__head">
        <span class="ds-sp__track"><span aria-hidden="true">{{ $s->mode === 'roro' ? '⛴️' : '🚢' }}</span><span><b>{{ $track }}</b><small>What the receiver sees on tracking</small></span></span>
        <span class="ds-sp__acts">
            @if ($canPress)
                <x-filament::button wire:click="advance" :color="$blockers ? 'gray' : 'primary'">Mark: {{ $nextLabel }}</x-filament::button>
            @endif
            @if ($canReceive)
                <x-filament::button color="success" wire:click="finishReceiving" wire:confirm="Finish receiving? Boxes not scanned in get an Invoice Issue each.">Finish receiving</x-filament::button>
            @endif
        </span>
    </div>
    @if ($blockers && $canPress)
        <div class="ds-sp__block">@foreach ($blockers as $b)<span>⚠ {{ $b }}</span>@endforeach</div>
    @endif

    <div class="ds-sp__grid">
        <section class="ds-board__panel ds-sp__box">
            <h3>Boxes</h3>
            <div class="ds-sp__nums4">
                <span><small>On trip {{ $s->trip?->trip_number }}</small><b class="num">{{ $counts['onTrip'] }}</b></span>
                <span><small>Left the warehouse</small><b class="num">{{ $counts['loaded'] }}</b></span>
                <span @class(['is-bad' => $counts['port'] !== null && $counts['port'] < $counts['loaded']])><small>At the port</small><b class="num">{{ $counts['port'] ?? '—' }}</b></span>
                <span @class(['is-bad' => $counts['missingHub']->isNotEmpty()])><small>Received at the hub</small><b class="num">{{ $counts['received'] }}</b></span>
            </div>
            @if ($counts['port'] !== null && $counts['port'] < $counts['loaded'])
                <p class="ds-sp__warn">⚠ {{ $counts['loaded'] - $counts['port'] }} {{ $counts['loaded'] - $counts['port'] === 1 ? 'box' : 'boxes' }} left the warehouse but {{ $counts['loaded'] - $counts['port'] === 1 ? 'was' : 'were' }} not handed over at the port{{ $counts['missingPort']->isNotEmpty() ? ': '.$counts['missingPort']->take(8)->join(', ') : '. Which ones is not known: only a full scan tells.' }}</p>
            @endif
            @if ($counts['missingHub']->isNotEmpty())
                <p class="ds-sp__warn">Not scanned in at the hub yet: {{ $counts['missingHub']->take(10)->join(', ') }}{{ $counts['missingHub']->count() > 10 ? '…' : '' }}</p>
            @endif
            @if ($openSets)
                <div class="ds-sp__sets">
                    <b>Customers with boxes left behind</b>
                    @foreach ($openSets as $o)
                        <span>{{ $o['name'] }} · {{ $o['have'] }} of {{ $o['of'] }} · @foreach ($o['missing'] as $m){{ $m['invoice'] }} ({{ $m['reason'] ? \App\Models\Boxes\SetSplit::REASONS[$m['reason']] ?? $m['reason'] : 'no reason yet' }}) @endforeach</span>
                    @endforeach
                </div>
            @endif
            @if ($wrong->isNotEmpty())
                <div class="ds-sp__sets">
                    <b>Not for {{ $s->hub?->hub_name }}</b>
                    @foreach ($wrong as $w)<span>{{ $w->invoice?->invoice }} → {{ $w->correctHub?->hub_name ?? '?' }} · {{ \App\Models\Shipping\WrongHubBox::STATUS[$w->status] ?? $w->status }}</span>@endforeach
                </div>
            @endif
            @if (! $hubSide)
                <p class="ds-board__muted">Load the boxes with Scan app → Load truck (trip {{ $s->trip?->trip_number }}). Sets and wrong hub are checked there.</p>
            @else
                <p class="ds-board__muted">Scan the boxes in with Scan app → Receive container, then press Finish receiving.</p>
            @endif
        </section>

        <section class="ds-board__panel ds-sp__box">
            <h3>Cost</h3>
            <dl class="ds-sp__dl">
                <dt>Freight</dt><dd>{{ $s->cost_freight !== null ? $peso($s->cost_freight) : '—' }}</dd>
                <dt>Trucking to port</dt><dd>{{ $s->cost_trucking !== null ? $peso($s->cost_trucking) : '—' }}</dd>
                <dt>Port fees (wharfage, arrastre)</dt><dd>{{ $s->cost_port !== null ? $peso($s->cost_port) : '—' }}</dd>
                <dt>Other</dt><dd>{{ $s->cost_other !== null ? $peso($s->cost_other) : '—' }}</dd>
            </dl>
            <p class="ds-sp__perbox"><span>Per box</span><b class="num">{{ $counts['perBox'] ? $peso($counts['perBox']) : '—' }}</b></p>
            @if ($s->seal_photo || $s->port_receipt)
                <span class="ds-sp__pics">
                    @if ($s->seal_photo)<a href="{{ $s->fileUrl($s->seal_photo) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->seal_photo) }}" alt="Seal"><small>Seal</small></a>@endif
                    @if ($s->port_receipt)<a href="{{ $s->fileUrl($s->port_receipt) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->port_receipt) }}" alt="Port receipt"><small>Port receipt</small></a>@endif
                </span>
            @endif
        </section>
    </div>

    @if (! $hubSide)
        <form wire:submit="save" class="ds-board__panel ds-sp__form">
            <h3>Details</h3>
            <div class="ds-sp__fields">
                <label><span>How it's shipped</span><select wire:model.live="f.mode">@foreach ($modes as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                <label><span>{{ $f['mode'] === 'roro' ? 'Truck door seal no.' : 'Seal no.' }}</span><input type="text" wire:model="f.seal_no"></label>
                @if ($f['mode'] !== 'roro')
                    <label><span>Container van no.</span><input type="text" wire:model="f.van_no" placeholder="MSKU 220871"></label>
                    <label><span>Size</span><input type="text" wire:model="f.van_size" placeholder="20 ft"></label>
                @endif
                <label><span>{{ $f['mode'] === 'roro' ? 'Ferry company' : 'Shipping line' }}</span><input type="text" wire:model="f.shipping_line" placeholder="2GO"></label>
                <label><span>Vessel</span><input type="text" wire:model="f.vessel"></label>
                <label><span>Voyage</span><input type="text" wire:model="f.voyage"></label>
                <label><span>{{ $f['mode'] === 'roro' ? 'Ticket no.' : 'BL no.' }}</span><input type="text" wire:model="f.bl_no"></label>
                <label><span>From port</span><input type="text" wire:model="f.port_from" placeholder="Manila North Harbor"></label>
                <label><span>To port</span><input type="text" wire:model="f.port_to" placeholder="Cebu Port"></label>
                <label><span>Leaves (ETD)</span><input type="date" wire:model="f.etd"></label>
                <label><span>Arrives (ETA)</span><input type="date" wire:model="f.eta"></label>
                <label class="is-file"><span>Seal photo</span><input type="file" wire:model="sealPhoto" accept="image/*"></label>
            </div>
            <h3>Port check</h3>
            <div class="ds-sp__fields">
                <label><span>Port check</span><select wire:model.live="f.port_check">@foreach ($checks as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                @if ($f['port_check'] === 'count')
                    <label><span>Boxes handed over (count)</span><input type="number" min="0" wire:model="f.port_count"></label>
                    <label class="is-file"><span>Photo of the forwarder receipt</span><input type="file" wire:model="receipt" accept="image/*"></label>
                @elseif ($f['port_check'] === 'off')
                    <label class="is-wide"><span>Why is it off? (required)</span><input type="text" wire:model="f.port_reason" placeholder="Container sealed at our warehouse"></label>
                @else
                    <p class="ds-board__muted is-wide">The crew scans every box at the port: Scan app → Port check.</p>
                @endif
            </div>
            <h3>Cost</h3>
            <div class="ds-sp__fields">
                <label><span>Freight ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_freight"></label>
                <label><span>Trucking to port ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_trucking"></label>
                <label><span>Port fees ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_port"></label>
                <label><span>Other ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_other"></label>
                <label class="is-wide"><span>Note</span><input type="text" wire:model="f.note" maxlength="500"></label>
            </div>
            @if ($errors->any())<p class="ds-sp__err">{{ $errors->first() }}</p>@endif
            <div><x-filament::button type="submit" wire:loading.attr="disabled" wire:target="save,sealPhoto,receipt">Save details</x-filament::button></div>
        </form>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_29

# ---------------------------------------------------------------- resources/views/filament/shipping/list.blade.php
mkdir -p 'resources/views/filament/shipping'
cat > 'resources/views/filament/shipping/list.blade.php' <<'DISPATCH_FILE_END_30'
<x-filament-panels::page>
<div class="ds-sp">
    @if (! $incoming)
        <form wire:submit="create" class="ds-board__panel ds-sp__new">
            <h3>New sea shipment</h3>
            <p class="ds-board__muted">Make the trip to the port first, as a normal trip to the partner hub (Delivery Log), and put the boxes on it. Then pick it here.</p>
            <div class="ds-sp__newrow">
                <select wire:model="tripId" aria-label="Trip to the port">
                    <option value="">Trip to the port…</option>
                    @foreach ($trips as $t)<option value="{{ $t->id }}">Trip {{ $t->trip_number }} → {{ $t->destination?->hub_name }}{{ $t->truck ? ' · '.$t->truck->plate_no : '' }}</option>@endforeach
                </select>
                <select wire:model.live="mode" aria-label="How it is shipped">@foreach ($modes as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                @if ($mode !== 'roro')
                    <select wire:model="portCheck" aria-label="Port check">@foreach ($checks as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                @endif
                <x-filament::button type="submit">Make shipment</x-filament::button>
            </div>
            @error('tripId')<p class="ds-sp__err">{{ $message }}</p>@enderror
            @if ($trips->isEmpty())<p class="ds-board__muted">No open trip to a partner hub yet.</p>@endif
        </form>
    @endif

    <div class="ds-sp__filter">
        <button type="button" wire:click="$set('show', 'open')" @class(['is-on' => $show === 'open'])>On the way</button>
        <button type="button" wire:click="$set('show', 'all')" @class(['is-on' => $show === 'all'])>All · {{ $done }} received</button>
    </div>

    <section class="ds-sp__list">
        @forelse ($list as $r)
            @php($s = $r['s'])
            <a href="{{ $r['url'] }}" class="ds-board__panel ds-sp__item" wire:key="sh-{{ $s->id }}">
                <span class="ds-sp__icon" aria-hidden="true">{{ $s->mode === 'roro' ? '⛴️' : '🚢' }}</span>
                <span class="ds-sp__main">
                    <b>{{ $s->code }} → {{ $s->hub?->hub_name }}</b>
                    <small>Trip {{ $s->trip?->trip_number }}{{ $s->van_no ? ' · van '.$s->van_no : '' }}{{ $s->vessel ? ' · '.$s->vessel : '' }}{{ $s->eta ? ' · ETA '.$s->eta->format('M j') : '' }}</small>
                    <span class="ds-sp__bar">@foreach ($r['steps'] as $i => $k)<i @class(['is-done' => array_search($s->status, $r['steps']) > $i, 'is-now' => $s->status === $k])></i>@endforeach</span>
                </span>
                <span class="ds-sp__nums"><b class="num">{{ $r['counts']['loaded'] }}</b><small>boxes</small></span>
                <span class="ds-sp__state is-{{ $s->status }}">{{ $r['label'] }}</span>
            </a>
        @empty
            <p class="ds-board__muted">{{ $incoming ? 'No sea shipments coming to your hub right now.' : 'No sea shipments yet.' }}</p>
        @endforelse
    </section>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_30

# ---------------------------------------------------------------- resources/views/filament/shipping/wrong-hub.blade.php
mkdir -p 'resources/views/filament/shipping'
cat > 'resources/views/filament/shipping/wrong-hub.blade.php' <<'DISPATCH_FILE_END_31'
<x-filament-panels::page>
<div class="ds-sp">
    <div class="ds-sp__filter">
        <button type="button" wire:click="$set('tab', 'list')" @class(['is-on' => $tab === 'list'])>List</button>
        <button type="button" wire:click="$set('tab', 'report')" @class(['is-on' => $tab === 'report'])>Report</button>
    </div>

    @if ($tab === 'list')
        @unless ($isAdmin)
            <form wire:submit="addBox" class="ds-board__panel ds-sp__new">
                <h3>Add a box</h3>
                <div class="ds-sp__newrow">
                    <input type="text" wire:model="code" placeholder="Box number" aria-label="Box number">
                    <select wire:model="reason" aria-label="Why">@foreach ($reasons as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                    <input type="text" wire:model="note" placeholder="Note (optional)" maxlength="300" aria-label="Note">
                    <x-filament::button type="submit">Add</x-filament::button>
                </div>
                @error('code')<p class="ds-sp__err">{{ $message }}</p>@enderror
                <p class="ds-board__muted">Wrong-hub boxes are added by themselves when you receive a container.</p>
            </form>
        @endunless

        <section class="ds-board__panel ds-sp__table">
            <div class="ds-sp__tr is-head"><span>Box</span><span>Why</span><span>Suggested way</span><span></span></div>
            @forelse ($list as $r)
                @php($w = $r['w'])
                <div class="ds-sp__tr" wire:key="wh-{{ $w->id }}">
                    <span><b>{{ $w->invoice?->invoice }} · {{ \Illuminate\Support\Str::title($w->invoice?->receiver_name) }}</b><small>{{ collect([$w->invoice?->receiver_city, $w->invoice?->receiver_province])->filter()->join(', ') }}{{ $isAdmin ? ' · at '.$w->hub?->hub_name : '' }}{{ $w->shipment ? ' · '.$w->shipment->code : '' }}</small></span>
                    <span><em @class(['ds-sp__tag', 'is-bad' => $w->reason === 'wrong_hub'])>{{ $reasons[$w->reason] ?? $w->reason }}</em>@if ($w->note)<small>“{{ $w->note }}”</small>@endif</span>
                    <span>
                        @if ($w->status === 'waiting')
                            <b>{{ $r['tip']['text'] }}</b><small>{{ $r['tip']['why'] }}</small>
                            @if ($w->reason === 'wrong_hub')
                                <select wire:change="setHub({{ $w->id }}, $event.target.value)" aria-label="Right hub"><option value="">Right hub: not a partner hub</option>@foreach ($hubs as $hid => $hn)<option value="{{ $hid }}" @selected($w->correct_hub_id == $hid)>Right hub: {{ $hn }}</option>@endforeach</select>
                            @endif
                        @else
                            <b class="ds-sp__ok">✓ {{ \App\Models\Shipping\WrongHubBox::STATUS[$w->status] ?? $w->status }}</b><small>{{ $w->done_at?->format('M j, g:i A') }}{{ $w->status === 'sent_hub' ? ' · '.$w->correctHub?->hub_name : '' }}</small>
                        @endif
                    </span>
                    <span class="ds-sp__btns">
                        @if ($w->status === 'waiting')
                            @if ($r['tip']['way'] === 'hub')<x-filament::button size="sm" wire:click="sendToHub({{ $w->id }})" wire:confirm="Hand {{ $w->invoice?->invoice }} over to {{ $w->correctHub?->hub_name }}?">Send to {{ $w->correctHub?->hub_name }}</x-filament::button>@endif
                            <x-filament::button size="sm" color="gray" wire:click="sendBack({{ $w->id }})" wire:confirm="Send {{ $w->invoice?->invoice }} back to the warehouse?">Back to warehouse</x-filament::button>
                        @endif
                    </span>
                </div>
            @empty
                <p class="ds-board__muted ds-sp__pad">Nothing here. 👍</p>
            @endforelse
        </section>
    @else
        <div class="ds-sp__grid">
            <section class="ds-board__panel ds-sp__box">
                <h3>By reason · {{ now()->format('F') }} · {{ $report['total'] }} {{ str('box')->plural($report['total']) }}</h3>
                @php($max = max(1, ...array_values($report['byReason'] ?: [1])))
                @forelse ($report['byReason'] as $k => $n)<span class="ds-sp__barrow"><span>{{ $k }}</span><i><b style="width: {{ round($n / $max * 100) }}%"></b></i><b class="num">{{ $n }}</b></span>@empty<p class="ds-board__muted">Nothing this month.</p>@endforelse
            </section>
            <section class="ds-board__panel ds-sp__box">
                <h3>By consolidator</h3>
                @php($max2 = max(1, ...array_values($report['byConsolidator'] ?: [1])))
                @forelse ($report['byConsolidator'] as $k => $n)<span class="ds-sp__barrow"><span>{{ $k }}</span><i><b style="width: {{ round($n / $max2 * 100) }}%"></b></i><b class="num">{{ $n }}</b></span>@empty<p class="ds-board__muted">Nothing this month.</p>@endforelse
                <p class="ds-board__muted">If one consolidator causes most of them (wrong addresses on the manifest), show them this, or charge the extra shipping back.</p>
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_31

# ---------------------------------------------------------------- tests/Feature/ScanAppTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/ScanAppTest.php' <<'DISPATCH_FILE_END_32'
<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Models\BoxPhoto;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Unmanifested;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Support\ScanModes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('public');
    Filament::setCurrentPanel(Filament::getPanel('scan'));
});

/** A copy of a demo user without the super_admin role, so we test the account type alone. */
function scanUser(string $email): User
{
    $base = User::where('email', $email)->firstOrFail();
    $u = $base->replicate()->fill(['email' => 'scan-'.$email]);
    $u->save();

    return $u;
}

it('lets warehouse, partner hub and office accounts in, but not drivers', function () {
    $this->actingAs(scanUser('warehouse@example.com'))->get('/scan')->assertOk()->assertSee('Unload container')->assertSee('Warehouse unload');
    $this->flushSession();
    $this->actingAs(scanUser('company@example.com'))->get('/scan')->assertOk()->assertSee('Hub load')->assertDontSee('Unload container');
    $this->flushSession();
    $this->actingAs(scanUser('admin@example.com'))->get('/scan')->assertOk()->assertSee('Load truck');
    $this->flushSession();
    $this->actingAs(scanUser('driver@example.com'))->get('/scan')->assertForbidden();
});

it('gives each account type its own scans', function () {
    expect(array_keys(ScanModes::for(scanUser('warehouse@example.com'))))->toBe(['unload', 'load', 'wh_load', 'wh_unload', 'return', 'port'])
        ->and(array_keys(ScanModes::for(scanUser('company@example.com'))))->toBe(['hub_load', 'return', 'ship_receive'])
        ->and(array_keys(ScanModes::for(scanUser('admin@example.com'))))->toBe(['unload', 'load', 'return', 'port'])
        ->and(ScanModes::for(scanUser('driver@example.com')))->toBe([]);
});

it('unloads a container box by box, with an optional photo, using the same rules as Unload Container', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $container = Container::where('warehouse_id', $user->warehouse_id)->firstOrFail();
    $box = Invoice::where('container_id', $container->id)->where('is_verified', false)->firstOrFail();

    $page = Livewire::test(ScanApp::class)
        ->call('open', 'unload')->assertSet('screen', 'pick')->assertSee($container->container_no)
        ->call('pick', $container->id)->assertSet('screen', 'scan')
        ->call('scan', $box->invoice)
        ->assertSet('status', 'success')->assertSee('Verified · off the container')->assertSee('Add photo · optional')
        ->call('setCondition', 'damaged')->assertSee('What is wrong?')
        ->set('note', 'Corner crushed')
        ->set('boxPhoto', UploadedFile::fake()->image('p.jpg', 2000, 1500))
        ->call('saveBoxPhoto')->assertHasNoErrors();

    expect($box->fresh()->is_verified)->toBeTrue();
    $photo = BoxPhoto::sole();
    expect($photo->step)->toBe('unload')->and($photo->condition)->toBe('damaged')->and($photo->note)->toBe('Corner crushed')
        ->and($photo->container_id)->toBe($container->id)->and($photo->user_id)->toBe($user->id);

    // a box that is not on the manifest
    $page->call('scan', 'NOTONMANIFEST1')->assertSet('status', 'danger')->assertSet('missing', 'NOTONMANIFEST1')
        ->assertSee('Not on this container')
        ->callAction('unmanifested', data: ['attachment_pic' => [UploadedFile::fake()->image('u.jpg')], 'remarks' => 'Found inside'])
        ->assertHasNoActionErrors()->assertSet('missing', null);
    expect(Unmanifested::where('invoice', 'NOTONMANIFEST1')->where('container_id', $container->id)->exists())->toBeTrue();

    $page->call('finish')->assertSet('screen', 'done')->assertSee('Keep scanning')->call('home')->assertSet('screen', 'home');
});

it('loads a delivery truck and refuses a box from another trip', function () {
    $user = scanUser('admin@example.com');
    $this->actingAs($user);
    $trip = Deliverylog::where('logistichub_id', $user->logistichub_id)->whereNotNull('truck_id')->where('is_active', true)->firstOrFail();
    $row = Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', false)->first();
    if (! $row) {
        $row = Tripinvoice::where('deliverylog_id', $trip->id)->firstOrFail();
        $row->update(['is_loaded' => false]);
    }

    Livewire::test(ScanApp::class)
        ->call('open', 'load')->call('pick', $trip->id)
        ->call('scan', $row->invoice)->assertSet('status', 'success')->assertSee('Loaded on the truck')
        ->call('scan', 'NOPE-123')->assertSet('status', 'danger')->assertSee('Keep it aside, scan next');

    expect($row->fresh()->is_loaded)->toBeTruthy();
});

it('does not open a container or trip that is not yours, or a scan your account does not have', function () {
    $user = scanUser('company@example.com');
    $this->actingAs($user);
    $otherTrip = Deliverylog::where('logistichub_id', '!=', $user->logistichub_id)->firstOrFail();

    Livewire::test(ScanApp::class)
        ->call('open', 'unload')->assertSet('screen', 'home')
        ->call('open', 'hub_load')->assertSet('screen', 'pick')
        ->call('pick', $otherTrip->id)->assertSet('screen', 'pick')->assertNotified('That one is not open for you any more.');
});

it('installs as its own app', function () {
    $this->get('/pwa/scan/manifest.webmanifest')->assertOk()->assertJsonPath('short_name', 'Scan')->assertJsonPath('scope', '/scan');
    $this->get('/scan/login')->assertOk()->assertSee('Load and unload, box by box.')->assertSee('/pwa/scan/manifest.webmanifest', false);
});

it('receives a warehouse transfer and adds the box to this warehouse', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $row = Whtripinvoice::firstOrFail();
    $row->update(['is_loaded' => true, 'is_unloaded' => false]);
    $trip = Whdeliverylog::findOrFail($row->whdeliverylog_id);
    $trip->update(['warehouse_id' => $user->warehouse_id]);
    $invoice = Invoice::findOrFail($row->invoice_id);
    $invoice->update(['warehouse_id' => null]);

    Livewire::test(ScanApp::class)
        ->call('open', 'wh_unload')->call('pick', $trip->id)
        ->call('scan', $invoice->invoice)->assertSet('status', 'success')->assertSee('Received · added to inventory');

    expect($row->fresh()->is_unloaded)->toBeTruthy()
        ->and($invoice->fresh()->warehouse_id)->toBe($user->warehouse_id);
});

it('hides finished and closed containers, with a link to show them', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $base = Container::where('warehouse_id', $user->warehouse_id)->firstOrFail();
    $open = $base->replicate()->fill(['container_no' => 'OPEN0000001', 'is_unloaded' => false, 'is_active' => true]);
    $open->save();
    $full = $base->replicate()->fill(['container_no' => 'FULL0000001', 'is_unloaded' => false, 'is_active' => true]);
    $full->save();
    $closed = $base->replicate()->fill(['container_no' => 'SHUT0000001', 'is_unloaded' => false, 'is_active' => false]);
    $closed->save();
    $box = Invoice::where('container_id', $base->id)->firstOrFail();
    $box->replicate()->fill(['invoice' => 'OPENBOX1', 'container_id' => $open->id, 'is_verified' => false])->save();
    $box->replicate()->fill(['invoice' => 'FULLBOX1', 'container_id' => $full->id, 'is_verified' => true])->save();
    $box->replicate()->fill(['invoice' => 'SHUTBOX1', 'container_id' => $closed->id, 'is_verified' => false])->save();

    Livewire::test(ScanApp::class)
        ->assertSee('waiting')
        ->call('open', 'unload')
        ->assertSee('OPEN0000001')->assertDontSee('FULL0000001')->assertDontSee('SHUT0000001')
        ->assertSee('Show finished')
        ->call('toggleFinished')
        ->assertSee('FULL0000001')->assertSee('SHUT0000001')->assertSee('· closed')->assertSee('Hide finished')
        ->call('pick', $full->id)->assertSet('screen', 'scan'); // still openable to re-check
});
DISPATCH_FILE_END_32

# ---------------------------------------------------------------- tests/Feature/SeaShipmentsTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/SeaShipmentsTest.php' <<'DISPATCH_FILE_END_33'
<?php

use App\Filament\Company\Pages\IncomingShipments;
use App\Filament\Company\Pages\SeaShipment as HubShipmentPage;
use App\Filament\Company\Pages\WrongHub as HubWrongHub;
use App\Filament\Pages\SeaShipment as AdminShipmentPage;
use App\Filament\Pages\SeaShipments as AdminShipments;
use App\Filament\Scan\Pages\ScanApp;
use App\Models\Boxes\SetSplit;
use App\Models\Boxes\WhSection;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\WrongHubBox;
use App\Models\Truck;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\HubDesk;
use App\Support\Shipping\Shipments;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    \App\Support\Boxes\Sections::forget();
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $base = User::where('email', 'company@example.com')->firstOrFail();
    $this->hubUser = $base->replicate()->fill(['email' => 'cebu-crew@example.com', 'first_name' => 'Carla']);
    $this->hubUser->save();
    $this->main = Logistichub::where('hub_code', 'MNL')->firstOrFail();
    $this->cebu = Logistichub::where('hub_code', 'CEB')->firstOrFail();
    $this->davao = Logistichub::create(['hub_code' => 'DVO', 'hub_name' => 'Davao Hub', 'is_active' => true, 'is_company' => true, 'trip_counter' => 0, 'user_id' => $this->admin->id]);
    $wh = $this->admin->warehouse_id ?? Container::value('warehouse_id');
    WhSection::create(['warehouse_id' => $wh, 'code' => 'C', 'name' => 'Cebu hub', 'kind' => 'area', 'provinces' => ['Cebu'], 'logistichub_id' => $this->cebu->id]);
    WhSection::create(['warehouse_id' => $wh, 'code' => 'D', 'name' => 'Davao hub', 'kind' => 'area', 'provinces' => ['Davao del Sur'], 'logistichub_id' => $this->davao->id]);

    $tpl = Invoice::firstOrFail();
    $mk = function (string $no, string $name, string $prov) use ($tpl, $wh) {
        $b = $tpl->replicate()->fill(['invoice' => $no, 'receiver_name' => $name, 'receiver_mobile_no' => '0917'.crc32($name), 'receiver_province' => $prov, 'receiver_city' => 'Somewhere',
            'is_verified' => true, 'is_assigned' => false, 'wh_is_assigned' => false, 'is_delivered' => false, 'warehouse_id' => $wh, 'set_key' => null]);
        $b->save();
        $b->update(['wh_section_id' => \App\Support\Boxes\Sections::forInvoice($b, $wh)?->id]);

        return $b->fresh();
    };
    $this->b1 = $mk('SEA-1', 'Maria Santos', 'Cebu');
    $this->b2 = $mk('SEA-2', 'Maria Santos', 'Cebu');       // stays behind
    $this->b3 = $mk('SEA-3', 'Ana Reyes', 'Cebu');          // lost at the port
    $this->b4 = $mk('SEA-4', 'Joy Lim', 'Davao del Sur');   // wrong hub
    $this->b5 = $mk('SEA-5', 'Ken Sy', 'Cebu');

    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->trip = Deliverylog::create(['truck_id' => Truck::value('id'), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $this->cebu->id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, collect([$this->b1, $this->b3, $this->b4, $this->b5]));
});

function loadAll($test): void
{
    foreach (Tripinvoice::where('deliverylog_id', $test->trip->id)->get() as $r) {
        app(TripAssignment::class)->markLoaded($r);
    }
}

it('makes a sea shipment from a trip, and only seals it when everything is loaded', function () {
    Livewire::test(AdminShipments::class)->assertSee('Trip '.$this->trip->trip_number)
        ->set('tripId', $this->trip->id)->set('portCheck', 'count')->call('create')->assertRedirect();
    $s = SeaShipment::sole();
    expect($s->code)->toBe('CEB-0001')->and($s->status)->toBe('preparing')->and($s->logistichub_id)->toBe($this->cebu->id);

    $page = Livewire::test(AdminShipmentPage::class, ['shipmentId' => $s->id])->assertSee('4 boxes on the trip are not loaded')->assertSee('Type the seal number');
    loadAll($this);
    SetSplit::create(['invoice_id' => $this->b2->id, 'deliverylog_id' => $this->trip->id, 'reason' => 'not_found', 'set_key' => $this->b2->set_key]);

    $page->set('f.seal_no', '0048213')->set('f.van_no', 'MSKU220871')->set('f.cost_freight', '32,500')->set('f.cost_trucking', '3800')->call('save')
        ->call('advance')->call('advance');
    expect($s->fresh()->status)->toBe('to_port');

    // count only: 3 of 4 handed over
    $page->call('advance')->assertSee('Type how many boxes were handed over');
    $page->set('f.port_count', '3')->call('save')->call('advance')->assertSee('left the warehouse but was not handed over at the port');
    expect($s->fresh()->status)->toBe('at_port');

    $page->call('advance')->assertSee('Type the vessel');
    $page->set('f.vessel', 'MV 2GO Masagana')->set('f.eta', today()->addDays(2)->toDateString())->call('save')->call('advance');
    $s->refresh();
    expect($s->status)->toBe('sailed')->and(Shipments::trackText($s))->toContain('by sea · arriving about')
        ->and(Shipments::counts($s)['perBox'])->toBe(9075.0);
});

it('lets the partner hub receive the container, flags wrong-hub and missing boxes', function () {
    loadAll($this);
    $s = Shipments::create($this->trip);
    $s->update(['status' => 'sailed', 'seal_no' => '1', 'vessel' => 'MV X', 'eta' => today()]);

    // the hub cannot put a box on its own truck while it is at sea
    $row = Tripinvoice::where('invoice_id', $this->b1->id)->firstOrFail();
    expect(Shipments::stillAtSea($row)?->id)->toBe($s->id);
    expect((new HubDesk($this->cebu->id))->track('SEA-1')['status'])->toContain('by sea');

    $this->actingAs($this->hubUser);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)->call('open', 'ship_receive')->assertSee($s->code)->call('pick', $s->id)
        ->call('scan', 'SEA-1')->assertSet('status', 'success')->assertSee('box 1 of 2')->assertSee('still in Manila')
        ->call('dismiss')->call('scan', 'SEA-4')->assertSet('status', 'warning')->assertSee('is for Davao Hub')
        ->call('dismiss')->call('scan', 'SEA-5')
        ->call('dismiss')->call('scan', 'SEA-5')->assertSee('already scanned');
    expect(Shipments::stillAtSea($row))->toBeNull();

    Filament::setCurrentPanel(Filament::getPanel('company'));
    $this->get(IncomingShipments::getUrl())->assertOk()->assertSee($s->code);
    Livewire::test(HubShipmentPage::class, ['shipmentId' => $s->id])->assertSee('Not scanned in at the hub yet: SEA-3')
        ->call('finishReceiving');
    expect($s->fresh()->status)->toBe('received')
        ->and(Invoiceissue::where('invoice', 'SEA-3')->count())->toBe(1);

    // wrong hub: send it straight to Davao
    $w = WrongHubBox::sole();
    expect($w->correct_hub_id)->toBe($this->davao->id);
    Livewire::test(HubWrongHub::class)->assertSee('Send to Davao Hub direct')->call('sendToHub', $w->id);
    expect(Tripinvoice::where('invoice_id', $this->b4->id)->value('logistichub_id'))->toBe($this->davao->id)
        ->and($w->fresh()->status)->toBe('sent_hub');

    // a refused box goes back to the warehouse
    Livewire::test(HubWrongHub::class)->set('code', 'SEA-5')->set('reason', 'refused')->call('addBox')->assertHasNoErrors()
        ->call('sendBack', WrongHubBox::where('reason', 'refused')->value('id'))
        ->set('tab', 'report')->assertSee('Refused by receiver');
    expect(Tripinvoice::where('invoice_id', $this->b5->id)->exists())->toBeFalse()
        ->and($this->b5->fresh()->is_returned)->toBeTruthy();
});

it('scans boxes at the port for a full-scan shipment', function () {
    loadAll($this);
    $s = Shipments::create($this->trip, 'container', 'full');
    $s->update(['status' => 'to_port', 'seal_no' => '1']);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)->call('open', 'port')->call('pick', $s->id)
        ->call('scan', 'SEA-1')->assertSet('status', 'success')->assertSee('Handed over at the port')
        ->call('dismiss')->call('scan', 'SEA-2')->assertSet('status', 'danger');
    $c = Shipments::counts($s);
    expect($c['port'])->toBe(1)->and($c['missingPort']->all())->toBe(['SEA-3', 'SEA-4', 'SEA-5']);
    expect(Shipments::blockers($s, 'at_port'))->toBe([]);
});

it('runs RoRo without the port and pick-up steps', function () {
    $s = Shipments::create($this->trip, 'roro');
    expect(array_keys(Shipments::steps($s)))->toBe(['preparing', 'sealed', 'to_port', 'sailed', 'arrived', 'received'])
        ->and(Shipments::label($s, 'sailed'))->toBe('On the ferry')
        ->and($s->port_check)->toBe('off');
});
DISPATCH_FILE_END_33

echo "▶ Updating the database (keeps your data)"
php artisan migrate --force

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
