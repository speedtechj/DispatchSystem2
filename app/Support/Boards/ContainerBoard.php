<?php

namespace App\Support\Boards;

use App\Models\Container;
use App\Models\Invoice;
use App\Models\Unmanifested;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;

/**
 * Containers: waiting to unload, unloading now, unloaded this week, boxes missing.
 *
 * - "Waiting" and "unloading" only look at containers added in the last 60 days,
 *   and "missing" at containers marked unloaded in the last 30 days, so old
 *   history does not fill the cards.
 * - A box is "missing" when its container is marked unloaded but the box was never scanned.
 */
class ContainerBoard extends Board
{
    public const RECENT_DAYS = 60;

    public const MISSING_DAYS = 30;

    /** @param  ?int  $warehouseId  null = every warehouse (Admin) */
    public function __construct(protected ?int $warehouseId = null, protected ?\Closure $containerUrl = null) {}

    protected function containers(): Builder
    {
        return Container::query()->when($this->warehouseId, fn (Builder $q) => $q->where('containers.warehouse_id', $this->warehouseId));
    }

    protected function withBoxes(Builder $query): Builder
    {
        return $query->withCount([
            'invoices as boxes_total',
            'invoices as boxes_scanned' => fn (Builder $q) => $q->where('is_verified', true),
        ]);
    }

    protected function open(): Builder
    {
        return $this->containers()
            ->where(fn (Builder $q) => $q->where('is_unloaded', false)->orWhereNull('is_unloaded'))
            ->where('containers.created_at', '>=', now()->subDays(self::RECENT_DAYS));
    }

    protected function waiting(): Builder
    {
        return $this->open()->whereDoesntHave('invoices', fn (Builder $q) => $q->where('is_verified', true));
    }

    protected function unloading(): Builder
    {
        return $this->open()->whereHas('invoices', fn (Builder $q) => $q->where('is_verified', true));
    }

    protected function unloadedSince(\DateTimeInterface $since): Builder
    {
        return $this->containers()->where('is_unloaded', true)
            ->whereRaw('COALESCE(containers.unloaded_at, containers.updated_at) >= ?', [$since]);
    }

    public function cards(): array
    {
        $waiting = $this->withBoxes($this->waiting())->get();
        $unloading = $this->withBoxes($this->unloading())->get();
        $week = $this->withBoxes($this->unloadedSince(now()->startOfWeek()))->get();
        $missing = Invoice::whereIn('container_id', $this->unloadedSince(now()->subDays(self::MISSING_DAYS))->select('containers.id'))
            ->where(fn (Builder $q) => $q->where('is_verified', false)->orWhereNull('is_verified'))
            ->count();

        $scanning = $unloading->sum('boxes_scanned');
        $scanningOf = $unloading->sum('boxes_total');

        return [
            static::card('Waiting to unload', $waiting->count(), number_format($waiting->sum('boxes_total')).' boxes on the manifests', 'steel'),
            static::card('Unloading now', $unloading->count(), number_format($scanning).' of '.number_format($scanningOf).' boxes scanned', 'yellow', static::pct($scanning, $scanningOf)),
            static::card('Unloaded this week', $week->count(), number_format($week->sum('boxes_scanned')).' boxes into inventory', 'ok'),
            static::card('Boxes missing', $missing, 'On the manifest, never scanned', 'bad', alert: $missing > 0),
        ];
    }

    public function attention(): Collection
    {
        $items = collect();
        $with = ['consolidator:id,company_name', 'warehouse:id,name'];

        $unloaded = $this->withBoxes($this->unloadedSince(now()->subDays(self::MISSING_DAYS)))->with($with)->get()
            ->filter(fn ($c) => $c->boxes_total > $c->boxes_scanned)
            ->sortByDesc(fn ($c) => $c->boxes_total - $c->boxes_scanned);

        foreach ($unloaded as $c) {
            $n = $c->boxes_total - $c->boxes_scanned;
            $items->push($this->item($c, $n.' '.str('box')->plural($n).' missing', 'bad',
                'Marked unloaded '.static::shortDate($c->unloaded_at ?? $c->updated_at)." · {$c->boxes_scanned} of {$c->boxes_total} boxes scanned", 'Open container', true));
        }

        $unmanifested = Unmanifested::query()
            ->whereIn('container_id', $this->containers()->where('containers.created_at', '>=', now()->subDays(self::MISSING_DAYS))->select('containers.id'))
            ->selectRaw('container_id, count(*) as n')->groupBy('container_id')->pluck('n', 'container_id');

        foreach ($this->containers()->with($with)->whereIn('id', $unmanifested->keys())->get() as $c) {
            $n = (int) $unmanifested[$c->id];
            $items->push($this->item($c, $n.' unmanifested', 'warn', "{$n} ".str('box')->plural($n).' scanned that '.($n > 1 ? 'are' : 'is').' not on the manifest', 'Open container'));
        }

        foreach ($this->waiting()->with($with)->where('containers.created_at', '<', now()->subDays(2))->oldest()->limit(5)->get() as $c) {
            $days = (int) $c->created_at->diffInDays(now());
            $items->push($this->item($c, "Waiting {$days} days", 'gray', 'Added '.$c->created_at->format('M j').' · no box scanned yet', 'Open container'));
        }

        return $items->take(6)->values();
    }

    protected function item(Container $c, string $tag, string $tone, string $detail, string $action, bool $primary = false): array
    {
        return [
            'tag' => $tag,
            'tone' => $tone,
            'title' => $c->container_no ?: 'Container #'.$c->id,
            'sub' => $c->consolidator?->company_name,
            'detail' => $detail,
            'meta' => $c->warehouse?->name,
            'url' => $this->containerUrl ? ($this->containerUrl)($c) : null,
            'action' => $action,
            'primary' => $primary,
        ];
    }

    public function charts(): array
    {
        $counts = Invoice::query()
            ->whereIn('container_id', $this->containers()->select('containers.id'))
            ->where('verified_at', '>=', today()->subDays(13))
            ->selectRaw('date(verified_at) as day, count(*) as n')
            ->groupBy('day')
            ->pluck('n', 'day');

        $consolidators = DB::table('invoices')
            ->join('containers', 'containers.id', '=', 'invoices.container_id')
            ->join('consolidators', 'consolidators.id', '=', 'containers.consolidator_id')
            ->when($this->warehouseId, fn ($q) => $q->where('containers.warehouse_id', $this->warehouseId))
            ->where('containers.created_at', '>=', now()->startOfMonth())
            ->selectRaw('consolidators.company_name as label, count(*) as n')
            ->groupBy('consolidators.company_name')
            ->orderByDesc('n')
            ->limit(5)
            ->get()
            ->map(fn ($r) => ['label' => $r->label, 'count' => (int) $r->n]);

        return [
            ['type' => 'days', 'title' => 'Boxes unloaded per day', 'note' => 'Last 14 days', 'rows' => static::lastDays($counts), 'empty' => ''],
            ['type' => 'bars', 'title' => 'Boxes this month by consolidator', 'note' => 'Containers added this month', 'rows' => $consolidators, 'tone' => 'teal', 'empty' => 'No containers added this month yet.'],
        ];
    }
}
