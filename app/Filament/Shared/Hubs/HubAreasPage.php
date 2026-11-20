<?php

namespace App\Filament\Shared\Hubs;

use App\Models\Hubs\HubArea;
use App\Models\Hubs\HubAreaRequest;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\AppSetting;
use App\Support\Hubs\HubAreas;
use App\Support\Maps\Barangays;
use App\Support\Trips\TripRules;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/** Settings → Hub areas: which partner hub delivers each place. Admin and Super admin. */
class HubAreasPage extends Page
{
    protected string $view = 'filament.hubs.areas';

    protected static ?string $slug = 'hub-areas';

    protected static ?string $title = 'Hub areas';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-map';

    /** @var array<int, array{province?: string, city?: string, barangay?: string}> */
    public array $add = [];

    public ?array $conflict = null;

    public static function canAccess(): bool
    {
        return HubAreas::ready() && TripRules::isOffice(Auth::user());
    }

    public static function getNavigationBadge(): ?string
    {
        $n = HubAreas::pendingCount();

        return $n ? (string) $n : null;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function addPlace(int $hubId): void
    {
        $f = $this->add[$hubId] ?? [];
        if (blank($f['province'] ?? null)) {
            Notification::make()->title('Type the province')->warning()->send();

            return;
        }
        $r = HubAreas::add($hubId, $f['province'], $f['city'] ?? null, $f['barangay'] ?? null, Auth::user());
        if (isset($r['conflict'])) {
            $this->conflict = ['hub' => $hubId, 'area' => $r['conflict']->id, 'owner' => (int) $r['conflict']->logistichub_id, 'label' => $r['conflict']->label()];

            return;
        }
        $this->add[$hubId] = [];
        $this->conflict = null;
    }

    public function moveIt(): void
    {
        if ($this->conflict && ($a = HubArea::find($this->conflict['area']))) {
            HubAreas::add($this->conflict['hub'], $a->province, $a->city, $a->barangay, Auth::user(), true);
            $this->add[$this->conflict['hub']] = [];
        }
        $this->conflict = null;
    }

    public function cancel(): void
    {
        $this->conflict = null;
    }

    public function removeArea(int $id): void
    {
        if ($a = HubArea::find($id)) {
            HubAreas::remove($a, Auth::user());
        }
    }

    public function decide(int $id, bool $yes): void
    {
        HubAreas::decide(HubAreaRequest::where('status', 'pending')->findOrFail($id), $yes, Auth::user());
    }

    /** A switched-off hub: keep its places direct (hide this warning) or give them to another hub. */
    public function keepDirect(int $hubId): void
    {
        AppSetting::put('hubs.orphan_ok.'.$hubId, '1');
    }

    public function giveTo(int $fromHub, int $toHub): void
    {
        $n = 0;
        foreach (HubArea::where('logistichub_id', $fromHub)->get() as $a) {
            $n += HubAreas::add($toHub, $a->province, $a->city, $a->barangay, Auth::user(), true)['ok'] ? 1 : 0;
        }
        Notification::make()->title($n.' places given to '.HubAreas::name($toHub))->success()->send();
    }

    protected function getViewData(): array
    {
        $areas = HubArea::query()->orderBy('province')->orderBy('city')->orderBy('barangay')->get()->groupBy('logistichub_id');
        $hubs = HubAreas::hubs()->map(fn (Logistichub $h) => ['hub' => $h, 'areas' => $areas[$h->id] ?? collect()]);
        $split = HubAreas::splitCities();

        // boxes waiting in a shared city with no barangay: they go to the city's main hub, or to Addresses to check
        $unclear = 0;
        foreach ($split as $s) {
            $unclear += Invoice::query()->where('is_verified', true)->where('is_assigned', false)->where('is_delivered', false)
                ->where('receiver_city', 'like', $s['city'].'%')->where('receiver_province', 'like', $s['province'])->limit(500)->get()
                ->filter(fn ($i) => Barangays::of($i) === null)->count();
        }

        return [
            'hubs' => $hubs, 'split' => $split, 'unclear' => $unclear,
            'requests' => HubAreaRequest::with(['hub', 'user'])->where('status', 'pending')->latest('id')->get(),
            'answered' => HubAreaRequest::with('hub')->where('status', '!=', 'pending')->latest('decided_at')->limit(3)->get(),
            'orphans' => HubAreas::orphans()->reject(fn ($o) => AppSetting::get('hubs.orphan_ok.'.$o['id'])),
            'log' => DB::table('hub_area_log')->latest('id')->limit(8)->get(),
            'colors' => ['#1d6fb8', '#c97a00', '#17895e', '#7a4fd6', '#c2410c', '#0e7490'],
            'setupUrl' => class_exists($p = str_replace('HubAreas', 'HubSetup', static::class)) && $p !== static::class ? $p::getUrl() : null,
            'provinces' => collect(HubAreas::REGIONS)->flatten()->sort()->values(),
        ];
    }
}
