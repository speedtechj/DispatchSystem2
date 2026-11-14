<?php

namespace App\Support\Ai;

use App\Models\Ai\AiAlert;
use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;

/**
 * Alerts: looks for unusual things in the scans and deliveries. Runs every 15 minutes.
 * Plain rules on your own data, so it works without the AI key.
 */
class Alerts
{
    /** Deliveries marked this close together look like they were not really made one by one. */
    public const BURST_COUNT = 10;

    public const BURST_MINUTES = 5;

    public const STUCK_DAYS = 4;

    public const AREA_FAILS = 5;

    public static function run(): int
    {
        if (! Ai::enabled('alerts')) {
            return 0;
        }

        return static::fastDeliveries() + static::onTwoTrips() + static::stuckAfterUnload()
            + static::longOnTruck() + static::areaFailures();
    }

    /** One driver marking many boxes delivered within a few minutes. */
    public static function fastDeliveries(): int
    {
        $n = 0;
        $rows = Tripinvoice::where('is_delivered', true)->whereNotNull('delivered_by')
            ->where('delivered_at', '>=', now()->subDay())
            ->orderBy('delivered_at')->get(['id', 'invoice', 'delivered_at', 'delivered_by', 'deliverylog_id', 'logistichub_id']);

        foreach ($rows->groupBy('delivered_by') as $driverId => $list) {
            $list = $list->values();
            for ($i = 0; $i + self::BURST_COUNT - 1 < $list->count(); $i++) {
                $first = $list[$i];
                $last = $list[$i + self::BURST_COUNT - 1];
                if ($first->delivered_at->diffInMinutes($last->delivered_at) <= self::BURST_MINUTES) {
                    $burst = $list->filter(fn ($r) => $r->delivered_at->between($first->delivered_at, $first->delivered_at->copy()->addMinutes(self::BURST_MINUTES)));
                    $driver = User::find($driverId);
                    $trip = Deliverylog::find($first->deliverylog_id);
                    AiAlert::raise('fast:'.$driverId.':'.$first->delivered_at->format('YmdHi'), [
                        'kind' => 'drivers', 'severity' => 'high',
                        'title' => 'Too many deliveries too fast',
                        'body' => sprintf('%s marked %d boxes delivered in %d minutes (%s, trip %s). Check the delivery photos.',
                            $driver?->full_name ?? 'A driver', $burst->count(), max(1, $first->delivered_at->diffInMinutes($burst->last()->delivered_at)),
                            $first->delivered_at->format('M j g:i A'), $trip?->trip_number ?? '—'),
                        'link' => 'box-photos?q='.urlencode((string) ($trip?->trip_number ?? $first->invoice)),
                        'logistichub_id' => $first->logistichub_id,
                    ]);
                    $n++;
                    break;
                }
            }
        }

        return $n;
    }

    /** The same box is on two active delivery trips. */
    public static function onTwoTrips(): int
    {
        $active = Deliverylog::where('is_active', true)->pluck('id');
        $dupes = Tripinvoice::whereIn('deliverylog_id', $active)->where('is_delivered', false)
            ->selectRaw('invoice_id, count(*) as n')->groupBy('invoice_id')->havingRaw('count(*) > 1')->pluck('n', 'invoice_id');

        foreach ($dupes as $invoiceId => $count) {
            $rows = Tripinvoice::where('invoice_id', $invoiceId)->whereIn('deliverylog_id', $active)->with('deliverylog')->get();
            AiAlert::raise('twotrips:'.$invoiceId, [
                'kind' => 'trips', 'severity' => 'mid',
                'title' => 'Box on two trips',
                'body' => sprintf('Box %s is on %d active trips (%s). One of them is probably a wrong scan.',
                    $rows->first()->invoice, $count, $rows->map(fn ($r) => $r->deliverylog?->trip_number)->filter()->join(', ')),
                'link' => 'box-photos?q='.urlencode((string) $rows->first()->invoice),
                'logistichub_id' => $rows->first()->logistichub_id,
            ]);
        }

        return $dupes->count();
    }

