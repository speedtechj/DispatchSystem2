<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\Invoiceissue;
use App\Models\Maps\TripStop;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Maps\TripSorter;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Everything the driver's dashboard shows about their current trip.
 * The trip is found the same way as on "My deliveries": the newest active
 * trip of the truck the driver is crew on.
 */
class DriverTrip
{
    public function __construct(
        public readonly User $driver,
        public readonly ?Deliverylog $trip,
    ) {}

    public static function for(User $driver): self
    {
        return new self($driver, static::currentTrip($driver));
    }

    /** The trip the person is on now: on its crew (trip steps), or the newest active trip of their truck. */
    public static function currentTrip(User $driver): ?Deliverylog
    {
        return \App\Support\TripFlow::tripFor($driver);
    }

    /** Every box on the trip, including ones a partner hub handed over to it. */
    public function boxes(): Builder
    {
        $tripId = $this->trip?->getKey() ?? 0;

        return Tripinvoice::query()->where(fn (Builder $query) => $query
            ->where('deliverylog_id', $tripId)
            ->orWhere('deliveryloghub_id', $tripId));
    }

    /** @return array{total: int, delivered: int, notDelivered: int, left: int, percent: int} */
    public function progress(): array
    {
        // one database question (the driver app asks this on every tap)
        $tried = \App\Models\DeliveryAttempt::query()->select('invoice_id')->whereColumn('delivery_attempts.invoice_id', 'tripinvoices.invoice_id')->limit(1)->toBase();
        $r = $this->boxes()->toBase()->selectRaw('count(*) as total, sum(case when is_delivered = 1 then 1 else 0 end) as delivered')
            ->selectRaw('sum(case when is_delivered = 0 and exists('.$tried->toSql().') then 1 else 0 end) as tried', $tried->getBindings())
            ->first();
        $total = (int) $r->total;
        $delivered = (int) $r->delivered;
        $notDelivered = (int) $r->tried;

        return [
            'total' => $total,
            'delivered' => $delivered,
            'notDelivered' => $notDelivered,
            'left' => $total - $delivered,
            'percent' => $total ? (int) floor($delivered / $total * 100) : 0,
        ];
    }

    public function isFinished(): bool
    {
        $progress = $this->progress();

        return $progress['total'] > 0 && $progress['left'] === 0;
    }

    /** The other people on the truck, e.g. "Jun Reyes · Helper". */
    public function crewmates(): Collection
    {
        if (! $this->trip?->truck_id) {
            return collect();
        }

        $crew = \App\Support\TripFlow::crew($this->trip)->pluck('user_id');

        return User::with('workposition')
            ->whereIn('id', $crew->isNotEmpty() ? $crew : Truckcrew::where('truck_id', $this->trip->truck_id)->pluck('crew'))
            ->whereKeyNot($this->driver->getKey())
            ->get()
            ->map(fn (User $user) => [
                'name' => $user->full_name,
                'role' => $user->workposition?->position_description,
            ]);
    }

    /** Undelivered priority boxes, shown first. */
    public function priority(): Collection
    {
        return $this->remaining()
            ->filter(fn (Tripinvoice $box) => $box->invdata?->is_priority)
            ->map(fn (Tripinvoice $box) => $this->stopCard($box))
            ->values();
    }

    /**
     * Remaining boxes grouped by city and barangay, then by receiver, so the
     * driver can finish one area at a time and hand a whole household over at once.
     */
    public function areas(): Collection
    {
        return $this->remaining()
            ->groupBy(fn (Tripinvoice $box) => Str::title((string) $box->invdata?->receiver_city).'|'.Str::title((string) \App\Support\Maps\Barangays::of($box->invdata)))
            ->map(function (Collection $boxes, string $key) {
                [$city, $barangay] = explode('|', $key);

                $stops = $boxes
                    ->groupBy(fn (Tripinvoice $box) => Str::lower(trim($box->invdata?->receiver_name.'|'.$box->invdata?->receiver_address)))
                    ->map(function (Collection $household) {
                        $card = $this->stopCard($household->first());
                        $card['count'] = $household->count();
                        $card['invoices'] = $household->pluck('invoice')->join(', ');

                        return $card;
                    })
                    ->values();

                return [
                    'key' => md5($key),
                    'city' => $city ?: 'No city',
                    'barangay' => $barangay,
                    'boxes' => $boxes->count(),
                    'stops' => $stops,
                ];
            })
            ->sortByDesc('boxes')
            ->values();
    }

