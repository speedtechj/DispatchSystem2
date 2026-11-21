<?php

namespace App\Support\Trips;

use App\Models\Boxes\WhSection;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Ai\TripPlanner;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Picking (board 49): before Load truck, pickers take each trip's boxes from the sections.
 *
 * - The office gives each trip its pickers (suggested: on shift today, free, the truck's crew first,
 *   about 1 picker for 40 boxes); a picker can Take a trip that has none.
 * - Pickers scan each box: picked, combo n of m, not for this trip, already picked, not found, undo.
 * - Many phones on one trip: everything is saved at once, so every phone sees the same list.
 * - Warehouse (and Admin): the hub's trips. Partner hub: its own trips.
 */
class Picking
{
    public const PER_PICKER = 40;

    public static function ready(): bool
    {
        static $ready = null;

        return $ready ??= Schema::hasTable('trip_pickers') && Schema::hasColumn('tripinvoices', 'picked_at');
    }

    /** A partner hub's own trip: its boxes are on deliveryloghub_id and loaded with is_loaded_hub. */
    public static function hubOwn(Deliverylog $trip): bool
    {
        static $memo = [];
        $k = spl_object_id(app()).':'.$trip->logistichub_id;

        return $memo[$k] ??= (bool) \App\Models\Logistichub::whereKey($trip->logistichub_id)->value('is_company');
    }

    /** The boxes of the trip that still need picking (not loaded yet). */
    public static function rows(Deliverylog $trip)
    {
        $hub = static::hubOwn($trip);

        $t = 'tripinvoices.';
        $loaded = $t.($hub ? 'is_loaded_hub' : 'is_loaded');

        return Tripinvoice::query()->where($t.($hub ? 'deliveryloghub_id' : 'deliverylog_id'), $trip->id)
            ->where(fn ($q) => $q->where($loaded, false)->orWhereNull($loaded))
            ->where(fn ($q) => $q->where($t.'is_delivered', false)->orWhereNull($t.'is_delivered'));
    }

    /** Trips of this hub to pick: open, not taken, with boxes not loaded. */
    public static function trips(?int $hubId): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $taken = Schema::hasColumn('deliverylogs', 'taken_at');

