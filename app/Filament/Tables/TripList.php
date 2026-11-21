<?php

namespace App\Filament\Tables;

use App\Models\Deliverylog;
use App\Models\TripCity;
use App\Models\TripCrew;
use App\Models\TripOverride;
use App\Support\Hubs\HubAreas;
use App\Support\TripFlow;
use App\Support\Trips\TripRules;
use Filament\Actions\Action;
use Filament\Forms\Components\ToggleButtons;
use Filament\Schemas\Components\Tabs\Tab;
use Filament\Tables\Columns\ViewColumn;
use Filament\Tables\Filters\Filter;
use Illuminate\Contracts\Pagination\Paginator;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Delivery trips list (board 42): one clear row per trip, who made it (✦ AI, ✦ Plan trips, changed, by hand),
 * where it goes, truck and crew, boxes, status; tabs, Made by and Going to filters, details on the side.
 */
class TripList
{
    public const MADE = [
        'ai' => ['✦ AI', 'ai'],
        'plan' => ['✦ Plan trips', 'plan'],
        'changed' => ['✦ Plan trips · changed', 'changed'],
        'manual' => ['✎ By hand', 'manual'],
    ];

    /** Rows loaded once for the whole page by prime(): trip id => cities, cities from boxes, crew. */
    protected static array $primed = ['app' => null, 'cities' => [], 'boxCities' => [], 'crew' => []];

    protected static function primed(string $kind, int $id)
    {
        return static::$primed['app'] === spl_object_id(app()) ? (static::$primed[$kind][$id] ?? null) : null;
    }

    /** Load what every row needs in a few queries instead of several per trip (speed). */
    public static function prime(iterable $trips): void
    {
        $trips = collect($trips instanceof Paginator ? $trips->items() : $trips)->filter(fn ($t) => $t instanceof Model);
        if ($trips->isEmpty()) {
            return;
        }
        (new Collection($trips->all()))->loadMissing(['truck', 'user', 'destination']);
        $ids = $trips->pluck('id')->all();
        TripFlow::known($trips);
        static::$primed = ['app' => spl_object_id(app()), 'cities' => [], 'boxCities' => [], 'crew' => []];
        $cities = TripCity::whereIn('deliverylog_id', $ids)->get()->groupBy('deliverylog_id');
        $crew = TripCrew::with('user.workposition')->whereIn('deliverylog_id', $ids)->get()->groupBy('deliverylog_id');
        $noCities = array_values(array_diff($ids, $cities->keys()->all()));
        $box = collect();
        if ($noCities) {
            $sel = fn (string $col) => DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                ->whereIn('tripinvoices.'.$col, $noCities)->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                ->select('tripinvoices.'.$col.' as trip', 'invoices.receiver_province as province', 'invoices.receiver_city as city')->distinct()->get();
            $box = $sel('deliverylog_id')->concat($sel('deliveryloghub_id'))->groupBy('trip');
        }
        foreach ($ids as $id) {
            static::$primed['cities'][$id] = $cities->get($id, collect());
            static::$primed['crew'][$id] = $crew->get($id, collect());
            static::$primed['boxCities'][$id] = $box->get($id, collect())->unique(fn ($r) => $r->province.'|'.$r->city)->take(6)->values();
        }
    }

    protected static function citiesOf(Model $trip)
    {
        return static::primed('cities', $trip->id) ?? TripCity::where('deliverylog_id', $trip->id)->get();
    }

    protected static function hasMade(): bool
    {
        static $has = null;

        return $has ??= Schema::hasColumn('deliverylogs', 'made_by');
    }

    /** How the trip was made. Old trips: Plan trips when they have cities, else by hand. */
    public static function madeKey(Model $trip): string
    {
        $m = static::hasMade() ? $trip->made_by : null;
        if ($m && isset(self::MADE[$m])) {
            return $m;
        }

        return static::citiesOf($trip)->isNotEmpty() ? 'plan' : 'manual';
    }

    public static function isHubTrip(Model $trip): bool
    {
        return $trip->assigned_to && (int) $trip->assigned_to !== (int) $trip->logistichub_id;
    }

    /** @return array{to: string, cities: string, dot: string} */
    public static function goes(Model $trip): array
    {
        $cities = static::citiesOf($trip);
        if ($cities->isEmpty()) {
            $rows = static::primed('boxCities', $trip->id) ?? DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                ->where(fn ($q) => $q->where('tripinvoices.deliverylog_id', $trip->id)->orWhere('tripinvoices.deliveryloghub_id', $trip->id))
                ->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                ->select('invoices.receiver_province as province', 'invoices.receiver_city as city')->distinct()->limit(6)->get();
            $prov = Str::title((string) ($rows->first()->province ?? ''));
            $list = $rows->pluck('city')->map(fn ($c) => Str::title($c))->unique();
        } else {
            $prov = (string) $cities->first()->province;
            $list = $cities->pluck('city')->unique();
        }
        $cityText = $list->isEmpty() ? 'No boxes yet' : $list->take(3)->join(', ').($list->count() > 3 ? ' +'.($list->count() - 3) : '');
        if (static::isHubTrip($trip)) {
            $color = class_exists(HubAreas::class) ? HubAreas::color((int) $trip->assigned_to) : '#1d6fb8';

            return ['to' => '→ '.($trip->destination?->hub_name ?? 'Hub'), 'cities' => $cityText, 'dot' => $color];
        }

        return ['to' => $prov ?: ($list->isEmpty() ? 'Not set yet' : 'Direct'), 'cities' => $cityText, 'dot' => '#17895e'];
    }

