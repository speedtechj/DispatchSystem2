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
