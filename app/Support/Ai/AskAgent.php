<?php

namespace App\Support\Ai;

use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use App\Models\User;
use App\Support\Branding;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Str;

/**
 * "Ask the system": the AI answers staff questions by looking things up with a few read-only tools.
 * Partner hub users only ever get data for their own hub.
 */
class AskAgent
{
    public const MAX_STEPS = 6;

    protected ?int $hub;

    public function __construct(protected User $user)
    {
        $hub = AiScope::hubId($user);
        if ($hub === false) {
            throw new AiUnavailable('Your account can\'t use this.');
        }
        $this->hub = $hub;
    }

    /**
     * @param  list<array{role: string, text: string}>  $history  earlier turns (text only)
     */
    public function answer(string $question, array $history = []): string
    {
        $messages = [];
        foreach (array_slice($history, -8) as $turn) {
            $messages[] = ['role' => $turn['role'], 'content' => $turn['text']];
        }
        $messages[] = ['role' => 'user', 'content' => $question];

        $hubName = $this->hub ? Logistichub::find($this->hub)?->hub_name : null;
        $system = 'You help the staff of '.Branding::companyName().', a cargo company that ships balikbayan boxes from abroad in containers '
            .'to warehouses in the Philippines and delivers them by truck (trips), partly through partner hubs. '
            .'Answer only from the tool results. If you can\'t find something, say so plainly. Never make up numbers. '
            .'Keep answers short and plain (a few sentences, or a small list). Use simple English, or the language the question is in. '
            .'Today is '.now()->format('l, F j, Y').'. '
            .($hubName ? "The person asking works at the partner hub \"{$hubName}\"; the tools only show that hub's boxes." : '');

        for ($step = 0; $step < self::MAX_STEPS; $step++) {
            $data = Ai::call('ask', $system, $messages, 'smart', 1200, $this->tools());
            $messages[] = ['role' => 'assistant', 'content' => $data['content']];

            if (($data['stop_reason'] ?? '') !== 'tool_use') {
                return Ai::textOf($data) ?: 'I could not find an answer.';
            }

            $results = [];
            foreach ($data['content'] as $block) {
                if (($block['type'] ?? '') === 'tool_use') {
                    $results[] = [
                        'type' => 'tool_result',
                        'tool_use_id' => $block['id'],
                        'content' => json_encode($this->run($block['name'], (array) ($block['input'] ?? [])), JSON_UNESCAPED_UNICODE),
                    ];
                }
            }
            $messages[] = ['role' => 'user', 'content' => $results];
        }

        return 'That question needed too many look-ups. Try asking it in smaller parts.';
    }

    public function tools(): array
    {
        $date = ['type' => 'string', 'description' => 'Date as YYYY-MM-DD'];

        return [
            ['name' => 'find_boxes', 'description' => 'Find boxes by invoice/box number, receiver name, phone or sender name. Returns status and history of each.',
                'input_schema' => ['type' => 'object', 'properties' => ['query' => ['type' => 'string']], 'required' => ['query']]],
            ['name' => 'container_report', 'description' => 'A container by number: totals, delivered, on trucks, not delivered with reasons, per hub/area.',
                'input_schema' => ['type' => 'object', 'properties' => ['container_no' => ['type' => 'string'], 'city_or_hub' => ['type' => 'string', 'description' => 'optional filter, e.g. Cebu']], 'required' => ['container_no']]],
            ['name' => 'trip_report', 'description' => 'A delivery trip by trip number: truck, driver, dates, boxes loaded, delivered, failed with reasons.',
                'input_schema' => ['type' => 'object', 'properties' => ['trip_number' => ['type' => 'string']], 'required' => ['trip_number']]],
            ['name' => 'driver_report', 'description' => 'Per driver between two dates: boxes delivered and failed deliveries with the main reason.',
                'input_schema' => ['type' => 'object', 'properties' => ['from' => $date, 'to' => $date], 'required' => ['from', 'to']]],
            ['name' => 'totals', 'description' => 'Totals between two dates: containers unloaded, boxes in, delivered, failed attempts, boxes still out.',
                'input_schema' => ['type' => 'object', 'properties' => ['from' => $date, 'to' => $date], 'required' => ['from', 'to']]],
            ['name' => 'not_delivered', 'description' => 'Boxes not delivered yet (on trucks or tried and failed), optionally for one city or barangay.',
                'input_schema' => ['type' => 'object', 'properties' => ['place' => ['type' => 'string']], 'required' => []]],
        ];
    }

