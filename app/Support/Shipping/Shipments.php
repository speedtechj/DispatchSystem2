<?php

namespace App\Support\Shipping;

use App\Models\Boxes\SetSplit;
use App\Models\Boxissue;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentScan;
use App\Models\Shipping\SeaShipmentStop;
use App\Models\Shipping\WrongHubBox;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Boxes\BoxSets;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Sea shipments: a normal trip to the port (to a partner hub), then the van and seal,
 * the port check, the ship, and receiving at the partner hub.
 */
class Shipments
{
    public const MODES = ['container' => 'Container (truck to port → container)', 'roro' => 'RoRo (our truck rides the ferry)', 'lcl' => 'LCL (a forwarder carries a few boxes)'];

    /** LCL (board 62): our truck hands the boxes to a forwarder; the partner hub picks them up there. */
    public const LCL = [
        'preparing' => ['Preparing', 'Preparing to ship to {hub}'],
        'sealed' => ['Loaded', 'Loaded for {hub}'],
        'to_port' => ['Truck to the forwarder', 'On the way to the forwarder'],
        'at_port' => ['Handed to the forwarder', 'With the forwarder{fwd}'],
        'sailed' => ['Shipped by the forwarder', 'On the way to {hub} by sea{eta}'],
        'arrived' => ['Ready to pick up', 'Ready to pick up at {pickup}'],
        'picked_up' => ['Picked up', 'On the way to {hub}'],
        'received' => ['Received', 'At {hub}'],
    ];

    /** How the forwarder charges. */
    public const CHARGES = ['cbm' => 'Per CBM', 'kg' => 'Per kilo', 'box' => 'Per box'];

    public const PORT_CHECKS = ['full' => 'Full scan at the port', 'count' => 'Count only + photo of the receipt', 'off' => 'Off (with a reason)'];

    /** status => [label for container, label for RoRo, what the receiver sees] */
    public const STATUSES = [
        'preparing' => ['Preparing', 'Preparing', 'Preparing to ship to {hub}'],
        'sealed' => ['Loaded & sealed', 'Loaded, truck door sealed', 'Loaded for {hub}'],
        'to_port' => ['Truck to port', 'Driving to port', 'On the way to the port'],
        'at_port' => ['At the port', null, 'At the port, waiting to sail'],
        'sailed' => ['Sailed', 'On the ferry', 'On the way to {hub} by sea{eta}'],
        'arrived' => ['Arrived port', 'Off the ferry', 'Arrived at {port}'],
        'picked_up' => ['Picked up', null, 'On the way to {hub}'],
        'received' => ['Received', 'Received', 'At {hub}'],
    ];

    public static function ready(): bool
    {
        return Schema::hasTable('sea_shipments');
    }

    /** The steps of this shipment, in order. */
    public static function steps(SeaShipment $s): array
    {
        if ($s->mode === 'lcl') {
            return collect(static::LCL)->map(fn ($v) => $v[0])->all();
        }
        $i = $s->mode === 'roro' ? 1 : 0;

        return collect(static::STATUSES)->map(fn ($v) => $v[$i])->filter()->all();
    }

    public static function label(SeaShipment $s, ?string $status = null): string
    {
        return static::steps($s)[$status ?? $s->status] ?? ucfirst((string) ($status ?? $s->status));
    }

    public static function next(SeaShipment $s): ?string
    {
        $keys = array_keys(static::steps($s));
        $i = array_search($s->status, $keys, true);

        return $i === false ? $keys[0] : ($keys[$i + 1] ?? null);
    }

    /** Which steps the partner hub presses (the office presses the others). */
    public static function hubStep(string $status): bool
    {
        return in_array($status, ['picked_up', 'received'], true);
    }

