<?php

namespace App\Support;

use App\Enums\FailedDeliveryReason;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\DeliveryReversal;
use App\Models\Truck;
use App\Models\Whdeliverylog;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;

/**
 * Numbers for the widgets on top of the trip lists, and the trip status
 * used by the "Status" column and filter of those lists.
 *
 * One class for the three kinds of trip:
 *  - delivery: a hub's delivery trips (boxes on tripinvoices.deliverylog_id)
 *  - hub:      a partner hub's own trips (boxes on tripinvoices.deliveryloghub_id)
 *  - warehouse: warehouse-to-warehouse trips (boxes on whtripinvoices; "done" = received)
 *
 * Trip status, worked out from the boxes on the trip:
 *  - loading:   open, has boxes, not all loaded
 *  - road:      open, all loaded, not all delivered (late when the ETA has passed)
 *  - done:      every box delivered / received
 *  - closed:    closed with boxes still not delivered
 *  - empty:     no boxes yet
 */
class TripBoard
{
    public const KINDS = ['delivery', 'hub', 'warehouse'];

    public const STATUSES = [
        'loading' => 'Loading',
        'road' => 'On the road',
        'late' => 'Late',
        'done' => 'Delivered',
        'closed' => 'Closed',
        'empty' => 'No boxes',
    ];

    protected string $trips;

    protected string $rows;

    protected string $fk;

    protected string $loaded;

    protected string $done;

    protected string $doneAt;

    protected string $eta;

    protected string $scopeColumn;

    protected function __construct(public readonly string $kind, protected int $scopeId)
    {
        [$this->trips, $this->rows, $this->fk, $this->loaded, $this->done, $this->doneAt, $this->eta, $this->scopeColumn] = match ($kind) {
            'delivery' => ['deliverylogs', 'tripinvoices', 'deliverylog_id', 'is_loaded', 'is_delivered', 'COALESCE(tripinvoices.delivered_at, tripinvoices.updated_at)', 'eta', 'logistichub_id'],
            'hub' => ['deliverylogs', 'tripinvoices', 'deliveryloghub_id', 'is_loaded_hub', 'is_delivered', 'COALESCE(tripinvoices.delivered_at, tripinvoices.updated_at)', 'eta', 'logistichub_id'],
            'warehouse' => ['whdeliverylogs', 'whtripinvoices', 'whdeliverylog_id', 'is_loaded', 'is_unloaded', 'whtripinvoices.updated_at', 'delivery_date', 'user_whid'],
        };
    }

    /** @param  int  $scopeId  the hub id (delivery, hub) or warehouse id (warehouse) */
    public static function make(string $kind, int $scopeId): static
    {
        return new static($kind, $scopeId);
    }

    public function isWarehouse(): bool
    {
        return $this->kind === 'warehouse';
    }

    /** "delivered" or "received". */
    public function doneWord(): string
    {
        return $this->isWarehouse() ? 'received' : 'delivered';
    }

    // ---------------------------------------------------------------- SQL pieces

    protected function count(string $extra = ''): string
    {
        return "(select count(*) from {$this->rows} where {$this->rows}.{$this->fk} = {$this->trips}.id{$extra})";
    }

    protected function total(): string
    {
        return $this->count();
    }

    protected function loadedCount(): string
    {
        return $this->count(" and {$this->rows}.{$this->loaded} = 1");
    }

    protected function doneCount(): string
    {
        return $this->count(" and {$this->rows}.{$this->done} = 1");
    }

    public function tripQuery(): Builder
    {
        $model = $this->isWarehouse() ? Whdeliverylog::class : Deliverylog::class;

        return $model::query()->where("{$this->trips}.{$this->scopeColumn}", $this->scopeId);
    }

    /** Add boxes_total / boxes_loaded / boxes_done to each trip row. */
    public function withProgress(Builder $query): Builder
    {
        if (empty($query->getQuery()->columns)) {
            $query->select("{$this->trips}.*");
        }

        return $query
            ->selectRaw("{$this->total()} as boxes_total")
            ->selectRaw("{$this->loadedCount()} as boxes_loaded")
            ->selectRaw("{$this->doneCount()} as boxes_done");
    }