    public function run(string $tool, array $in): array
    {
        try {
            return match ($tool) {
                'find_boxes' => $this->findBoxes((string) ($in['query'] ?? '')),
                'container_report' => $this->containerReport((string) ($in['container_no'] ?? ''), (string) ($in['city_or_hub'] ?? '')),
                'trip_report' => $this->tripReport((string) ($in['trip_number'] ?? '')),
                'driver_report' => $this->driverReport($this->date($in['from'] ?? null, now()->startOfWeek()), $this->date($in['to'] ?? null, now())),
                'totals' => $this->totals($this->date($in['from'] ?? null, now()->startOfMonth()), $this->date($in['to'] ?? null, now())),
                'not_delivered' => $this->notDelivered((string) ($in['place'] ?? '')),
                default => ['error' => 'Unknown tool'],
            };
        } catch (\Throwable $e) {
            report($e);

            return ['error' => 'Look-up failed'];
        }
    }

    protected function date(?string $v, Carbon $default): Carbon
    {
        try {
            return $v ? Carbon::parse($v) : $default;
        } catch (\Throwable) {
            return $default;
        }
    }

    /** Invoices this person may see. */
    protected function invoices(): Builder
    {
        $q = Invoice::query();
        if ($this->hub) {
            $q->whereIn('id', Tripinvoice::where('logistichub_id', $this->hub)->select('invoice_id'));
        }

        return $q;
    }

    protected function tripinvoices(): Builder
    {
        $q = Tripinvoice::query();

        return $this->hub ? $q->where('logistichub_id', $this->hub) : $q;
    }

    public function findBoxes(string $query): array
    {
        $query = trim($query);
        if (mb_strlen($query) < 2) {
            return ['boxes' => []];
        }
        $digits = preg_replace('/\D+/', '', $query);
        $found = $this->invoices()->with('container:id,container_no,unloaded_at')
            ->where(fn (Builder $q) => $q->where('invoice', $query)
                ->orWhere('invoice', 'like', "%{$query}%")
                ->orWhere('receiver_name', 'like', "%{$query}%")
                ->orWhere('sender_name', 'like', "%{$query}%")
                ->when(strlen($digits) >= 7, fn ($q) => $q->orWhere('receiver_mobile_no', 'like', '%'.substr($digits, -9).'%')))
            ->limit(10)->get();

        return ['count' => $found->count(), 'boxes' => $found->map(fn (Invoice $i) => $this->boxStatus($i))->all()];
    }

    public function boxStatus(Invoice $i): array
    {
        return static::statusOf($i);
    }

    public static function statusOf(Invoice $i): array
    {
        $trips = Tripinvoice::where('invoice_id', $i->id)->with(['deliverylog.truck', 'deliverylog.logistichub', 'logistichub'])->orderBy('id')->get();
        $attempts = DeliveryAttempt::where('invoice_id', $i->id)->orderBy('created_at')->get();
        $last = $trips->last();
        $status = match (true) {
            (bool) $i->is_delivered => 'delivered',
            $last && $last->is_loaded => 'on a truck (trip '.$last->deliverylog?->trip_number.')',
            $last !== null => 'assigned to trip '.$last->deliverylog?->trip_number.' (not loaded yet)',
            $i->container?->unloaded_at !== null => 'in the warehouse',
            default => 'in the container (not unloaded yet)',
        };

        return [
            'box' => $i->invoice,
            'receiver' => Str::title((string) $i->receiver_name),
            'address' => Str::title(trim($i->receiver_address.', '.$i->receiver_barangay.', '.$i->receiver_city, ', ')),
            'sender' => Str::title((string) $i->sender_name),
            'container' => $i->container?->container_no,
            'unloaded' => $i->container?->unloaded_at ? Carbon::parse($i->container->unloaded_at)->format('M j, Y') : null,
            'status' => $status,
            'delivered_at' => $last?->delivered_at?->format('M j, Y g:i A'),
            'trips' => $trips->map(fn ($t) => [
                'trip' => $t->deliverylog?->trip_number, 'truck' => $t->deliverylog?->truck?->plate_no,
                'hub' => $t->logistichub?->hub_name, 'loaded' => (bool) $t->is_loaded, 'delivered' => (bool) $t->is_delivered,
            ])->all(),
            'failed_attempts' => $attempts->map(fn ($a) => ['when' => $a->created_at->format('M j g:i A'), 'reason' => $a->reason?->getLabel(), 'note' => $a->note])->all(),
        ];
    }

