<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station for a sea shipment, used by the Scan app: Port check (the boxes handed over at
 * the port) or Receive (the partner hub scans the container in).
 */
abstract class ShipmentScanStation extends Page
{
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
    abstract protected function shipments(): \Illuminate\Database\Eloquent\Builder;

    protected function selected(): ?SeaShipment
    {
        return $this->shipments()->find($this->data['sea_shipment_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $s = $this->selected();
        if (! $s) {
            $this->scanResult('danger', 'That shipment is not open for this scan any more.');

            return;
        }
        $row = Tripinvoice::with('invdata.whSection')->where('deliverylog_id', $s->deliverylog_id)->where('invoice', $code)->latest('id')->first();
        if (! $row) {
            $other = $this->invoicesMatching($code)->first();
            $this->scanResult('danger', "{$code} is not in shipment {$s->code}.", $other);

            return;
        }
        if (static::$step === 'port' && ! $row->is_loaded) {
            $this->scanResult('warning', "{$code} was never scanned onto trip {$s->trip?->trip_number} at the warehouse. Check where it came from.", $row->invdata);

            return;
        }
        $prev = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('invoice_id', $row->invoice_id)->where('step', static::$step)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', "{$code} was already scanned".($who ? " by {$who}" : '').($prev->created_at ? ' at '.\Illuminate\Support\Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

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
        $this->scanResult('success', "{$code} ".(static::$step === 'port' ? 'handed over at the port.' : 'received.'), $row->invdata);
    }

    public function progress(): array
    {
        $s = $this->selected();
        if (! $s) {
            return ['loaded' => 0, 'total' => 0];
        }

        return [
            'loaded' => SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', static::$step)->count(),
            'total' => Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->where('is_loaded', true)->count(),
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

    public function photoStep(): ?string
    {
        return null;
    }

    public function photoContext(): array
    {
        return [];
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
