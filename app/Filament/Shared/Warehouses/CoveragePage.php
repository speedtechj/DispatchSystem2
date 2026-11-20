<?php

namespace App\Filament\Shared\Warehouses;

use App\Models\Warehouse;
use App\Models\Warehouses\CoverageRequest;
use App\Models\Warehouses\WarehouseCoverage;
use App\Support\Warehouses\Coverage;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/** Settings → Warehouse coverage: which warehouse delivers each province. */
class CoveragePage extends Page
{
    protected string $view = 'filament.warehouses.coverage';

    protected static ?string $slug = 'warehouse-coverage';

    protected static ?string $title = 'Warehouse coverage';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-map';

    /** @var array<int, string> new province typed per warehouse */
    public array $newProvince = [];

    /** @var array<int, string> new town exception per warehouse: "Rosales, Pangasinan" */
    public array $newTown = [];

    public ?array $conflict = null;

    public static function canAccess(): bool
    {
        $u = Auth::user();

        return Coverage::ready() && $u && (static::isAdmin() || $u->warehouse_id);
    }

    public static function isAdmin(): bool
    {
        $u = Auth::user();

        return Filament::getCurrentPanel()?->getId() === 'admin' && ($u?->hasRole('super_admin') || $u?->is_admin);
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    protected function canEdit(int $warehouseId): bool
    {
        return static::isAdmin() || (int) Auth::user()?->warehouse_id === $warehouseId;
    }

    public function addProvince(int $warehouseId, ?string $name = null): void
    {
        abort_unless($this->canEdit($warehouseId), 403);
        $p = trim((string) ($name ?? $this->newProvince[$warehouseId] ?? ''));
        if ($p === '') {
            return;
        }
        $r = Coverage::add($warehouseId, $p, null, Auth::user());
        if (! $r['ok'] && $r['owner']) {
            $this->conflict = ['warehouse' => $warehouseId, 'province' => Str::title(Coverage::key($p)), 'owner' => $r['owner']];

            return;
        }
        $this->newProvince[$warehouseId] = '';
        $this->conflict = null;
    }

    public function addTown(int $warehouseId): void
    {
        abort_unless($this->canEdit($warehouseId), 403);
        [$city, $province] = array_pad(array_map('trim', explode(',', (string) ($this->newTown[$warehouseId] ?? ''), 2)), 2, '');
        if ($city === '' || $province === '') {
            Notification::make()->title('Type the town and the province: “Rosales, Pangasinan”')->warning()->send();

            return;
        }
        Coverage::add($warehouseId, $province, $city, Auth::user(), true);
        $this->newTown[$warehouseId] = '';
    }

    public function remove(int $rowId): void
    {
        $row = WarehouseCoverage::findOrFail($rowId);
        abort_unless($this->canEdit((int) $row->warehouse_id), 403);
        Coverage::remove($row, Auth::user());
    }

    /** The conflict box: the admin moves it; a warehouse asks the admin. */
    public function resolveConflict(): void
    {
        if (! $this->conflict) {
            return;
        }
        [$w, $p, $owner] = [$this->conflict['warehouse'], $this->conflict['province'], $this->conflict['owner']];
        if (static::isAdmin()) {
            Coverage::add($w, $p, null, Auth::user(), true);
            Notification::make()->title($p.' moved to '.Coverage::name($w))->success()->send();
        } else {
            Coverage::request($w, $p, $owner, Auth::user());
            Notification::make()->title('Asked the admin to move '.$p)->success()->send();
        }
        $this->conflict = null;
    }

    public function cancelConflict(): void
    {
        $this->conflict = null;
    }

    public function decide(int $requestId, bool $yes): void
    {
        abort_unless(static::isAdmin(), 403);
        Coverage::decide(CoverageRequest::findOrFail($requestId), $yes, Auth::user());
    }

    public function makeDefault(int $warehouseId): void
    {
        abort_unless(static::isAdmin(), 403);
        Warehouse::query()->update(['is_default' => false]);
        Warehouse::whereKey($warehouseId)->update(['is_default' => true]);
        Coverage::log($warehouseId, Coverage::name($warehouseId).' is now the default warehouse', Auth::user());
        Coverage::forget();
    }

    protected function getViewData(): array
    {
        $default = Coverage::defaultId();
        $rows = WarehouseCoverage::all();
        $explicit = $rows->whereNull('city_key')->pluck('province_key')->flip();
        $counts = DB::table('invoices')->where('is_delivered', false)->selectRaw('receiver_province, count(*) n')->groupBy('receiver_province')->get()
            ->groupBy(fn ($r) => Coverage::key($r->receiver_province))->map(fn ($g) => $g->sum('n'));
        $rest = $counts->reject(fn ($n, $k) => $k === '' || isset($explicit[$k]))->sortDesc();
        $known = Coverage::knownProvinces();

        return [
            'warehouses' => Warehouse::orderByRaw('id = ? desc', [$default])->orderBy('name')->get()->map(fn ($w) => [
                'w' => $w, 'default' => (int) $w->id === (int) $default, 'edit' => $this->canEdit($w->id),
                'provinces' => $rows->where('warehouse_id', $w->id)->whereNull('city_key')->sortBy('province')->values(),
                'towns' => $rows->where('warehouse_id', $w->id)->whereNotNull('city_key')->sortBy('city')->values(),
                'rest' => (int) $w->id === (int) $default ? $rest->keys()->take(8)->map(fn ($k) => Str::title($k))->all() : [],
                'restMore' => (int) $w->id === (int) $default ? max(0, $rest->count() - 8) : 0,
                'suggest' => collect($counts)->sortDesc()->keys()->reject(fn ($k) => $k === '' || $rows->where('warehouse_id', $w->id)->where('province_key', $k)->isNotEmpty())->take(2)->map(fn ($k) => Str::title($k))->values()->all(),
            ]),
            'known' => $known, 'admin' => static::isAdmin(),
            'requests' => CoverageRequest::with(['warehouse', 'fromWarehouse', 'user'])->where('status', 'pending')->latest('id')->get(),
            'myRequests' => CoverageRequest::where('status', 'pending')->where('warehouse_id', Auth::user()?->warehouse_id)->pluck('province'),
            'log' => DB::table('coverage_log')->latest('id')->limit(6)->get(),
            'users' => \App\Models\User::whereIn('id', DB::table('coverage_log')->latest('id')->limit(6)->pluck('user_id')->filter())->pluck('first_name', 'id'),
            'active' => Coverage::active(),
        ];
    }
}
