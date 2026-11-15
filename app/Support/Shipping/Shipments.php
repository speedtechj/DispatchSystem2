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
    public const MODES = ['container' => 'Container (truck to port → container)', 'roro' => 'RoRo (our truck rides the ferry)'];

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
    public static function trackText(SeaShipment $s): string
    {
        $t = static::STATUSES[$s->status][2] ?? '';

        return strtr($t, ['{hub}' => $s->hub?->hub_name ?? 'the hub', '{port}' => $s->port_to ?: 'the port',
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

    /** Open trips to a partner hub that are not a shipment yet. */
    public static function tripsFor(int|false|null $hub): Collection
    {
        if ($hub === false) {
            return collect();
        }

        return Deliverylog::with('destination:id,hub_name,is_company', 'truck:id,plate_no')
            ->where('is_active', true)
            ->whereHas('destination', fn ($q) => $q->where('is_company', true))
            ->whereNotIn('id', SeaShipment::select('deliverylog_id'))
            ->when($hub !== null, fn ($q) => $q->where('logistichub_id', $hub))
            ->latest('id')->limit(50)->get();
    }

    public static function create(Deliverylog $trip, string $mode = 'container', ?string $portCheck = null): SeaShipment
    {
        $hub = Logistichub::findOrFail($trip->assigned_to);

        return SeaShipment::create([
            'code' => static::newCode($hub), 'deliverylog_id' => $trip->id, 'logistichub_id' => $hub->id,
            'mode' => array_key_exists($mode, static::MODES) ? $mode : 'container',
            'port_check' => $mode === 'roro' ? 'off' : ($portCheck && isset(static::PORT_CHECKS[$portCheck]) ? $portCheck : 'count'),
            'port_reason' => $mode === 'roro' ? 'RoRo: the truck drives onto the ferry' : null,
            'status' => 'preparing', 'status_log' => [['status' => 'preparing', 'at' => now()->toIso8601String(), 'by' => Auth::id()]],
            'created_by' => Auth::id(),
        ]);
    }

    /** Shipments a person may see. null hub = all (Admin). */
    public static function visible(int|false|null $hub): Builder
    {
        return SeaShipment::query()->with(['hub:id,hub_name,hub_code', 'trip:id,trip_number,logistichub_id,truck_id', 'trip.truck:id,plate_no'])
            ->when($hub === false, fn ($q) => $q->whereRaw('1 = 0'))
            ->when(is_int($hub), fn ($q) => $q->where(fn ($q) => $q->where('logistichub_id', $hub)
                ->orWhereIn('deliverylog_id', Deliverylog::where('logistichub_id', $hub)->select('id'))));
    }

    // ------------------------------------------------------------------ counts

    /** @return array{onTrip: int, loaded: int, port: ?int, received: int, missingPort: Collection, missingHub: Collection, perBox: ?float} */
    public static function counts(SeaShipment $s): array
    {
        $rows = Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->get();
        $loaded = $rows->where('is_loaded', true);
        $scans = SeaShipmentScan::where('sea_shipment_id', $s->id)->get()->groupBy('step');
        $portIds = ($scans['port'] ?? collect())->pluck('invoice_id')->all();
        $recIds = ($scans['received'] ?? collect())->pluck('invoice_id')->all();
        $port = match ($s->port_check) { 'full' => count($portIds), 'count' => $s->port_count, default => null };
        $atHub = in_array($s->status, ['arrived', 'picked_up', 'received'], true) || count($recIds) > 0;

        return [
            'onTrip' => $rows->count(), 'loaded' => $loaded->count(), 'port' => $port, 'received' => count($recIds),
            'missingPort' => $s->port_check === 'full' && count($portIds) > 0 ? $loaded->reject(fn ($r) => in_array($r->invoice_id, $portIds, true))->pluck('invoice')->values() : collect(),
            'missingHub' => $atHub ? $loaded->reject(fn ($r) => in_array($r->invoice_id, $recIds, true))->pluck('invoice')->values() : collect(),
            'perBox' => $loaded->count() > 0 && $s->cost() > 0 ? round($s->cost() / $loaded->count(), 2) : null,
        ];
    }

    // ------------------------------------------------------------------ moving on

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
            $open = $s->trip ? collect(BoxSets::openOnTrip($s->trip))->filter(fn ($o) => collect($o['missing'])->contains(fn ($m) => ! $m['reason'])) : collect();
            if ($open->isNotEmpty()) {
                $out[] = $open->count().' '.str('customer')->plural($open->count()).' missing boxes without a reason: '.$open->take(3)->pluck('name')->join(', ').'.';
            }
            if (! $s->seal_no) {
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
        if ($to === 'sailed' && (! $s->vessel || ! $s->eta)) {
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
        $s = SeaShipment::where('deliverylog_id', $row->deliverylog_id)->first();
        if (! $s || $s->status === 'received') {
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
        if (! $section?->logistichub_id || (int) $section->logistichub_id === (int) $s->logistichub_id) {
            return null;
        }

        return WrongHubBox::firstOrCreate(['invoice_id' => $row->invoice_id, 'logistichub_id' => $s->logistichub_id, 'status' => 'waiting'], [
            'tripinvoice_id' => $row->id, 'correct_hub_id' => $section->logistichub_id, 'sea_shipment_id' => $s->id,
            'reason' => 'wrong_hub', 'created_by' => Auth::id(),
        ]);
    }

    /** Partner hub finished receiving: missing boxes get an Invoice Issue each. */
    public static function finishReceiving(SeaShipment $s, ?User $by = null): int
    {
        $c = static::counts($s);
        $type = Boxissue::firstOrCreate(['issue_type' => 'Missing box']);
        $made = 0;
        DB::transaction(function () use ($s, $c, $type, $by, &$made) {
            foreach (Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->whereIn('invoice', $c['missingHub'])->get() as $row) {
                $inv = Invoice::find($row->invoice_id);
                $exists = Invoiceissue::where('invoice_id', $row->invoice_id)->where('boxissue_id', $type->id)->where('remarks', 'like', '%'.$s->code.'%')->exists();
                if (! $exists) {
                    Invoiceissue::create(['invoice' => $row->invoice, 'invoice_id' => $row->invoice_id, 'container_id' => $inv?->container_id, 'boxissue_id' => $type->id,
                        'remarks' => "Not in sea shipment {$s->code} when {$s->hub?->hub_name} received it.", 'user_id' => ($by ?? Auth::user())?->id]);
                    $made++;
                }
            }
            if ($s->status !== 'received') {
                $log = (array) $s->status_log;
                $log[] = ['status' => 'received', 'at' => now()->toIso8601String(), 'by' => ($by ?? Auth::user())?->id];
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
        $onShip = Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->whereIn('invoice_id', $all->pluck('id'))->pluck('invoice_id')->all();
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
