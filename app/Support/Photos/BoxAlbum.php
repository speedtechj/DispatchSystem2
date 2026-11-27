<?php

namespace App\Support\Photos;

use App\Models\BoxPhoto;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Storage;

/**
 * Every photo of a box in one list: scan photos (box_photos) plus the driver's
 * delivery photos (tripinvoices.delivery_picture) and not-delivered photos (delivery_attempts.photos).
 *
 * Each photo is an array with a key used for selecting it:
 *   p:{box_photo id}   d:{tripinvoice id}:{n}   a:{delivery attempt id}:{n}
 */
class BoxAlbum
{
    public const MAX_BOXES = 30;

    public function __construct(public readonly ?User $user) {}

    /** Partner hub users only see their own boxes. Null = sees everything. */
    protected function hubLimit(): ?int
    {
        if (! $this->user || $this->user->hasRole('super_admin')) {
            return $this->user ? null : -1;
        }
        $hub = $this->user->logistichub_id ? Logistichub::find($this->user->logistichub_id) : null;
        if ($hub?->is_company) {
            return $hub->id;
        }

        return ($hub || $this->user->warehouse_id) ? null : -1;
    }

    /** Invoice ids for a search by invoice, container or trip number. */
    public function find(string $q): Collection
    {
        $q = trim($q);
        if ($q === '') {
            return collect();
        }

        $ids = Invoice::query()->where('invoice', 'like', "%{$q}%")->limit(200)->pluck('id')
            ->merge(BoxPhoto::search($q)->whereNotNull('invoice_id')->limit(500)->pluck('invoice_id'))
            ->merge(Invoice::query()->whereHas('container', fn ($c) => $c->where('container_no', 'like', "%{$q}%"))->limit(500)->pluck('id'))
            ->merge(Tripinvoice::query()->where(fn ($t) => $t
                ->whereIn('deliverylog_id', Deliverylog::where('trip_number', 'like', "%{$q}%")->select('id'))
                ->orWhereIn('deliveryloghub_id', Deliverylog::where('trip_number', 'like', "%{$q}%")->select('id')))->limit(500)->pluck('invoice_id'))
            ->merge(Whtripinvoice::query()->whereIn('whdeliverylog_id', Whdeliverylog::where('trip_number', 'like', "%{$q}%")->select('id'))->limit(500)->pluck('invoice_id'))
            ->filter()->unique()->values();

        return $this->allowed($ids);
    }

    /**
     * Part 45 (board 72): an exact box, trip or container number first; similar numbers only when nothing is exact.
     *
     * @return array{kind: string, ids: Collection}  kind: short | exact | trip | container | like
     */
    public function match(string $q): array
    {
        $q = trim($q);
        if (mb_strlen($q) < 3) {
            return ['kind' => 'short', 'ids' => collect()];
        }
        $exact = Invoice::query()->where('invoice', $q)->limit(20)->pluck('id');
        if ($exact->isNotEmpty()) {
            return ['kind' => 'exact', 'ids' => $this->allowed($exact)];
        }
        $trips = Deliverylog::where('trip_number', $q)->pluck('id');
        $whTrips = Whdeliverylog::where('trip_number', $q)->pluck('id');
        if ($trips->isNotEmpty() || $whTrips->isNotEmpty()) {
            $ids = Tripinvoice::query()->where(fn ($t) => $t->whereIn('deliverylog_id', $trips)->orWhereIn('deliveryloghub_id', $trips))->limit(1000)->pluck('invoice_id')
                ->merge(Whtripinvoice::query()->whereIn('whdeliverylog_id', $whTrips)->limit(1000)->pluck('invoice_id'))->filter()->unique()->values();

            return ['kind' => 'trip', 'ids' => $this->allowed($ids)];
        }
        $cont = Invoice::query()->whereHas('container', fn ($c) => $c->where('container_no', $q))->limit(1000)->pluck('id');
        if ($cont->isNotEmpty()) {
            return ['kind' => 'container', 'ids' => $this->allowed($cont)];
        }

        return ['kind' => 'like', 'ids' => $this->find($q)];
    }

    /** The boxes of these that this user may see. */
    public function allowed(Collection $ids): Collection
    {
        $hub = $this->hubLimit();
        if ($hub === -1) {
            return collect();
        }
        if ($hub === null) {
            return $ids->values();
        }

        return $ids->intersect(
            Tripinvoice::where('logistichub_id', $hub)->whereIn('invoice_id', $ids)->pluck('invoice_id')
                ->merge(BoxPhoto::where('logistichub_id', $hub)->whereIn('invoice_id', $ids)->pluck('invoice_id'))
        )->values();
    }

