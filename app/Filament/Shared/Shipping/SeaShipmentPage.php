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