    /** What the receiver sees on tracking. */
    public static function trackText(SeaShipment $s, ?int $tripId = null): string
    {
        $stop = $tripId ? static::stopOf($s, $tripId) : null;
        $hubName = $stop?->hub?->hub_name ?? $s->hub?->hub_name ?? 'the hub';
        if ($stop?->received_at) {
            return 'At '.$hubName;
        }
        $t = $s->mode === 'lcl' ? (static::LCL[$s->status][1] ?? '') : (static::STATUSES[$s->status][2] ?? '');
        if ($s->mode === 'roro' && $stop?->arrived_at && ! $stop->received_at) {
            return 'Our truck is at '.$hubName;
        }
        $before = $stop ? static::stops($s)->filter(fn ($x) => $x->stop < $stop->stop && ! $x->received_at) : collect();
        if ($stop && $stop->stop > 1 && $before->isEmpty() && in_array($s->status, ['arrived', 'picked_up', 'sailed'], true)) {
            return 'On the way to '.$hubName;
        }

        return strtr($t, ['{hub}' => $hubName, '{port}' => $s->port_to ?: 'the port', '{pickup}' => $s->pick_up_at ?: ($s->forwarder ?: 'the forwarder'),
            '{fwd}' => $s->forwarder ? ' ('.$s->forwarder.')' : '',
            '{eta}' => $s->eta && $s->status === 'sailed' ? ' · arriving about '.$s->eta->format('M j') : '']);
    }

    /** "CEB-0007" */
    public static function newCode(Logistichub $hub): string
    {
        $prefix = strtoupper(preg_replace('/[^A-Za-z]/', '', (string) $hub->hub_code)) ?: 'SEA';
        $n = SeaShipment::where('code', 'like', $prefix.'-%')->count() + 1;
        do {
            $code = $prefix.'-'.str_pad((string) $n++, 4, '0', STR_PAD_LEFT);
        } while (SeaShipment::where('code', $code)->exists());

        return $code;
    }

    /** Open trips to a partner hub reached by sea that are not a shipment yet ($all: every partner hub). */
    public static function tripsFor(int|false|null $hub, bool $all = false): Collection
    {
        if ($hub === false) {
            return collect();
        }
        $sea = ! $all && Islands::ready() ? (Islands::seaHubIds() ?: [0]) : null;

        return Deliverylog::with('destination', 'truck:id,plate_no')->withCount('tripinvoices')
            ->where('is_active', true)
            ->whereHas('destination', fn ($q) => $q->where('is_company', true)->when($sea, fn ($q) => $q->whereIn('id', $sea)))
            ->whereNotIn('id', SeaShipment::select('deliverylog_id'))
            ->when(static::stopsReady(), fn ($q) => $q->whereNotIn('id', SeaShipmentStop::select('deliverylog_id')))
            ->when($hub !== null, fn ($q) => $q->where('logistichub_id', $hub))
            ->latest('id')->limit(50)->get();
    }

    /**
     * One container. With more trips (one per hub) the first trip's hub unloads first.
     *
     * @param  Deliverylog|array<int, Deliverylog>  $trips
     */
    public static function create(Deliverylog|array $trips, string $mode = 'container', ?string $portCheck = null): SeaShipment
    {
        $trips = array_values(is_array($trips) ? $trips : [$trips]);
        $trip = $trips[0];
        $hub = Logistichub::findOrFail($trip->assigned_to);

        return DB::transaction(function () use ($trips, $trip, $hub, $mode, $portCheck) {
            $s = SeaShipment::create([
            'code' => static::newCode($hub), 'deliverylog_id' => $trip->id, 'logistichub_id' => $hub->id,
            'mode' => array_key_exists($mode, static::MODES) ? $mode : 'container',
            'port_check' => $mode === 'roro' ? 'off' : ($mode === 'lcl' ? 'count' : ($portCheck && isset(static::PORT_CHECKS[$portCheck]) ? $portCheck : 'count')),
            'port_reason' => $mode === 'roro' ? 'RoRo: the truck drives onto the ferry' : null,
            'status' => 'preparing', 'status_log' => [['status' => 'preparing', 'at' => now()->toIso8601String(), 'by' => Auth::id()]],
            'port_to' => Islands::port($hub), 'created_by' => Auth::id(),
            ]);
            if (static::stopsReady()) {
                foreach ($trips as $i => $t) {
                    SeaShipmentStop::create(['sea_shipment_id' => $s->id, 'deliverylog_id' => $t->id, 'logistichub_id' => (int) $t->assigned_to, 'stop' => $i + 1]);
                    // board 62: the other trips go with the main truck
                    if ($i > 0) {
                        SeaTrucks::goWithMain($s, (int) $t->id);
                    }
                }
            }

            return $s;
        });
    }