    /**
     * Boxes with their photos, newest box first. Boxes without any photo are left out.
     *
     * @return Collection<int, array{invoice: Invoice, items: Collection, journey: array, worst: ?string, delivered: ?array, attempts: Collection}>
     */
    public function boxes(Collection $invoiceIds): Collection
    {
        if ($invoiceIds->isEmpty()) {
            return collect();
        }

        $invoices = Invoice::whereKey($invoiceIds->take(500))->get()->keyBy('id');
        $scan = BoxPhoto::visibleTo($this->user)
            ->with('container:id,container_no', 'deliverylog:id,trip_number', 'whdeliverylog:id,trip_number', 'user:id,first_name,last_name', 'warehouse:id,name', 'logistichub:id,hub_name')
            ->whereIn('invoice_id', $invoices->keys())->orderBy('taken_at')->orderBy('id')->get()->groupBy('invoice_id');
        $trips = Tripinvoice::with('deliverer:id,first_name,last_name', 'deliverylog:id,trip_number', 'hubTrip:id,trip_number')
            ->whereIn('invoice_id', $invoices->keys())->where('is_delivered', true)->get()->groupBy('invoice_id');
        $attempts = DeliveryAttempt::with('user:id,first_name,last_name', 'deliverylog:id,trip_number')
            ->whereIn('invoice_id', $invoices->keys())->orderBy('created_at')->get()->groupBy('invoice_id');

        return $invoices->map(function (Invoice $box) use ($scan, $trips, $attempts) {
            $items = collect();
            foreach ($scan->get($box->id, collect()) as $p) {
                $items->push($this->scanItem($p));
            }

            $missCards = collect();
            foreach ($attempts->get($box->id, collect()) as $a) {
                $photos = collect($a->photos)->filter()->values();
                $cardItems = $photos->map(fn ($path, $n) => $this->publicItem('a:'.$a->id.':'.$n, $box, 'not_delivered', $path, $n + 1, $photos->count(), [
                    'ref' => 'Trip '.($a->deliverylog?->trip_number ?? '—').' · '.$a->reason->getLabel(),
                    'who' => $a->user?->full_name, 'at' => $a->created_at, 'note' => $a->note,
                ]))->filter();
                $items = $items->merge($cardItems);
                $missCards->push(['reason' => $a->reason->getLabel(), 'at' => $a->created_at, 'who' => $a->user?->full_name,
                    'trip' => $a->deliverylog?->trip_number, 'note' => $a->note, 'keys' => $cardItems->pluck('key')->all()]);
            }

            $delivered = null;
            if ($row = $trips->get($box->id)?->sortByDesc('delivered_at')->first()) {
                $photos = collect($row->delivery_picture)->filter()->values();
                $at = $row->delivered_at ? Carbon::parse($row->delivered_at) : $row->updated_at;
                $trip = $row->hubTrip?->trip_number ?? $row->deliverylog?->trip_number;
                // Part 44: signed on the phone (damaged, or no paper receipt)
                $sig = \Illuminate\Support\Facades\Schema::hasTable('delivery_signatures') ? \App\Models\DeliverySignature::where('tripinvoice_id', $row->id)->latest('id')->first() : null;
                $cardItems = $photos->map(fn ($path, $n) => $this->publicItem('d:'.$row->id.':'.$n, $box, 'delivered', $path, $n + 1, $photos->count(), [
                    'ref' => 'Trip '.($trip ?? '—').' · delivered to '.($sig?->recipient_name ?: ($box->receiver_name ?: 'receiver')),
                    'who' => $row->deliverer?->full_name, 'at' => $at, 'note' => null,
                ]))->filter()->map(function ($i) use ($sig) {
                    if (str_contains((string) $i['path'], '/receipt-')) {
                        $i['label'] = 'Signed receipt';
                    } elseif ($sig?->isDamaged()) {
                        $i['condition'] = 'damaged';
                        $i['note'] = $sig->damageText();
                    }

                    return $i;
                });
                $items = $items->merge($cardItems);
                $delivered = ['at' => $at, 'who' => $row->deliverer?->full_name, 'to' => $sig?->recipient_name ?: $box->receiver_name, 'trip' => $trip, 'keys' => $cardItems->pluck('key')->all(),
                    'signed' => $sig ? ['by' => $sig->recipient_name, 'rel' => $sig->relationship, 'damaged' => $sig->isDamaged(), 'damage' => $sig->damageText(),
                        'paper' => \App\Models\DeliverySignature::PAPER[$sig->paper_reason] ?? null, 'link' => $sig->link(), 'cant' => $sig->cant_sign, 'issue' => $sig->invoiceissue_id] : null];
            }

            if ($items->isEmpty()) {
                return null;
            }

            return [
                'invoice' => $box,
                'items' => $items->keyBy('key'),
                'journey' => $this->journey($items),
                'worst' => static::worst($items->pluck('condition')),
                'delivered' => $delivered,
                'attempts' => $missCards,
                'latest' => $items->max(fn ($i) => $i['at']?->timestamp ?? 0),
            ];
        })->filter()->sortByDesc('latest')->take(self::MAX_BOXES)->values();
    }

