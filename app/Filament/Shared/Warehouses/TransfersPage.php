<?php

namespace App\Filament\Shared\Warehouses;

use App\Models\Truck;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Services\TripAssignment;
use App\Support\Rentals;
use App\Support\Warehouses\Coverage;
use App\Support\Warehouses\TransferDraft;
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

    /** Ask the AI: the draft trips (dest, truck_id, places, load, why, made), null = the manual list. */
    public ?array $draft = null;

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
            $this->truck = [];
            $this->draft = null;
        }
    }

    protected function trucks()
    {
        return Rentals::usable(Truck::where('is_active', true)->where('is_assigned', false)->where('logistichub_id', Auth::user()->logistichub_id))
            ->orderBy('plate_no')->get();
    }

    protected function helper(): TransferDraft
    {
        return new TransferDraft(Auth::user(), (int) $this->here);
    }

    /** The truck picked for a warehouse: by hand, else the smallest free truck that fits. */
    protected function truckFor(int $dest, ?array $need = null): ?int
    {
        if (! empty($this->truck[$dest])) {
            return (int) $this->truck[$dest];
        }
        $h = $this->helper();
        $need ??= $h->needs()->get($dest);

        return $h->bestTruck((float) ($need['space'] ?? 0), $h->trucks())['id'] ?? null;
    }

    public function pickTruck(int $dest, int $truckId): void
    {
        $this->truck[$dest] = $truckId;
    }

    public function askAi(): void
    {
        $this->draft = $this->helper()->make();
    }

    public function manual(): void
    {
        $this->draft = null;
    }

    public function pickDraftTruck(int $i, int $truckId): void
    {
        if (isset($this->draft['trips'][$i]) && ! $this->draft['trips'][$i]['made']
            && ! collect($this->draft['trips'])->except($i)->contains('truck_id', $truckId)) {
            $this->draft['trips'][$i]['truck_id'] = $truckId;
        }
    }

    public function createDraft(int $i, bool $quiet = false): bool
    {
        $t = $this->draft['trips'][$i] ?? null;
        if (! $t || $t['made']) {
            return false;
        }
        $cap = $this->helper()->trucks()->firstWhere('id', $t['truck_id'])['capacity'] ?? 0;
        if ($t['load'] > $cap) {
            $quiet || Notification::make()->title('Too full: pick a bigger truck')->warning()->send();

            return false;
        }
        try {
            $made = $this->helper()->planner()->create([$t], Carbon::parse($this->date));
        } catch (\DomainException $e) {
            Notification::make()->title($e->getMessage())->danger()->send();

            return false;
        }
        if (! $made) {
            return false;
        }
        $this->draft['trips'][$i]['made'] = $made[0]['number'];
        $quiet || Notification::make()->title('Transfer '.$made[0]['number'].' to '.Coverage::name($t['dest']).' created · '.$made[0]['boxes'].' boxes')->success()->send();

        return true;
    }

    public function createAllDraft(): void
    {
        $n = 0;
        foreach (array_keys($this->draft['trips'] ?? []) as $i) {
            $n += $this->createDraft($i, true) ? 1 : 0;
        }
        Notification::make()->title($n ? $n.' transfer '.Str::plural('trip', $n).' created' : 'Nothing to create: pick bigger trucks')->{$n ? 'success' : 'warning'}()->send();
    }

    public function create(int $dest): void
    {
        $boxes = Coverage::waitingTransfer((int) $this->here)->where('home', $dest)->pluck('inv');
        $truckId = $this->truckFor($dest);
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
        $h = $this->helper();
        $units = $h->units();
        $needs = $units->groupBy('home')->map(fn ($g) => ['space' => \App\Support\BoxSizes::half($g->sum('space')), 'boxes' => $g->sum('n'), 'receivers' => $g->count()]);
        $trucks = $h->trucks();
        $cap = $trucks->pluck('capacity', 'id');
        $groups = Coverage::waitingTransfer($here)->groupBy('home')->map(function ($g, $dest) use ($needs, $cap) {
            $rows = $g->groupBy(fn ($x) => Str::title(Coverage::key($x['inv']->receiver_province)) ?: 'No province')->map(fn ($p, $name) => [
                'name' => $name, 'n' => $p->count(),
                'days' => (int) $p->map(fn ($x) => floor(Carbon::parse($x['inv']->verified_at ?? $x['inv']->created_at)->diffInHours(now()) / 24))->max(),
            ])->sortByDesc('n')->values();
            $need = $needs->get($dest, ['space' => $g->count(), 'boxes' => $g->count(), 'receivers' => 0]);
            $truckId = $this->truckFor((int) $dest, $need);

            return ['dest' => (int) $dest, 'name' => Coverage::name((int) $dest), 'total' => $g->count(), 'rows' => $rows,
                'space' => $need['space'], 'receivers' => $need['receivers'], 'truckId' => $truckId, 'cap' => (int) ($cap[$truckId] ?? 0)];
        })->values();

        $draft = null;
        if ($this->draft !== null) {
            $count = collect($this->draft['trips'])->countBy('dest');
            $seen = [];
            $draft = $this->draft + ['cards' => collect($this->draft['trips'])->map(function ($t, $i) use ($h, $units, $count, &$seen, $cap, $trucks) {
                $seen[$t['dest']] = ($seen[$t['dest']] ?? 0) + 1;
                $keys = collect($t['places'])->flatMap(fn ($p) => $p['units']);

                return $t + ['i' => $i, 'title' => Coverage::name($t['dest']).($count[$t['dest']] > 1 ? ' · '.$seen[$t['dest']].' of '.$count[$t['dest']] : ''),
                    'rows' => $h->rows($t, $units), 'boxes' => $units->only($keys->all())->sum('n') ?: $keys->count(), 'receivers' => $keys->count(),
                    'cap' => (int) ($cap[$t['truck_id']] ?? 0), 'taken' => collect($this->draft['trips'])->except($i)->pluck('truck_id')->all()];
            })->all()];
        }

        return [
            'hereName' => Coverage::name($here), 'groups' => $groups, 'active' => Coverage::active(), 'dv' => $draft,
            'warehouses' => Warehouse::orderBy('name')->get(['id', 'name']), 'canSwitch' => ! Auth::user()->warehouse_id || CoveragePage::isAdmin(),
            'mainId' => Coverage::defaultId(), 'trucks' => $trucks,
            'onTheWay' => Whdeliverylog::with('warehouse:id,name')->where(fn ($q) => $q->where('user_whid', $here)->orWhere('warehouse_id', $here))->latest('id')->limit(8)->get()
                ->map(fn ($t) => ['t' => $t, 'n' => DB::table('whtripinvoices')->where('whdeliverylog_id', $t->id)->count(), 'left' => DB::table('whtripinvoices')->where('whdeliverylog_id', $t->id)->where('is_unloaded', false)->count()])
                ->filter(fn ($x) => $x['left'] > 0)->values(),
        ];
    }
}