        return Deliverylog::with('truck:id,plate_no', 'destination:id,hub_name')->where('is_active', true)
            ->when($hubId, fn ($q) => $q->where('logistichub_id', $hubId), fn ($q) => $q->whereIn('logistichub_id', \App\Models\Logistichub::where(fn ($w) => $w->where('is_company', false)->orWhereNull('is_company'))->select('id')))
            ->when($taken, fn ($q) => $q->whereNull('taken_at'))
            ->where(fn ($q) => $q->whereExists(fn ($w) => $w->select(DB::raw(1))->from('tripinvoices')->whereColumn('tripinvoices.deliverylog_id', 'deliverylogs.id')
                ->where(fn ($x) => $x->where('is_loaded', false)->orWhereNull('is_loaded')))
                ->orWhereExists(fn ($w) => $w->select(DB::raw(1))->from('tripinvoices')->whereColumn('tripinvoices.deliveryloghub_id', 'deliverylogs.id')
                    ->where(fn ($x) => $x->where('is_loaded_hub', false)->orWhereNull('is_loaded_hub'))))
            ->orderBy('departure_date')->orderBy('id')->get();
    }

    /** @return array{total: int, picked: int, missing: int} */
    public static function progress(Deliverylog $trip): array
    {
        $r = static::rows($trip)->selectRaw('count(*) as total, sum(case when picked_at is not null then 1 else 0 end) as picked, sum(case when missing_at is not null and picked_at is null then 1 else 0 end) as missing')->first();

        return ['total' => (int) $r->total, 'picked' => (int) $r->picked, 'missing' => (int) $r->missing];
    }

    /** "C 12 · D 4": sections of the boxes not picked yet. */
    public static function sectionsText(Deliverylog $trip): string
    {
        $codes = static::rows($trip)->whereNull('tripinvoices.picked_at')->join('invoices as i', 'i.id', '=', 'tripinvoices.invoice_id')
            ->leftJoin('wh_sections as s', 's.id', '=', 'i.wh_section_id')->selectRaw('coalesce(s.code, ?) as c, count(*) as n', ['No section'])
            ->groupBy('c')->orderBy('c')->toBase()->get()->pluck('n', 'c');

        return $codes->map(fn ($n, $c) => $c.' '.$n)->join(' · ');
    }

    // ---------------------------------------------------------------- pickers

    /** People who can pick here: registered in this warehouse or partner hub. */
    public static function eligible(int $hubId): Collection
    {
        return User::where('logistichub_id', $hubId)->where(fn ($q) => $q->where('is_active', true)->orWhereNull('is_active'))
            ->whereHas('panelcategory', fn ($q) => $q->whereIn('code', ['whse', 'co']))->orderBy('first_name')->get();
    }

    public static function pickers(Deliverylog $trip): Collection
    {
        return User::whereIn('id', DB::table('trip_pickers')->where('deliverylog_id', $trip->id)->pluck('user_id'))->orderBy('first_name')->get();
    }

    public static function isPicker(Deliverylog $trip, User $u): bool
    {
        return DB::table('trip_pickers')->where('deliverylog_id', $trip->id)->where('user_id', $u->id)->exists();
    }

    public static function assign(Deliverylog $trip, array $userIds, ?User $by, string $how = 'office'): void
    {
        $ok = static::eligible((int) $trip->logistichub_id)->pluck('id')->intersect($userIds);
        foreach ($ok as $uid) {
            DB::table('trip_pickers')->updateOrInsert(['deliverylog_id' => $trip->id, 'user_id' => $uid], ['how' => $how, 'by_user_id' => $by?->id, 'created_at' => now(), 'updated_at' => now()]);
        }
        if ($ok->isNotEmpty()) {
            static::log($trip, $by, null, $how === 'took' ? 'took' : 'assigned', ($how === 'took' ? 'took the trip in the Scan app' : 'gave it to '.User::whereIn('id', $ok)->pluck('first_name')->join(' and ')).($how === 'suggested' ? ' (suggested)' : ''));
        }
    }

    public static function unassign(Deliverylog $trip, int $userId): void
    {
        DB::table('trip_pickers')->where('deliverylog_id', $trip->id)->where('user_id', $userId)->delete();
    }

    /** Take a trip with no picker yet (Scan app). */
    public static function take(Deliverylog $trip, User $u): bool
    {
        if (DB::table('trip_pickers')->where('deliverylog_id', $trip->id)->exists() || ! static::eligible((int) $trip->logistichub_id)->contains('id', $u->id)) {
            return false;
        }
        static::assign($trip, [$u->id], $u, 'took');

        return true;
    }

    /** Signed in today (on shift). */
    protected static function onShift(Collection $ids): array
    {
        if (! Schema::hasTable('sessions')) {
            return $ids->all();
        }

        return DB::table('sessions')->whereIn('user_id', $ids)->where('last_activity', '>=', today()->timestamp)->distinct()->pluck('user_id')->map(fn ($i) => (int) $i)->all();
    }

    /**
     * Suggested pickers: on shift today, not picking another trip, the truck's crew first; about 1 for 40 boxes.
     *
     * @return array{ids: list<int>, names: list<string>, why: string}
     */
    public static function suggest(Deliverylog $trip, ?Collection $busy = null): array
    {
        $all = static::eligible((int) $trip->logistichub_id);
        if ($all->isEmpty()) {
            return ['ids' => [], 'names' => [], 'why' => ''];
        }
        $boxes = static::rows($trip)->whereNull('picked_at')->count();
        $need = max(1, min(3, (int) ceil($boxes / self::PER_PICKER)));
        $busy ??= DB::table('trip_pickers')->join('deliverylogs as d', 'd.id', '=', 'trip_pickers.deliverylog_id')->where('d.is_active', true)
            ->where('d.id', '!=', $trip->id)->pluck('trip_pickers.user_id')->map(fn ($i) => (int) $i);
        $shift = static::onShift($all->pluck('id'));
        $crew = collect(Schema::hasTable('trip_crews') ? DB::table('trip_crews')->where('deliverylog_id', $trip->id)->pluck('user_id') : [])
            ->merge($trip->truck_id ? DB::table('truckcrews')->where('truck_id', $trip->truck_id)->pluck('crew') : [])->filter()->map(fn ($i) => (int) $i)->unique()->all();
        $ranked = $all->reject(fn ($u) => $busy->contains($u->id))
            ->sortBy(fn ($u) => [in_array($u->id, $crew, true) ? 0 : 1, in_array($u->id, $shift, true) ? 0 : 1, $u->first_name])->values();
        $pick = $ranked->take($need);
        $why = collect([
            $pick->every(fn ($u) => in_array($u->id, $shift, true)) ? 'on shift' : null,
            'free',
            $pick->contains(fn ($u) => in_array($u->id, $crew, true)) ? 'crew of '.($trip->truck?->plate_no ?? 'the truck') : null,
            $boxes.' '.Str::plural('box', $boxes).': '.$need.' '.Str::plural('picker', $need),
        ])->filter()->join(' · ');

        return ['ids' => $pick->pluck('id')->all(), 'names' => $pick->pluck('first_name')->all(), 'why' => $why];
    }

    // ---------------------------------------------------------------- the list on the phone

    /** Section and spot of each box, grouped: spot C1, C2…, then the section with no spot, in section order. */
    public static function groups(Deliverylog $trip): array
    {
        $rows = static::rows($trip)->with('invdata:id,invoice,receiver_name,receiver_mobile_no,receiver_city,receiver_province,receiver_address,receiver_barangay,set_key,wh_section_id,wh_spot_id')->get();
        $secs = WhSection::query()->whereIn('id', $rows->pluck('invdata.wh_section_id')->filter()->unique())->get()->keyBy('id');
        $spots = Schema::hasTable('wh_spots') ? \App\Models\Boxes\WhSpot::whereIn('id', $rows->pluck('invdata.wh_spot_id')->filter()->unique())->get()->keyBy('id') : collect();
        $names = User::whereIn('id', $rows->pluck('picked_by')->merge($rows->pluck('missing_by'))->filter()->unique())->pluck('first_name', 'id');
        $combo = static::combos($rows);
        $groups = [];
        foreach ($rows as $r) {
            $inv = $r->invdata;
            $sec = $secs[$inv?->wh_section_id] ?? null;
            $spot = $spots[$inv?->wh_spot_id] ?? null;
            $city = Str::title(Str::lower((string) $inv?->receiver_city)) ?: 'No city';
            $key = $sec ? str_pad((string) $sec->sort, 5, '0', STR_PAD_LEFT).'|'.$sec->code.'|'.($spot ? '0'.str_pad((string) $spot->sort, 4, '0', STR_PAD_LEFT) : '9') : '99999|~|'.$city;
            $groups[$key] ??= ['name' => $spot ? 'Spot '.$spot->code.' · section '.$sec->code : ($sec ? 'Section '.$sec->code.' · '.($sec->name ?: $sec->goesTo()).($spots->isNotEmpty() && $sec->use_spots ? ' · no spot' : '') : 'No section · '.$city),
                'color' => $sec?->color ?? '#6b7b88', 'boxes' => []];
            $groups[$key]['boxes'][] = ['id' => $r->id, 'code' => $r->invoice, 'name' => $inv?->receiver_name, 'combo' => ($combo[$r->id] ?? 0) > 1,
                'picked' => (bool) $r->picked_at, 'by' => $names[$r->picked_by] ?? null, 'byId' => $r->picked_by,
                'missing' => ! $r->picked_at && $r->missing_at, 'missBy' => $names[$r->missing_by] ?? null];
        }
        ksort($groups);

        return array_values(array_map(function ($g) {
            $done = collect($g['boxes'])->where('picked', true)->count();

            return $g + ['done' => $done, 'total' => count($g['boxes'])];
        }, $groups));
    }

    /** Combo size of each row (one receiver, or one set). */
    protected static function combos(Collection $rows): array
    {
        $key = fn ($r) => $r->invdata ? ($r->invdata->set_key ?: TripPlanner::receiverKey($r->invdata)) : 'x'.$r->id;
        $sizes = $rows->groupBy($key)->map->count();

        return $rows->mapWithKeys(fn ($r) => [$r->id => $sizes[$key($r)] ?? 1])->all();
    }

    // ---------------------------------------------------------------- scanning

    /**
     * A picker scanned a box.
     *
     * @return array{status: string, title: string, why: string, invoice: ?Invoice, undo: ?int, tone: string}
     */
    public static function scan(Deliverylog $trip, User $u, string $code): array
    {
        $code = trim($code);
        $row = static::rows($trip)->with('invdata')->where('invoice', $code)->first();
        if (! $row) {
            $any = Tripinvoice::with('invdata')->where('invoice', $code)->latest('id')->first();
            $other = $any ? Deliverylog::whereKey($any->deliveryloghub_id ?: $any->deliverylog_id)->value('trip_number') : null;
            $inv = $any?->invdata ?? Invoice::with('whSection')->where('invoice', $code)->first();
            $sec = $inv?->whSection;
            static::log($trip, $u, $code, 'wrong', $other ? 'is for '.$other : 'not on this trip');

            return ['status' => 'danger', 'tone' => 'bad', 'title' => '✕ Not for '.$trip->trip_number.' · put it back', 'invoice' => $inv, 'undo' => null,
                'why' => ($other ? 'It is for '.$other.'. ' : 'It is not on this trip. ').($sec ? 'Put it back in section '.$sec->code.'.' : 'Put it back where it was.').' Nothing changed.'];
        }
        if ($row->picked_at) {
            $who = (int) $row->picked_by === $u->id ? null : User::whereKey($row->picked_by)->value('first_name');

            return ['status' => 'warning', 'tone' => 'warn', 'invoice' => $row->invdata, 'undo' => null,
                'title' => $who ? 'Already picked by '.$who : 'You already picked this', 'why' => $who ? $who.' has it. Leave this one.' : 'Scanned twice: counted once.'];
        }
        $row->forceFill(['picked_at' => now(), 'picked_by' => $u->id, 'missing_at' => null, 'missing_by' => null])->save();
        static::log($trip, $u, $code, 'picked');

        // combo: the rest of one receiver or one set, and where they are
        $inv = $row->invdata;
        $sib = $inv ? static::rows($trip)->with('invdata.whSection', 'invdata.whSpot')->whereKeyNot($row->id)->get()
            ->filter(fn ($r) => $r->invdata && (($inv->set_key && $r->invdata->set_key === $inv->set_key) || TripPlanner::receiverKey($r->invdata) === TripPlanner::receiverKey($inv))) : collect();
        $left = $sib->whereNull('picked_at');
        $p = static::progress($trip);
        $all = $p['picked'] >= $p['total'];
        if ($left->isNotEmpty()) {
            $size = $sib->count() + 1;

            return ['status' => 'success', 'tone' => 'warn', 'invoice' => $inv, 'undo' => $row->id,
                'title' => 'Picked · combo '.($size - $left->count()).' of '.$size,
                'why' => ($inv->receiver_name ?: 'Same receiver').': '.$left->count().' more · '.$left->map(fn ($r) => $r->invoice.' in '.($r->invdata?->whSpot?->code ?? ($r->invdata?->whSection ? 'section '.$r->invdata->whSection->code : 'no section')))->join(', ')];
        }

        return ['status' => 'success', 'tone' => 'ok', 'invoice' => $inv, 'undo' => $row->id,
            'title' => $sib->isNotEmpty() ? 'Picked · combo complete ('.($sib->count() + 1).')' : 'Picked ✓',
            'why' => $all ? 'All '.$p['total'].' boxes picked · go to Load truck.' : $p['picked'].' of '.$p['total'].' picked'];
    }

    /** Picked by mistake: back on the list. */
    public static function undo(Deliverylog $trip, int $rowId, User $u): bool
    {
        $row = static::rows($trip)->whereKey($rowId)->whereNotNull('picked_at')->first();
        if (! $row) {
            return false;
        }
        $row->forceFill(['picked_at' => null, 'picked_by' => null])->save();
        static::log($trip, $u, $row->invoice, 'undone', 'picked by mistake');

        return true;
    }

    /** Not in its section: the office sees it; the others keep picking. */
    public static function notFound(Deliverylog $trip, int $rowId, User $u): bool
    {
        $row = static::rows($trip)->with('invdata.whSection')->whereKey($rowId)->whereNull('picked_at')->first();
        if (! $row) {
            return false;
        }
        $row->forceFill(['missing_at' => now(), 'missing_by' => $u->id])->save();
        static::log($trip, $u, $row->invoice, 'not_found', 'not in '.($row->invdata?->whSection ? 'section '.$row->invdata->whSection->code : 'its place'));

        return true;
    }

    public static function log(Deliverylog $trip, ?User $u, ?string $invoice, string $what, ?string $note = null): void
    {
        DB::table('pick_logs')->insert(['deliverylog_id' => $trip->id, 'user_id' => $u?->id, 'invoice' => $invoice, 'what' => $what, 'note' => $note ? Str::limit($note, 250) : null, 'created_at' => now()]);
    }

    /** The latest lines for these trips: "8:12 AM · Ben · 80501 picked". */
    public static function recent(Collection $tripIds, int $n = 8): Collection
    {
        $rows = DB::table('pick_logs')->whereIn('deliverylog_id', $tripIds)->orderByDesc('id')->limit($n)->get();
        $names = User::whereIn('id', $rows->pluck('user_id')->filter()->unique())->pluck('first_name', 'id');
        $trips = Deliverylog::whereIn('id', $rows->pluck('deliverylog_id')->unique())->pluck('trip_number', 'id');

        return $rows->map(fn ($r) => ['t' => \Illuminate\Support\Carbon::parse($r->created_at)->format('g:i A'),
            'm' => ($trips[$r->deliverylog_id] ?? '').' · '.($names[$r->user_id] ?? 'Office').' · '.match ($r->what) {
                'picked' => $r->invoice.' picked', 'undone' => $r->invoice.' undone ('.$r->note.')', 'not_found' => $r->invoice.' not found, '.$r->note,
                'wrong' => $r->invoice.' scanned: '.$r->note, default => $r->note,
            }]);
    }
}