    /** Limit a trip query to one status, or to a card of the widget (delivered today / problems today). */
    public function whereStatus(Builder $query, ?string $status): Builder
    {
        $t = $this->trips;
        $open = fn (Builder $q) => $q->where("{$t}.is_active", true)->whereRaw("{$this->total()} > 0");
        $today = today()->toDateString();

        return match ($status) {
            'loading' => $query->where($open)->whereRaw("{$this->loadedCount()} < {$this->total()}"),
            'road' => $query->where($open)->whereRaw("{$this->loadedCount()} = {$this->total()}")->whereRaw("{$this->doneCount()} < {$this->total()}"),
            'late' => $this->whereStatus($query, 'road')->where("{$t}.{$this->eta}", '<', $today),
            'done' => $query->whereRaw("{$this->total()} > 0")->whereRaw("{$this->doneCount()} = {$this->total()}"),
            'closed' => $query->where("{$t}.is_active", false)->whereRaw("{$this->total()} > 0")->whereRaw("{$this->doneCount()} < {$this->total()}"),
            'empty' => $query->whereRaw("{$this->total()} = 0"),
            'today' => $query->whereRaw($this->count(" and {$this->rows}.{$this->done} = 1 and date({$this->doneAt}) = ?").' > 0', [$today]),
            'problems' => $query->whereIn("{$t}.id", $this->problemTripIds(today())),
            default => $query,
        };
    }

    /** Status of one trip loaded through withProgress(). */
    public function statusOf(Model $trip): string
    {
        $total = (int) $trip->boxes_total;
        $loaded = (int) $trip->boxes_loaded;
        $done = (int) $trip->boxes_done;

        return match (true) {
            $total === 0 => 'empty',
            $done === $total => 'done',
            ! $trip->is_active => 'closed',
            $loaded < $total => 'loading',
            $trip->{$this->eta} && Carbon::parse($trip->{$this->eta})->lt(today()) => 'late',
            default => 'road',
        };
    }

    public static function statusColor(string $status): string
    {
        return match ($status) {
            'loading' => 'warning',
            'road' => 'info',
            'late' => 'danger',
            'done' => 'success',
            default => 'gray',
        };
    }

    // ---------------------------------------------------------------- widget numbers

    /** Trip ids with a failed attempt or an undone delivery since $since. */
    protected function problemTripIds(Carbon $since): Collection
    {
        if ($this->isWarehouse()) {
            return $this->whereStatus($this->tripQuery(), 'late')->pluck("{$this->trips}.id");
        }

        $tripIds = $this->tripQuery()->select('id');

        return DeliveryAttempt::query()->whereIn('deliverylog_id', $tripIds)->where('created_at', '>=', $since)->select('deliverylog_id')
            ->union(DeliveryReversal::query()->whereIn('deliverylog_id', $tripIds)->where('created_at', '>=', $since)->select('deliverylog_id'))
            ->pluck('deliverylog_id');
    }

