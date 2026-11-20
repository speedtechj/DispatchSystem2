<?php

namespace App\Filament\Shared\Warehouses;

use App\Models\Truck;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Services\TripAssignment;
use App\Support\Rentals;
use App\Support\Warehouses\Coverage;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/** Boxes here that another warehouse delivers: one transfer per warehouse, only its provinces. */
class TransfersPage extends Page
{
    protected string $view = 'filament.warehouses.transfers';

    protected static ?string $slug = 'warehouse-transfers';

    protected static ?string $title = 'Transfers to warehouses';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-arrows-right-left';

    public ?int $here = null;

    /** @var array<int, ?int> truck per destination */
    public array $truck = [];

    public string $date = '';

    public array $made = [];

    public static function canAccess(): bool
    {
        return Coverage::ready() && (bool) Auth::user();
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function mount(): void
    {
        $this->here = Auth::user()->warehouse_id ?: Coverage::defaultId();
        $this->date = today()->addDay()->toDateString();
    }

    public function setHere(int $id): void
    {
        if (! Auth::user()->warehouse_id || CoveragePage::isAdmin()) {
            $this->here = $id;
            $this->made = [];
        }
    }

    protected function trucks()
    {
        return Rentals::usable(Truck::where('is_active', true)->where('is_assigned', false)->where('logistichub_id', Auth::user()->logistichub_id))
            ->orderBy('plate_no')->get();
    }

    public function create(int $dest): void
    {
        $boxes = Coverage::waitingTransfer((int) $this->here)->where('home', $dest)->pluck('inv');
        $truckId = $this->truck[$dest] ?? $this->trucks()->first()?->id;
        if ($boxes->isEmpty() || ! $truckId) {
            Notification::make()->title($truckId ? 'No boxes to transfer' : 'No free truck')->warning()->send();

            return;
        }
        $trip = DB::transaction(function () use ($dest, $truckId, $boxes) {
            $trip = Whdeliverylog::create(['truck_id' => $truckId, 'warehouse_id' => $dest, 'departure_date' => Carbon::parse($this->date)->toDateString(),
                'delivery_date' => Carbon::parse($this->date)->toDateString(), 'user_id' => Auth::id(), 'user_whid' => $this->here]);
            app(TripAssignment::class)->addToWarehouseTrip($trip, $boxes);

            return $trip;
        });
        $this->made[$dest] = $trip->trip_number;
        Notification::make()->title('Transfer '.$trip->trip_number.' to '.Coverage::name($dest).' created')->success()->send();
    }

    protected function getViewData(): array
    {
        $here = (int) $this->here;
        $groups = Coverage::waitingTransfer($here)->groupBy('home')->map(function ($g, $dest) {
            $rows = $g->groupBy(fn ($x) => Str::title(Coverage::key($x['inv']->receiver_province)) ?: 'No province')->map(fn ($p, $name) => [
                'name' => $name, 'n' => $p->count(),
                'days' => (int) $p->map(fn ($x) => floor(Carbon::parse($x['inv']->verified_at ?? $x['inv']->created_at)->diffInHours(now()) / 24))->max(),
            ])->sortByDesc('n')->values();

            return ['dest' => (int) $dest, 'name' => Coverage::name((int) $dest), 'total' => $g->count(), 'rows' => $rows, 'max' => max(1, $rows->max('n'))];
        })->values();

        return [
            'hereName' => Coverage::name($here), 'groups' => $groups, 'active' => Coverage::active(),
            'warehouses' => Warehouse::orderBy('name')->get(['id', 'name']), 'canSwitch' => ! Auth::user()->warehouse_id || CoveragePage::isAdmin(),
            'trucks' => $this->trucks(),
            'onTheWay' => Whdeliverylog::with('warehouse:id,name')->where(fn ($q) => $q->where('user_whid', $here)->orWhere('warehouse_id', $here))->latest('id')->limit(8)->get()
                ->map(fn ($t) => ['t' => $t, 'n' => DB::table('whtripinvoices')->where('whdeliverylog_id', $t->id)->count(), 'left' => DB::table('whtripinvoices')->where('whdeliverylog_id', $t->id)->where('is_unloaded', false)->count()])
                ->filter(fn ($x) => $x['left'] > 0)->values(),
        ];
    }
}