    public function containerReport(string $no, string $filter = ''): array
    {
        $no = preg_replace('/\s+/', '', $no);
        $c = Container::whereRaw("REPLACE(container_no, ' ', '') like ?", ['%'.$no.'%'])->first();
        if (! $c) {
            return ['error' => "No container like {$no}"];
        }
        $boxes = $this->invoices()->where('container_id', $c->id)
            ->when($filter !== '', fn ($q) => $q->where(fn ($w) => $w->where('receiver_city', 'like', "%{$filter}%")->orWhere('receiver_province', 'like', "%{$filter}%")
                ->orWhereIn('id', Tripinvoice::whereHas('logistichub', fn ($h) => $h->where('hub_name', 'like', "%{$filter}%"))->select('invoice_id'))))
            ->get(['id', 'invoice', 'is_delivered', 'receiver_city']);
        $ids = $boxes->pluck('id');
        $onTruck = Tripinvoice::whereIn('invoice_id', $ids)->where('is_loaded', true)->where('is_delivered', false)->distinct()->count('invoice_id');
        $failed = DeliveryAttempt::whereIn('invoice_id', $ids)->whereIn('invoice_id', $boxes->where('is_delivered', false)->pluck('id'))->get()
            ->groupBy(fn ($a) => $a->reason?->getLabel() ?? 'Other')->map->count();

        return [
            'container' => $c->container_no, 'consolidator' => $c->consolidator?->company_name,
            'unloaded' => $c->unloaded_at ? Carbon::parse($c->unloaded_at)->format('M j, Y') : 'not yet',
            'filter' => $filter ?: null,
            'boxes' => $boxes->count(), 'delivered' => $boxes->where('is_delivered', true)->count(),
            'not_delivered' => $boxes->where('is_delivered', false)->count(), 'on_trucks_now' => $onTruck,
            'failed_attempt_reasons_for_undelivered' => $failed,
            'not_delivered_by_city' => $boxes->where('is_delivered', false)->groupBy(fn ($b) => Str::title((string) $b->receiver_city))->map->count(),
            'not_delivered_boxes' => $boxes->where('is_delivered', false)->pluck('invoice')->take(40)->values(),
        ];
    }

    public function tripReport(string $no): array
    {
        $trip = Deliverylog::with(['truck', 'logistichub'])->where('trip_number', trim($no))
            ->when($this->hub, fn ($q) => $q->where('logistichub_id', $this->hub))->latest('id')->first();
        if (! $trip) {
            return ['error' => "No trip {$no}"];
        }
        $boxes = Tripinvoice::where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id)->get();
        $drivers = Truckcrew::where('truck_id', $trip->truck_id)->with('user')->get()->map(fn ($c) => $c->user?->full_name)->filter()->values();
        $failed = DeliveryAttempt::whereIn('tripinvoice_id', $boxes->pluck('id'))->get()->groupBy(fn ($a) => $a->reason?->getLabel() ?? 'Other')->map->count();

