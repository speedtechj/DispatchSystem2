<?php

namespace App\Filament\Pages;

use App\Models\Boxes\WhSection;
use App\Models\Logistichub;
use App\Models\Warehouse;
use App\Support\Boxes\Sections;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
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

    /** @var list<array{id: ?int, code: string, name: string, color: string, kind: string, to: string, provinces: string}> */
    public array $rows = [];

    public bool $labelScan = false;

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
        $this->rows = WhSection::where('warehouse_id', $this->warehouseId)->orderBy('sort')->orderBy('code')->get()
            ->map(fn (WhSection $s) => ['id' => $s->id, 'code' => $s->code, 'name' => $s->name, 'color' => $s->color, 'kind' => $s->kind,
                'to' => $s->logistichub_id ? 'hub:'.$s->logistichub_id : ($s->to_warehouse_id ? 'wh:'.$s->to_warehouse_id : ''),
                'provinces' => implode(', ', (array) $s->provinces)])->all();
        $this->labelScan = Sections::labelScan($this->warehouseId);
    }

    public function addRow(): void
    {
        $used = collect($this->rows)->pluck('code')->all();
        $code = collect(range('A', 'Z'))->first(fn ($l) => ! in_array($l, $used, true)) ?? '';
        $this->rows[] = ['id' => null, 'code' => $code, 'name' => '', 'color' => self::COLORS[count($this->rows) % count(self::COLORS)], 'kind' => 'area', 'to' => '', 'provinces' => ''];
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
            $this->rows[] = ['id' => null, 'code' => chr(65 + $i), 'name' => $hub->hub_name, 'color' => self::COLORS[$i % count(self::COLORS)], 'kind' => 'area', 'to' => 'hub:'.$hub->id, 'provinces' => ''];
        }
        $this->rows[] = ['id' => null, 'code' => 'R', 'name' => 'Returns & wrong hub', 'color' => '#c8372d', 'kind' => 'returns', 'to' => '', 'provinces' => ''];
        $this->rows[] = ['id' => null, 'code' => 'X', 'name' => 'Check address', 'color' => '#b07400', 'kind' => 'check', 'to' => '', 'provinces' => ''];
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
            'rows.*.provinces' => 'nullable|string|max:2000',
        ], ['rows.*.code.distinct' => 'Two sections have the same code.', 'rows.*.name.required' => 'Give each section a name.']);

        // a province can only be in one section
        $seen = [];
        foreach ($this->rows as $r) {
            foreach ($this->provinceList($r['provinces']) as $p) {
                $k = Sections::clean($p);
                if (isset($seen[$k]) && $seen[$k] !== $r['code']) {
                    $this->addError('rows', "\"{$p}\" is in section {$seen[$k]} and {$r['code']}. A province can be in one section only.");

                    return;
                }
                $seen[$k] = $r['code'];
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
                    'provinces' => $this->provinceList($r['provinces']) ?: null, 'sort' => $i, 'is_active' => true,
                ])->save();
                $keep[] = $s->id;
            }
            WhSection::where('warehouse_id', $this->warehouseId)->whereNotIn('id', $keep ?: [0])->delete();
        });
        Sections::setLabelScan($this->warehouseId, $this->labelScan);
        Sections::forget();
        $this->loadRows();
        Notification::make()->title('Warehouse sections saved')->success()->send();
    }

    /** @return list<string> */
    protected function provinceList(?string $text): array
    {
        return collect(preg_split('/[,;\n]+/', (string) $text))->map(fn ($p) => trim($p))->filter()->unique(fn ($p) => Sections::clean($p))->values()->all();
    }

    protected function getViewData(): array
    {
        $counts = WhSection::where('warehouse_id', $this->warehouseId)->withCount(['invoices' => fn ($q) => $q->where('is_verified', true)
            ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))->where('is_assigned', false)->where('wh_is_assigned', false)])
            ->pluck('invoices_count', 'id');

        return [
            'warehouses' => Warehouse::orderBy('name')->pluck('name', 'id'),
            'targets' => collect(['' => '— nobody (returns, check address)'])
                ->merge(Logistichub::orderBy('hub_name')->get()->mapWithKeys(fn ($h) => ['hub:'.$h->id => 'Hub · '.$h->hub_name]))
                ->merge(Warehouse::where('id', '!=', $this->warehouseId)->orderBy('name')->get()->mapWithKeys(fn ($w) => ['wh:'.$w->id => 'Warehouse · '.$w->name])),
            'counts' => $counts,
            'kinds' => WhSection::KINDS,
            'colors' => self::COLORS,
            'labelsUrl' => $this->warehouseId ? route('sections.labels', ['warehouse' => $this->warehouseId]) : null,
        ];
    }
}