    /** Boxes from an unloaded container that are not on any trip, not delivered and not returned after a few days. */
    public static function stuckAfterUnload(): int
    {
        $n = 0;
        $containers = Container::whereNotNull('unloaded_at')
            ->where('unloaded_at', '<=', now()->subDays(self::STUCK_DAYS))
            ->where('unloaded_at', '>=', now()->subDays(60))->get();

        foreach ($containers as $c) {
            $stuck = Invoice::where('container_id', $c->id)->where('is_verified', true)
                ->where('is_delivered', false)->where('is_assigned', false)->where('wh_is_assigned', false)
                ->whereNotIn('id', Tripinvoice::select('invoice_id'))->pluck('invoice');
            if ($stuck->isEmpty()) {
                continue;
            }
            $days = (int) Carbon::parse($c->unloaded_at)->diffInDays(now());
            AiAlert::raise('stuck:'.$c->id.':'.$stuck->count(), [
                'kind' => 'warehouse', 'severity' => $stuck->count() > 20 ? 'high' : 'mid',
                'title' => 'Boxes not moving after unload',
                'body' => sprintf('%d %s from container %s %s unloaded %d days ago but not on any trip yet: %s.',
                    $stuck->count(), Str::plural('box', $stuck->count()), $c->container_no, $stuck->count() === 1 ? 'was' : 'were', $days,
                    $stuck->take(8)->join(', ').($stuck->count() > 8 ? ' …' : '')),
                'link' => 'box-photos?q='.urlencode((string) $c->container_no),
                'warehouse_id' => $c->warehouse_id,
            ]);
            $n++;
        }

        return $n;
    }

    /** Loaded on a trip that left days ago, still not delivered and no attempt recorded. */
    public static function longOnTruck(): int
    {
        $n = 0;
        $trips = Deliverylog::where('is_active', true)->whereNotNull('departure_date')
            ->where('departure_date', '<=', now()->subDays(3)->toDateString())->get();
        foreach ($trips as $trip) {
            $boxes = Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->where('is_delivered', false)
                ->whereDoesntHave('deliveryAttempts')->pluck('invoice');
            if ($boxes->isEmpty()) {
                continue;
            }
            AiAlert::raise('ontruck:'.$trip->id.':'.$boxes->count(), [
                'kind' => 'trips', 'severity' => 'mid',
                'title' => 'Boxes on a truck for days',
                'body' => sprintf('Trip %s left on %s. %d loaded %s still not delivered and no attempt was recorded: %s.',
                    $trip->trip_number, Carbon::parse($trip->departure_date)->format('M j'), $boxes->count(), Str::plural('box', $boxes->count()),
                    $boxes->take(8)->join(', ').($boxes->count() > 8 ? ' …' : '')),
                'link' => 'box-photos?q='.urlencode((string) $trip->trip_number),
                'logistichub_id' => $trip->logistichub_id,
            ]);
            $n++;
        }

        return $n;
    }

    /** Many failed deliveries in one barangay this week. */
    public static function areaFailures(): int
    {
        $n = 0;
        $rows = DeliveryAttempt::where('delivery_attempts.created_at', '>=', now()->subDays(7))
            ->join('invoices', 'invoices.id', '=', 'delivery_attempts.invoice_id')
            ->selectRaw('invoices.receiver_barangay as brgy, invoices.receiver_city as city, count(*) as n')
            ->groupBy('invoices.receiver_barangay', 'invoices.receiver_city')
            ->havingRaw('count(*) >= ?', [self::AREA_FAILS])->get();

        foreach ($rows as $r) {
            $attempts = DeliveryAttempt::where('delivery_attempts.created_at', '>=', now()->subDays(7))
                ->whereHas('invoice', fn ($q) => $q->where('receiver_barangay', $r->brgy)->where('receiver_city', $r->city))
                ->with('tripinvoice')->get();
            $top = $attempts->groupBy(fn ($a) => $a->reason?->getLabel() ?? 'Other')->sortByDesc->count()->keys()->first();
            $hours = $attempts->groupBy(fn ($a) => (int) $a->created_at->format('G'))->sortByDesc->count()->keys()->first();
            AiAlert::raise('area:'.Str::slug($r->brgy.'-'.$r->city).':'.now()->format('oW'), [
                'kind' => 'trips', 'severity' => 'low',
                'title' => 'Many failed deliveries in one area',
                'body' => sprintf('%d failed deliveries in %s, %s this week, mostly "%s"%s.',
                    $r->n, Str::title((string) $r->brgy), Str::title((string) $r->city), $top,
                    $hours !== null ? sprintf(' around %s. Try another time of day', Carbon::today()->setHour($hours)->format('g A')) : ''),
                'logistichub_id' => $attempts->first()?->tripinvoice?->logistichub_id,
            ]);
            $n++;
        }

        return $n;
    }
}