    /** Every city and municipality of the trip, in stop order (board 47). */
    public static function cityNames(Model $trip): array
    {
        $cities = TripCity::where('deliverylog_id', $trip->id)->orderBy('id')->pluck('city');
        if ($cities->isEmpty()) {
            $cities = DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                ->where(fn ($q) => $q->where('tripinvoices.deliverylog_id', $trip->id)->orWhere('tripinvoices.deliveryloghub_id', $trip->id))
                ->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                ->orderBy('invoices.receiver_city')->distinct()->pluck('invoices.receiver_city');
        }

        return $cities->map(fn ($c) => Str::title(Str::squish((string) $c)))->unique()->values()->all();
    }

    public static function crew(Model $trip)
    {
        return (static::primed('crew', $trip->id) ?? TripCrew::with('user.workposition')->where('deliverylog_id', $trip->id)->get())->sortBy(fn ($c) => TripFlow::isLead($c) ? 0 : 1)->values();
    }

    /** @return array{label: string, tone: string, when: string} */
    public static function status(Model $trip): array
    {
        $stage = TripFlow::ready() ? TripFlow::stage($trip) : ($trip->is_active ? 'loading' : 'closed');
        $label = $stage === 'back' ? 'Coming back' : (TripFlow::STAGES[$stage][0] ?? Str::title($stage));
        if ($stage === 'closed' && $trip->release_reason === 'auto') {
            $label = 'Done';
        }
        $when = match ($stage) {
            'road' => $trip->taken_at ? 'Left '.$trip->taken_at->format('g:i A') : 'On the road',
            'back' => ($n = TripFlow::left($trip)) > 0 ? $n.' '.Str::plural('return', $n).' to scan at the office' : ($trip->back_at ? 'Back '.$trip->back_at->format('g:i A') : 'Back at the hub'),
            'closed' => $trip->closed_at ? 'Done '.$trip->closed_at->format('M j g:i A') : 'Done',
            'ready' => $trip->ready_at ? 'Locked '.$trip->ready_at->format('g:i A') : 'Locked',
            'waiting' => 'Waits for the truck',
            default => $trip->departure_date ? 'Leaves '.Carbon::parse($trip->departure_date)->format('M j') : '',
        };

        return ['label' => $label, 'tone' => $stage, 'when' => $when];
    }

    /** "How this trip was made" lines for the details panel. */
    public static function how(Deliverylog $trip): array
    {
        $key = static::madeKey($trip);
        $note = static::hasMade() ? $trip->made_note : null;
        $lines = [];
        $lines[] = match ($key) {
            'ai' => ['✦', 'Plan trips with the AI'.($note ? ': “'.$note.'”' : '').'.'],
            'changed' => ['✎', 'Plan trips, changed before Create'.($note ? ': '.$note : '').'.'],
            'plan' => ['✦', ($note ?: (static::isHubTrip($trip) ? 'Plan trips › To hubs' : 'Plan trips')).' (system rules).'],
            default => ['✎', 'Made by hand in Delivery trips › New trip.'],
        };
        if ($trip->plan_why) {
            $lines[] = ['💬', 'Why: '.$trip->plan_why];
        }
        if (static::isHubTrip($trip)) {
            $lines[] = ['⌂', ($trip->destination?->hub_name ?? 'The hub').' delivers the boxes with its own trucks.'];
        }
        if (TripRules::ready()) {
            foreach (TripOverride::where('trip_id', $trip->id)->latest('id')->limit(4)->get() as $o) {
                $lines[] = ['⇄', (TripRules::RULES[$o->rule][0] ?? $o->rule).($o->box ? ' · '.$o->box : '').($o->reason ? ': '.$o->reason : '').' ('.$o->status.')'];
            }
        }

        return $lines;
    }

    /** @return list<ViewColumn> */
    public static function columns(): array
    {
        return [
            ViewColumn::make('trip_number')->label('Trip · made by')->view('filament.trips.list.trip')->searchable()->sortable(),
            ViewColumn::make('goes')->label('Going to')->view('filament.trips.list.goes'),
            ViewColumn::make('truck_view')->label('Truck · crew')->view('filament.trips.list.truck')
                ->searchable(query: fn (Builder $query, string $search) => $query->whereHas('truck', fn ($t) => $t->where('plate_no', 'like', "%{$search}%"))),
            ViewColumn::make('boxes_bar')->label('Boxes')->view('filament.trips.list.boxes'),
            ViewColumn::make('stage_view')->label('Status')->view('filament.trips.list.status'),
        ];
    }

