<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\PlacesOnHubTrips;
use App\Filament\Concerns\ScansInvoices;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Pages\Page;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station for a sea shipment, used by the Scan app: Port check (the boxes handed over at
 * the port) or Receive (the partner hub scans the container in).
 */
abstract class ShipmentScanStation extends Page
{
    use PlacesOnHubTrips;
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    /** port or received */
    protected static string $step = 'port';

    /** The box's set at the hub: "2 of 3 arrived · 1 still in Manila". */
    public ?array $setInfo = null;

    /** The box is for another hub (added to the Wrong hub list). */
    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'sea_shipment_id';
    }

    protected function selectionLabel(): string
    {
        return 'a shipment';
    }

    /** Shipments open for this scan. */
    abstract protected function shipments(): Builder;

    protected function selected(): ?SeaShipment
    {
        return $this->shipments()->find($this->data['sea_shipment_id'] ?? null);
    }

    /** Receive: the trips of this hub's stop. Port check: every trip in the container. */
    protected function myTripIds(SeaShipment $s): array
    {
        if (static::$step !== 'received') {
            return Shipments::tripIds($s);
        }
        $stop = Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s);

        return $stop ? [(int) $stop->deliverylog_id] : [];
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $this->hubTrip = null;
        $s = $this->selected();
        if (! $s) {
            $this->scanResult('danger', 'That shipment is not open for this scan any more.');

            return;
        }
        $row = Tripinvoice::with('invdata.whSection')->whereIn('deliverylog_id', $this->myTripIds($s))->where('invoice', $code)->latest('id')->first();
        if (! $row) {
            $other = $this->invoicesMatching($code)->first();
            // One container, more hubs: the box is for another stop.
            $theirs = Tripinvoice::whereIn('deliverylog_id', Shipments::tripIds($s))->where('invoice', $code)->latest('id')->first();
            $stop = $theirs ? Shipments::stopOf($s, (int) $theirs->deliverylog_id) : null;
            if ($stop && $stop->received_at) {
                $this->scanResult('warning', "{$code} was already received at ".($stop->hub?->hub_name ?? 'the hub before').'. Not counted again.', $other);
            } elseif ($stop) {
                $this->route = ['kind' => 'wrong', 'code' => '→', 'name' => 'For '.($stop->hub?->hub_name ?? 'the next hub').': leave it in the container', 'color' => '#7a4fb0', 'why' => 'Stop '.$stop->stop.'. Not counted, not missing.'];
                $this->scanResult('warning', "{$code} is for ".($stop->hub?->hub_name ?? 'the next hub').': leave it in the container.', $other);
            } else {
                $this->scanResult('danger', "{$code} is not in shipment {$s->code}.", $other);
            }

            return;
        }
        if (static::$step === 'port' && ! $row->is_loaded) {
            $this->scanResult('warning', "{$code} was never scanned onto trip {$s->trip?->trip_number} at the warehouse. Check where it came from.", $row->invdata);

            return;
        }
        $prev = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('invoice_id', $row->invoice_id)->where('step', static::$step)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', "{$code} was already scanned".($who ? " by {$who}" : '').($prev->created_at ? ' at '.Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

            return;
        }
        Shipments::scan($s, $row, static::$step);

        if (static::$step === 'received') {
            $this->setInfo = $row->invdata ? Shipments::setAtHub($s, $row->invdata) : null;
            if ($wrong = Shipments::checkWrongHub($s, $row)) {
                $this->route = ['kind' => 'wrong', 'code' => '⛔', 'name' => 'Not ours: for '.($wrong->correctHub?->hub_name ?? 'another hub'), 'color' => '#c8372d', 'why' => 'Put it aside. It is on the Wrong hub & returns list.'];
                $this->scanResult('warning', "{$code} is for ".($wrong->correctHub?->hub_name ?? 'another hub').'. Received, and put on the Wrong hub & returns list.', $row->invdata);

                return;
            }
        }
        // received at the partner hub: the box goes on the hub's trip of its city (board 45d)
        $placed = static::$step === 'received' ? $this->placeOnHubTrip($row) : null;
        $this->scanResult('success', "{$code} ".(static::$step === 'port' ? 'handed over at the port.' : 'received.').($placed ? ' → '.$placed['trip'] : ''), $row->invdata);
    }

    public function progress(): array
    {
        $s = $this->selected();
        if (! $s) {
            return ['loaded' => 0, 'total' => 0];
        }

        return [
            'loaded' => SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', static::$step)
                ->whereIn('invoice_id', Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->select('invoice_id'))->count(),
            'total' => Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->where('is_loaded', true)->count(),
        ];
    }

    public function team(): array
    {
        $id = $this->data['sea_shipment_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = SeaShipmentScan::where('sea_shipment_id', $id)->where('step', static::$step)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    /** Receive container asks for the photo of the box at the partner hub (Box photo settings: Receiving at a partner hub). */
    public function photoStep(): ?string
    {
        return static::$step === 'received' ? 'hub_receive' : null;
    }

    public function photoContext(): array
    {
        $s = $this->selected();
        $stop = $s ? (Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s)) : null;

        return ['deliverylog_id' => $stop?->deliverylog_id ?? $s?->deliverylog_id, 'logistichub_id' => $stop?->logistichub_id ?? $s?->logistichub_id];
    }

    /** Receive container, Done screen: received, missing, and Finish receiving. */
    public function receiveResult(): ?array
    {
        $s = static::$step === 'received' ? $this->selected() : null;
        if (! $s) {
            return null;
        }
        $p = $this->progress();
        $missing = Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->where('is_loaded', true)
            ->whereNotIn('invoice_id', SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', 'received')->select('invoice_id'))->limit(30)->pluck('invoice');
        $stop = Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s);
        $next = Shipments::stops($s)->first(fn ($x) => $stop && $x->stop > $stop->stop && ! $x->received_at);

        return ['got' => $p['loaded'], 'of' => $p['total'], 'finished' => $s->status === 'received' || (bool) $stop?->received_at,
            'next' => $next?->hub?->hub_name,
            'missing' => $missing->map(fn ($code) => ['code' => $code, 'sub' => 'Not scanned off the container'])->all()];
    }

    public function finishReceiving(): ?int
    {
        $s = static::$step === 'received' ? $this->selected() : null;

        return $s ? Shipments::finishReceiving($s, null, Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ? (int) Auth::user()?->logistichub_id : null) : null;
    }

    public function appChoices(): Collection
    {
        return $this->shipments()->latest('id')->limit(40)->get()->map(fn (SeaShipment $s) => [
            'id' => $s->id, 'name' => $s->code.' → '.($s->hub?->hub_name ?? ''), 'active' => true,
            'sub' => collect([$s->van_no ? 'Van '.$s->van_no : null, Shipments::label($s), $s->eta ? 'ETA '.$s->eta->format('M j') : null])->filter()->join(' · '),
        ]);
    }

    protected function hub(string $panel): int|false|null
    {
        return Tracker::hubFor(Auth::user(), $panel);
    }
}
