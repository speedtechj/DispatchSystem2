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

    /** Warehouse panel: the boxes coming back to the warehouse, from every hub (view only). */
    protected static bool $comingBack = false;

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
        if (static::$comingBack) {
            return null;
        }
        $h = Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());

        return is_int($h) ? $h : null;
    }

    protected function find(int $id): ?WrongHubBox
    {
        return WrongHubBox::with('correctHub', 'tripinvoice')->when($this->hub(), fn ($q, $h) => $q->where('logistichub_id', $h))->find($id);
    }

    public function addBox(): void
    {
        abort_if(static::$comingBack, 403);
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
        abort_if(static::$comingBack, 403);
        $w = $this->find($id);
        if ($w && $w->status === 'waiting' && WrongHub::sendToHub($w)) {
            Notification::make()->title('Handed over to '.$w->correctHub?->hub_name)->success()->send();
        }
    }

    /** Put the box on this hub's return shipment to the warehouse. */
    public function sendBack(int $id): void
    {
        abort_if(static::$comingBack, 403);
        $w = $this->find($id);
        if ($w && $w->status === 'waiting') {
            $rs = \App\Support\Shipping\Returns::add($w);
            Notification::make()->title($w->invoice?->invoice.' is on return shipment '.$rs->code)->body('Send the return shipment when it is ready (tab Return shipment).')->success()->send();
        }
    }

    public function takeOff(int $id): void
    {
        abort_if(static::$comingBack, 403);
        $w = $this->find($id);
        if ($w) {
            \App\Support\Shipping\Returns::remove($w);
        }
    }

    public array $rf = ['van_no' => '', 'seal_no' => '', 'vessel' => '', 'bl_no' => '', 'eta' => '', 'cost' => '', 'note' => ''];

    protected function openReturn(): ?\App\Models\Shipping\ReturnShipment
    {
        $hub = $this->hub() ?? (int) Auth::user()?->logistichub_id;

        return \App\Models\Shipping\ReturnShipment::where('logistichub_id', $hub)->where('status', 'preparing')->latest('id')->first();
    }

    public function saveReturn(): void
    {
        abort_if(static::$comingBack, 403);
        $rs = $this->openReturn();
        if (! $rs) {
            return;
        }
        $this->rf['cost'] = str_replace([',', '₱', ' '], '', (string) $this->rf['cost']);
        $this->validate(['rf.van_no' => 'nullable|string|max:20', 'rf.seal_no' => 'nullable|string|max:30', 'rf.vessel' => 'nullable|string|max:80',
            'rf.bl_no' => 'nullable|string|max:40', 'rf.eta' => 'nullable|date', 'rf.cost' => 'nullable|numeric|min:0', 'rf.note' => 'nullable|string|max:300']);
        $rs->update(collect($this->rf)->map(fn ($v) => $v === '' ? null : $v)->all());
        Notification::make()->title('Saved')->success()->send();
    }

    public function sendReturn(): void
    {
        abort_if(static::$comingBack, 403);
        $rs = $this->openReturn();
        if ($rs && \App\Support\Shipping\Returns::send($rs)) {
            Notification::make()->title($rs->code.' sent to the warehouse')->success()->send();
        }
    }

    /** Warehouse: every box was scanned in (Scan app → Receive returns). */
    public function finishReturn(int $id): void
    {
        abort_unless(static::$comingBack, 403);
        $rs = \App\Models\Shipping\ReturnShipment::where('status', 'sent')->find($id);
        if ($rs) {
            $made = \App\Support\Shipping\Returns::finish($rs);
            Notification::make()->title($rs->code.' received')->body($made ? $made.' missing: an Invoice Issue was opened for each.' : 'Every box arrived.')->success()->send();
        }
    }

    public function setHub(int $id, ?int $hubId): void
    {
        abort_if(static::$comingBack, 403);
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

        $rows = $list->map(fn ($w) => ['w' => $w, 'tip' => WrongHub::suggestion($w)]);
        if (static::$comingBack) {
            $rows = $rows->filter(fn ($r) => in_array($r['w']->status, ['back', 'returning'], true) || ($r['w']->status === 'waiting' && $r['tip']['way'] === 'back'))->values();
        }
        $open = ! static::$comingBack && \App\Support\Shipping\Returns::ready() ? $this->openReturn() : null;
        if ($open && $this->tab === 'return' && ! array_filter($this->rf)) {
            foreach (array_keys($this->rf) as $k) {
                $this->rf[$k] = (string) ($k === 'eta' ? $open->eta?->toDateString() : $open->{$k});
            }
        }

        return [
            'comingBack' => static::$comingBack,
            'openReturn' => $open,
            'openBoxes' => $open ? $open->boxes()->with('invoice')->get() : collect(),
            'returns' => \App\Support\Shipping\Returns::ready() ? \App\Models\Shipping\ReturnShipment::with('hub:id,hub_name')->withCount('boxes')
                ->when(! static::$comingBack, fn ($q) => $q->where('logistichub_id', $this->hub() ?? (int) Auth::user()?->logistichub_id))
                ->when(static::$comingBack, fn ($q) => $q->whereIn('status', ['sent', 'received']))
                ->latest('id')->limit(20)->get()->map(fn ($rs) => ['rs' => $rs, 'c' => \App\Support\Shipping\Returns::counts($rs)]) : collect(),
            'list' => $rows,
            'report' => $this->tab === 'report' ? WrongHub::report($hub) : null,
            'reasons' => WrongHubBox::REASONS,
            'hubs' => \App\Models\Logistichub::where('is_company', true)->orderBy('hub_name')->pluck('hub_name', 'id'),
            'isAdmin' => $hub === null && ! static::$comingBack,
        ];
    }
}
