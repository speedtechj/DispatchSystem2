<?php

namespace App\Support\Sms;

use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Models\Maps\TripStop;
use App\Models\Sms\SmsMessage;
use App\Models\Tracking\TruckPosition;
use App\Models\Tripinvoice;
use App\Support\Ai\TripPlanner;
use App\Support\Maps\TripSorter;
use App\Support\Tracking\Tracker;
use Illuminate\Support\Str;
use Throwable;

/**
 * When to text receivers. One text per receiver (all their boxes together), never twice
 * for the same thing. Nothing is sent when the message is switched off or there is no key.
 */
class SmsEvents
{
    /** Trip on the road: all boxes loaded, or the first box delivered. */
    public static function outForDelivery(Deliverylog $trip): int
    {
        if (TripSorter::isTransfer($trip) || ($trip->no_sms ?? false)) {
            return 0;
        }
        // a hub's own trip has its own switch and text
        $atHub = Tripinvoice::where('deliveryloghub_id', $trip->id)->exists();
        $kind = $atHub && array_key_exists('out_for_delivery_hub', SmsSettings::KINDS) ? 'out_for_delivery_hub' : 'out_for_delivery';
        if (! SmsSettings::on($kind)) {
            return 0;
        }
        // Trip planned by city: boxes keep joining while loading, so text only once the trip is locked.
        if (\App\Support\Trips\CityTrips::isCityTrip($trip) && ! $trip->is_lock && ! $trip->taken_at) {
            return 0;
        }
        if (! TripSorter::ensure($trip, 0)) {
            return 0;
        }
        $boxes = TripSorter::boxes($trip);
        $hub = Tripinvoice::where('deliveryloghub_id', $trip->id)->exists();
        $onRoad = ! (clone $boxes)->where($hub ? 'is_loaded_hub' : 'is_loaded', false)->exists() || (clone $boxes)->where('is_delivered', true)->exists();
        if (! $onRoad || ! (clone $boxes)->exists()) {
            return 0;
        }
        $n = 0;
        foreach (Tracker::stopsLeft($trip) as $stop) {
            $n += static::forStop($kind, $trip, $stop) ? 1 : 0;
        }

        return $n;
    }

    /** The next 1–2 stops, once the driver is delivering (a box delivered or the truck moving). */
    public static function driverNext(Deliverylog $trip): int
    {
        if (! SmsSettings::on('driver_next') || TripSorter::isTransfer($trip) || ! TripSorter::ensure($trip, 0)) {
            return 0;
        }
        $active = TripSorter::boxes($trip)->where('is_delivered', true)->whereDate('delivered_at', today())->exists()
            || TruckPosition::where('deliverylog_id', $trip->id)->where('recorded_at', '>=', now()->subMinutes(15))->exists();
        if (! $active) {
            return 0;
        }
        $card = $trip->truck ? Tracker::card($trip) : null;
        $n = 0;
        foreach (Tracker::stopsLeft($trip)->take(2)->values() as $i => $stop) {
            $min = $i === 0 && $card && preg_match('/~(\d+) min/', (string) $card['next'], $m) ? (int) $m[1] : 15 + $i * 15;
            $n += static::forStop('driver_next', $trip, $stop, ['minutes' => max(5, (int) (ceil($min / 5) * 5))]) ? 1 : 0;
        }

        return $n;
    }

    /** The last box of a receiver was delivered. */
    public static function delivered(Tripinvoice $box): void
    {
        if (! SmsSettings::on('delivered') || ! ($trip = static::tripOf($box)) || ! TripSorter::ensure($trip, 0)) {
            return;
        }
        $stop = static::stopOf($trip, $box->id);
        if (! $stop) {
            return;
        }
        $rows = Tripinvoice::whereIn('id', $stop->box_ids)->get(['id', 'is_delivered', 'delivered_at']);
        if ($rows->contains(fn ($r) => ! $r->is_delivered)) {
            return;
        }
        static::forStop('delivered', $trip, $stop, ['time' => optional($rows->max('delivered_at'))->format('g:i A') ?? now()->format('g:i A')], $stop->box_ids);
    }

    public static function notDelivered(DeliveryAttempt $a): void
    {
        $box = Tripinvoice::find($a->tripinvoice_id);
        if (! SmsSettings::on('not_delivered') || ! $box || ! ($trip = static::tripOf($box)) || ! TripSorter::ensure($trip, 0)) {
            return;
        }
        $stop = static::stopOf($trip, $box->id);
        if (! $stop) {
            return;
        }
        $lang = Templates::langFor($box->invdata?->receiver_province);
        static::forStop('not_delivered', $trip, $stop, [
            'reason' => SmsWriter::reason($a, $lang),
            'next_day' => static::nextDay(),
        ], [$box->id], perDay: true);
    }

