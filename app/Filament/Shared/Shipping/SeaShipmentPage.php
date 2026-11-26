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

    /** The "Change trip" list is open. */
    public bool $changing = false;

    public string $changeSearch = '';

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
        $mine = (int) Auth::user()?->logistichub_id;
        $q = Shipments::visible($hub)->when(static::$hubSide, fn ($q) => $q->where(fn ($q) => $q->where('logistichub_id', $mine)
            ->when(Shipments::stopsReady(), fn ($q) => $q->orWhereIn('id', \App\Models\Shipping\SeaShipmentStop::where('logistichub_id', $mine)->select('sea_shipment_id')))));

        return $q->find($this->shipmentId);
    }

    protected function fillForm(SeaShipment $s): void
    {
        $lcl = \App\Support\Shipping\SeaTrucks::ready() ? ['forwarder', 'waybill_no', 'charge_basis', 'charge_rate', 'hand_over_at', 'pick_up_at'] : [];
        if (\Illuminate\Support\Facades\Schema::hasColumn('sea_shipments', 'forwarder_id')) {
            $lcl = array_merge($lcl, ['forwarder_id', 'hand_over_branch_id', 'pick_up_branch_id']);
        }
        foreach (array_merge(['mode', 'van_no', 'van_size', 'seal_no', 'shipping_line', 'vessel', 'voyage', 'bl_no', 'port_from', 'port_to', 'port_check', 'port_count', 'port_reason', 'cost_freight', 'cost_trucking', 'cost_port', 'cost_other', 'note'], $lcl) as $k) {
            $this->f[$k] = (string) ($s->{$k} ?? '');
        }
        $this->truckCost = \App\Support\Shipping\SeaTrucks::ready()
            ? \App\Support\Shipping\SeaTrucks::trucks($s)->mapWithKeys(fn ($t) => [$t['tripId'] => $t['cost'] !== null ? (string) $t['cost'] : ''])->all() : [];
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
        foreach (['cost_freight', 'cost_trucking', 'cost_port', 'cost_other', 'charge_rate'] as $k) {
            if (array_key_exists($k, $this->f)) {
                $this->f[$k] = str_replace([',', '₱', ' '], '', (string) $this->f[$k]);
            }
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
            'f.forwarder' => 'nullable|string|max:80', 'f.waybill_no' => 'nullable|string|max:40', 'f.charge_basis' => 'nullable|in:'.implode(',', array_keys(Shipments::CHARGES)),
            'f.charge_rate' => 'nullable|numeric|min:0', 'f.hand_over_at' => 'nullable|string|max:160', 'f.pick_up_at' => 'nullable|string|max:160',
            'f.forwarder_id' => 'nullable|integer', 'f.hand_over_branch_id' => 'nullable|integer', 'f.pick_up_branch_id' => 'nullable|integer',
            'sealPhoto' => 'nullable|image|max:12288', 'receipt' => 'nullable|image|max:12288',
        ]);
        $data = collect($this->f)->map(fn ($v) => $v === '' ? null : $v)->all();
        // board 64: the forwarder and its branches come from Settings → Forwarders; the text follows them
        if (! empty($data['forwarder_id']) && ($fw = \App\Models\Shipping\Forwarder::find($data['forwarder_id']))) {
            $data['forwarder'] = $fw->name;
            foreach (['hand_over_branch_id' => 'hand_over_at', 'pick_up_branch_id' => 'pick_up_at'] as $id => $text) {
                $b = ! empty($data[$id]) ? \App\Models\Shipping\ForwarderBranch::where('forwarder_id', $fw->id)->find($data[$id]) : null;
                $data[$id] = $b?->id;
                if ($b) {
                    $data[$text] = $b->line();
                }
            }
        }
        if ($data['port_count'] !== null && (int) $data['port_count'] !== (int) $s->port_count) {
            $data['port_by'] = Auth::id();
            $data['port_at'] = now();
        }
        foreach (['sealPhoto' => 'seal_photo', 'receipt' => 'port_receipt'] as $prop => $col) {
            if ($this->{$prop}) {
                $path = $this->{$prop}->store(\App\Support\Photos\Storage\PhotoFolders::dir('shipments', $s->code ?? null), 'public');
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

    public function openChange(bool $open = true): void
    {
        $this->changing = $open && ! static::$hubSide;
        $this->changeSearch = '';
    }

    public function changeTrip(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        $trip = Shipments::tripsFor(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()), true)->firstWhere('id', $tripId);
        if ($s && $trip && Shipments::changeTrip($s, $trip)) {
            $this->changing = false;
            Notification::make()->title($s->fresh()->code.' now uses trip '.$trip->trip_number)->success()->send();
        }
    }

    public function removeShipment(): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if ($s && Shipments::remove($s)) {
            Notification::make()->title($s->code.' removed')->body('Trip '.$s->trip?->trip_number.' and its boxes stay as they are.')->success()->send();
            $this->redirect(str_replace('SeaShipment', 'SeaShipments', static::class)::getUrl());
        }
    }

    public function finishReceiving(): void
    {
        $s = $this->shipment();
        abort_unless($s && in_array($s->status, ['sailed', 'arrived', 'picked_up'], true), 404);
        abort_unless(static::$hubSide || Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) === null, 403);
        $hubId = static::$hubSide ? (int) Auth::user()?->logistichub_id : null;
        $stop = $hubId ? Shipments::stopFor($s, $hubId) : Shipments::currentStop($s);
        abort_unless($stop && ! $stop->received_at && $this->isTurnOf($s, $stop), 403);
        $made = Shipments::finishReceiving($s, null, (int) $stop->logistichub_id);
        $next = Shipments::currentStop($s->fresh());
        Notification::make()->title(($stop->hub?->hub_name ?? $s->code).' received'.($next ? ' · passed on to '.$next->hub?->hub_name : ''))
            ->body($made ? "{$made} missing ".str('box')->plural($made).': an Invoice Issue was opened for each.' : 'Every box arrived.')->success()->send();
    }

    /** Every stop before this one is received (one container, more hubs). */
    protected function isTurnOf(SeaShipment $s, \App\Models\Shipping\SeaShipmentStop $stop): bool
    {
        return Shipments::stops($s)->every(fn ($x) => $x->stop >= $stop->stop || $x->received_at);
    }

    /** While preparing: put another hub's trip in this container (it unloads after the others). */
    public function addStop(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        $trip = Shipments::tripsFor(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()), true)->firstWhere('id', $tripId);
        if (! $s || ! $trip) {
            return;
        }
        if ($clash = Shipments::portClash([$s->trip, $trip])) {
            Notification::make()->title('Different ports: '.implode(' and ', $clash))->body('One container goes to one port. Make another sea shipment for that trip.')->warning()->send();

            return;
        }
        if (Shipments::addStop($s, $trip)) {
            $this->changing = false;
            Notification::make()->title('Trip '.$trip->trip_number.' ('.$trip->destination?->hub_name.') is now in this container')->success()->send();
        }
    }

    public function removeStop(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if ($s && Shipments::removeStop($s, $tripId)) {
            Notification::make()->title('Trip taken out of this container')->body('The trip and its boxes stay as they are.')->success()->send();
        }
    }

    public bool $adding = false;

    /** Board 62: Container, RoRo or LCL, from the buttons at the top (until the truck leaves). */
    public function setMode(string $mode): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if (! $s || ! array_key_exists($mode, Shipments::MODES) || ! in_array($s->status, ['preparing', 'sealed'], true)) {
            return;
        }
        $s->update(match ($mode) {
            'roro' => ['mode' => 'roro', 'port_check' => 'off', 'port_reason' => $s->port_reason ?: 'RoRo: the truck drives onto the ferry'],
            'lcl' => ['mode' => 'lcl', 'port_check' => 'count'],
            default => ['mode' => 'container', 'port_check' => $s->port_check === 'off' && $s->mode === 'roro' ? 'count' : $s->port_check],
        });
        $this->fillForm($s->fresh());
    }

    /** Board 64: pick the forwarder; its usual rate fills in. */
    public function pickForwarder(int $id): void
    {
        abort_if(static::$hubSide, 403);
        $fw = \App\Models\Shipping\Forwarder::find($id);
        if (! $fw) {
            return;
        }
        $this->f['forwarder_id'] = (string) $fw->id;
        $this->f['forwarder'] = $fw->name;
        $this->f['charge_basis'] = $this->f['charge_basis'] ?: (string) $fw->charge_basis;
        $this->f['charge_rate'] = $this->f['charge_rate'] ?: (string) ($fw->charge_rate ?? '');
        $mine = $fw->branches()->pluck('id')->map(fn ($i) => (string) $i)->all();
        foreach (['hand_over_branch_id', 'pick_up_branch_id'] as $k) {
            if (! in_array((string) ($this->f[$k] ?? ''), $mine, true)) {
                $this->f[$k] = '';
            }
        }
    }

    /** Board 64: ＋ New branch for the chosen forwarder, right from the shipment. */
    public function newBranchAction(): \Filament\Actions\Action
    {
        return \Filament\Actions\Action::make('newBranch')->modalWidth('lg')
            ->modalHeading(fn () => 'New branch · '.(\App\Models\Shipping\Forwarder::find((int) ($this->f['forwarder_id'] ?? 0))?->name ?? ''))
            ->schema([
                \Filament\Forms\Components\Select::make('for')->label('Use it as')->options(['pick_up_branch_id' => 'Pick up at (the hub goes here)', 'hand_over_branch_id' => 'Hand over at (our truck goes here)'])->default('pick_up_branch_id')->required(),
                \Filament\Forms\Components\TextInput::make('name')->label('Branch')->required()->maxLength(80)->placeholder('Cebu · Pier 3'),
                \Filament\Forms\Components\TextInput::make('address')->maxLength(200),
                \Filament\Forms\Components\TextInput::make('hours')->maxLength(60)->placeholder('8 AM–5 PM'),
                \Filament\Forms\Components\TextInput::make('phone')->label('Contact no.')->maxLength(40),
            ])
            ->action(function (array $data) {
                $fid = (int) ($this->f['forwarder_id'] ?? 0);
                if (static::$hubSide || ! $fid) {
                    return;
                }
                $b = \App\Models\Shipping\ForwarderBranch::create(['forwarder_id' => $fid] + collect($data)->only(['name', 'address', 'hours', 'phone'])->all());
                $this->f[$data['for']] = (string) $b->id;
                Notification::make()->title($b->name.' added to the forwarder')->body('Press Save to keep it on this shipment.')->success()->send();
            });
    }

    /** "+ Add a second truck" list is open. */
    public bool $second = false;

    /** truck picked for a trip in that list */
    public array $secondTruck = [];

    public function useSecondTruck(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        $truck = (int) ($this->secondTruck[$tripId] ?? 0) ?: null;
        if ($s && \App\Support\Shipping\SeaTrucks::ownTruck($s, $tripId, $truck)) {
            $this->second = false;
            Notification::make()->title('Second truck added')->success()->send();
        } else {
            Notification::make()->title('Pick the truck for that trip first')->warning()->send();
        }
    }

    /** Board 62: this trip goes with the main truck. */
    public function goWithMain(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if ($s && \App\Support\Shipping\SeaTrucks::goWithMain($s, $tripId)) {
            Notification::make()->title('It goes with the main truck now')->body('Load it on the main truck\'s trip in the Scan app.')->success()->send();
        }
    }

    /** Board 62: this trip keeps its own truck (a second truck). */
    public function ownTruck(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        if ($s && \App\Support\Shipping\SeaTrucks::ownTruck($s, $tripId)) {
            Notification::make()->title('Second truck: this trip uses its own truck')->success()->send();
        } else {
            Notification::make()->title('This trip has no truck of its own')->body('Give the trip a truck first (Delivery trips), then press this again.')->warning()->send();
        }
    }

    /** @var array<int, string> trucking per truck trip */
    public array $truckCost = [];

    public function saveTruckCost(int $tripId): void
    {
        abort_if(static::$hubSide, 403);
        $s = $this->shipment();
        $v = str_replace([',', '₱', ' '], '', (string) ($this->truckCost[$tripId] ?? ''));
        if (! $s || ($v !== '' && ! is_numeric($v))) {
            return;
        }
        \App\Support\Shipping\SeaTrucks::setCost($s, $tripId, $v === '' ? null : (float) $v);
        $this->fillForm($s->fresh());
        Notification::make()->title('Trucking saved')->success()->send();
    }

    public function openAdd(bool $open = true): void
    {
        $this->adding = $open && ! static::$hubSide;
        $this->changing = false;
        $this->changeSearch = '';
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
            'openSets' => \App\Models\Deliverylog::whereIn('id', Shipments::tripIds($s))->get()->flatMap(fn ($t) => BoxSets::openOnTrip($t))->all(),
            'stops' => $stops = Shipments::stops($s),
            'wrong' => WrongHubBox::with('invoice', 'correctHub')->where('sea_shipment_id', $s->id)->get(),
            'modes' => Shipments::MODES,
            'charges' => Shipments::CHARGES,
            'forwarders' => \Illuminate\Support\Facades\Schema::hasTable('forwarders') ? \App\Models\Shipping\Forwarder::with('branches')->where(fn ($q) => $q->where('is_active', true)->orWhere('id', (int) ($this->f['forwarder_id'] ?? 0)))->orderBy('name')->get() : collect(),
            'ports' => \Illuminate\Support\Facades\Schema::hasTable('ports') ? \App\Models\Shipping\Port::where('is_active', true)->orderBy('name')->pluck('name') : collect(),
            'stopBoxes' => \App\Models\Tripinvoice::whereIn('deliverylog_id', Shipments::tripIds($s))->selectRaw('deliverylog_id, count(*) n')->groupBy('deliverylog_id')->pluck('n', 'deliverylog_id'),
            'hubTrucks' => $this->second ? \App\Models\Truck::where('is_active', 1)->where('logistichub_id', $s->trip?->logistichub_id)->orderBy('plate_no')->pluck('plate_no', 'id') : collect(),
            'trucks' => $trucks = \App\Support\Shipping\SeaTrucks::ready() ? \App\Support\Shipping\SeaTrucks::trucks($s) : collect(),
            'canTruck' => ! static::$hubSide && \App\Support\Shipping\SeaTrucks::ready() && \App\Support\Shipping\SeaTrucks::canChange($s),
            'carrierPlate' => fn ($st) => \App\Support\Shipping\SeaTrucks::ready() ? $trucks->first(fn ($t) => $t['stops']->contains('deliverylog_id', $st->deliverylog_id))['plate'] ?? null : null,
            'rides' => fn ($st) => \App\Support\Shipping\SeaTrucks::ready() && $st->exists && \App\Support\Shipping\SeaTrucks::rides($s, $st),
            'checks' => Shipments::PORT_CHECKS,
            'hubSide' => static::$hubSide,
            'canPress' => $to && $to !== 'received' && (! static::$hubSide || in_array($to, ['arrived', 'picked_up'], true)),
            'receiveStop' => $rs = in_array($s->status, ['sailed', 'arrived', 'picked_up'], true) && (static::$hubSide || Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) === null)
                ? (static::$hubSide ? Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) : Shipments::currentStop($s)) : null,
            'canReceive' => $rs && ! $rs->received_at && $this->isTurnOf($s, $rs),
            'nextAfter' => $rs ? $stops->first(fn ($x) => $x->stop > $rs->stop && ! $x->received_at)?->hub?->hub_name : null,
            'addTrips' => $this->adding ? Shipments::tripsFor(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()))->filter(fn ($t) => ! Shipments::portClash([$s->trip, $t])) : collect(),
            'whenOf' => fn ($st) => Shipments::when($s, $st),
            'changeTrips' => $this->changing ? Shipments::tripsFor(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()))
                ->filter(fn ($t) => $this->changeSearch === '' || collect(preg_split('/\s+/', mb_strtolower(trim($this->changeSearch))))->filter()
                    ->every(fn ($w) => str_contains(mb_strtolower($t->trip_number.' '.$t->destination?->hub_name.' '.$t->truck?->plate_no), $w)))->take(20) : collect(),
        ];
    }
}
