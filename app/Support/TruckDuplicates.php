<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\TruckMerge;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/** Same truck saved twice: find, compare, merge (with undo), and stop it at Add truck. */
class TruckDuplicates
{
    /** Fields copied to the kept truck when it has none. */
    public const FILL = ['truck_picture', 'make_model', 'capacity', 'fuel_type', 'tank_liters', 'cargo_length_cm', 'cargo_width_cm', 'cargo_height_cm', 'fill_pct', 'registration_no', 'description'];

    public const UNDO_DAYS = 7;

    public static function ready(): bool
    {
        return Schema::hasTable('truck_merges');
    }

    /** Plate compared without spaces, dashes and capitals: "nab-2210" → "NAB2210". */
    public static function key(?string $plate): string
    {
        return strtoupper(preg_replace('/[^A-Za-z0-9]/', '', (string) $plate));
    }

    /** Plate as saved: capitals, one space ("nab2210" → "NAB 2210", "nab - 2210" → "NAB 2210"). */
    public static function format(?string $plate): string
    {
        $p = strtoupper(trim(preg_replace('/[\s\-_.]+/', ' ', (string) $plate)));
        if ($p !== '' && ! str_contains($p, ' ') && preg_match('/^([A-Z]+)(\d+[A-Z]?)$/', $p, $m)) {
            $p = $m[1].' '.$m[2];
        }

        return $p;
    }

    /** Another truck with the same plate (any hub), not the one being edited. */
    public static function existing(?string $plate, ?int $except = null): ?Truck
    {
        $key = static::key($plate);
        if (strlen($key) < 3) {
            return null;
        }

        return Truck::with('rentalCompany')->when($except, fn ($q) => $q->where('id', '!=', $except))->get()
            ->filter(fn (Truck $t) => static::key($t->plate_no) === $key && ! static::isMergedAway($t->id))
            ->sortByDesc('is_active')->first();
    }

    public static function isMergedAway(int $truckId): bool
    {
        return static::ready() && TruckMerge::where('kind', 'merge')->where('dropped_id', $truckId)->whereNull('undone_at')->exists();
    }