    /** @return array<int, array{id: string, label: string, value: string, sub: string, pct: ?int, tone: string}> */
    public function cards(): array
    {
        $road = $this->withProgress($this->whereStatus($this->tripQuery(), 'road'))->get();
        $loading = $this->withProgress($this->whereStatus($this->tripQuery(), 'loading'))->get();

        $doneToday = DB::table($this->rows)
            ->join($this->trips, "{$this->trips}.id", '=', "{$this->rows}.{$this->fk}")
            ->where("{$this->trips}.{$this->scopeColumn}", $this->scopeId)
            ->where("{$this->rows}.{$this->done}", true)
            ->whereRaw("date({$this->doneAt}) = ?", [today()->toDateString()])
            ->count();
        $stillOut = $road->sum(fn ($trip) => $trip->boxes_total - $trip->boxes_done);
        $outToday = $doneToday + $stillOut;

        $boxesLoading = $loading->sum('boxes_total');
        $boxesLoaded = $loading->sum('boxes_loaded');

        $cards = [
            [
                'id' => 'road', 'label' => 'On the road', 'value' => number_format($road->count()), 'tone' => 'navy', 'pct' => null,
                'sub' => $this->isWarehouse() ? number_format($stillOut).' boxes on trucks' : $this->truckLine(),
            ],
            [
                'id' => 'loading', 'label' => 'Being loaded', 'value' => number_format($loading->count()), 'tone' => 'yellow',
                'pct' => $boxesLoading ? (int) round($boxesLoaded / $boxesLoading * 100) : null,
                'sub' => $boxesLoading ? number_format($boxesLoaded).' of '.number_format($boxesLoading).' boxes loaded' : 'No trips loading',
            ],
            [
                'id' => 'today', 'label' => ucfirst($this->doneWord()).' today', 'value' => number_format($doneToday), 'tone' => 'ok',
                'pct' => $outToday ? (int) round($doneToday / $outToday * 100) : null,
                'sub' => 'of '.number_format($outToday).' boxes out today',
            ],
        ];

        if ($this->isWarehouse()) {
            $late = $this->withProgress($this->whereStatus($this->tripQuery(), 'late'))->get();
            $cards[] = [
                'id' => 'late', 'label' => 'Late', 'value' => number_format($late->count()), 'tone' => 'bad', 'pct' => null,
                'sub' => number_format($late->sum(fn ($trip) => $trip->boxes_total - $trip->boxes_done)).' boxes not received yet',
            ];
        } else {
            $tripIds = $this->tripQuery()->select('id');
            $failed = DeliveryAttempt::whereIn('deliverylog_id', $tripIds)->whereDate('created_at', today())->count();
            $undone = DeliveryReversal::whereIn('deliverylog_id', $tripIds)->whereDate('created_at', today())->count();
            $cards[] = [
                'id' => 'problems', 'label' => 'Problems today', 'value' => number_format($failed + $undone), 'tone' => 'bad', 'pct' => null,
                'sub' => "{$failed} not delivered · {$undone} undone",
            ];
        }

        return $cards;
    }

    protected function truckLine(): string
    {
        $trucks = Truck::where('logistichub_id', $this->scopeId);
        $out = (clone $trucks)->where('is_assigned', true)->count();
        $free = (clone $trucks)->where('is_assigned', false)->count();

        return "{$out} trucks out · {$free} free";
    }

    /**
     * Trips someone should look at, most urgent first.
     *
     * @return Collection<int, array{trip: Model, tag: string, tone: string, detail: string, action: ?string}>
     */
    public function attention(int $limit = 6): Collection
    {
        $with = $this->isWarehouse() ? ['warehouse:id,name', 'truck:id,plate_no'] : ['destination:id,hub_name', 'truck:id,plate_no'];
        $trips = fn (string $status) => $this->withProgress($this->whereStatus($this->tripQuery(), $status))->with($with);
        $items = collect();

        foreach ($trips('late')->orderBy($this->eta)->limit($limit)->get() as $trip) {
            $items->push($this->item($trip, 'Late', 'bad',
                'ETA was '.Carbon::parse($trip->{$this->eta})->format('M j').' · '.($trip->boxes_total - $trip->boxes_done)." boxes not {$this->doneWord()}"));
        }

        if (! $this->isWarehouse()) {
            $failed = DeliveryAttempt::query()
                ->whereIn('deliverylog_id', $this->tripQuery()->select('id'))
                ->whereDate('created_at', today())
                ->get(['deliverylog_id', 'reason'])
                ->groupBy('deliverylog_id');

            $problemTrips = $this->withProgress($this->tripQuery())->with($with)->whereIn('id', $failed->keys())->get();
            foreach ($problemTrips as $trip) {
                $reasons = $failed[$trip->id]->countBy(fn ($attempt) => $attempt->reason->getLabel())
                    ->map(fn ($n, $label) => $n > 1 ? "{$label} ×{$n}" : $label)->join(' · ');
                $items->push($this->item($trip, $failed[$trip->id]->count().' not delivered', 'warn', $reasons));
            }
        }

        foreach ($trips('road')->where("{$this->trips}.is_lock", false)->whereRaw("{$this->doneCount()} = 0")->limit($limit)->get() as $trip) {
            $items->push($this->item($trip, 'Loaded, not locked', 'gray', "All {$trip->boxes_total} boxes loaded · lock the trip before it leaves", 'lock'));
        }

        if (! $this->isWarehouse()) {
            foreach ($trips('done')->where("{$this->trips}.is_current", true)->limit($limit)->get() as $trip) {
                $items->push($this->item($trip, 'Truck still in use', 'gray', "All {$trip->boxes_total} boxes delivered · truck not released", 'release'));
            }
        }

        foreach ($this->tripQuery()->with($with)->where("{$this->trips}.is_active", true)->whereRaw("{$this->total()} = 0")
            ->whereDate("{$this->trips}.created_at", '<', today())->limit($limit)->get() as $trip) {
            $items->push($this->item($trip, 'No boxes', 'gray', 'Created '.$trip->created_at->format('M j').' and still empty'));
        }

        return $items->unique(fn ($item) => $item['trip']->id)->take($limit)->values();
    }