        return [
            'trip' => $trip->trip_number, 'active' => (bool) $trip->is_active, 'hub' => $trip->logistichub?->hub_name,
            'truck' => $trip->truck?->plate_no, 'crew' => $drivers,
            'departure' => $trip->departure_date ? Carbon::parse($trip->departure_date)->format('M j, Y') : null,
            'boxes' => $boxes->count(), 'loaded' => $boxes->where('is_loaded', true)->count(),
            'delivered' => $boxes->where('is_delivered', true)->count(),
            'left_to_deliver' => $boxes->where('is_delivered', false)->count(),
            'failed_attempts_by_reason' => $failed,
        ];
    }

    public function driverReport(Carbon $from, Carbon $to): array
    {
        $to = $to->copy()->endOfDay();
        $delivered = $this->tripinvoices()->where('is_delivered', true)->whereBetween('delivered_at', [$from, $to])
            ->whereNotNull('delivered_by')->selectRaw('delivered_by as u, count(*) as n')->groupBy('delivered_by')->pluck('n', 'u');
        $failed = DeliveryAttempt::whereBetween('created_at', [$from, $to])
            ->when($this->hub, fn ($q) => $q->whereIn('tripinvoice_id', Tripinvoice::where('logistichub_id', $this->hub)->select('id')))
            ->get()->groupBy('user_id');
        $ids = $delivered->keys()->merge($failed->keys())->unique();

        return ['from' => $from->toDateString(), 'to' => $to->toDateString(), 'drivers' => User::whereIn('id', $ids)->get()->map(fn ($u) => [
            'driver' => $u->full_name,
            'delivered' => (int) ($delivered[$u->id] ?? 0),
            'failed' => ($failed[$u->id] ?? collect())->count(),
            'main_failure_reason' => ($failed[$u->id] ?? collect())->groupBy(fn ($a) => $a->reason?->getLabel() ?? 'Other')->sortByDesc->count()->keys()->first(),
        ])->sortByDesc('delivered')->values()->all()];
    }

    public function totals(Carbon $from, Carbon $to): array
    {
        $to = $to->copy()->endOfDay();
        $containers = Container::whereBetween('unloaded_at', [$from, $to]);

        return [
            'from' => $from->toDateString(), 'to' => $to->toDateString(),
            'containers_unloaded' => $this->hub ? null : (clone $containers)->count(),
            'boxes_in_those_containers' => $this->invoices()->whereIn('container_id', (clone $containers)->select('id'))->count(),
            'boxes_delivered' => $this->tripinvoices()->where('is_delivered', true)->whereBetween('delivered_at', [$from, $to])->count(),
            'failed_attempts' => DeliveryAttempt::whereBetween('created_at', [$from, $to])
                ->when($this->hub, fn ($q) => $q->whereIn('tripinvoice_id', Tripinvoice::where('logistichub_id', $this->hub)->select('id')))->count(),
            'boxes_on_trucks_now' => $this->tripinvoices()->where('is_loaded', true)->where('is_delivered', false)->count(),
        ];
    }

    public function notDelivered(string $place = ''): array
    {
        $q = $this->tripinvoices()->where('is_delivered', false)->whereHas('deliverylog', fn ($d) => $d->where('is_active', true))->with(['invdata', 'deliverylog'])
            ->when($place !== '', fn ($q) => $q->whereHas('invdata', fn ($i) => $i->where('receiver_city', 'like', "%{$place}%")->orWhere('receiver_barangay', 'like', "%{$place}%")));
        $rows = $q->withCount('deliveryAttempts')->limit(300)->get();

        return [
            'count' => $rows->count(),
            'tried_and_failed' => $rows->where('delivery_attempts_count', '>', 0)->count(),
            'by_trip' => $rows->groupBy(fn ($r) => $r->deliverylog?->trip_number)->map->count(),
            'by_city' => $rows->groupBy(fn ($r) => Str::title((string) $r->invdata?->receiver_city))->map->count(),
            'boxes' => $rows->take(30)->map(fn ($r) => $r->invoice.' · '.Str::title((string) $r->invdata?->receiver_name).' · '.Str::title((string) $r->invdata?->receiver_barangay))->values(),
        ];
    }
}
