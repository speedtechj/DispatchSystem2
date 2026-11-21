<?php

namespace App\Filament\Shared\Trips;

use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Tracking\Tracker;
use App\Support\Trips\Picking;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

/**
 * Picking (board 49): give each trip its pickers (✦ suggested: on shift, free, the truck's crew first,
 * about 1 for 40 boxes), see who picks what live, undo a pick, and the boxes not found.
 */
class PickingPage extends Page
{
    protected string $view = 'filament.trips.picking';

    protected static ?string $slug = 'picking';

    protected static ?string $title = 'Picking';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-archive-box-arrow-down';

    /** The trip whose + list is open. */
    public ?int $addFor = null;

    public static function canAccess(): bool
    {
        return Picking::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    protected function hub(): ?int
    {
        $h = Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());

        return $h === false ? -1 : ($h ?? (Auth::user()?->logistichub_id ? (int) Auth::user()->logistichub_id : null));
    }

    protected function trip(int $id): ?Deliverylog
    {
        $hub = $this->hub();

        return Picking::trips($hub)->firstWhere('id', $id);
    }

    public function openAdd(?int $tripId): void
    {
        $this->addFor = $this->addFor === $tripId ? null : $tripId;
    }

    public function add(int $tripId, int $userId): void
    {
        if ($trip = $this->trip($tripId)) {
            Picking::assign($trip, [$userId], Auth::user());
        }
        $this->addFor = null;
    }

    public function remove(int $tripId, int $userId): void
    {
        if ($trip = $this->trip($tripId)) {
            Picking::unassign($trip, $userId);
        }
    }

    public function useSuggestion(int $tripId): void
    {
        if (! $trip = $this->trip($tripId)) {
            return;
        }
        $s = Picking::suggest($trip);
        Picking::assign($trip, $s['ids'], Auth::user(), 'suggested');
        Notification::make()->title($trip->trip_number.': '.implode(' and ', $s['names']).' will pick it')->success()->send();
    }

    /** Office undo of a pick. */
    public function undo(int $rowId): void
    {
        $row = Tripinvoice::find($rowId);
        $trip = $row ? $this->trip((int) ($row->deliveryloghub_id ?: $row->deliverylog_id)) : null;
        if ($trip && Picking::undo($trip, $rowId, Auth::user())) {
            Notification::make()->title($row->invoice.' is back on the pick list')->success()->send();
        }
    }

    /** A box marked not found turned up: back on the list. */
    public function found(int $rowId): void
    {
        $row = Tripinvoice::find($rowId);
        $trip = $row ? $this->trip((int) ($row->deliveryloghub_id ?: $row->deliverylog_id)) : null;
        if ($trip && $row->missing_at) {
            $row->forceFill(['missing_at' => null, 'missing_by' => null])->save();
            Picking::log($trip, Auth::user(), $row->invoice, 'found', 'found again');
        }
    }

    protected function getViewData(): array
    {
        $trips = Picking::trips($this->hub());
        $pickers = DB::table('trip_pickers')->whereIn('deliverylog_id', $trips->pluck('id'))->get()->groupBy('deliverylog_id');
        $names = User::whereIn('id', $pickers->flatten()->pluck('user_id')->unique())->pluck('first_name', 'id');
        $busy = DB::table('trip_pickers')->join('deliverylogs as d', 'd.id', '=', 'trip_pickers.deliverylog_id')->where('d.is_active', true)
            ->get(['trip_pickers.user_id', 'trip_pickers.deliverylog_id']);
        $eligible = [];
        $suggested = collect(); // one person is suggested for one trip: earlier trips first

        $rows = $trips->map(function (Deliverylog $t) use ($pickers, $names, $busy, &$eligible, &$suggested) {
            $p = Picking::progress($t);
            $ps = collect($pickers[$t->id] ?? [])->map(fn ($r) => ['id' => (int) $r->user_id, 'name' => $names[$r->user_id] ?? '?'])->values();
            $status = $p['total'] > 0 && $p['picked'] >= $p['total'] ? 'ready' : ($ps->isEmpty() ? 'none' : ($p['picked'] ? 'picking' : 'wait'));
            $sug = $ps->isEmpty() && $status !== 'ready' ? Picking::suggest($t, $busy->where('deliverylog_id', '!=', $t->id)->pluck('user_id')->map(fn ($i) => (int) $i)->merge($suggested)) : null;
            $suggested = $suggested->merge($sug['ids'] ?? []);
            $eligible[$t->logistichub_id] ??= Picking::eligible((int) $t->logistichub_id)->map(fn ($u) => ['id' => $u->id, 'name' => trim($u->first_name.' '.$u->last_name)]);
            $missing = Picking::rows($t)->whereNull('picked_at')->whereNotNull('missing_at')->get(['id', 'invoice']);

            return [
                'id' => $t->id, 'no' => $t->trip_number, 'to' => $t->destination?->hub_name ?? '—', 'truck' => $t->truck?->plate_no ?? 'no truck',
                'secs' => Picking::sectionsText($t) ?: 'All picked', 'pickers' => $ps->all(),
                'others' => collect($eligible[$t->logistichub_id])->reject(fn ($u) => $ps->contains('id', $u['id']))
                    ->map(fn ($u) => $u + ['busy' => $busy->where('user_id', $u['id'])->where('deliverylog_id', '!=', $t->id)->isNotEmpty()])->values()->all(),
                'sug' => $sug && $sug['ids'] ? $sug : null,
                'p' => $p, 'pct' => $p['total'] ? round($p['picked'] / $p['total'] * 100) : 0, 'status' => $status, 'missing' => $missing,
            ];
        });

        // the live log, with Undo on picks that still stand
        $log = Picking::recent($trips->pluck('id'), 10);
        $raw = DB::table('pick_logs')->whereIn('deliverylog_id', $trips->pluck('id'))->orderByDesc('id')->limit(10)->get();
        $log = $log->values()->map(function ($l, $i) use ($raw) {
            $r = $raw[$i] ?? null;
            $row = $r && $r->what === 'picked' ? Tripinvoice::where('invoice', $r->invoice)->where(fn ($q) => $q->where('deliverylog_id', $r->deliverylog_id)->orWhere('deliveryloghub_id', $r->deliverylog_id))
                ->whereNotNull('picked_at')->where('picked_by', $r->user_id)->value('id') : null;

            return $l + ['undo' => $row];
        });

        return ['rows' => $rows, 'log' => $log];
    }
}