    /** Made by and Going to, as chips above the list. */
    public static function filters(): array
    {
        return [
            Filter::make('made')
                ->schema([ToggleButtons::make('v')->label('Made by')->inline()->options(['all' => 'All', 'ai' => '✦ AI', 'plan' => '✦ Plan trips', 'manual' => '✎ By hand'])->default('all')])
                ->query(function (Builder $query, array $data) {
                    $q = $query;
                    $v = $data['v'] ?? 'all';
                    if ($v === 'all' || ! $v) {
                        return $q;
                    }
                    $hasCities = fn ($w) => $w->select(DB::raw(1))->from('trip_cities')->whereColumn('trip_cities.deliverylog_id', 'deliverylogs.id');
                    $made = static::hasMade();

                    return match ($v) {
                        'ai' => $made ? $q->where('deliverylogs.made_by', 'ai') : $q->whereRaw('1 = 0'),
                        'plan' => $q->where(fn ($w) => $made
                            ? $w->whereIn('deliverylogs.made_by', ['plan', 'changed'])->orWhere(fn ($n) => $n->whereNull('deliverylogs.made_by')->whereExists($hasCities))
                            : $w->whereExists($hasCities)),
                        'manual' => $q->where(fn ($w) => $made
                            ? $w->where('deliverylogs.made_by', 'manual')->orWhere(fn ($n) => $n->whereNull('deliverylogs.made_by')->whereNotExists($hasCities))
                            : $w->whereNotExists($hasCities)),
                        default => $q,
                    };
                })
                ->columnSpan(2)
                ->indicateUsing(fn (array $data) => ($data['v'] ?? 'all') !== 'all' ? 'Made by: '.(['ai' => 'AI', 'plan' => 'Plan trips', 'manual' => 'By hand'][$data['v']] ?? '') : null),
            Filter::make('going')
                ->schema([ToggleButtons::make('v')->label('Going to')->inline()->options(['all' => 'All', 'direct' => 'Direct', 'hub' => 'To hubs'])->default('all')])
                ->query(fn (Builder $query, array $data) => match ($data['v'] ?? 'all') {
                    'direct' => $query->whereColumn('deliverylogs.assigned_to', 'deliverylogs.logistichub_id'),
                    'hub' => $query->whereColumn('deliverylogs.assigned_to', '!=', 'deliverylogs.logistichub_id'),
                    default => $query,
                })
                ->indicateUsing(fn (array $data) => ($data['v'] ?? 'all') !== 'all' ? 'Going to: '.(['direct' => 'Direct', 'hub' => 'To hubs'][$data['v']] ?? '') : null),
        ];
    }

    /** Click a trip: its details on the side. */
    public static function details(): Action
    {
        return Action::make('details')
            ->label('Details')
            ->icon('heroicon-o-ellipsis-horizontal')
            ->iconButton()
            ->slideOver()
            ->modalWidth('lg')
            ->modalHeading(fn (Deliverylog $record) => 'Trip '.$record->trip_number)
            ->modalContent(fn (Deliverylog $record, $livewire) => view('filament.trips.list.details', ['trip' => $record,
                'editUrl' => method_exists($livewire, 'getResource') ? $livewire::getResource()::getUrl('edit', ['record' => $record]) : null]))
            ->modalSubmitAction(false)
            ->modalCancelActionLabel('Close');
    }

    /** All / Planned / Loading / On the road / Done. */
    public static function tabs(Builder $base): array
    {
        $loaded = fn ($w) => $w->select(DB::raw(1))->from('tripinvoices')->where('tripinvoices.is_loaded', true)
            ->where(fn ($x) => $x->whereColumn('tripinvoices.deliverylog_id', 'deliverylogs.id')->orWhereColumn('tripinvoices.deliveryloghub_id', 'deliverylogs.id'));
        $taken = Schema::hasColumn('deliverylogs', 'taken_at');
        $back = Schema::hasColumn('deliverylogs', 'back_at');
        $q = [
            'work' => fn (Builder $b) => $b->where('deliverylogs.is_active', true),
            'planned' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNull('deliverylogs.taken_at'))->whereNotExists($loaded),
            'loading' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNull('deliverylogs.taken_at'))->whereExists($loaded),
            'road' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNotNull('deliverylogs.taken_at'), fn ($x) => $x->whereRaw('1 = 0'))
                ->when($back, fn ($x) => $x->whereNull('deliverylogs.back_at')),
            'back' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($back, fn ($x) => $x->whereNotNull('deliverylogs.back_at'), fn ($x) => $x->whereRaw('1 = 0')),
            'done' => fn (Builder $b) => $b->where('deliverylogs.is_active', false),
            'all' => fn (Builder $b) => $b,
        ];
        // board 45c: only trips still at work by default; done trips stay in the Done tab
        $labels = ['work' => 'Still at work', 'planned' => 'Planned', 'loading' => 'Loading', 'road' => 'On the road', 'back' => 'Coming back', 'done' => 'Done', 'all' => 'All'];

        return collect($q)->mapWithKeys(fn ($fn, $k) => [$k => Tab::make($labels[$k])
            ->badge(fn () => $fn((clone $base))->count())
            ->modifyQueryUsing(fn (Builder $query) => $fn($query))])->all();
    }
}