    /** Handed to a partner hub. */
    public static function hubArrived(Tripinvoice $box): void
    {
        if (! SmsSettings::on('hub_arrived') || ! $box->logistichub_id || ! ($inv = $box->invdata)) {
            return;
        }
        $hub = Logistichub::find($box->logistichub_id);
        if (! $hub?->is_company) {
            return;
        }
        $key = substr(sha1('hub'.$hub->id.TripPlanner::receiverKey($inv).$box->deliverylog_id), 0, 40);
        if (SmsMessage::where('kind', 'hub_arrived')->where('receiver_key', $key)->exists()) {
            return;
        }
        $codes = Tripinvoice::where('deliverylog_id', $box->deliverylog_id)->where('logistichub_id', $hub->id)->with('invdata')->get()
            ->filter(fn ($b) => $b->invdata && TripPlanner::receiverKey($b->invdata) === TripPlanner::receiverKey($inv));
        $lang = Templates::langFor($inv->receiver_province);
        $text = Templates::render(Templates::get('hub_arrived', $lang), [
            'name' => static::firstName($inv->receiver_name), 'boxes' => static::codes($codes->pluck('invoice')->all()),
            'box_count' => $codes->count(), 'hub' => $hub->hub_name, 'hub_phone' => SmsSettings::officePhone(),
        ]);
        SmsSender::send('hub_arrived', $inv->receiver_mobile_no, Str::title((string) $inv->receiver_name), $text, ['receiver_key' => $key, 'invoice_ids' => $codes->pluck('invoice_id')->all(), 'lang' => $lang]);
    }

    protected static function forStop(string $kind, Deliverylog $trip, TripStop $stop, array $extra = [], ?array $ids = null, bool $perDay = false): ?SmsMessage
    {
        $already = SmsMessage::where('kind', $kind)->where('deliverylog_id', $trip->id)->where('receiver_key', $stop->receiver_key)
            ->whereNotIn('status', ['failed'])->when($perDay, fn ($q) => $q->whereDate('created_at', today()));
        if ($already->exists()) {
            return null;
        }
        $boxes = Tripinvoice::with('invdata')->whereIn('id', $ids ?? $stop->box_ids)->get();
        $inv = $boxes->first()?->invdata;
        if (! $inv) {
            return null;
        }
        $lang = Templates::langFor($inv->receiver_province);
        $driver = $trip->truck ? Tracker::crew($trip->truck_id)['driver'] : null;
        $text = Templates::render(Templates::get($kind, $lang), $extra + [
            'name' => static::firstName($inv->receiver_name),
            'boxes' => static::codes($boxes->pluck('invoice')->all()),
            'box_count' => $boxes->count(),
            'truck' => (string) $trip->truck?->plate_no,
            'driver' => $driver ? Str::before((string) $driver->full_name, ' ') : '',
            'hub' => (string) $trip->destination?->hub_name,
            'hub_phone' => $kind === 'out_for_delivery_hub' ? ((string) \App\Models\Logistichub::whereKey($trip->logistichub_id)->value('phone') ?: SmsSettings::officePhone()) : SmsSettings::officePhone(),
        ]);

        return SmsSender::send($kind, $stop->phone ?: $inv->receiver_mobile_no, $stop->name, $text, [
            'deliverylog_id' => $trip->id, 'receiver_key' => $stop->receiver_key, 'invoice_ids' => $boxes->pluck('invoice_id')->all(), 'lang' => $lang,
        ]);
    }

    protected static function tripOf(Tripinvoice $box): ?Deliverylog
    {
        return Deliverylog::with('truck')->find($box->deliveryloghub_id ?: $box->deliverylog_id);
    }

    protected static function stopOf(Deliverylog $trip, int $boxId): ?TripStop
    {
        $stop = TripStop::where('deliverylog_id', $trip->id)->get()->first(fn (TripStop $s) => in_array($boxId, $s->box_ids ?? [], false));
        if (! $stop) {
            TripSorter::sort($trip, 0);
            $stop = TripStop::where('deliverylog_id', $trip->id)->get()->first(fn (TripStop $s) => in_array($boxId, $s->box_ids ?? [], false));
        }

        return $stop;
    }

    public static function firstName(?string $name): string
    {
        return Str::title(Str::before(Str::squish((string) $name), ' ')) ?: 'po';
    }

    public static function codes(array $codes): string
    {
        $codes = array_values(array_filter($codes));

        return count($codes) > 4 ? implode(', ', array_slice($codes, 0, 3)).' +'.(count($codes) - 3).' more' : implode(', ', $codes);
    }

    public static function nextDay(): string
    {
        $d = today()->addDay();

        return ($d->isSunday() ? $d->addDay() : $d)->format('M j');
    }

    /** Every 5 minutes (sms:work). */
    public static function work(): int
    {
        $n = 0;
        foreach (Deliverylog::with('truck', 'destination')->where('is_active', true)->get() as $trip) {
            try {
                $n += static::outForDelivery($trip) + static::driverNext($trip);
            } catch (Throwable $e) {
                report($e);
            }
        }

        return $n;
    }
}
