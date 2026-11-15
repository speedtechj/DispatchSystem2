<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\TruckReceiptScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Shipping\TruckReceive;
use Filament\Pages\Page;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Scan app · Receive truck: the partner hub (by truck) scans every box in when the truck from Manila arrives. */
class TruckReceiveStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    public ?array $setInfo = null;

    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a truck';
    }

    protected function hubId(): int
    {
        return (int) Auth::user()?->logistichub_id;
    }

    protected function selected(): ?Deliverylog
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);

        return $id && TruckReceive::rows($id, $this->hubId())->exists() ? Deliverylog::find($id) : null;
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $trip = $this->selected();
        $hub = $this->hubId();
        if (! $trip) {
            $this->scanResult('danger', 'Pick the truck that arrived first.');

            return;
        }
        $row = Tripinvoice::with('invdata.whSection')->where('deliverylog_id', $trip->id)->where('logistichub_id', $hub)->where('invoice', $code)->latest('id')->first();
        if (! $row) {
            $other = Tripinvoice::where('invoice', $code)->latest('id')->first();
            $sea = $other ? Shipments::forTrip((int) $other->deliverylog_id) : null;
            $box = $this->invoicesMatching($code)->first();
            if ($sea) {
                $this->scanResult('warning', "{$code} came on sea shipment {$sea->code}. Use Receive container.", $box);
            } elseif ($other && (int) $other->deliverylog_id !== $trip->id) {
                $this->route = ['kind' => 'wrong', 'code' => '!', 'name' => 'Not on this truck', 'color' => '#b07400', 'why' => 'It is on trip '.Deliverylog::whereKey($other->deliverylog_id)->value('trip_number').'. Keep it apart and tell the office.'];
                $this->scanResult('warning', "{$code} is not on this truck.", $box);
            } else {
                $this->scanResult('danger', "{$code} is not on trip {$trip->trip_number} for your hub.", $box);
            }

            return;
        }
        $prev = TruckReceiptScan::where('deliverylog_id', $trip->id)->where('invoice_id', $row->invoice_id)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', "{$code} was already received".($who ? " by {$who}" : '').($prev->created_at ? ' at '.Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

            return;
        }
        $wasLoaded = (bool) $row->is_loaded;
        TruckReceive::scan($trip->id, $hub, $row);
        $this->setInfo = $row->invdata ? TruckReceive::setAtHub($trip->id, $hub, $row->invdata) : null;
        if ($wrong = TruckReceive::checkWrongHub($hub, $row)) {
            $this->route = ['kind' => 'wrong', 'code' => '⛔', 'name' => 'Not ours: for '.($wrong->correctHub?->hub_name ?? 'another hub'), 'color' => '#c8372d', 'why' => 'Put it aside. It is on the Wrong hub & returns list.'];
            $this->scanResult('warning', "{$code} is for ".($wrong->correctHub?->hub_name ?? 'another hub').'. Received, and put on the Wrong hub & returns list.', $row->invdata);

            return;
        }
        $this->scanResult('success', "{$code} received at your hub.".($wasLoaded ? '' : ' It was not scanned onto the truck in Manila.'), $row->invdata);
    }

    public function progress(): array
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);
        if (! $id) {
            return ['loaded' => 0, 'total' => 0];
        }
        $c = TruckReceive::counts($id, $this->hubId());

        return ['loaded' => $c['got'], 'total' => $c['of']];
    }

    /** Done screen: received, missing, and Finish receiving. */
    public function receiveResult(): ?array
    {
        $trip = $this->selected();
        if (! $trip) {
            return null;
        }
        $c = TruckReceive::counts($trip->id, $this->hubId());
        $names = User::whereIn('id', $c['missing']->pluck('loaded_by')->filter())->pluck('first_name', 'id');

        return ['got' => $c['got'], 'of' => $c['of'], 'finished' => (bool) TruckReceive::receipt($trip->id, $this->hubId())?->finished_at,
            'missing' => $c['missing']->take(30)->map(fn ($r) => ['code' => $r->invoice,
                'sub' => 'Loaded in Manila'.($r->loaded_by && isset($names[$r->loaded_by]) ? ' by '.$names[$r->loaded_by] : '').($r->loaded_at ? ' at '.Carbon::parse($r->loaded_at)->format('M j g:i A') : '')])->all()];
    }

    public function finishReceiving(): ?int
    {
        $trip = $this->selected();

        return $trip ? TruckReceive::finish($trip, $this->hubId()) : null;
    }

    public function team(): array
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);
        if (! $id) {
            return [];
        }
        $counts = TruckReceiptScan::where('deliverylog_id', $id)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return 'hub_receive';
    }

    public function photoContext(): array
    {
        return ['deliverylog_id' => $this->data['deliverylog_id'] ?? null, 'logistichub_id' => $this->hubId()];
    }

    public function appChoices(): Collection
    {
        return TruckReceive::trips($this->hubId())->map(fn (Deliverylog $t) => [
            'id' => $t->id, 'name' => $t->trip_number.' from Manila', 'active' => true,
            'sub' => collect([$t->truck?->plate_no ? 'Truck '.$t->truck->plate_no : null, $t->delivery_date ? 'Date '.Carbon::parse($t->delivery_date)->format('M j') : null])->filter()->join(' · '),
        ])->values();
    }
}