    /** Groups of 2+ trucks with the same plate, for this hub (null = all). */
    public static function groups(int|false|null $hub = null): Collection
    {
        if (! static::ready() || $hub === false) {
            return collect();
        }
        $gone = TruckMerge::where('kind', 'merge')->whereNull('undone_at')->pluck('dropped_id')->all();
        $different = TruckMerge::where('kind', 'different')->get(['kept_id', 'dropped_id'])
            ->map(fn ($m) => collect([$m->kept_id, $m->dropped_id])->sort()->join('-'))->all();

        return Truck::with('logistichub')->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))
            ->whereNotIn('id', $gone)->get()
            ->groupBy(fn (Truck $t) => static::key($t->plate_no))
            ->filter(fn ($g, $k) => $k !== '' && $g->count() > 1)
            ->filter(function ($g) use ($different) {
                // drop the group when every pair in it was marked "Different trucks"
                $ids = $g->pluck('id')->sort()->values();
                foreach ($ids as $i => $a) {
                    foreach ($ids->slice($i + 1) as $b) {
                        if (! in_array($a.'-'.$b, $different, true)) {
                            return true;
                        }
                    }
                }

                return false;
            })
            ->map(fn ($g) => $g->sort(fn ($a, $b) => static::rank($b) <=> static::rank($a))->values())
            ->values();
    }

    /** Ids of trucks that are in a duplicate group. */
    public static function flagged(int|false|null $hub = null): array
    {
        $out = [];
        foreach (static::groups($hub) as $g) {
            foreach ($g as $t) {
                $out[$t->id] = $g->firstWhere('id', '!=', $t->id)?->plate_no;
            }
        }

        return $out;
    }

    /** Every table with a truck_id column (trips, crew, fuel, tracking, bookings, …). */
    public static function tables(): array
    {
        return collect(Schema::getTables())->pluck('name')
            ->reject(fn ($n) => in_array($n, ['trucks', 'truck_merges', 'migrations'], true))
            ->filter(fn ($n) => Schema::hasColumn($n, 'truck_id'))->values()->all();
    }

    /** Which copy to keep first: active, then has crew, then more trips, then the older one. */
    public static function rank(Truck $t): array
    {
        return [(int) $t->is_active, (int) Truckcrew::where('truck_id', $t->id)->exists(), static::tripCount($t), -($t->created_at?->timestamp ?? 0)];
    }

    public static function tripCount(Truck $t): int
    {
        return Deliverylog::where('truck_id', $t->id)->count() + (Schema::hasTable('whdeliverylogs') ? DB::table('whdeliverylogs')->where('truck_id', $t->id)->count() : 0);
    }

    /** What the compare cards show. */
    public static function stats(Truck $t): array
    {
        $last = Deliverylog::where('truck_id', $t->id)->latest('id')->first();
        $crew = Truckcrew::with('member')->where('truck_id', $t->id)->get()->map(fn ($c) => $c->member?->first_name)->filter();

        return [
            'trips' => static::tripCount($t),
            'crew' => $crew->isNotEmpty() ? $crew->join(', ') : '—',
            'fuel' => Schema::hasTable('fuel_fills') ? DB::table('fuel_fills')->where('truck_id', $t->id)->count() : 0,
            'last' => $last ? Carbon::parse($last->departure_date ?? $last->created_at)->format('M j').' · '.$last->trip_number : '—',
            'photo' => $t->truck_picture ? 'Yes' : 'No',
            'booked' => Schema::hasTable('truck_bookings') ? DB::table('truck_bookings')->where('truck_id', $t->id)->where('day', '>=', today()->toDateString())->count() : 0,
        ];
    }

    /** Move everything from $drop to $keep; $drop turns inactive. */
    public static function merge(Truck $keep, Truck $drop, ?int $userId = null): TruckMerge
    {
        abort_if($keep->id === $drop->id, 422);

        return DB::transaction(function () use ($keep, $drop, $userId) {
            $moved = [];
            foreach (static::tables() as $table) {
                $q = DB::table($table)->where('truck_id', $drop->id);
                if ($table === 'truckcrews') {
                    // a person already on the kept truck: just leave the extra row on the copy
                    $q->whereNotIn('crew', DB::table('truckcrews')->where('truck_id', $keep->id)->pluck('crew'));
                }
                if ($table === 'truck_bookings') {
                    $q->whereNotIn('day', DB::table('truck_bookings')->where('truck_id', $keep->id)->pluck('day'));
                }
                $ids = Schema::hasColumn($table, 'id') ? $q->pluck('id')->all() : [];
                if ($ids) {
                    DB::table($table)->whereIn('id', $ids)->update(['truck_id' => $keep->id]);
                    $moved[$table] = $ids;
                }
            }
            $fill = [];
            foreach (static::FILL as $f) {
                if (Schema::hasColumn('trucks', $f) && blank($keep->{$f}) && filled($drop->{$f})) {
                    $fill[$f] = $drop->{$f};
                }
            }
            $before = ['kept' => array_fill_keys(array_keys($fill), null), 'dropped' => ['is_active' => (bool) $drop->is_active, 'Note' => $drop->Note, 'is_assigned' => $drop->is_assigned]];
            if ($fill) {
                $keep->forceFill($fill)->save();
            }
            $drop->forceFill(['is_active' => false, 'is_assigned' => false, 'Note' => trim('Merged into '.$keep->plate_no.' on '.today()->format('M j, Y').".\n".$drop->Note)])->save();

            return TruckMerge::create(['kind' => 'merge', 'kept_id' => $keep->id, 'dropped_id' => $drop->id, 'moved' => $moved, 'before' => $before, 'user_id' => $userId]);
        });
    }

    public static function canUndo(TruckMerge $m): bool
    {
        return $m->kind === 'merge' && ! $m->undone_at && $m->created_at->gte(now()->subDays(static::UNDO_DAYS));
    }

    public static function undo(TruckMerge $m): void
    {
        abort_unless(static::canUndo($m), 422);
        DB::transaction(function () use ($m) {
            foreach ((array) $m->moved as $table => $ids) {
                if (Schema::hasTable($table)) {
                    DB::table($table)->whereIn('id', $ids)->update(['truck_id' => $m->dropped_id]);
                }
            }
            if ($m->kept && ($b = $m->before['kept'] ?? [])) {
                $m->kept->forceFill($b)->save();
            }
            if ($m->dropped && ($b = $m->before['dropped'] ?? [])) {
                $m->dropped->forceFill($b)->save();
            }
            $m->update(['undone_at' => now()]);
        });
    }

    public static function markDifferent(Truck $a, Truck $b, ?int $userId = null): void
    {
        TruckMerge::firstOrCreate(['kind' => 'different', 'kept_id' => min($a->id, $b->id), 'dropped_id' => max($a->id, $b->id)], ['user_id' => $userId]);
    }
}
