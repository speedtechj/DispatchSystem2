<?php

namespace App\Support;

use App\Enums\FailedDeliveryReason;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\DeliveryReversal;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Storage;

/**
 * Everything the partner hub (Company) panel shows for one hub:
 * incoming boxes by area, drivers today, needs attention, the week,
 * the hub score, the drivers leaderboard, the retry list and box tracking.
 *
 * "Our boxes" = boxes handed to this hub (tripinvoices.logistichub_id)
 * or put on one of its own trips (tripinvoices.deliveryloghub_id).
 */
class HubDesk
{
    /** Boxes per truck when a truck has no capacity set. */
    public const DEFAULT_CAPACITY = 60;

    public const WAIT_DAYS = 2;

    public function __construct(public readonly int $hubId) {}

    // ----------------------------------------------------------------- building blocks

    public function trips(): Builder
    {
        return Deliverylog::query()->where('logistichub_id', $this->hubId);
    }

    public function ours(): Builder
    {
        return Tripinvoice::query()->where(fn (Builder $q) => $q
            ->where('logistichub_id', $this->hubId)
            ->orWhereIn('deliveryloghub_id', $this->trips()->select('id')));
    }

    /** Handed to this hub on a loaded main truck, not on a hub trip yet. */
    public function waiting(): Builder
    {
        return Tripinvoice::query()
            ->where('logistichub_id', $this->hubId)
            ->where('is_loaded', true)
            ->where(fn (Builder $q) => $q->where('hub_assigned', false)->orWhereNull('hub_assigned'))
            ->where(fn (Builder $q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'));
    }

    protected static function notDelivered(Builder $q): Builder
    {
        return $q->where(fn (Builder $q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'));
    }

    protected static function deliveredSince(Builder $q, Carbon $since): Builder
    {
        return $q->where('tripinvoices.is_delivered', true)->whereRaw('COALESCE(tripinvoices.delivered_at, tripinvoices.updated_at) >= ?', [$since]);
    }

    /** Users of this hub marked as crew (drivers and helpers). */
    public function crew(): Builder
    {
        return User::query()
            ->where('logistichub_id', $this->hubId)
            ->where(fn (Builder $q) => $q->where('is_crew', true)->orWhereHas('workposition', fn (Builder $w) => $w->where('is_crew', true)));
    }

    protected function days(?string $since): int
    {
        return $since ? max(0, (int) Carbon::parse($since)->startOfDay()->diffInDays(today())) : 0;
    }

    // ----------------------------------------------------------------- incoming boxes

    /** Waiting boxes grouped by receiver city. @return Collection<int, array{key: string, city: string, barangays: string, boxes: int, oldest: int, ids: list<int>}> */
    public function areas(): Collection
    {
        return $this->waiting()->with(['box:id,receiver_city,receiver_barangay', 'deliverylog:id,eta'])->get()
            ->groupBy(fn (Tripinvoice $t) => trim((string) $t->box?->receiver_city) ?: 'No city')
            ->map(fn (Collection $rows, string $city) => [
                'key' => md5($city),
                'city' => $city,
                'barangays' => $rows->map(fn ($t) => trim((string) $t->box?->receiver_barangay))->filter()->countBy()->sortDesc()->keys()->take(3)->join(', '),
                'boxes' => $rows->count(),
                'oldest' => $rows->max(fn ($t) => $this->days($t->deliverylog?->eta)),
                'ids' => $rows->modelKeys(),
            ])
            ->sortByDesc('boxes')
            ->values();
    }

    /** Waiting boxes, the longest-waiting first. */
    public function oldestWaiting(int $limit = 50): Collection
    {
        return $this->waiting()
            ->with(['box:id,invoice,receiver_name,receiver_city,receiver_barangay,boxtype', 'deliverylog:id,eta,trip_number'])
            ->get()
            ->sortBy(fn ($t) => $t->deliverylog?->eta ?? '9999')
            ->take($limit)
            ->map(fn (Tripinvoice $t) => [
                'id' => $t->id,
                'invoice' => $t->box?->invoice ?? $t->invoice,
                'receiver' => $t->box?->receiver_name,
                'area' => collect([$t->box?->receiver_barangay, $t->box?->receiver_city])->filter()->join(', '),
                'boxtype' => $t->box?->boxtype,
                'days' => $this->days($t->deliverylog?->eta),
            ])
            ->values();
    }

    public function freeTrucks(): Collection
    {
        return Truck::query()->where('logistichub_id', $this->hubId)->where('is_active', true)
            ->where(fn (Builder $q) => $q->where('is_assigned', false)->orWhereNull('is_assigned'))
            ->orderBy('plate_no')->get(['id', 'plate_no', 'capacity']);
    }

    public function capacity(): int
    {
        $sizes = $this->freeTrucks()->pluck('capacity')->filter();

        return (int) ($sizes->isNotEmpty() ? round($sizes->avg()) : self::DEFAULT_CAPACITY);
    }

    // ----------------------------------------------------------------- dashboard

    /** Open trips of this hub with progress and crew. */
    public function driversToday(int $limit = 8): Collection
    {
        $trips = $this->trips()->where('is_active', true)->with(['truck:id,plate_no', 'truck.truckcrews'])
            ->latest('id')->limit($limit)->get();

        // truckcrews.crew is the crew member (truckcrews.user_id is who added them)
        $people = User::whereIn('id', $trips->flatMap(fn ($t) => $t->truck?->truckcrews->pluck('crew') ?? []))->get()->keyBy('id');

        return $trips->map(function (Deliverylog $trip) use ($people) {
            $rows = Tripinvoice::where('deliveryloghub_id', $trip->id)->with('box:id,receiver_city')->get();
            $total = $rows->count();
            $loaded = $rows->where('is_loaded_hub', true)->count();
            $done = $rows->where('is_delivered', true)->count();
            $crew = $trip->truck?->truckcrews->map(fn ($c) => $people[$c->crew]?->full_name ?? null)->filter()->values() ?? collect();

            return [
                'trip' => $trip,
                'driver' => $crew->first() ?? 'No crew',
                'initials' => collect(explode(' ', (string) $crew->first()))->filter()->map(fn ($p) => mb_substr($p, 0, 1))->take(2)->join('') ?: '?',
                'truck' => $trip->truck?->plate_no,
                'areas' => $rows->map(fn ($r) => $r->box?->receiver_city)->filter()->countBy()->sortDesc()->keys()->take(2)->join(', '),
                'total' => $total,
                'done' => $done,
                'status' => $total === 0 ? 'empty' : ($done === $total ? 'done' : ($loaded < $total ? 'loading' : 'road')),
            ];
        })->filter(fn ($row) => $row['total'] > 0)->values();
    }

    /** @return Collection<int, array{tag: string, tone: string, detail: string, action: string, link: string}> */
    public function attention(): Collection
    {
        $items = collect();

        $late = HubBoxes::waitingTooLong($this->hubId, self::WAIT_DAYS);
        if ($late['count']) {
            $items->push(['tag' => "{$late['count']} waiting ".self::WAIT_DAYS.'+ days', 'tone' => 'bad',
                'detail' => "Oldest {$late['oldest']}, due ".Carbon::parse($late['since'])->format('M j'), 'action' => 'Plan a trip', 'link' => 'incoming']);
        }

        $failed = DeliveryAttempt::whereIn('deliverylog_id', $this->trips()->select('id'))->whereDate('created_at', today())->get(['reason']);
        if ($failed->isNotEmpty()) {
            $items->push(['tag' => $failed->count().' not delivered today', 'tone' => 'warn',
                'detail' => $failed->countBy(fn ($a) => $a->reason->getLabel())->map(fn ($n, $l) => $n > 1 ? "{$l} ×{$n}" : $l)->join(' · '),
                'action' => 'Retry list', 'link' => 'retry']);
        }

        foreach (Truck::where('logistichub_id', $this->hubId)->whereDate('date_expired', '<=', today()->addDays(30))->orderBy('date_expired')->limit(3)->get() as $truck) {
            $expired = Carbon::parse($truck->date_expired)->lt(today());
            $items->push(['tag' => $expired ? 'Registration expired' : 'Registration due', 'tone' => $expired ? 'bad' : 'warn',
                'detail' => "Truck {$truck->plate_no} ".($expired ? 'expired ' : 'expires ').Carbon::parse($truck->date_expired)->format('M j'), 'action' => 'Open truck', 'link' => 'trucks']);
        }

        $onCrew = Truckcrew::query()->select('crew');
        foreach ($this->crew()->whereNotIn('id', $onCrew)->limit(3)->get() as $user) {
            $items->push(['tag' => 'Driver without truck', 'tone' => 'gray', 'detail' => "{$user->full_name} is not on any crew", 'action' => 'Assign', 'link' => 'crew']);
        }

        return $items;
    }

    /** Delivered per day for the last $days days, oldest first. */
    public function week(int $days = 7): Collection
    {
        $from = today()->subDays($days - 1);
        $counts = static::deliveredSince($this->ours(), $from)
            ->selectRaw('date(COALESCE(delivered_at, updated_at)) as day, count(*) as n')->groupBy('day')->pluck('n', 'day');

        return collect(range(0, $days - 1))->map(fn ($i) => ['date' => $from->copy()->addDays($i), 'boxes' => (int) ($counts[$from->copy()->addDays($i)->toDateString()] ?? 0)]);
    }

    /** Hub score for the last 30 days. */
    public function score(): array
    {
        // 30-day numbers change slowly: kept 10 minutes so the dashboard opens fast
        return cache()->store('file')->remember('hubdesk.score.'.$this->hubId.'.'.today()->toDateString(), 600, fn () => $this->workScore());
    }

    protected function workScore(): array
    {
        $since = now()->subDays(30);

        // counted in the database (no long lists of ids): delivered boxes, and those that had a failed try first
        $firstTry = function (Builder $delivered): ?int {
            $all = (clone $delivered)->count();
            if (! $all) {
                return null;
            }
            $tried = (clone $delivered)->whereExists(fn ($q) => $q->selectRaw('1')->from('delivery_attempts')->whereColumn('delivery_attempts.invoice_id', 'tripinvoices.invoice_id'))->count();

            return (int) round(($all - $tried) / $all * 100);
        };

        $mine = $firstTry(static::deliveredSince($this->ours(), $since));
        $network = $firstTry(static::deliveredSince(Tripinvoice::query(), $since));

        // grouped in the database: one row per (delivered day, due day), not one per box
        $handed = static::deliveredSince(Tripinvoice::query()->where('tripinvoices.logistichub_id', $this->hubId), $since)
            ->join('deliverylogs as dl', 'dl.id', '=', 'tripinvoices.deliverylog_id')->whereNotNull('dl.eta')
            ->selectRaw('date(COALESCE(tripinvoices.delivered_at, tripinvoices.updated_at)) as done, date(dl.eta) as due, count(*) as n')
            ->groupBy('done', 'due')->toBase()->get();
        $total = (int) $handed->sum('n');
        $onTime = $total ? (int) round($handed->filter(fn ($r) => Carbon::parse($r->done)->lte(Carbon::parse($r->due)->addDays(self::WAIT_DAYS)))->sum('n') / $total * 100) : null;

        $wait = function (Carbon $from, Carbon $to): ?float {
            $rows = Tripinvoice::query()->where('tripinvoices.logistichub_id', $this->hubId)->whereNotNull('tripinvoices.deliveryloghub_id')
                ->whereBetween('tripinvoices.updated_at', [$from, $to])
                ->join('deliverylogs as dl', 'dl.id', '=', 'tripinvoices.deliverylog_id')
                ->join('deliverylogs as hl', 'hl.id', '=', 'tripinvoices.deliveryloghub_id')
                ->whereNotNull('dl.eta')->whereNotNull('hl.departure_date')
                ->selectRaw('date(dl.eta) as due, date(hl.departure_date) as left_on, count(*) as n')
                ->groupBy('due', 'left_on')->toBase()->get();
            $n = (int) $rows->sum('n');

            return $n ? $rows->sum(fn ($r) => max(0, Carbon::parse($r->due)->diffInDays(Carbon::parse($r->left_on), false)) * $r->n) / $n : null;
        };

        return [
            'firstTry' => $mine, 'network' => $network, 'onTime' => $onTime,
            'wait' => $wait($since, now()), 'waitBefore' => $wait(now()->subDays(60), $since),
        ];
    }

    // ----------------------------------------------------------------- drivers

    public function drivers(int $days = 30): Collection
    {
        $since = now()->subDays($days);

        $trucks = Truckcrew::with('truck:id,plate_no')->latest('id')->get()->unique('crew')->mapWithKeys(fn ($c) => [$c->crew => $c->truck?->plate_no]);

        return $this->crew()->get()
            ->map(function (User $user) use ($since, $trucks) {
                $delivered = static::deliveredSince(Tripinvoice::where('delivered_by', $user->id), $since)->pluck('invoice_id');
                $tried = $delivered->isEmpty() ? 0 : DeliveryAttempt::whereIn('invoice_id', $delivered)->distinct()->count('invoice_id');
                $attempts = DeliveryAttempt::where('user_id', $user->id)->where('created_at', '>=', $since)->get(['reason']);
                $top = $attempts->countBy(fn ($a) => $a->reason->getLabel())->sortDesc();

                return [
                    'user' => $user,
                    'name' => $user->full_name,
                    'initials' => mb_substr((string) $user->first_name, 0, 1).mb_substr((string) $user->last_name, 0, 1),
                    'truck' => $trucks[$user->id] ?? null,
                    'delivered' => $delivered->count(),
                    'firstTry' => $delivered->isEmpty() ? null : (int) round(($delivered->count() - $tried) / $delivered->count() * 100),
                    'failed' => $attempts->count(),
                    'reason' => $top->isEmpty() ? null : $top->keys()->first().($top->first() > 1 ? ' ×'.$top->first() : ''),
                ];
            })
            ->sortByDesc('delivered')->values();
    }

    // ----------------------------------------------------------------- not delivered

    /** Our boxes with a failed attempt, still not delivered and not returned, grouped by the latest reason. */
    public function retryList(): Collection
    {
        $rows = static::notDelivered($this->ours())
            ->whereHas('box', fn (Builder $q) => $q->where(fn ($q) => $q->where('is_returned', false)->orWhereNull('is_returned')))
            ->whereIn('invoice_id', DeliveryAttempt::query()->select('invoice_id'))
            ->with(['box:id,invoice,receiver_name,receiver_city,receiver_barangay', 'hubTrip:id,trip_number'])
            ->get();

        $attempts = DeliveryAttempt::whereIn('invoice_id', $rows->pluck('invoice_id'))->orderBy('id')->get(['invoice_id', 'reason', 'created_at'])->groupBy('invoice_id');

        return $rows->map(function (Tripinvoice $t) use ($attempts) {
            $mine = $attempts[$t->invoice_id] ?? collect();

            return [
                'id' => $t->id,
                'invoice' => $t->box?->invoice ?? $t->invoice,
                'receiver' => $t->box?->receiver_name,
                'area' => collect([$t->box?->receiver_barangay, $t->box?->receiver_city])->filter()->join(', '),
                'tries' => $mine->count(),
                'reason' => $mine->last()?->reason,
                'trip' => $t->hubTrip?->trip_number,
            ];
        })
            ->groupBy(fn ($r) => $r['reason']?->value ?? 'other')
            ->map(fn (Collection $boxes, string $reason) => [
                'reason' => FailedDeliveryReason::tryFrom($reason) ?? FailedDeliveryReason::Other,
                'boxes' => $boxes->sortByDesc('tries')->values(),
            ])
            ->sortByDesc(fn ($g) => $g['boxes']->count())
            ->values();
    }

    public static function retryTip(FailedDeliveryReason $reason): string
    {
        return match ($reason) {
            FailedDeliveryReason::NoOneHome => 'Try again on another day, earlier or later than last time.',
            FailedDeliveryReason::PhoneUnreachable => 'Text the receiver before the next trip.',
            FailedDeliveryReason::AddressNotFound => 'Ask the main hub for the correct address first.',
            FailedDeliveryReason::Refused => 'Usually goes back: check with the main hub before trying again.',
            FailedDeliveryReason::Rescheduled => 'Put it on a trip for the day the receiver asked for.',
            FailedDeliveryReason::AreaInaccessible => 'Plan it with a smaller vehicle or when the road is open.',
            FailedDeliveryReason::BoxDamaged => 'Report the damage before sending it out again.',
            FailedDeliveryReason::OutOfTime => 'Put it first on tomorrow\'s trip.',
            default => 'Read the driver\'s note before trying again.',
        };
    }

    /** Open, unlocked trips of this hub that boxes can still be added to. */
    public function openTrips(): Collection
    {
        return $this->trips()->where('is_active', true)->where(fn ($q) => $q->where('is_lock', false)->orWhereNull('is_lock'))
            ->with('truck:id,plate_no')->latest('id')->get()
            ->mapWithKeys(fn ($t) => [$t->id => $t->trip_number.($t->truck ? ' · '.$t->truck->plate_no : '').($t->departure_date ? ' · leaves '.Carbon::parse($t->departure_date)->format('M j') : '')]);
    }

    // ----------------------------------------------------------------- track a box

    /** The box's story, if it is one of this hub's boxes. */
    public function track(string $code): ?array
    {
        $code = trim($code);
        if ($code === '') {
            return null;
        }

        $row = $this->ours()->where(fn ($q) => $q->where('invoice', $code)->orWhereHas('box', fn ($i) => $i->where('invoice', $code)))
            ->with(['box.container:id,container_no', 'deliverylog:id,trip_number,eta,logistichub_id', 'hubTrip.truck:id,plate_no', 'deliverer'])
            ->latest('id')->first();

        if (! $row) {
            return null;
        }

        /** @var Invoice|null $box */
        $box = $row->box;
        $url = fn (?string $path) => $path && Storage::disk('public')->exists($path) ? Storage::disk('public')->url($path) : null;
        $events = collect();

        if ($box?->verified_at || $box?->is_verified) {
            $events->push(['at' => $box->verified_at, 'title' => 'Unloaded at the warehouse', 'detail' => $box->container?->container_no ? 'Container '.$box->container->container_no : null, 'tone' => null]);
        }
        if ($row->deliverylog) {
            $events->push(['at' => $row->deliverylog->eta, 'title' => 'Handed to your hub', 'detail' => 'Main trip '.$row->deliverylog->trip_number, 'tone' => null, 'dateOnly' => true]);
        }
        $sea = \App\Support\Shipping\Shipments::ready() && $row->deliverylog_id ? \App\Support\Shipping\Shipments::forTrip((int) $row->deliverylog_id) : null;
        if ($sea) {
            foreach ((array) $sea->status_log as $e) {
                if (in_array($e['status'] ?? '', ['sealed', 'sailed', 'arrived', 'received'], true)) {
                    $events->push(['at' => $e['at'], 'title' => \App\Support\Shipping\Shipments::label($sea, $e['status']), 'detail' => 'Sea shipment '.$sea->code.($e['status'] === 'sailed' && $sea->vessel ? ' · '.$sea->vessel : ''), 'tone' => null]);
                }
            }
        }
        if ($row->hubTrip) {
            $events->push(['at' => $row->hubTrip->departure_date, 'title' => 'Out for delivery', 'detail' => 'Trip '.$row->hubTrip->trip_number.($row->hubTrip->truck ? ' · truck '.$row->hubTrip->truck->plate_no : ''), 'tone' => null, 'dateOnly' => true]);
        }
        foreach (DeliveryAttempt::where('invoice_id', $row->invoice_id)->with('user')->get() as $a) {
            $events->push(['at' => $a->created_at, 'title' => 'Not delivered: '.$a->reason->getLabel(), 'detail' => trim(($a->user?->full_name ?? '').($a->note ? ' · "'.$a->note.'"' : ''), ' ·'),
                'tone' => 'warn', 'photo' => $url(collect($a->photos)->first())]);
        }
        foreach (DeliveryReversal::where('invoice_id', $row->invoice_id)->with('user')->get() as $r) {
            $events->push(['at' => $r->created_at, 'title' => 'Delivery undone: '.$r->reason->getLabel(), 'detail' => $r->user?->full_name, 'tone' => 'warn']);
        }
        if ($row->is_delivered) {
            $events->push(['at' => $row->delivered_at ?? $row->updated_at, 'title' => 'Delivered', 'detail' => $row->deliverer?->full_name, 'tone' => 'ok',
                'photo' => $url(collect($row->delivery_picture)->first())]);
        }

        return [
            'row' => $row,
            'box' => $box,
            'status' => $row->is_delivered ? 'Delivered' : ($row->hubTrip ? ($row->is_loaded_hub ? 'Out for delivery' : 'On a trip, loading')
                : ($sea && \App\Support\Shipping\Shipments::stillAtSea($row) ? \App\Support\Shipping\Shipments::trackText($sea) : 'Waiting at your hub')),
            'events' => $events->sortByDesc(fn ($e) => $e['at'] ? Carbon::parse($e['at'])->timestamp : 0)->values(),
        ];
    }
}
