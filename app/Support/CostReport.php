<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\Fuel\FuelFill;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Truck;
use App\Models\Tripinvoice;
use App\Support\Shipping\Shipments;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Schema;

/**
 * Cost per box delivered, for each hub and month: fuel of the hub's trucks, plus the sea
 * shipments that went to the hub, divided by the boxes the hub delivered.
 */
class CostReport
{
    public Carbon $from;

    public Carbon $to;

    public function __construct(?string $month = null)
    {
        $this->from = $month && preg_match('/^\d{4}-\d{2}$/', $month) ? Carbon::parse($month.'-01')->startOfMonth() : now()->startOfMonth();
        $this->to = $this->from->copy()->endOfMonth();
    }

    /** @return Collection<int, array{hub: Logistichub, boxes: int, fuel: float, sea: float, total: float, perBox: ?float, fuelPerBox: ?float, seaPerBox: ?float}> */
    public function rows(): Collection
    {
        $hubs = Logistichub::orderByDesc('is_company')->orderBy('hub_name')->get();
        $delivered = Tripinvoice::query()->where('is_delivered', true)
            ->whereRaw('COALESCE(delivered_at, updated_at) between ? and ?', [$this->from, $this->to])->get(['deliverylog_id', 'deliveryloghub_id']);
        $tripHub = Deliverylog::whereIn('id', $delivered->pluck('deliverylog_id')->merge($delivered->pluck('deliveryloghub_id'))->filter()->unique())->pluck('logistichub_id', 'id');
        $boxes = $delivered->groupBy(fn ($r) => $tripHub[$r->deliveryloghub_id ?: $r->deliverylog_id] ?? 0)->map->count();

        $fuel = collect();
        if (Schema::hasTable('fuel_fills')) {
            $truckHub = Truck::pluck('logistichub_id', 'id');
            $fuel = FuelFill::whereBetween('filled_at', [$this->from, $this->to])->get(['truck_id', 'total'])
                ->groupBy(fn ($f) => $truckHub[$f->truck_id] ?? 0)->map(fn ($g) => (float) $g->sum('total'));
        }
        $sea = collect();
        if (Shipments::ready()) {
            $sea = $this->shipments()->groupBy('logistichub_id')->map(fn ($g) => (float) $g->sum(fn ($s) => $s->cost()));
        }

        return $hubs->map(function (Logistichub $h) use ($boxes, $fuel, $sea) {
            $b = (int) ($boxes[$h->id] ?? 0);
            $f = (float) ($fuel[$h->id] ?? 0);
            $s = (float) ($sea[$h->id] ?? 0);
            $per = fn ($x) => $b > 0 && $x > 0 ? round($x / $b, 2) : null;

            return ['hub' => $h, 'boxes' => $b, 'fuel' => $f, 'sea' => $s, 'total' => $f + $s, 'perBox' => $per($f + $s), 'fuelPerBox' => $per($f), 'seaPerBox' => $per($s)];
        })->filter(fn ($r) => $r['boxes'] || $r['total'])->values();
    }

    /** Sea shipments that sailed this month (or were made, if no sail date). */
    public function shipments(): Collection
    {
        return SeaShipment::with('hub:id,hub_name')->get()->filter(function (SeaShipment $s) {
            $at = Shipments::when($s, 'sailed') ? Carbon::parse(collect((array) $s->status_log)->where('status', 'sailed')->last()['at']) : ($s->etd ?? $s->created_at);

            return $at && $at->between($this->from, $this->to);
        })->values();
    }

    /** Container vs RoRo: cost per box shipped, from the shipments with a cost. */
    public function byMode(): array
    {
        if (! Shipments::ready()) {
            return [];
        }
        $out = [];
        foreach (SeaShipment::where('created_at', '>=', $this->from->copy()->subMonths(5))->get()->groupBy('mode') as $mode => $list) {
            $cost = 0.0;
            $n = 0;
            foreach ($list as $s) {
                $loaded = Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->where('is_loaded', true)->count();
                if ($s->cost() > 0 && $loaded > 0) {
                    $cost += $s->cost();
                    $n += $loaded;
                }
            }
            $out[$mode] = ['shipments' => $list->count(), 'boxes' => $n, 'perBox' => $n ? round($cost / $n, 2) : null];
        }

        return $out;
    }
}