    /** More trips in one container must go to the same port. Returns the ports when they differ. */
    public static function portClash(array $trips): array
    {
        $ports = collect($trips)->map(fn ($t) => ($h = Logistichub::find($t->assigned_to)) ? (Islands::port($h) ?: $h->hub_name) : null)->filter()->unique()->values()->all();

        return count($ports) > 1 ? $ports : [];
    }

    // ------------------------------------------------------------------ stops (one container, more hubs)

    public static function stopsReady(): bool
    {
        static $ready;

        return $ready ??= Schema::hasTable('sea_shipment_stops');
    }

    /** The hubs of the container in unloading order. A shipment from before stops has one: its trip. */
    public static function stops(SeaShipment $s): Collection
    {
        $stops = static::stopsReady() ? $s->stops()->with('hub:id,hub_name,hub_code', 'trip:id,trip_number,truck_id')->get() : collect();

        return $stops->isNotEmpty() ? $stops : collect([new SeaShipmentStop(['sea_shipment_id' => $s->id, 'deliverylog_id' => $s->deliverylog_id, 'logistichub_id' => $s->logistichub_id, 'stop' => 1,
            'received_at' => $s->status === 'received' ? now() : null])]);
    }

    /** @return list<int> */
    public static function tripIds(SeaShipment $s): array
    {
        return static::stops($s)->pluck('deliverylog_id')->map(fn ($id) => (int) $id)->all();
    }

    public static function stopOf(SeaShipment $s, int $tripId): ?SeaShipmentStop
    {
        return static::stops($s)->first(fn ($x) => (int) $x->deliverylog_id === $tripId);
    }

    /** The stop of this hub, if the container goes there. */
    public static function stopFor(SeaShipment $s, int $hubId): ?SeaShipmentStop
    {
        return static::stops($s)->first(fn ($x) => (int) $x->logistichub_id === $hubId);
    }

    /** The hub that unloads now: the first stop not received yet. */
    public static function currentStop(SeaShipment $s): ?SeaShipmentStop
    {
        return static::stops($s)->first(fn ($x) => ! $x->received_at);
    }

    /** The shipment a trip goes on (as its main trip or another stop). */
    public static function forTrip(?int $tripId): ?SeaShipment
    {
        if (! $tripId || ! static::ready()) {
            return null;
        }
        $id = static::stopsReady() ? SeaShipmentStop::where('deliverylog_id', $tripId)->value('sea_shipment_id') : null;

        return $id ? SeaShipment::find($id) : SeaShipment::where('deliverylog_id', $tripId)->first();
    }

    /** All trips that are part of a sea shipment (for lists that must leave them out). */
    public static function allTripIds(): \Illuminate\Database\Query\Builder|array
    {
        if (! static::ready()) {
            return [];
        }

        return static::stopsReady()
            ? DB::table('sea_shipment_stops')->select('deliverylog_id')->union(DB::table('sea_shipments')->select('deliverylog_id'))
            : DB::table('sea_shipments')->select('deliverylog_id');
    }

    /** Loading the container: the hub that unloads last goes deep inside, the first near the door. */
    public static function loadZone(int $tripId): ?array
    {
        $s = static::forTrip($tripId);
        $stops = $s ? static::stops($s) : collect();
        if ($stops->count() < 2) {
            return null;
        }
        $stop = $stops->first(fn ($x) => (int) $x->deliverylog_id === $tripId);
        $zone = $stop->stop === 1 ? 'back' : ($stop->stop === $stops->count() ? 'front' : 'middle');

        return ['zone' => $zone, 'stop' => $stop->stop, 'hub' => $stop->hub?->hub_name];
    }