    /** All photos of one box, oldest first (for the invoice Photos window and Track a box). */
    public function forInvoice(?int $invoiceId): Collection
    {
        return $invoiceId ? ($this->boxes(collect([$invoiceId]))->first()['items'] ?? collect())->sortBy(fn ($i) => $i['at']?->timestamp ?? 0)->values() : collect();
    }

    /** Photos for the given keys, if this user may see them. */
    public function resolve(array $keys): Collection
    {
        $keys = collect($keys)->map(fn ($k) => (string) $k)->unique();
        $boxIds = collect();
        foreach ($keys as $key) {
            [$kind, $id] = array_pad(explode(':', $key), 2, null);
            $boxIds->push(match ($kind) {
                'p' => BoxPhoto::whereKey((int) $id)->value('invoice_id'),
                'd' => Tripinvoice::whereKey((int) $id)->value('invoice_id'),
                'a' => DeliveryAttempt::whereKey((int) $id)->value('invoice_id'),
                default => null,
            });
        }

        return $this->boxes($this->allowed($boxIds->filter()->unique()->values()))->flatMap(fn ($b) => $b['items']->values())
            ->filter(fn ($i) => $keys->contains($i['key']))->values();
    }

    protected function scanItem(BoxPhoto $p): array
    {
        return [
            'key' => 'p:'.$p->id, 'kind' => 'scan', 'step' => $p->step,
            'label' => BoxPhoto::SHORT[$p->step] ?? $p->step,
            'condition' => $p->condition, 'note' => $p->note,
            'ref' => $p->reference(), 'place' => $p->place(), 'who' => $p->user?->full_name, 'at' => $p->taken_at,
            'url' => $p->url(), 'download' => $p->downloadUrl(), 'name' => $p->fileName(),
            'disk' => 'box', 'path' => $p->path, 'size' => (int) $p->size,
            'invoice' => $p->invoice, 'photo' => $p,
        ];
    }

    protected function publicItem(string $key, Invoice $box, string $step, string $path, int $n, int $of, array $meta): ?array
    {
        $disk = Storage::disk('public');
        if (! $disk->exists($path)) {
            return null;
        }
        $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION)) ?: 'jpg';

        return [
            'key' => $key, 'kind' => $step, 'step' => $step,
            'label' => $step === 'delivered' ? 'Delivered' : 'Not delivered',
            'condition' => null, 'note' => $meta['note'], 'n' => $n, 'of' => $of,
            'ref' => $meta['ref'], 'place' => null, 'who' => $meta['who'], 'at' => $meta['at'],
            'url' => $disk->url($path), 'download' => $disk->url($path), 'name' => $box->invoice.'_'.$step.'_'.$n.'.'.$ext,
            'disk' => 'public', 'path' => $path, 'size' => (int) rescue(fn () => $disk->size($path), 0, false),
            'invoice' => $box->invoice, 'photo' => null,
        ];
    }

    /** Steps in the order they happened, each with its worst condition. */
    protected function journey(Collection $items): array
    {
        return $items->reject(fn ($i) => $i['label'] === 'Signed receipt')->sortBy(fn ($i) => $i['at']?->timestamp ?? 0)->groupBy('label')
            ->map(fn ($g, $label) => ['label' => $label, 'kind' => $g->first()['kind'], 'condition' => static::worst($g->pluck('condition')), 'at' => $g->first()['at']?->timestamp ?? 0])
            ->sortBy('at')->values()->all();
    }

    public static function worst(Collection $conditions): ?string
    {
        foreach (['damaged', 'wet', 'open', 'good'] as $c) {
            if ($conditions->contains($c)) {
                return $c;
            }
        }

        return null;
    }
}