    /**
     * Stops still to visit, in the order the office sorted them (Maps & routes).
     * Each has what Navigate needs: the pin, or the address when there is no pin.
     */
    public function stops(): Collection
    {
        if (! $this->trip || ! TripSorter::ensure($this->trip, 10)) {
            return collect();
        }
        $left = $this->remaining()->keyBy('id');

        return TripSorter::stops($this->trip)
            ->map(function (TripStop $s) use ($left) {
                $boxes = collect($s->box_ids)->map(fn ($id) => $left[$id] ?? null)->filter()->values();
                if ($boxes->isEmpty()) {
                    return null;
                }
                $first = $boxes->first();
                $phone = $first->invdata?->receiver_mobile_no;

                return [
                    'id' => $s->id, 'no' => $s->stop_no, 'name' => $s->name, 'address' => $s->address,
                    'place' => trim(($s->barangay ? $s->barangay.', ' : '').$s->city, ', '),
                    'count' => $boxes->count(), 'invoice' => $first->invoice, 'invoices' => $boxes->pluck('invoice')->join(', '),
                    'priority' => $s->priority, 'zone' => $s->zone,
                    'lat' => $s->lat, 'lng' => $s->lng, 'exact' => $s->exact,
                    'go' => $s->hasPin() ? $s->lat.','.$s->lng : $s->address.', Philippines',
                    'phone' => $phone, 'tel' => $phone ? 'tel:'.preg_replace('/[^0-9+]/', '', $phone) : null,
                ];
            })
            ->filter()
            ->values();
    }

    /** Undelivered boxes with a problem reported at unloading. */
    public function problems(): Collection
    {
        $remaining = $this->remaining()->keyBy('invoice_id');

        if ($remaining->isEmpty()) {
            return collect();
        }

        return Invoiceissue::with('boxissue')
            ->whereIn('invoice_id', $remaining->keys())
            ->latest('id')
            ->get()
            ->unique('invoice_id')
            ->map(fn (Invoiceissue $issue) => $this->stopCard($remaining[$issue->invoice_id]) + [
                'issue' => $issue->boxissue?->issue_type ?? 'Problem reported',
                'remarks' => Str::limit(strip_tags((string) $issue->remarks), 80),
            ])
            ->values();
    }

    /** The latest boxes delivered today, with their proof photo. */
    public function deliveredToday(int $limit = 5): Collection
    {
        return $this->boxes()
            ->with('invdata')
            ->where('is_delivered', true)
            ->where(fn (Builder $query) => $query
                ->whereDate('delivered_at', today())
                ->orWhere(fn (Builder $query) => $query->whereNull('delivered_at')->whereDate('updated_at', today())))
            ->orderByRaw('COALESCE(delivered_at, updated_at) DESC')
            ->limit($limit)
            ->get()
            ->map(fn (Tripinvoice $box) => $this->stopCard($box) + [
                'id' => $box->getKey(),
                'undoMinutesLeft' => app(TripAssignment::class)->driverUndoMinutesLeft($box, $this->driver),
                'time' => ($box->delivered_at ?? $box->updated_at)?->format('g:i A'),
                'photo' => ($photo = collect($box->delivery_picture)->first())
                    ? Storage::disk('public')->url($photo)
                    : null,
            ]);
    }

    protected function remaining(): Collection
    {
        return once(fn () => $this->boxes()
            ->with('invdata')
            ->where('is_delivered', false)
            ->orderBy('invoice')
            ->get());
    }

    /** @return array{invoice: string, name: string, address: string, phone: ?string, tel: ?string, count: int} */
    protected function stopCard(Tripinvoice $box): array
    {
        $invoice = $box->invdata;
        $phone = $invoice?->receiver_mobile_no;

        return [
            'invoice' => $box->invoice,
            'name' => Str::title((string) $invoice?->receiver_name),
            'address' => collect([$invoice?->receiver_address, \App\Support\Maps\Barangays::of($invoice), $invoice?->receiver_city])
                ->filter()->map(fn ($part) => Str::title($part))->join(', '),
            'phone' => $phone,
            'tel' => $phone ? 'tel:'.preg_replace('/[^0-9+]/', '', $phone) : null,
            'count' => 1,
        ];
    }
}
