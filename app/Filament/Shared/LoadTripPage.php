<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Invoice;
use Filament\Notifications\Notification;
use App\Models\Tripinvoice;
use App\Models\Boxes\SetSplit;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Boxes\BoxSets;
use App\Support\Maps\LoadOrder;
use App\Support\Maps\TripSorter;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station: crew scans each box as it goes onto the truck of a trip.
 *
 * Used by the admin hub (Scanload), the warehouse hub (Hubloaded) and partner
 * hubs (LoadTruck, which loads boxes handed over to the hub's own trips).
 */
abstract class LoadTripPage extends Page
{
    use ScansInvoices;
    use \App\Filament\Concerns\BypassesTripRules;

    protected string $view = 'filament.pages.scanload';

    protected static string|\BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUpTray;

    /** Partner-hub mode: invoices are linked via deliveryloghub_id / is_loaded_hub. */
    protected static bool $atHub = false;

    /** Set by "Load it anyway" after a "too early" warning. */
    public bool $forceLoad = false;

    /** The last box that was too early to load (see LoadOrder). */
    public ?array $early = null;

    /** Where the box just loaded goes: ['zone' => 'front', 'stop' => 7]. */
    public ?array $spot = null;

    /** The box is for another hub than the trip goes to. */
    public ?array $wrongHub = null;

    /** The box's set on this truck: "Maria Santos · 2 of 3 · still to load X-103 (C)". */
    public ?array $setInfo = null;

    public function mount(): void
    {
        $this->form->fill();
    }

    protected function tripColumn(): string
    {
        return static::$atHub ? 'deliveryloghub_id' : 'deliverylog_id';
    }

    protected function loadedColumn(): string
    {
        return static::$atHub ? 'is_loaded_hub' : 'is_loaded';
    }

    protected function tripOptionsQuery(): Builder
    {
        return Deliverylog::query()
            ->with('destination:id,hub_name')
            ->where('logistichub_id', Auth::user()->logistichub_id)
            ->whereNotNull('truck_id')
            ->where('is_active', true)
            ->latest('id');
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('deliverylog_id')
                    ->label('Trip')
                    ->placeholder('Choose the trip you are loading')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage'))
                    ->options(fn () => $this->tripOptionsQuery()
                        ->get()
                        ->mapWithKeys(fn (Deliverylog $trip) => [
                            $trip->id => $trip->trip_number.($trip->destination ? ' → '.$trip->destination->hub_name : ''),
                        ])),
            ]);
    }

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a trip';
    }

    /** The selected trip, re-checked against what this user may load. */
    protected function selectedTrip(): ?Deliverylog
    {
        return $this->tripOptionsQuery()->find($this->data['deliverylog_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->selectedTrip();

        if (! $trip) {
            $this->scanResult('danger', 'That trip is no longer open for loading.');

            return;
        }

        // two boxes with this number on the trip: the one not loaded yet first (board 57)
        $tripinvoice = Tripinvoice::with('invdata')
            ->where($this->tripColumn(), $trip->id)
            ->where('invoice', $code)
            ->orderByRaw('coalesce('.$this->loadedColumn().', 0) asc')
            ->latest('id')
            ->first();
        $sameOnTrip = $tripinvoice ? Tripinvoice::where($this->tripColumn(), $trip->id)->where('invoice', $code)->count() : 0;

        $this->bypass = null;
        $box = $tripinvoice?->invdata ?? \App\Support\Boxes\SameNumber::best($code, Auth::user()?->warehouse_id);
        // Truck full: the box does not fit in the truck's space (only for trucks with a space set).
        if ($box && ! static::$atHub && ! $tripinvoice?->{$this->loadedColumn()} && ($full = \App\Support\Trips\TripSpace::overFull($trip, $box))
            && ! $this->skips('truck_full', $trip->id, $box->id)) {
            $this->early = null;
            $this->wrongHub = ['kind' => 'full', 'code' => $code, 'for' => $full['used'].' of '.$full['cap'].' space used', 'section' => $box->whSection?->code ?? '—',
                'color' => $box->whSection?->color, 'trip' => $trip->trip_number, 'space' => $full['space'], 'province' => $box->receiver_province];
            $this->scanResult('warning', "Truck full: {$code} does not fit ({$full['used']} of {$full['cap']} space used).", $box);

            return;
        }

        // Trip planned by city: a waiting box of one of its cities joins the trip now.
        $cityTrip = ! static::$atHub && \App\Support\Trips\CityTrips::isCityTrip($trip);
        if (! $tripinvoice && $cityTrip) {
            [$joined, $why] = \App\Support\Trips\CityTrips::join($trip, $code, $box ? $this->skips('topup_other', $trip->id, $box->id) : $this->forceLoad,
                $box ? $this->skips('direct_hub', $trip->id, $box->id) : false);
            if ($joined) {
                $tripinvoice = $joined;
            } elseif ($why === 'other-city') {
                $inv = \App\Support\Boxes\SameNumber::best($code);
                $place = \Illuminate\Support\Str::title(trim($inv?->receiver_city.', '.$inv?->receiver_province, ', '));
                $this->early = null;
                $this->wrongHub = ['kind' => 'city', 'code' => $code, 'for' => $place, 'section' => $inv?->whSection?->code ?? '—', 'color' => $inv?->whSection?->color,
                    'trip' => \App\Models\TripCity::where('deliverylog_id', $trip->id)->pluck('city')->join(', ')];
                $this->forceLoad = false;
                $this->scanResult('warning', "Other city: {$code} is for {$place}. Trip {$trip->trip_number} goes to {$this->wrongHub['trip']}.", $inv);

                return;
            } elseif (is_string($why) && str_starts_with($why, 'hub:')) {
                // the box goes to a partner hub, or is ours while this trip goes to a hub
                $inv = \App\Support\Boxes\SameNumber::best($code);
                $hubId = (int) substr($why, 4);
                $place = \Illuminate\Support\Str::title(trim($inv?->receiver_city.', '.$inv?->receiver_province, ', '));
                $goes = $hubId ? \App\Support\Hubs\HubAreas::name($hubId) : 'our own trucks (direct to the customer)';
                $this->early = null;
                $this->wrongHub = ['kind' => 'hub', 'code' => $code, 'for' => $place, 'home' => $goes, 'section' => $inv?->whSection?->code ?? '—', 'color' => $inv?->whSection?->color,
                    'trip' => $trip->trip_number];
                $this->forceLoad = false;
                $this->scanResult('warning', "Not for this trip: {$code} ({$place}) goes ".($hubId ? "to {$goes}" : 'with our own trucks').'.', $inv);

                return;
            } elseif ($why) {
                $this->scanResult('danger', $why, $this->invoicesMatching($code)->first());

                return;
            }
        }

        if (! $tripinvoice && static::$atHub && $box && \App\Support\Hubs\HubAreas::ready()
            && ($other = \App\Support\Hubs\HubAreas::hubOf($box)) && $other !== (int) Auth::user()?->logistichub_id) {
            // a box of another hub's area came to this hub by mistake
            $mine = \App\Support\Hubs\HubAreas::name((int) Auth::user()?->logistichub_id);
            $place = \Illuminate\Support\Str::title(trim($box->receiver_city.', '.$box->receiver_province, ', '));
            $this->scanResult('danger', "Not for {$mine}: {$code} is for ".\App\Support\Hubs\HubAreas::name($other)." ({$place}). Not loaded: put it aside and tell the office.", $box);

            return;
        }

        if (! $tripinvoice) {
            $elsewhere = Tripinvoice::with(['deliverylog:id,trip_number', 'invdata'])
                ->where('invoice', $code)
                ->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
                ->latest('id')
                ->first();

            $this->scanResult(
                'danger',
                $elsewhere
                    ? "{$code} belongs to trip {$elsewhere->deliverylog?->trip_number}, not {$trip->trip_number}."
                    : "{$code} is not on trip {$trip->trip_number}.",
                $elsewhere?->invdata ?? $this->invoicesMatching($code)->first(),
            );

            return;
        }

        if (static::$atHub && \App\Support\Shipping\Shipments::ready() && ($sea = \App\Support\Shipping\Shipments::stillAtSea($tripinvoice))) {
            $this->scanResult('danger', "{$code} is still on sea shipment {$sea->code}".($sea->eta ? ' (arriving about '.$sea->eta->format('M j').')' : '').'. Receive the container first (Scan app → Receive container).', $tripinvoice->invdata);

            return;
        }

        if ($tripinvoice->{$this->loadedColumn()}) {
            $who = $tripinvoice->loaded_by && $tripinvoice->loaded_by !== Auth::id() ? User::find($tripinvoice->loaded_by)?->first_name : null;
            $when = $tripinvoice->loaded_at ? \Illuminate\Support\Carbon::parse($tripinvoice->loaded_at)->format('g:i A') : null;
            $this->scanResult('warning', $sameOnTrip > 1 ? "Already loaded: all {$sameOnTrip} boxes with number {$code} are on the truck. Leave this one." : "{$code} was already loaded".($who ? " by {$who}" : '').($when ? " at {$when}" : '').'. Not counted again.', $tripinvoice->invdata);

            return;
        }

        $this->early = null;
        $this->spot = null;
        $this->wrongHub = null;
        $this->setInfo = null;
        if (! $this->skips('wrong_hub', $trip->id, $tripinvoice->invoice_id) && ($wrong = $this->wrongHubFor($trip, $tripinvoice))) {
            $this->wrongHub = $wrong;
            $this->scanResult('warning', "Wrong hub: {$code} is for {$wrong['for']} (section {$wrong['section']}). This trip goes to {$wrong['trip']}.", $tripinvoice->invdata);

            return;
        }
        if (! $this->skips('load_order', $trip->id, $tripinvoice->invoice_id) && ! $cityTrip && ($early = LoadOrder::tooEarly($trip, $tripinvoice, static::$atHub))) {
            $this->early = $early;
            $this->scanResult('warning', "Too early: {$code} is for stop {$early['stop']}".($early['place'] ? " ({$early['place']})" : '').'. It goes in later, nearer the door. Load stop '.$early['nextStop'].' first.', $tripinvoice->invdata);

            return;
        }
        $this->forceLoad = false;

        app(TripAssignment::class)->markLoaded($tripinvoice, atHub: static::$atHub);
        $tripinvoice->forceFill(['loaded_by' => Auth::id(), 'loaded_at' => now()])->saveQuietly();
        $this->spot = TripSorter::zoneMap($trip)[$tripinvoice->id] ?? null;
        // One container, more hubs: the hub that unloads last goes deep inside.
        if (! $this->spot && ! static::$atHub && \App\Support\Shipping\Shipments::ready()) {
            $this->spot = \App\Support\Shipping\Shipments::loadZone($trip->id);
        }
        if ($tripinvoice->invdata) {
            $this->setInfo = BoxSets::onTrip($tripinvoice->invdata, $trip, $this->tripColumn(), $this->loadedColumn());
        }

        $done = $sameOnTrip > 1 ? Tripinvoice::where($this->tripColumn(), $trip->id)->where('invoice', $code)->where($this->loadedColumn(), true)->count() : 0;
        $this->scanResult('success', "{$code} loaded".\App\Support\Boxes\SameNumber::suffix($done, $sameOnTrip).($sameOnTrip > $done && $sameOnTrip > 1 ? ': scan the other one too' : '').'.', $tripinvoice->invdata);
    }

    /** The box's section is for another partner hub than the one this trip goes to. */
    protected function wrongHubFor(Deliverylog $trip, Tripinvoice $tripinvoice): ?array
    {
        $section = $tripinvoice->invdata?->whSection;
        $to = static::$atHub ? null : $trip->assigned_to;
        if (! $section || ! $section->logistichub_id || ! $to || (int) $section->logistichub_id === (int) $to) {
            return null;
        }

        return ['code' => $tripinvoice->invoice, 'for' => $section->name ?: $section->goesTo(), 'section' => $section->code, 'color' => $section->color,
            'trip' => $trip->destination?->hub_name ?? 'another hub'];
    }

    /**
     * Trip by city, every waiting box of its cities loaded, and room left: the best nearby city to top up with.
     *
     * @return array{room: int, key: string, city: string, province: string, boxes: int, days: int, section: ?string}|null
     */
    public function cityTopUp(): ?array
    {
        $trip = $this->selectedTrip();
        if (! $trip || static::$atHub || $trip->is_lock || ! \App\Support\Trips\CityTrips::isCityTrip($trip)) {
            return null;
        }
        $mine = \App\Models\TripCity::where('deliverylog_id', $trip->id)->get();
        $keys = $mine->map(fn ($c) => \Illuminate\Support\Str::lower((string) $c->province).'|'.$c->city_key)->flip();
        $ct = new \App\Support\Trips\CityTrips(Auth::user());
        $places = $ct->places();
        if ($places->contains(fn ($p) => isset($keys[$p['key']])) || ! Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->exists()) {
            return null; // still boxes of its own cities to load
        }
        $cap = \App\Support\Trips\TripSpace::capacity($trip) ?? \App\Support\TruckSpace::capacity($trip->truck);
        $room = (int) floor($cap - \App\Support\Trips\TripSpace::used($trip));
        if ($room < 5) {
            return null;
        }
        $covered = $ct->covered();
        $prov = \Illuminate\Support\Str::lower((string) $mine->first()?->province);
        $best = $places->reject(fn ($p) => $p['unclear'] || isset($keys[$p['key']]) || isset($covered[$p['key']]) || $p['space'] > $room)
            ->sortBy(fn ($p) => [\Illuminate\Support\Str::lower($p['province']) === $prov ? 0 : 1, -$p['days'], -$p['boxes']])->first();
        if (! $best) {
            return null;
        }
        $section = Invoice::where('is_verified', true)->where('is_assigned', false)->where('receiver_city', 'like', '%'.\Illuminate\Support\Str::before($best['city'], ' ').'%')
            ->whereNotNull('wh_section_id')->with('whSection')->first()?->whSection?->code;

        return ['room' => $room, 'key' => $best['key'], 'city' => $best['city'], 'province' => $best['province'], 'boxes' => $best['boxes'], 'days' => $best['days'], 'section' => $section,
            'same' => \Illuminate\Support\Str::lower($best['province']) === $prov];
    }

    /** Add the suggested city: its boxes join when scanned. */
    public function addTopUpCity(string $key): void
    {
        $trip = $this->selectedTrip();
        $top = $this->cityTopUp();
        if (! $trip || ! $top || $top['key'] !== $key) {
            Notification::make()->title('That top-up is not possible any more.')->warning()->send();

            return;
        }
        \App\Models\TripCity::create(['deliverylog_id' => $trip->id, 'province' => $top['province'], 'city' => $top['city'],
            'city_key' => \Illuminate\Support\Str::after($key, '|'), 'planned_boxes' => $top['boxes']]);
        Notification::make()->title($top['city'].' added to '.$trip->trip_number.': scan its '.$top['boxes'].' boxes'.($top['section'] ? ' (section '.$top['section'].')' : ''))->success()->send();
    }

    /** Customers whose boxes are not all on the truck, for the Done screen. */
    public function openSets(): array
    {
        $trip = $this->selectedTrip();

        return $trip ? BoxSets::openOnTrip($trip, $this->tripColumn(), $this->loadedColumn()) : [];
    }

    /** Why a box of a set stays behind. */
    public function recordSplit(int $invoiceId, string $reason): bool
    {
        $trip = $this->selectedTrip();
        if (! $trip || ! array_key_exists($reason, SetSplit::REASONS)) {
            return false;
        }
        $ok = collect($this->openSets())->pluck('missing')->flatten(1)->contains('id', $invoiceId);
        if (! $ok) {
            return false;
        }
        $need = \App\Support\Trips\TripRules::need('split_set', Auth::user(), $trip->id, $invoiceId);
        $ctx = ['trip_id' => $trip->id, 'trip_number' => $trip->trip_number, 'invoice_id' => $invoiceId, 'box' => Invoice::whereKey($invoiceId)->value('invoice'), 'data' => ['split' => $reason]];
        if ($need === 'office') {
            \App\Support\Trips\TripRules::ask('split_set', Auth::user(), SetSplit::REASONS[$reason], $ctx);

            return true;
        }
        if ($need === 'reason' && ! SetSplit::where('invoice_id', $invoiceId)->where('deliverylog_id', $trip->id)->exists()) {
            \App\Support\Trips\TripRules::record('split_set', Auth::user(), SetSplit::REASONS[$reason], $ctx);
        }
        $split = SetSplit::updateOrCreate(['invoice_id' => $invoiceId, 'deliverylog_id' => $trip->id],
            ['reason' => $reason, 'user_id' => Auth::id(), 'set_key' => Invoice::whereKey($invoiceId)->value('set_key')]);
        if ($split->wasRecentlyCreated) {
            BoxSets::textRestFollows($split, $trip, $this->tripColumn(), $this->loadedColumn());
        }

        return true;
    }

    /** Who loaded how many boxes on this trip. */
    public function team(): array
    {
        $id = $this->data['deliverylog_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = Tripinvoice::where($this->tripColumn(), $id)->where($this->loadedColumn(), true)->whereNotNull('loaded_by')
            ->selectRaw('loaded_by, count(*) n')->groupBy('loaded_by')->pluck('n', 'loaded_by');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }


    /** What to load next on the selected trip (null when the trip has no sorted stops). */
    public function loadNext(): ?array
    {
        $trip = $this->selectedTrip();

        return $trip ? LoadOrder::next($trip, static::$atHub) : null;
    }

    /** @return array{loaded: int, total: int} */
    public function progress(): array
    {
        $tripId = $this->data['deliverylog_id'] ?? null;

        if (! $tripId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $query = Tripinvoice::where($this->tripColumn(), $tripId);

        return [
            'loaded' => (clone $query)->where($this->loadedColumn(), true)->count(),
            'total' => $query->count(),
            'last' => (clone $query)->where($this->loadedColumn(), true)->max('updated_at'),
        ];
    }

    /**
     * Progress of many trips in one database question (the Scan app trip list).
     *
     * @param  list<int>  $ids
     * @return array<int, array{loaded: int, total: int}>
     */
    public function progressMany(array $ids): array
    {
        if (! $ids) {
            return [];
        }
        $col = $this->tripColumn();
        $loaded = $this->loadedColumn();

        return Tripinvoice::whereIn($col, $ids)->selectRaw("{$col} as t, count(*) as total, sum(case when {$loaded} = 1 then 1 else 0 end) as loaded")
            ->groupBy($col)->toBase()->get()
            ->mapWithKeys(fn ($r) => [(int) $r->t => ['loaded' => (int) $r->loaded, 'total' => (int) $r->total]])->all();
    }

    public function household(): array
    {
        $tripId = (int) ($this->data['deliverylog_id'] ?? 0);

        return $this->householdRows($this->lastInvoice(), function (Invoice $box) use ($tripId): array {
            $onTrip = Tripinvoice::with('deliverylog:id,trip_number')->where('invoice_id', $box->id)->latest('id')->first();

            return [
                'trip' => $onTrip?->deliverylog?->trip_number,
                'done' => (bool) ($onTrip?->{$this->loadedColumn()} && (int) $onTrip->{$this->tripColumn()} === $tripId),
            ];
        });
    }

    public function photoStep(): ?string
    {
        return static::$atHub ? 'hub_load' : 'load';
    }

    public function photoContext(): array
    {
        return [
            'deliverylog_id' => $this->data['deliverylog_id'] ?? null,
            'warehouse_id' => Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        return $this->tripOptionsQuery()->latest('id')->limit(60)->get()
            ->map(fn (Deliverylog $t) => ['id' => $t->id, 'name' => 'Trip '.$t->trip_number, 'active' => (bool) ($t->is_active ?? true),
                'sub' => $t->destination?->hub_name ? 'To '.$t->destination->hub_name : ($t->departure_date ? 'Leaves '.$t->departure_date : null)]);
    }
}