    protected function item(Model $trip, string $tag, string $tone, string $detail, ?string $action = null): array
    {
        return [
            'trip' => $trip,
            'tag' => $tag,
            'tone' => $tone,
            'detail' => $detail,
            'action' => $action,
            'destination' => $this->isWarehouse() ? $trip->warehouse?->name : $trip->destination?->hub_name,
            'truck' => $trip->truck?->plate_no,
        ];
    }

    /** @return Collection<int, array{date: Carbon, boxes: int}> boxes delivered / received per day, oldest first */
    public function perDay(int $days = 14): Collection
    {
        $from = today()->subDays($days - 1);

        $counts = DB::table($this->rows)
            ->join($this->trips, "{$this->trips}.id", '=', "{$this->rows}.{$this->fk}")
            ->where("{$this->trips}.{$this->scopeColumn}", $this->scopeId)
            ->where("{$this->rows}.{$this->done}", true)
            ->whereRaw("{$this->doneAt} >= ?", [$from->toDateTimeString()])
            ->selectRaw("date({$this->doneAt}) as day, count(*) as boxes")
            ->groupBy('day')
            ->pluck('boxes', 'day');

        return collect(range(0, $days - 1))->map(function (int $offset) use ($from, $counts) {
            $date = $from->copy()->addDays($offset);

            return ['date' => $date, 'boxes' => (int) ($counts[$date->toDateString()] ?? 0)];
        });
    }

    /**
     * Second chart: why boxes were not delivered this week (delivery, hub),
     * or where boxes were sent this week (warehouse).
     *
     * @return Collection<int, array{label: string, count: int}>
     */
    public function breakdown(int $limit = 5): Collection
    {
        $since = today()->subDays(6);

        if ($this->isWarehouse()) {
            return DB::table('whtripinvoices')
                ->join('whdeliverylogs', 'whdeliverylogs.id', '=', 'whtripinvoices.whdeliverylog_id')
                ->join('warehouses', 'warehouses.id', '=', 'whdeliverylogs.warehouse_id')
                ->where('whdeliverylogs.user_whid', $this->scopeId)
                ->where('whtripinvoices.created_at', '>=', $since)
                ->selectRaw('warehouses.name as label, count(*) as count')
                ->groupBy('warehouses.name')
                ->orderByDesc('count')
                ->limit($limit)
                ->get()
                ->map(fn ($row) => ['label' => $row->label, 'count' => (int) $row->count]);
        }

        return DeliveryAttempt::query()
            ->whereIn('deliverylog_id', $this->tripQuery()->select('id'))
            ->where('created_at', '>=', $since)
            ->selectRaw('reason, count(*) as count')
            ->groupBy('reason')
            ->orderByDesc('count')
            ->limit($limit)
            ->get()
            ->map(fn ($row) => [
                'label' => $row->reason instanceof FailedDeliveryReason ? $row->reason->getLabel() : (string) $row->reason,
                'count' => (int) $row->count,
            ]);
    }

    public function breakdownTitle(): string
    {
        return $this->isWarehouse() ? 'Where boxes were sent' : 'Why boxes were not delivered';
    }

    public function find(int $tripId): ?Model
    {
        return $this->tripQuery()->find($tripId);
    }
}
