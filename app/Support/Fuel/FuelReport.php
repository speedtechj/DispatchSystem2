<?php

namespace App\Support\Fuel;

use App\Models\Fuel\FuelCash;
use App\Models\Fuel\FuelFill;
use App\Models\Fuel\FuelStatementLine;
use App\Models\Truck;
use App\Models\Tripinvoice;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;

/**
 * What the Fuel page shows for a month, for the trucks a person may see:
 * totals, each truck, alerts and VAT.
 */
class FuelReport
{
    public Carbon $from;

    public Carbon $to;

    /** @param  int|false|null  $hub  null = all hubs (Admin), false = none */
    public function __construct(public int|false|null $hub, ?string $month = null)
    {
        $this->from = $month ? Carbon::parse($month.'-01')->startOfMonth() : now()->startOfMonth();
        $this->to = $this->from->copy()->endOfMonth();
    }

    /** @return Collection<int, Truck> */
    public function trucks(): Collection
    {
        if ($this->hub === false) {
            return collect();
        }

        return Truck::query()->when($this->hub !== null, fn ($q) => $q->where('logistichub_id', $this->hub))
            ->orderBy('plate_no')->get();
    }

    public function fills(): Builder
    {
        return FuelFill::query()->whereIn('truck_id', $this->trucks()->pluck('id'))
            ->whereBetween('filled_at', [$this->from, $this->to]);
    }

    public function totals(): array
    {
        $f = $this->fills()->get();
        $spent = $f->sum('total');
        $cash = $f->where('paid_with', 'cash')->sum('total');
        $vat = $f->sum('vat');
        $noTin = $f->filter(fn ($x) => $x->buyer_tin_ok === false)->sum('vat');
        $km = $f->sum('km_since');
        $kmLiters = $f->whereNotNull('km_since')->sum('liters');
        $boxes = Tripinvoice::query()->where('is_delivered', true)->whereBetween('delivered_at', [$this->from, $this->to])
            ->whereIn('deliverylog_id', \App\Models\Deliverylog::query()->whereIn('truck_id', $this->trucks()->pluck('id'))->select('id'))->count();

        return [
            'spent' => $spent, 'liters' => $f->sum('liters'), 'fills' => $f->count(),
            'diesel' => $f->where('fuel_type', 'diesel')->sum('liters'), 'gasoline' => $f->where('fuel_type', 'gasoline')->sum('liters'),
            'cash' => $cash, 'cashPct' => $spent > 0 ? (int) round($cash / $spent * 100) : 0,
            'vat' => $vat, 'vatNoTin' => $noTin, 'kml' => $kmLiters > 0 ? round($km / $kmLiters, 1) : null,
            'boxes' => $boxes, 'perBox' => $boxes > 0 ? round($spent / $boxes, 2) : null,
            'unsettled' => FuelCash::whereNull('settled_at')->whereIn('truck_id', $this->trucks()->pluck('id'))->count(),
        ];
    }

    /** One row per truck with fills this month. */
    public function perTruck(): Collection
    {
        $fills = $this->fills()->orderBy('filled_at')->get()->groupBy('truck_id');

        return $this->trucks()->map(function (Truck $t) use ($fills) {
            $f = $fills->get($t->id, collect());
            $withKm = $f->whereNotNull('km_since');
            $kml = $withKm->sum('liters') > 0 ? round($withKm->sum('km_since') / $withKm->sum('liters'), 1) : null;
            $recent = Fuel::kml($t->id, 3);
            $before = Fuel::kml($t->id, 10, 3);
            $change = $recent && $before ? (int) round(($recent - $before) / $before * 100) : null;
            $last = $f->last();

            return [
                'truck' => $t, 'liters' => $f->sum('liters'), 'spent' => $f->sum('total'), 'fills' => $f->count(), 'kml' => $kml,
                'change' => $change, 'perKm' => $withKm->sum('km_since') > 0 ? round($withKm->sum('total') / $withKm->sum('km_since'), 2) : null,
                'last' => $last ? $last->filled_at->format('M j').' · '.($last->station ?: '—') : null,
            ];
        })->filter(fn ($r) => $r['fills'] > 0 || $this->hub !== null)->values();
    }

