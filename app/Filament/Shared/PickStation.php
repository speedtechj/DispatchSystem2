<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\User;
use App\Support\Trips\Picking;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/** Scan app · Pick boxes: take each box of the trip from its section before Load truck (board 49). */
class PickStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    /** The last result for the phone: title, why, tone, undo row. */
    public ?array $pick = null;

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a trip';
    }

    public function trip(): ?Deliverylog
    {
        return Deliverylog::with('truck:id,plate_no', 'destination:id,hub_name')->where('logistichub_id', Auth::user()?->logistichub_id)
            ->find((int) ($this->data['deliverylog_id'] ?? 0));
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->trip();
        $u = Auth::user();
        if (! $trip || ! $u instanceof User || ! Picking::isPicker($trip, $u)) {
            $this->pick = ['title' => 'This trip is not yours', 'why' => 'Take the trip first, or ask the office to add you.', 'tone' => 'bad', 'undo' => null, 'code' => $code];
            $this->scanResult('danger', $this->pick['title'], notify: false);

            return;
        }
        $r = Picking::scan($trip, $u, $code, $this->pinInvoice);
        if ($r['status'] === 'which') {
            $this->pick = null;
            $this->askWhich($code, $r['boxes']);

            return;
        }
        $this->pick = ['title' => $r['title'], 'why' => $r['why'], 'tone' => $r['tone'], 'undo' => $r['undo'], 'code' => $code,
            'section' => $r['invoice']?->whSection?->code, 'spot' => $r['invoice']?->whSpot?->code];
        $this->scanResult($r['status'], $r['title'].' · '.$r['why'], $r['invoice'], notify: false);
    }

    public function progress(): array
    {
        $trip = $this->trip();
        if (! $trip) {
            return ['loaded' => 0, 'total' => 0];
        }
        $p = Picking::progress($trip);

        return ['loaded' => $p['picked'], 'total' => $p['total']];
    }

    /** My trips and trips with no picker yet, of my warehouse or hub. */
    public function appChoices(): Collection
    {
        $u = Auth::user();
        $hub = (int) $u?->logistichub_id;
        if (! $hub || ! Picking::ready()) {
            return collect();
        }
        $trips = Picking::trips($hub);
        $pickers = DB::table('trip_pickers')->whereIn('deliverylog_id', $trips->pluck('id'))->get()->groupBy('deliverylog_id');

        return $trips->map(function (Deliverylog $t) use ($pickers, $u) {
            $ps = collect($pickers[$t->id] ?? []);
            $mine = $ps->contains('user_id', $u->id);
            if (! $mine && $ps->isNotEmpty()) {
                return null;
            }

            return ['id' => $t->id, 'name' => $t->trip_number, 'active' => true, 'mine' => $mine,
                'sub' => collect([$t->destination?->hub_name ? 'To '.$t->destination->hub_name : null, $t->truck?->plate_no, $mine && $ps->count() > 1 ? 'with '.User::whereIn('id', $ps->pluck('user_id')->reject(fn ($i) => (int) $i === $u->id))->pluck('first_name')->join(', ') : null])->filter()->join(' · ')];
        })->filter()->values();
    }

    /** Who picked what on this trip (the chips on the phone). */
    public function team(): array
    {
        $trip = $this->trip();
        if (! $trip) {
            return [];
        }
        $counts = Picking::rows($trip)->whereNotNull('picked_by')->selectRaw('picked_by, count(*) n')->groupBy('picked_by')->pluck('n', 'picked_by');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function groups(): array
    {
        $trip = $this->trip();

        return $trip ? Picking::groups($trip) : [];
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
}
