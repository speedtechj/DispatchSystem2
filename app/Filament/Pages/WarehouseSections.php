<?php

namespace App\Filament\Pages;

use App\Models\Boxes\WhSection;
use App\Models\Boxes\WhSpot;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Warehouse;
use App\Support\Boxes\Sections;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use UnitEnum;

/**
 * Admin → Settings → Warehouse sections: each section of a warehouse is for one destination,
 * chosen by the receiver's province. The Scan app shows the section for each box at unload.
 */
class WarehouseSections extends Page
{
    protected string $view = 'filament.boxes.sections';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedSquares2x2;

    protected static ?string $navigationLabel = 'Warehouse sections';

    protected static ?string $title = 'Settings · Warehouse sections';

    protected static ?string $slug = 'warehouse-sections';

    protected static ?int $navigationSort = 93;

    public ?int $warehouseId = null;

    /** @var list<array{id: ?int, code: string, name: string, color: string, kind: string, to: string, provinces: list<string>, cities: list<string>, use_spots: bool, spots: list<string>}> */
    public array $rows = [];

    public bool $labelScan = false;

    /** Sections by "province" (default) or "city" (board 50b). */
    public string $by = 'province';

    /** Spots inside sections (C1, C2…), optional (board 50). */
    public bool $spotsOn = false;

    /** The row whose province or city list is open, and what is typed in its search. */
    public ?int $pickRow = null;

    public string $pickQ = '';

    public const COLORS = ['#1d6fb8', '#17895e', '#8a4bd1', '#e8590c', '#c8372d', '#0e2433', '#b07400', '#0f8b8d'];

    public static function canAccess(): bool
    {
        return Sections::ready() && (bool) Auth::user()?->hasRole('super_admin');
    }

    public function mount(): void
    {
        $this->warehouseId = Auth::user()?->warehouse_id ?? Warehouse::orderBy('id')->value('id');
        $this->loadRows();
    }

    public function updatedWarehouseId(): void
    {
        $this->loadRows();
    }

    protected function loadRows(): void
    {
        $spots = Schema::hasTable('wh_spots');
        $this->rows = WhSection::where('warehouse_id', $this->warehouseId)->when($spots, fn ($q) => $q->with('spots'))->orderBy('sort')->orderBy('code')->get()
            ->map(fn (WhSection $s) => ['id' => $s->id, 'code' => $s->code, 'name' => $s->name, 'color' => $s->color, 'kind' => $s->kind,
                'to' => $s->logistichub_id ? 'hub:'.$s->logistichub_id : ($s->to_warehouse_id ? 'wh:'.$s->to_warehouse_id : ''),
                'provinces' => array_values((array) $s->provinces), 'cities' => array_values((array) $s->cities),
                'use_spots' => (bool) $s->use_spots, 'spots' => $spots ? $s->spots->pluck('code')->all() : []])->all();
        $this->labelScan = Sections::labelScan($this->warehouseId);
        $this->by = Sections::by($this->warehouseId);
        $this->spotsOn = Sections::spotsOn($this->warehouseId);
        $this->pickRow = null;
    }

    public function addRow(): void
    {
        $used = collect($this->rows)->pluck('code')->all();
        $code = collect(range('A', 'Z'))->first(fn ($l) => ! in_array($l, $used, true)) ?? '';
        $this->rows[] = ['id' => null, 'code' => $code, 'name' => '', 'color' => self::COLORS[count($this->rows) % count(self::COLORS)], 'kind' => 'area', 'to' => '', 'provinces' => [], 'cities' => [], 'use_spots' => false, 'spots' => []];
    }

    // ---------------------------------------------------------------- provinces or cities (board 50b)

    public function setBy(string $by): void
    {
        $this->by = $by === 'city' ? 'city' : 'province';
        $this->pickQ = '';
    }

    protected function listKey(): string
    {
        return $this->by === 'city' ? 'cities' : 'provinces';
    }

    public function openPick(int $i): void
    {
        $this->pickRow = $this->pickRow === $i ? null : $i;
        $this->pickQ = '';
    }

    public function closePick(): void
    {
        $this->pickRow = null;
        $this->pickQ = '';
    }

    /** Add a province or city to the open row; it leaves any other section (one place, one section). */
    public function addPlace(string $value): void
    {
        if ($this->pickRow === null || ! isset($this->rows[$this->pickRow])) {
            return;
        }
        $k = $this->listKey();
        $same = fn ($v) => $k === 'cities' ? Sections::cityKey($v) === Sections::cityKey($value) : Sections::clean($v) === Sections::clean($value);
        foreach ($this->rows as $i => $r) {
            $this->rows[$i][$k] = array_values(array_filter((array) ($r[$k] ?? []), fn ($v) => ! $same($v)));
        }
        $list = [...$this->rows[$this->pickRow][$k], $value];
        sort($list);
        $this->rows[$this->pickRow][$k] = $list;
        $this->pickQ = '';
    }

