<?php

namespace App\Filament\Pages;

use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Truck;
use App\Support\Ai\Ai;
use App\Support\BoxSizes;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/**
 * Admin → Settings → Box sizes. The box types come from the manifests; the normal box is 1
 * and the others are set next to it. Same box, different spelling: join them. Each truck's
 * space is in normal boxes. Changes are saved right away.
 */
class BoxSizeSettings extends Page
{
    protected string $view = 'filament.boxes.settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedCube;

    protected static ?string $navigationLabel = 'Box sizes';

    protected static ?string $title = 'Box sizes';

    protected static ?string $slug = 'box-sizes';

    protected static ?int $navigationSort = 89;

    /** AI look-alikes: [[from id, into id, why]] */
    public array $aiPairs = [];

    public bool $aiChecked = false;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        BoxSizes::sync();
    }

    public function toggle(): void
    {
        AppSetting::put(BoxSizes::SETTING, BoxSizes::switchedOn() ? '0' : '1');
        BoxSizes::forget();
    }

    public function step(int $id, int $dir): void
    {
        if ($size = BoxSize::find($id)) {
            BoxSizes::setSpace($size, (float) $size->space + ($dir > 0 ? 0.5 : -0.5));
        }
    }

    /** "Looks right": a new type keeps 1 and is no longer new. */
    public function confirm(int $id): void
    {
        BoxSize::whereKey($id)->update(['is_set' => true]);
        BoxSizes::forget();
    }

    public function makeBase(int $id): void
    {
        if ($size = BoxSize::find($id)) {
            BoxSizes::setBase($size);
            Notification::make()->title("{$size->name} is now your normal box (1)")->body('The other sizes were changed to stay the same real size.')->success()->send();
        }
    }

    public function join(int $from, int $into): void
    {
        $a = BoxSize::find($from);
        $b = BoxSize::find($into);
        if ($a && $b) {
            BoxSizes::join($a, $b);
            $this->aiPairs = array_values(array_filter($this->aiPairs, fn ($p) => $p[0] !== $from && $p[1] !== $from));
            Notification::make()->title("“{$a->name}” joined to {$b->name}")->success()->send();
        }
    }

    public function keepApart(int $a, int $b): void
    {
        $x = BoxSize::find($a);
        $y = BoxSize::find($b);
        if ($x && $y) {
            BoxSizes::keepApart($x, $y);
            $this->aiPairs = array_values(array_filter($this->aiPairs, fn ($p) => ! in_array($p[0], [$a, $b], true) || ! in_array($p[1], [$a, $b], true)));
        }
    }

    public function askAi(): void
    {
        $this->aiChecked = true;
        $this->aiPairs = collect(BoxSizes::lookAlikeAi())->map(fn ($p) => [$p['from']->id, $p['into']->id, $p['why']])->all();
        if (! $this->aiPairs) {
            Notification::make()->title('The AI found no other look-alikes')->send();
        }
    }

    public function setDim(int $id, string $field, mixed $value): void
    {
        if (! in_array($field, ['length_cm', 'width_cm', 'height_cm'], true) || ! \App\Support\TruckSpace::ready()) {
            return;
        }
        $v = (int) $value;
        BoxSize::whereKey($id)->update([$field => $v >= 1 && $v <= 999 ? $v : null]);
        BoxSizes::forget();
    }

    /** Use the space worked out from the box size. */
    public function useDims(int $id): void
    {
        $size = BoxSize::find($id);
        if ($size && ($sp = \App\Support\TruckSpace::spaceFromDims($size))) {
            BoxSizes::setSpace($size, $sp);
        }
    }

    public function setTruckDim(int $id, string $field, mixed $value): void
    {
        $limits = ['cargo_length_cm' => [1, 2000], 'cargo_width_cm' => [1, 2000], 'cargo_height_cm' => [1, 2000], 'fill_pct' => [40, 100], 'reserve_pct' => [0, 50]];
        if (! isset($limits[$field]) || ! \App\Support\TruckSpace::ready()) {
            return;
        }
        $v = trim((string) $value) === '' ? null : (int) $value;
        Truck::whereKey($id)->update([$field => $v !== null && $v >= $limits[$field][0] && $v <= $limits[$field][1] ? $v : null]);
    }

    /** Use the space worked out from the truck's cargo box. */
    public function useFit(int $id): void
    {
        $truck = Truck::find($id);
        if ($truck && ($fit = \App\Support\TruckSpace::fit($truck))) {
            $truck->update(['capacity' => $fit]);
        }
    }

    public function truckStep(int $id, int $dir): void
    {
        $truck = Truck::find($id);
        if ($truck) {
            $now = (int) ($truck->capacity ?: 50);
            $truck->update(['capacity' => max(1, min(2000, $now + ($dir > 0 ? 1 : -1)))]);
        }
    }

    public function setTruck(int $id, mixed $value): void
    {
        $v = (int) $value;
        if ($v >= 1 && $v <= 2000) {
            Truck::whereKey($id)->update(['capacity' => $v]);
        }
    }

    protected function getViewData(): array
    {
        $sizes = BoxSizes::sizes();
        $counts30 = BoxSizes::counts(30);
        $countsAll = BoxSizes::counts();
        $written = BoxSizes::spellingsShown();
        $byId = $sizes->keyBy('id');

        $pairs = collect(BoxSizes::lookAlike())->map(fn ($p) => [$p['from']->id, $p['into']->id, $p['why']]);
        foreach ($this->aiPairs as $p) {
            if ($byId->has($p[0]) && $byId->has($p[1]) && ! $pairs->contains(fn ($q) => $q[0] === $p[0])) {
                $pairs->push($p);
            }
        }

        $trucks = Truck::where('is_active', true)->orderBy('plate_no')->get();
        $past = BoxSizes::truckPast($trucks->pluck('id')->all());
        $big = $sizes->where('is_set', true)->sortByDesc('space')->first();
        $small = $sizes->where('is_set', true)->sortBy('space')->first();

        return [
            'on' => BoxSizes::switchedOn(),
            'working' => BoxSizes::on(),
            'sizes' => $sizes,
            'base' => $sizes->firstWhere('is_base', true),
            'counts30' => $counts30,
            'countsAll' => $countsAll,
            'written' => $written,
            'noType' => Invoice::query()->where(fn ($q) => $q->whereNull('boxtype')->orWhere('boxtype', ''))->where('created_at', '>=', now()->subDays(30))->count(),
            'pairs' => $pairs->map(fn ($p) => ['from' => $byId[$p[0]], 'into' => $byId[$p[1]], 'why' => $p[2]])->values(),
            'trucks' => $trucks,
            'past' => $past,
            'hubs' => Logistichub::pluck('hub_name', 'id'),
            'big' => $big && $big->space > 1 ? $big : null,
            'small' => $small && $small->space < 1 ? $small : null,
            'aiOn' => Ai::enabled('box_sizes'),
            'dimsOn' => \App\Support\TruckSpace::ready(),
        ];
    }
}