    /**
     * What to look at, newest first.
     *
     * @return list<array{kind: string, icon: string, title: string, text: string, when: string, at: Carbon, fill: ?int}>
     */
    public function alerts(): array
    {
        $out = [];
        $trucks = $this->trucks()->keyBy('id');
        $fills = $this->fills()->with('truck')->orderBy('filled_at')->get();
        $peso = fn ($n) => '₱'.number_format((float) $n, 2);
        $add = function (string $kind, string $icon, string $title, string $text, Carbon $at, ?int $fill = null) use (&$out) {
            $out[] = ['kind' => $kind, 'icon' => $icon, 'title' => $title, 'text' => $text, 'when' => $at->format('M j · g:i A'), 'at' => $at, 'fill' => $fill];
        };
        $prices = [];

        foreach ($fills as $f) {
            $t = $f->truck;
            $plate = $t?->plate_no ?? 'Truck';
            if ($t?->fuel_type && $f->fuel_type && $t->fuel_type !== $f->fuel_type) {
                $add('red', '⛽', "{$plate} ({$t->fuel_type}) · {$f->fuel_type} on the receipt",
                    trim(($f->station ?: '').' · '.rtrim(rtrim(number_format($f->liters, 2), '0'), '.').' L '.($f->product ?: '').' · '.$peso($f->total).' · paid '.$f->paid_with, ' ·').'. Wrong fuel, or another vehicle?', $f->filled_at, $f->id);
            }
            if ($t?->tank_liters && $f->liters > $t->tank_liters * 1.02) {
                $add('red', '🛢️', "{$plate} · {$f->liters} L in one fill", "The tank holds {$t->tank_liters} L. ".($f->station ? "At {$f->station}." : ''), $f->filled_at, $f->id);
            }
            if ($f->gps_ok === false) {
                $add('red', '📍', "{$plate} · fill added away from the truck", 'The phone was '.number_format($f->gps_distance_m / 1000, 1).' km from the truck GPS when this fill was added.', $f->filled_at, $f->id);
            }
            if ($f->price_per_liter && $f->fuel_type) {
                $week = Fuel::weekStart($f->filled_at)->toDateString();
                $prices[$f->fuel_type][$week] ??= Fuel::price($f->fuel_type, $f->filled_at)['price'];
                $usual = $prices[$f->fuel_type][$week];
                if ($usual && abs($f->price_per_liter - $usual) > $usual * 0.1) {
                    $add('amber', '💵', "{$plate} · ₱".number_format($f->price_per_liter, 2)."/L on a {$f->paid_with} receipt", 'This week\'s '.$f->fuel_type.' price is ₱'.number_format($usual, 2).'/L. '.($f->station ? "At {$f->station}." : ''), $f->filled_at, $f->id);
                }
            }
            if ($f->total >= 1000 && $f->vat !== null && $f->vat == 0.0) {
                $add('amber', '🧾', "{$plate} · no VAT on the receipt", ($f->station ?: 'The station').' · '.$peso($f->total).'. A non-VAT station, or not a proper receipt.', $f->filled_at, $f->id);
            }
        }

        // two fills close together
        foreach ($fills->groupBy('truck_id') as $list) {
            $prev = null;
            foreach ($list as $f) {
                if ($prev && $prev->filled_at->diffInMinutes($f->filled_at) < 120) {
                    $add('amber', '⏱️', ($f->truck?->plate_no ?? 'Truck').' · two fills in '.(int) $prev->filled_at->diffInMinutes($f->filled_at).' minutes',
                        rtrim(rtrim(number_format($prev->liters, 2), '0'), '.').' L then '.rtrim(rtrim(number_format($f->liters, 2), '0'), '.').' L.', $f->filled_at, $f->id);
                }
                $prev = $f;
            }
        }

        // km per liter dropping
        foreach ($trucks as $t) {
            $recent = Fuel::kml($t->id, 3);
            $before = Fuel::kml($t->id, 10, 3);
            if ($recent && $before && $recent < $before * 0.85) {
                $add('amber', '📉', "{$t->plate_no} · km per liter down ".(int) round((1 - $recent / $before) * 100).'%',
                    "{$recent} km/L the last 3 fills, normally {$before}. Check tires, engine, or the fills.", now(), null);
            }
        }

        // the company TIN missing on receipts of ₱1,000 and up
        $noTin = $fills->filter(fn ($f) => $f->buyer_tin_ok === false);
        if ($noTin->isNotEmpty()) {
            $add('amber', '🧾', $noTin->count().' '.str('receipt')->plural($noTin->count()).' without your company TIN',
                'VAT of '.$peso($noTin->sum('vat')).' cannot be claimed. Ask the drivers to show the company TIN card to the cashier.', $noTin->last()->filled_at, null);
        }

        // card statement lines
        $lines = FuelStatementLine::query()->whereIn('truck_id', $trucks->keys())->whereBetween('charged_at', [$this->from, $this->to])
            ->whereIn('status', ['no_fill', 'liters_differ'])->with('truck')->get();
        $noFill = $lines->where('status', 'no_fill');
        if ($noFill->isNotEmpty()) {
            $add('amber', '💳', $noFill->count().' card '.str('charge')->plural($noFill->count()).' with no fill in the Driver app',
                $noFill->take(3)->map(fn ($l) => ($l->truck?->plate_no ?? '?').' '.($l->charged_at?->format('M j g:i A') ?? '').' '.$peso($l->amount))->join(' · '), $noFill->max('charged_at'), null);
        }
        foreach ($lines->where('status', 'liters_differ') as $l) {
            $add('amber', '⚖️', ($l->truck?->plate_no ?? 'Truck').' · liters differ from the card', 'Card: '.$l->liters.' L · Driver app: '.($l->fuelFill?->liters ?? '—').' L · '.($l->station ?: ''), $l->charged_at ?? now(), $l->fuel_fill_id);
        }

        // fuel cash not settled 2 days after it was given
        FuelCash::whereNull('settled_at')->whereIn('truck_id', $trucks->keys())->where('given_at', '<', now()->subDays(2))->with('trip')
            ->get()->each(fn ($c) => $add('amber', '💵', 'Fuel cash not settled · trip '.($c->trip?->trip_number ?? $c->deliverylog_id),
                $peso($c->given).' given '.$c->given_at->diffForHumans().'. Cash receipts so far: '.$peso($c->spent()).'.', $c->given_at, null));

        usort($out, fn ($a, $b) => [$a['kind'] === 'red' ? 0 : 1, -$a['at']->getTimestamp()] <=> [$b['kind'] === 'red' ? 0 : 1, -$b['at']->getTimestamp()]);

        return $out;
    }
}