    public function removePlace(int $i, string $value): void
    {
        $k = $this->listKey();
        if (isset($this->rows[$i])) {
            $this->rows[$i][$k] = array_values(array_filter((array) $this->rows[$i][$k], fn ($v) => $v !== $value));
        }
    }

    // ---------------------------------------------------------------- spots (board 50)

    public function toggleSpots(int $i): void
    {
        if (! isset($this->rows[$i])) {
            return;
        }
        $this->rows[$i]['use_spots'] = ! $this->rows[$i]['use_spots'];
        if ($this->rows[$i]['use_spots'] && ! $this->rows[$i]['spots']) {
            $c = mb_strtoupper(trim($this->rows[$i]['code']));
            $this->rows[$i]['spots'] = [$c.'1', $c.'2', $c.'3'];
        }
    }

    public function addSpot(int $i): void
    {
        if (! isset($this->rows[$i])) {
            return;
        }
        $c = mb_strtoupper(trim($this->rows[$i]['code']));
        $n = count($this->rows[$i]['spots']) + 1;
        while (in_array($c.$n, $this->rows[$i]['spots'], true)) {
            $n++;
        }
        $this->rows[$i]['spots'][] = $c.$n;
    }

    public function removeSpot(int $i, string $code): void
    {
        if (isset($this->rows[$i])) {
            $this->rows[$i]['spots'] = array_values(array_diff($this->rows[$i]['spots'], [$code]));
        }
    }

    public function removeRow(int $i): void
    {
        unset($this->rows[$i]);
        $this->rows = array_values($this->rows);
    }

    /** A first set of sections: one per partner hub, plus Returns (R) and Check address (X). */
    public function suggest(): void
    {
        if ($this->rows) {
            return;
        }
        foreach (Logistichub::where('is_active', true)->orderBy('id')->get() as $i => $hub) {
            $this->rows[] = ['id' => null, 'code' => chr(65 + $i), 'name' => $hub->hub_name, 'color' => self::COLORS[$i % count(self::COLORS)], 'kind' => 'area', 'to' => 'hub:'.$hub->id, 'provinces' => [], 'cities' => [], 'use_spots' => false, 'spots' => []];
        }
        $this->rows[] = ['id' => null, 'code' => 'R', 'name' => 'Returns & wrong hub', 'color' => '#c8372d', 'kind' => 'returns', 'to' => '', 'provinces' => [], 'cities' => [], 'use_spots' => false, 'spots' => []];
        $this->rows[] = ['id' => null, 'code' => 'X', 'name' => 'Check address', 'color' => '#b07400', 'kind' => 'check', 'to' => '', 'provinces' => [], 'cities' => [], 'use_spots' => false, 'spots' => []];
    }

    public function save(): void
    {
        $this->validate([
            'warehouseId' => 'required|integer|exists:warehouses,id',
            'rows' => 'array',
            'rows.*.code' => 'required|string|max:8|distinct',
            'rows.*.name' => 'required|string|max:80',
            'rows.*.color' => ['required', 'regex:/^#[0-9a-fA-F]{6}$/'],
            'rows.*.kind' => 'required|in:'.implode(',', array_keys(WhSection::KINDS)),
            'rows.*.to' => ['nullable', 'regex:/^(hub|wh):\d+$/'],
            'rows.*.provinces' => 'nullable|array|max:120',
            'rows.*.cities' => 'nullable|array|max:600',
            'rows.*.spots' => 'nullable|array|max:60',
            'rows.*.spots.*' => 'string|max:12',
        ], ['rows.*.code.distinct' => 'Two sections have the same code.', 'rows.*.name.required' => 'Give each section a name.']);

        // a province (or a city) can only be in one section
        foreach (['provinces' => 'A province', 'cities' => 'A city'] as $k => $what) {
            $seen = [];
            foreach ($this->rows as $r) {
                foreach ((array) ($r[$k] ?? []) as $p) {
                    $key = $k === 'cities' ? Sections::cityKey($p) : Sections::clean($p);
                    if (isset($seen[$key]) && $seen[$key] !== $r['code']) {
                        $this->addError('rows', "\"{$p}\" is in section {$seen[$key]} and {$r['code']}. {$what} can be in one section only.");

                        return;
                    }
                    $seen[$key] = $r['code'];
                }
            }
        }

        DB::transaction(function () {
            $keep = [];
            foreach (array_values($this->rows) as $i => $r) {
                [$type, $id] = array_pad(explode(':', (string) $r['to']), 2, null);
                $s = ($r['id'] ? WhSection::where('warehouse_id', $this->warehouseId)->find($r['id']) : null) ?? new WhSection(['warehouse_id' => $this->warehouseId]);
                $s->fill([
                    'code' => mb_strtoupper(trim($r['code'])), 'name' => trim($r['name']), 'color' => $r['color'], 'kind' => $r['kind'],
                    'logistichub_id' => $type === 'hub' ? (int) $id : null, 'to_warehouse_id' => $type === 'wh' ? (int) $id : null,
                    'provinces' => $this->provinceList($r['provinces'] ?? []) ?: null, 'sort' => $i, 'is_active' => true,
                ] + (Schema::hasColumn('wh_sections', 'cities') ? [
                    'cities' => collect((array) ($r['cities'] ?? []))->map(fn ($c) => trim($c))->filter()->unique(fn ($c) => Sections::cityKey($c))->values()->all() ?: null,
                    'use_spots' => (bool) ($r['use_spots'] ?? false),
                ] : []))->save();
                $keep[] = $s->id;
                $this->saveSpots($s, (array) ($r['spots'] ?? []));
            }
            WhSection::where('warehouse_id', $this->warehouseId)->whereNotIn('id', $keep ?: [0])->delete();
        });
        Sections::setLabelScan($this->warehouseId, $this->labelScan);
        Sections::setBy($this->warehouseId, $this->by);
        Sections::setSpotsOn($this->warehouseId, $this->spotsOn);
        Sections::forget();
        $this->loadRows();
        Notification::make()->title('Warehouse sections saved')->success()->send();
    }