    /** While preparing: use another trip. The code stays when the hub is the same. */
    public static function changeTrip(SeaShipment $s, Deliverylog $trip): bool
    {
        if ($s->status !== 'preparing' || SeaShipment::where('deliverylog_id', $trip->id)->where('id', '!=', $s->id)->exists()
            || (static::stopsReady() && SeaShipmentStop::where('deliverylog_id', $trip->id)->exists())) {
            return false;
        }
        $hub = Logistichub::findOrFail($trip->assigned_to);
        if (static::stopsReady()) {
            SeaShipmentStop::where('sea_shipment_id', $s->id)->where('deliverylog_id', $s->deliverylog_id)->update(['deliverylog_id' => $trip->id, 'logistichub_id' => $hub->id]);
        }
        $s->update(['deliverylog_id' => $trip->id, 'logistichub_id' => $hub->id,
            'code' => (int) $hub->id === (int) $s->logistichub_id ? $s->code : static::newCode($hub),
            'port_to' => (int) $hub->id === (int) $s->logistichub_id ? $s->port_to : Islands::port($hub)]);

        return true;
    }

    /** While preparing: take the shipment away. The trip and its boxes stay as they are. */
    public static function remove(SeaShipment $s): bool
    {
        if ($s->status !== 'preparing') {
            return false;
        }
        DB::transaction(function () use ($s) {
            SeaShipmentScan::where('sea_shipment_id', $s->id)->delete();
            if (static::stopsReady()) {
                SeaShipmentStop::where('sea_shipment_id', $s->id)->delete();
            }
            $s->delete();
        });

        return true;
    }

    /** While preparing: add another hub's trip to the container (unloads after the others). */
    public static function addStop(SeaShipment $s, Deliverylog $trip): bool
    {
        if ($s->status !== 'preparing' || ! static::stopsReady() || static::forTrip($trip->id) || static::portClash([$s->trip, $trip])) {
            return false;
        }
        $n = (int) static::stops($s)->max('stop');
        SeaShipmentStop::create(['sea_shipment_id' => $s->id, 'deliverylog_id' => $trip->id, 'logistichub_id' => (int) $trip->assigned_to, 'stop' => $n + 1]);
        SeaTrucks::goWithMain($s, (int) $trip->id); // board 62: it goes with the main truck

        return true;
    }

    /** While preparing: take another hub's trip out of the container (not the first one). */
    public static function removeStop(SeaShipment $s, int $tripId): bool
    {
        if ($s->status !== 'preparing' || $tripId === (int) $s->deliverylog_id || ! static::stopsReady()) {
            return false;
        }
        $gone = SeaShipmentStop::where('sea_shipment_id', $s->id)->where('deliverylog_id', $tripId)->first();
        if ($gone?->own_truck_id) {
            Deliverylog::whereKey($tripId)->update(['truck_id' => $gone->own_truck_id]); // its own truck back
        }
        $deleted = SeaShipmentStop::where('sea_shipment_id', $s->id)->where('deliverylog_id', $tripId)->delete();
        foreach (SeaShipmentStop::where('sea_shipment_id', $s->id)->orderBy('stop')->get()->values() as $i => $x) {
            $x->update(['stop' => $i + 1]);
        }

        return $deleted > 0;
    }

    /** Shipments a person may see. null hub = all (Admin). */
    public static function visible(int|false|null $hub): Builder
    {
        return SeaShipment::query()->with(['hub:id,hub_name,hub_code', 'trip:id,trip_number,logistichub_id,truck_id', 'trip.truck:id,plate_no'])
            ->when($hub === false, fn ($q) => $q->whereRaw('1 = 0'))
            ->when(is_int($hub), fn ($q) => $q->where(fn ($q) => $q->where('logistichub_id', $hub)
                ->orWhereIn('deliverylog_id', Deliverylog::where('logistichub_id', $hub)->select('id'))
                ->when(static::stopsReady(), fn ($q) => $q->orWhereIn('id', SeaShipmentStop::where('logistichub_id', $hub)->select('sea_shipment_id')))));
    }

    // ------------------------------------------------------------------ counts

