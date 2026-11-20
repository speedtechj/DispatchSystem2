<?php

namespace App\Filament\Shared\Hubs;

use App\Models\Hubs\HubArea;
use App\Models\Logistichub;
use App\Support\Hubs\HubAreas;
use App\Support\Trips\TripRules;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Livewire\Attributes\Url;

/** Settings → Hubs → add a hub (or set where a hub is) and approve its suggested area. */
class HubSetupPage extends Page
{
    protected string $view = 'filament.hubs.setup';

    protected static ?string $slug = 'hub-setup';

    protected static ?string $title = 'Add a hub';

    protected static bool $shouldRegisterNavigation = false;

    #[Url]
    public ?int $hub = null;

    public array $form = ['name' => '', 'code' => '', 'province' => '', 'city' => '', 'barangay' => '', 'phone' => ''];

    /** @var array<int, bool> suggestions left out (by index) */
    public array $leave = [];

    /** @var array<int, string> "closer" places: area id => yes|no */
    public array $move = [];

    public bool $saved = false;

    public static function canAccess(): bool
    {
        return HubAreas::ready() && TripRules::isOffice(Auth::user());
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function mount(): void
    {
        if ($h = $this->record()) {
            $this->form = ['name' => $h->hub_name, 'code' => $h->hub_code, 'province' => (string) $h->province, 'city' => (string) $h->city, 'barangay' => (string) $h->barangay, 'phone' => (string) $h->phone];
        }
    }

    protected function record(): ?Logistichub
    {
        return $this->hub ? Logistichub::where('is_company', true)->find($this->hub) : null;
    }

    public function save(): void
    {
        $f = array_map(fn ($v) => Str::squish((string) $v), $this->form);
        if ($f['name'] === '' || $f['code'] === '' || $f['province'] === '') {
            Notification::make()->title('Fill in the name, the code and where the hub is (province)')->warning()->send();

            return;
        }
        $code = Str::upper($f['code']);
        if (Logistichub::where('hub_code', $code)->when($this->hub, fn ($q) => $q->whereKeyNot($this->hub))->exists()) {
            Notification::make()->title('The code '.$code.' is used by another hub')->warning()->send();

            return;
        }
        $h = $this->record() ?? (new Logistichub)->forceFill(['is_company' => true, 'is_active' => true, 'trip_counter' => 0, 'user_id' => Auth::id()]);
        $h->forceFill(['hub_name' => $f['name'], 'hub_code' => $code, 'province' => Str::title($f['province']), 'city' => $f['city'] ? Str::title($f['city']) : null,
            'barangay' => $f['barangay'] ?: null, 'phone' => $f['phone'] ?: null])->save();
        $this->hub = $h->id;
        Notification::make()->title($h->hub_name.' saved')->success()->send();
    }

    public function toggleLeave(int $i): void
    {
        $this->leave[$i] = ! ($this->leave[$i] ?? false);
    }

    public function decideMove(int $areaId, string $yes): void
    {
        $this->move[$areaId] = $yes === 'yes' ? 'yes' : 'no';
    }

    public function approve(): void
    {
        $h = $this->record();
        if (! $h) {
            return;
        }
        $s = HubAreas::suggest($h);
        $n = 0;
        foreach ($s['free'] as $i => $g) {
            if (empty($this->leave[$i])) {
                $n += HubAreas::add($h->id, $g['province'], $g['city'], null, Auth::user())['ok'] ? 1 : 0;
            }
        }
        foreach ($this->move as $areaId => $yes) {
            if ($yes === 'yes' && ($a = HubArea::find($areaId))) {
                $n += HubAreas::add($h->id, $a->province, $a->city, $a->barangay, Auth::user(), true)['ok'] ? 1 : 0;
            }
        }
        $this->saved = true;
        $this->leave = [];
        $this->move = [];
        Notification::make()->title($h->hub_name.': '.$n.' '.Str::plural('place', $n).' approved')->success()->send();
    }

    public function toggleActive(): void
    {
        if ($h = $this->record()) {
            $h->forceFill(['is_active' => ! $h->is_active])->save();
            HubAreas::log($h->id, $h->hub_name.' switched '.($h->is_active ? 'on' : 'off'), Auth::user());
        }
    }

    protected function getViewData(): array
    {
        $h = $this->record();
        $s = $h ? HubAreas::suggest($h) : ['free' => [], 'closer' => []];
        $picked = collect($s['free'])->keys()->reject(fn ($i) => ! empty($this->leave[$i]))->count() + collect($this->move)->filter(fn ($v) => $v === 'yes')->count();
        $areasPage = str_replace('HubSetup', 'HubAreas', static::class);

        return [
            'record' => $h, 'free' => $s['free'], 'closer' => $s['closer'], 'picked' => $picked,
            'mine' => $h ? HubArea::where('logistichub_id', $h->id)->get() : collect(),
            'provinces' => collect(HubAreas::REGIONS)->flatten()->sort()->values(),
            'areasUrl' => class_exists($areasPage) && $areasPage !== static::class ? $areasPage::getUrl() : null,
        ];
    }
}