    /** @return list<string> */
    protected function provinceList(array|string|null $list): array
    {
        $list = is_array($list) ? $list : preg_split('/[,;\n]+/', (string) $list);

        return collect($list)->map(fn ($p) => trim((string) $p))->filter()->unique(fn ($p) => Sections::clean($p))->values()->all();
    }

    /** Keep spots by code (boxes keep their spot); spots taken away leave their boxes in the section. */
    protected function saveSpots(WhSection $s, array $codes): void
    {
        if (! Schema::hasTable('wh_spots')) {
            return;
        }
        $codes = collect($codes)->map(fn ($c) => mb_strtoupper(trim((string) $c)))->filter()->unique()->values();
        $have = WhSpot::where('wh_section_id', $s->id)->get()->keyBy('code');
        foreach ($codes as $i => $c) {
            ($have[$c] ?? new WhSpot(['wh_section_id' => $s->id, 'code' => $c]))->fill(['sort' => $i])->save();
        }
        $gone = $have->keys()->diff($codes);
        if ($gone->isNotEmpty()) {
            $ids = $have->only($gone->all())->pluck('id');
            Invoice::whereIn('wh_spot_id', $ids)->update(['wh_spot_id' => null]);
            WhSpot::whereIn('id', $ids)->delete();
        }
    }

    protected function getViewData(): array
    {
        // the open list: every province (or city) A to Z, without the ones this row has; search by what is typed
        $options = [];
        if ($this->pickRow !== null && isset($this->rows[$this->pickRow])) {
            $k = $this->listKey();
            $all = $k === 'cities' ? Sections::cityOptions() : Sections::provinceOptions();
            $keyOf = fn ($v) => $k === 'cities' ? Sections::cityKey($v) : Sections::clean($v);
            $mine = collect($this->rows[$this->pickRow][$k])->map($keyOf)->flip();
            $owner = [];
            foreach ($this->rows as $i => $r) {
                foreach ((array) ($r[$k] ?? []) as $v) {
                    $owner[$keyOf($v)] = $r['code'];
                }
            }
            $q = mb_strtolower(trim($this->pickQ));
            $options = collect($all)->reject(fn ($v) => isset($mine[$keyOf($v)]))
                ->filter(fn ($v) => $q === '' || str_contains(mb_strtolower($v), $q))->take(200)
                ->map(fn ($v) => ['value' => $v, 'in' => $owner[$keyOf($v)] ?? null])->values()->all();
        }

        return [
            'options' => $options,
            'warehouses' => Warehouse::orderBy('name')->pluck('name', 'id'),
            'targets' => collect(['' => '— nobody (returns, check address)'])
                ->merge(Logistichub::orderBy('hub_name')->get()->mapWithKeys(fn ($h) => ['hub:'.$h->id => 'Hub · '.$h->hub_name]))
                ->merge(Warehouse::where('id', '!=', $this->warehouseId)->orderBy('name')->get()->mapWithKeys(fn ($w) => ['wh:'.$w->id => 'Warehouse · '.$w->name])),
            'kinds' => WhSection::KINDS,
            'colors' => self::COLORS,
            'labelsUrl' => $this->warehouseId ? route('sections.labels', ['warehouse' => $this->warehouseId]) : null,
        ];
    }
}