    /** @return array{onTrip: int, loaded: int, port: ?int, received: int, missingPort: Collection, missingHub: Collection, perBox: ?float} */
    public static function counts(SeaShipment $s): array
    {
        $stops = static::stops($s);
        $rows = Tripinvoice::whereIn('deliverylog_id', $stops->pluck('deliverylog_id'))->get();
        $loaded = $rows->where('is_loaded', true);
        $scans = SeaShipmentScan::where('sea_shipment_id', $s->id)->get()->groupBy('step');
        $portIds = ($scans['port'] ?? collect())->pluck('invoice_id')->all();
        $recIds = ($scans['received'] ?? collect())->pluck('invoice_id')->all();
        $port = match ($s->port_check) { 'full' => count($portIds), 'count' => $s->port_count, default => null };
        // Missing at a hub: only the stops that finished receiving (one stop: as before).
        $doneTrips = $stops->count() > 1 ? $stops->filter(fn ($x) => $x->received_at)->pluck('deliverylog_id')->map(fn ($i) => (int) $i)->all() : null;
        $atHub = $doneTrips !== null ? $doneTrips !== [] : (in_array($s->status, ['arrived', 'picked_up', 'received'], true) || count($recIds) > 0);
        if ($doneTrips !== null) {
            $loaded2 = $loaded->filter(fn ($r) => in_array((int) $r->deliverylog_id, $doneTrips, true));
        }

        return [
            'onTrip' => $rows->count(), 'loaded' => $loaded->count(), 'port' => $port, 'received' => count($recIds),
            'missingPort' => $s->port_check === 'full' && count($portIds) > 0 ? $loaded->reject(fn ($r) => in_array($r->invoice_id, $portIds, true))->pluck('invoice')->values() : collect(),
            'missingHub' => $atHub ? ($loaded2 ?? $loaded)->reject(fn ($r) => in_array($r->invoice_id, $recIds, true))->pluck('invoice')->values() : collect(),
            'perBox' => $loaded->count() > 0 && $s->cost() > 0 ? round($s->cost() / $loaded->count(), 2) : null,
        ];
    }

    // ------------------------------------------------------------------ moving on

    /** The sea shipment of the driver's trip, waiting for the count at the port (Count only). */
    public static function forDriverPort(?\App\Models\Deliverylog $trip): ?SeaShipment
    {
        if (! $trip || ! static::ready()) {
            return null;
        }

        $s = static::forTrip($trip->id);

        return $s && $s->port_check === 'count' && in_array($s->status, ['preparing', 'sealed', 'to_port', 'at_port'], true) ? $s->loadMissing('hub:id,hub_name') : null;
    }

    /** The driver typed the count at the port (and took the receipt photo). */
    public static function driverPort(SeaShipment $s, int $count, ?string $receipt, ?float $lat, ?float $lng): void
    {
        $s->update(array_filter([
            'port_count' => $count, 'port_receipt' => $receipt ?? $s->port_receipt, 'port_by' => Auth::id(), 'port_at' => now(),
            'port_lat' => $lat, 'port_lng' => $lng,
        ], fn ($v) => $v !== null));
        // the truck is at the port: move the shipment along when it was on its way there
        if ($s->status === 'to_port' && ! static::blockers($s->fresh(), 'at_port')) {
            static::move($s->fresh(), 'at_port');
        }
    }

