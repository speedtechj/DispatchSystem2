<?php

namespace App\Filament\Shared\Trucks;

use App\Models\Truck;
use App\Models\TruckMerge;
use App\Support\Tracking\Tracker;
use App\Support\TruckDuplicates;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/** Same truck twice: compare the copies, keep one, move everything to it; Undo for 7 days. */
class TruckDuplicatesPage extends Page
{
    protected string $view = 'filament.trucks.duplicates';

    protected static ?string $slug = 'truck-duplicates';

    protected static bool $shouldRegisterNavigation = false;

    #[Url(as: 'trucks')]
    public string $ids = '';

    #[Url(as: 'merge')]
    public ?int $mergeId = null;

    public ?int $keep = null;

    public static function canAccess(): bool
    {
        return TruckDuplicates::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    /** The copies, most trips first; only trucks this panel may see. */
    public function copies()
    {
        $ids = collect(explode(',', $this->ids))->map(fn ($i) => (int) $i)->filter()->unique();

        return Truck::with(['logistichub', 'rentalCompany'])->whereIn('id', $ids)->get()
            ->filter(fn ($t) => Tracker::canSeeTruck($this->hub(), $t))
            ->sort(fn ($a, $b) => TruckDuplicates::rank($b) <=> TruckDuplicates::rank($a))->values();
    }

    public function merge(): ?TruckMerge
    {
        $m = $this->mergeId ? TruckMerge::with(['kept', 'dropped'])->find($this->mergeId) : null;

        return $m && $m->kept && Tracker::canSeeTruck($this->hub(), $m->kept) ? $m : null;
    }

    public function mount(): void
    {
        if ($this->mergeId) {
            abort_unless($this->merge(), 404);

            return;
        }
        $copies = $this->copies();
        abort_if($copies->count() < 2, 404);
        $this->keep = $copies->first()->id;
    }

    public function getTitle(): string|Htmlable
    {
        return 'Duplicate trucks';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function pick(int $id): void
    {
        if ($this->copies()->contains('id', $id)) {
            $this->keep = $id;
        }
    }

    public function doMerge(): void
    {
        $copies = $this->copies();
        $keep = $copies->firstWhere('id', $this->keep);
        abort_unless($keep && $copies->count() >= 2, 422);
        $last = null;
        foreach ($copies->where('id', '!=', $keep->id) as $drop) {
            $last = TruckDuplicates::merge($keep, $drop, Auth::id());
        }
        Notification::make()->title('Merged into '.$keep->plate_no)->success()->send();
        $this->mergeId = $last->id;
        $this->ids = '';
    }

    public function different(): void
    {
        $copies = $this->copies();
        foreach ($copies as $i => $a) {
            foreach ($copies->slice($i + 1) as $b) {
                TruckDuplicates::markDifferent($a, $b, Auth::id());
            }
        }
        Notification::make()->title('Marked as different trucks')->success()->send();
        $this->redirect($this->fleetUrl() ?? '/');
    }

    public function undo(): void
    {
        $m = $this->merge();
        abort_unless($m && TruckDuplicates::canUndo($m), 422);
        TruckDuplicates::undo($m);
        Notification::make()->title('Undone: '.$m->dropped?->plate_no.' is back as it was')->success()->send();
        $this->ids = $m->kept_id.','.$m->dropped_id;
        $this->mergeId = null;
        $this->keep = $m->kept_id;
    }

    protected function fleetUrl(): ?string
    {
        $p = str_replace('TruckDuplicates', 'Fleet', static::class);

        return static::class !== self::class && class_exists($p) ? $p::getUrl() : null;
    }

    public static function urlFor(iterable $trucks): ?string
    {
        return static::class === self::class ? null : static::getUrl(['trucks' => collect($trucks)->pluck('id')->join(',')]);
    }

    protected function getViewData(): array
    {
        $m = $this->mergeId ? $this->merge() : null;
        $colors = FleetPage::COLORS;
        $copies = $m ? collect() : $this->copies()->map(fn (Truck $t) => [
            't' => $t, 's' => TruckDuplicates::stats($t), 'color' => $colors[$t->id % count($colors)],
            'line' => collect([$t->category, $t->make_model, $t->logistichub?->hub_name, 'added '.$t->created_at?->format('M j, Y')])->filter()->join(' · '),
        ]);
        $keep = $copies->firstWhere('t.id', $this->keep);
        $drops = $copies->where('t.id', '!=', $this->keep);
        $profile = str_replace('TruckDuplicates', 'TruckProfile', static::class);

        return [
            'm' => $m, 'copies' => $copies, 'keepCard' => $keep, 'drops' => $drops,
            'moved' => $m ? collect($m->moved)->map(fn ($ids) => count($ids)) : collect(),
            'canUndo' => $m && TruckDuplicates::canUndo($m),
            'fleetUrl' => $this->fleetUrl(),
            'keptUrl' => $m && static::class !== self::class && class_exists($profile) ? $profile::getUrl(['truck' => $m->kept_id]) : null,
            'title' => TruckDuplicates::format($copies->first()['t']->plate_no ?? ''),
        ];
    }
}