    /** What stops the shipment going to the next step (empty = can go). */
    public static function blockers(SeaShipment $s, ?string $to = null): array
    {
        $to ??= static::next($s);
        $out = [];
        $c = static::counts($s);
        if ($to === 'sealed') {
            if ($c['onTrip'] === 0) {
                $out[] = 'No boxes on trip '.$s->trip?->trip_number.' yet.';
            } elseif ($c['loaded'] < $c['onTrip']) {
                $out[] = ($c['onTrip'] - $c['loaded']).' boxes on the trip are not loaded (scanned) yet.';
            }
            $open = Deliverylog::whereIn('id', static::tripIds($s))->get()->flatMap(fn ($t) => BoxSets::openOnTrip($t))->filter(fn ($o) => collect($o['missing'])->contains(fn ($m) => ! $m['reason']));
            if ($open->isNotEmpty()) {
                $out[] = $open->count().' '.str('customer')->plural($open->count()).' missing boxes without a reason: '.$open->take(3)->pluck('name')->join(', ').'.';
            }
            if (! $s->seal_no && $s->mode !== 'lcl') {
                $out[] = 'Type the seal number.';
            }
        }
        if ($to === 'at_port' || ($to === 'sailed' && $s->mode === 'roro')) {
            $out = array_merge($out, match ($s->port_check) {
                'full' => $c['port'] ? [] : ['Scan the boxes at the port first (Scan app → Port check).'],
                'count' => $s->port_count !== null ? [] : ['Type how many boxes were handed over at the port.'],
                default => $s->port_reason ? [] : ['Say why the port check is off.'],
            });
        }
        if ($to === 'sailed' && $s->mode === 'lcl') {
            if (! $s->forwarder || ! $s->waybill_no) {
                $out[] = 'Type the forwarder and the waybill number.';
            }
        } elseif ($to === 'sailed' && (! $s->vessel || ! $s->eta)) {
            $out[] = 'Type the vessel and the arrival date (ETA).';
        }

        return $out;
    }

    public static function move(SeaShipment $s, string $to, ?User $by = null): bool
    {
        if ($to !== static::next($s) || static::blockers($s, $to)) {
            return false;
        }
        $log = (array) $s->status_log;
        $log[] = ['status' => $to, 'at' => now()->toIso8601String(), 'by' => ($by ?? Auth::user())?->id];
        $s->update(['status' => $to, 'status_log' => $log]);

        return true;
    }

    /** When a step was reached. */
    public static function when(SeaShipment $s, string $status): ?string
    {
        $e = collect((array) $s->status_log)->where('status', $status)->last();

        return $e ? \Illuminate\Support\Carbon::parse($e['at'])->format('M j · g:i A') : null;
    }

    // ------------------------------------------------------------------ boxes

    /** The open shipment a box is on (not received at the hub yet), if any. */
    public static function stillAtSea(Tripinvoice $row): ?SeaShipment
    {
        if (! static::ready() || ! $row->deliverylog_id) {
            return null;
        }
        $s = static::forTrip((int) $row->deliverylog_id);
        if (! $s || $s->status === 'received' || static::stopOf($s, (int) $row->deliverylog_id)?->received_at) {
            return null;
        }

        return SeaShipmentScan::where('sea_shipment_id', $s->id)->where('invoice_id', $row->invoice_id)->where('step', 'received')->exists() ? null : $s;
    }

    /** Scan a box at the port, or at the partner hub. */
    public static function scan(SeaShipment $s, Tripinvoice $row, string $step): bool
    {
        $created = SeaShipmentScan::firstOrCreate(['sea_shipment_id' => $s->id, 'invoice_id' => $row->invoice_id, 'step' => $step], ['user_id' => Auth::id(), 'created_at' => now()]);

        return $created->wasRecentlyCreated;
    }

    /** The section of this box is for another partner hub: put it on the Wrong hub list. */
    public static function checkWrongHub(SeaShipment $s, Tripinvoice $row): ?WrongHubBox
    {
        $section = $row->invdata?->whSection;
        $hubId = (int) (static::stopOf($s, (int) $row->deliverylog_id)?->logistichub_id ?? $s->logistichub_id);
        if (! $section?->logistichub_id || (int) $section->logistichub_id === $hubId) {
            return null;
        }

        return WrongHubBox::firstOrCreate(['invoice_id' => $row->invoice_id, 'logistichub_id' => $hubId, 'status' => 'waiting'], [
            'tripinvoice_id' => $row->id, 'correct_hub_id' => $section->logistichub_id, 'sea_shipment_id' => $s->id,
            'reason' => 'wrong_hub', 'created_by' => Auth::id(),
        ]);
    }

    /**
     * A partner hub finished receiving its part of the container: its missing boxes get an
     * Invoice Issue each. With more hubs the container is passed on to the next one; the
     * shipment is Received when the last hub finished. Returns how many issues were opened.
     */
    public static function finishReceiving(SeaShipment $s, ?User $by = null, ?int $hubId = null): int
    {
        $by ??= Auth::user();
        $stop = $hubId ? static::stopFor($s, $hubId) : static::currentStop($s);
        if (! $stop) {
            return 0;
        }
        $type = Boxissue::firstOrCreate(['issue_type' => 'Missing box']);
        $received = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', 'received')->pluck('invoice_id')->all();
        $missing = Tripinvoice::where('deliverylog_id', $stop->deliverylog_id)->where('is_loaded', true)->whereNotIn('invoice_id', $received)->get();
        $hubName = $stop->hub?->hub_name ?? $s->hub?->hub_name;
        $made = 0;
        DB::transaction(function () use ($s, $stop, $missing, $type, $by, $hubName, &$made) {
            foreach ($missing as $row) {
                $exists = Invoiceissue::where('invoice_id', $row->invoice_id)->where('boxissue_id', $type->id)->where('remarks', 'like', '%'.$s->code.'%')->exists();
                if (! $exists) {
                    Invoiceissue::create(['invoice' => $row->invoice, 'invoice_id' => $row->invoice_id, 'container_id' => Invoice::whereKey($row->invoice_id)->value('container_id'), 'boxissue_id' => $type->id,
                        'remarks' => "Not in sea shipment {$s->code} when {$hubName} received it.", 'user_id' => $by?->id]);
                    $made++;
                }
            }
            if ($stop->exists) {
                $stop->update(['received_at' => now(), 'received_by' => $by?->id, 'missing' => $missing->count()]);
            }
            $next = $stop->exists ? static::currentStop($s->fresh()) : null;
            $log = (array) $s->status_log;
            if ($next) {
                $log[] = ['status' => 'passed', 'at' => now()->toIso8601String(), 'by' => $by?->id, 'to' => $next->hub?->hub_name, 'from' => $hubName];
                $s->update(['status_log' => $log]);
            } elseif ($s->status !== 'received') {
                $log[] = ['status' => 'received', 'at' => now()->toIso8601String(), 'by' => $by?->id];
                $s->update(['status' => 'received', 'status_log' => $log]);
            }
        });

        return $made;
    }

    /** Set info for a box at the partner hub: "2 of 3 arrived · 1 still in Manila". */
    public static function setAtHub(SeaShipment $s, Invoice $invoice): ?array
    {
        $all = BoxSets::members($invoice);
        if ($all->count() < 2) {
            return null;
        }
        $rec = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', 'received')->whereIn('invoice_id', $all->pluck('id'))->pluck('invoice_id')->all();
        $onShip = Tripinvoice::whereIn('deliverylog_id', static::tripIds($s))->whereIn('invoice_id', $all->pluck('id'))->pluck('invoice_id')->all();
        $here = count($rec);
        $notShipped = $all->reject(fn ($b) => in_array($b->id, $onShip, true));
        $toScan = count($onShip) - $here;
        $reasons = SetSplit::whereIn('invoice_id', $notShipped->pluck('id'))->pluck('reason', 'invoice_id');
        $parts = [];
        if ($toScan > 0) {
            $parts[] = $toScan.' more in this container';
        }
        if ($notShipped->isNotEmpty()) {
            $parts[] = $notShipped->count().' still in Manila ('.$notShipped->map(fn ($b) => $b->invoice.(isset($reasons[$b->id]) ? ' · '.(SetSplit::REASONS[$reasons[$b->id]] ?? $reasons[$b->id]) : ''))->join(', ').'), it follows';
        }

        return ['n' => $here, 'of' => $all->count(), 'name' => \Illuminate\Support\Str::title((string) $invoice->receiver_name),
            'text' => $parts ? implode(' · ', $parts) : '✓ All '.$all->count().' boxes arrived', 'kind' => $notShipped->isNotEmpty() ? 'split' : ($toScan ? 'wait' : 'done')];
    }
}
