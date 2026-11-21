<?php

namespace App\Filament\Shared\Trips;

use App\Models\Ai\AiSetting;
use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Support\Ai\Ai;
use App\Support\Ai\AiAccess;
use App\Support\Hubs\HubAreas;
use App\Support\Sms\SmsSettings;
use App\Support\Tracking\Tracker;
use App\Support\Trips\CityTrips;
use App\Support\Trips\TripRules;
use App\Support\Warehouses\Coverage;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;

/** Plan trips by city: the AI groups nearby cities into truckloads; Create puts the boxes on the trips. */
class PlanTripsPage extends Page
{
    protected string $view = 'filament.trips.plan';

    protected static ?string $slug = 'plan-trips';

    protected static ?string $title = 'Plan trips';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-sparkles';

    public string $day = 'today';

    public string $date = '';

    public string $ask = 'oldest';

    public string $instruction = '';

    public array $trips = [];

    public ?int $kept = null;

    public string $note = '';

    public bool $ai = false;

    public string $open = '';

    public array $made = [];

    public ?string $given = null;

    /** Reason for changing the AI plan (trip rules: Change the AI plan). */
    public string $planReason = '';

    /** A partner hub plans its own trips (Partner hub panel): direct to customers of its area only. */
    protected static bool $atHub = false;

    /** Direct to customers, or To hubs. */
    public string $tab = 'direct';

    /** Cities of a hub's area delivered direct instead ("hubId|province|city"). */
    public array $direct = [];

    /** Waiting for a reason: deliver this hub city direct ("hubId|province|city"). */
    public ?string $askDirect = null;

    public array $hubPlan = [];

    /** @var array<int, string> hub id => made|wait */
    public array $hubState = [];

    /** @var array<int, string> hub id => now|later (Trip 2 and more) */
    public array $hubWhen = [];

    /** @var array<int, string> hub id => message after Create */
    public array $hubMade = [];

    public static function canAccess(): bool
    {
        $u = Auth::user();

        return CityTrips::ready() && $u?->logistichub_id && Tracker::hubFor($u, Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    /** One per request: every list is read once per click. */
    protected ?CityTrips $cityMemo = null;

    protected function city(): CityTrips
    {
        if (! $this->cityMemo) {
            $this->cityMemo = new CityTrips(Auth::user(), static::$atHub);
            $this->cityMemo->direct = $this->direct;
        }

        return $this->cityMemo;
    }

    public function mount(): void
    {
        $this->date = today()->toDateString();
        $this->replan();
        $this->open = Str::lower((string) ($this->trips[0]['province'] ?? ''));
    }

    public function topProvince(): ?string
    {
        return $this->city()->places()->groupBy('province')->map->sum('boxes')->sortDesc()->keys()->reject(fn ($p) => $p === 'No province')->first();
    }

    public function replan(): void
    {
        $plan = $this->city()->plan([
            'first' => $this->ask === 'first' ? $this->topProvince() : null,
            'keep' => $this->ask === 'keep', 'full' => $this->ask === 'full',
            'instruction' => trim($this->instruction),
        ]);
        $this->trips = $plan['trips'];
        $this->kept = $plan['kept'];
        $this->note = $plan['note'];
        $this->ai = $plan['ai'];
        $this->replanHubs();
    }

    protected function replanHubs(): void
    {
        $used = collect($this->trips)->where('on', true)->pluck('truck_id')->filter()->values()->all();
        $this->hubPlan = HubAreas::ready() && ! static::$atHub ? json_decode(json_encode($this->city()->planHubs($used)), true) : [];
        foreach ($this->hubPlan as $h) {
            $this->hubWhen[$h['hub']] ??= collect($h['trips'])->contains('when', 'later') ? 'later' : 'now';
        }
    }

    public function setTab(string $t): void
    {
        $this->tab = $t === 'hubs' ? 'hubs' : 'direct';
    }

    public function setWhen(int $hub, string $when): void
    {
        $this->hubWhen[$hub] = $when === 'later' ? 'later' : 'now';
    }

    public function waitHub(int $hub): void
    {
        $this->hubState[$hub] = 'wait';
    }

    public function makeHub(int $hub): void
    {
        $h = collect($this->hubPlan)->firstWhere('hub', $hub);
        if (! $h) {
            return;
        }
        $trips = ($this->hubWhen[$hub] ?? 'now') === 'later' ? array_slice($h['trips'], 0, 1) : $h['trips'];
        try {
            $this->city()->made = [];
            $made = $this->city()->createHub($hub, $trips, Carbon::parse($this->date ?: today()), $h['tip']);
        } catch (\Throwable $e) {
            report($e);
            Notification::make()->title('Could not create the trip')->body($e->getMessage())->danger()->send();

            return;
        }
        $nums = collect($made)->pluck('number')->join(' and ');
        $later = count($h['trips']) - count($trips);
        $this->hubState[$hub] = 'made';
        $this->hubMade[$hub] = '✓ '.$nums.' to '.$h['name'].($later ? ' now · the rest shows again tomorrow' : ' · the hub sees '.(count($made) > 1 ? 'them' : 'it').' in Incoming boxes');
        Notification::make()->title(count($made).' '.Str::plural('trip', count($made)).' to '.$h['name'].' created')->body($nums)->success()->send();
    }

    /** "Deliver direct instead": a hub city moves to the Direct tab (with a reason, per the trip rules). */
    public function askDirectCity(int $hub, string $key): void
    {
        $need = TripRules::need('direct_hub', Auth::user());
        if ($need === 'office') {
            Notification::make()->title('Only the office can deliver a hub’s boxes direct')->warning()->send();

            return;
        }
        $this->askDirect = $hub.'|'.$key;
        if ($need === 'free') {
            $this->directWith('');
        }
    }

    public function directWith(string $reason): void
    {
        if (! $this->askDirect) {
            return;
        }
        [$hub, $p, $c] = array_pad(explode('|', $this->askDirect, 3), 3, '');
        TripRules::record('direct_hub', Auth::user(), $reason ?: null, ['note' => Str::title($c).', '.Str::title($p).': '.HubAreas::name((int) $hub).' → direct']);
        $this->direct[] = $this->askDirect;
        $this->direct = array_values(array_unique($this->direct));
        $this->askDirect = null;
        $this->cityMemo = null;
        $this->made = [];
        $this->replan();
    }

    public function cancelDirect(): void
    {
        $this->askDirect = null;
    }

    public function toggleSms(int $i): void
    {
        if (isset($this->trips[$i])) {
            $this->trips[$i]['sms'] = ! ($this->trips[$i]['sms'] ?? true);
        }
    }

    public function setAsk(string $k): void
    {
        $this->ask = in_array($k, ['oldest', 'first', 'keep', 'full'], true) ? $k : 'oldest';
        $this->instruction = '';
        $this->made = [];
        $this->replan();
    }

    public function askAi(): void
    {
        $this->made = [];
        $this->replan();
        if (filled($this->instruction) && ! $this->ai) {
            Notification::make()->title('Planned without AI')->body(Ai::whyOff('trips') ?: $this->note)->warning()->send();
        }
    }

    public function setDay(string $d): void
    {
        $this->day = in_array($d, ['today', 'tomorrow', 'date'], true) ? $d : 'today';
        if ($this->day !== 'date') {
            $this->date = ($this->day === 'tomorrow' ? today()->addDay() : today())->toDateString();
        }
    }

    /** Trip rules: may this person change the AI plan? */
    protected function mayChange(): bool
    {
        if (TripRules::need('change_plan', Auth::user()) === 'office') {
            Notification::make()->title('Only the office can change the AI plan')->body('Ask an admin, or create the trips as suggested.')->warning()->send();

            return false;
        }

        return true;
    }

    public function toggleTrip(int $i): void
    {
        if (isset($this->trips[$i]) && empty($this->trips[$i]['madeAs']) && $this->mayChange()) {
            $this->trips[$i]['on'] = ! $this->trips[$i]['on'];
            $this->trips[$i]['changed'] = true;
            $this->trips[$i]['changedNote'] = $this->trips[$i]['on'] ? 'Switched off, then on again' : 'Switched off';
            $this->made = [];
        }
    }

    /** Top-up: the city picked in a trip's suggestion box. */
    public function pickTop(int $i, string $key): void
    {
        if (isset($this->trips[$i])) {
            $this->trips[$i]['topPick'] = $key;
        }
    }

    public function addTop(int $i): void
    {
        $t = $this->trips[$i] ?? null;
        $opt = $t ? collect($this->topOptions($i))->firstWhere('key', $t['topPick'] ?? null) ?? collect($this->topOptions($i))->first() : null;
        if (! $opt) {
            return;
        }
        $this->trips[$i]['cities'][] = ['city' => $opt['city'], 'key' => $opt['key'], 'boxes' => $opt['boxes'], 'space' => $opt['space'], 'province' => $opt['province']];
        $this->trips[$i]['load'] += $opt['space'];
        $this->trips[$i]['topped'] = $opt['city'].($opt['province'] !== $t['province'] ? ', '.$opt['province'] : '').' added · '.$opt['boxes'].' '.Str::plural('box', $opt['boxes']).' · now about '.$this->trips[$i]['load'].' of '.$t['cap'].' space';
        $this->made = [];
    }

    public function skipTop(int $i): void
    {
        if (isset($this->trips[$i])) {
            $this->trips[$i]['noTop'] = true;
        }
    }

    /** Waiting cities that fit the room left on trip $i: same province first. */
    public function topOptions(int $i): array
    {
        $t = $this->trips[$i] ?? null;
        $room = $t ? $t['cap'] - $t['load'] : 0;
        if (! $t || ! $t['on'] || $room < 5 || ! empty($t['noTop']) || ! empty($t['topped'])) {
            return [];
        }
        $c = $this->city();
        $taken = collect($this->trips)->flatMap(fn ($x) => collect($x['cities'])->pluck('key'))->flip();
        $covered = $c->covered();

        return $c->places()->reject(fn ($p) => $p['unclear'] || isset($taken[$p['key']]) || isset($covered[$p['key']]) || $p['space'] > $room)
            ->sortBy(fn ($p) => [Str::lower($p['province']) === Str::lower($t['province']) ? 0 : 1, -$p['days'], -$p['boxes']])
            ->take(2)->values()->map(fn ($p) => $p + ['same' => Str::lower($p['province']) === Str::lower($t['province'])])->all();
    }

    public function toggleOpen(string $p): void
    {
        $this->open = $this->open === $p ? '' : $p;
    }

    /** Truck button: free trucks, then trucks still out (the trip waits), then no truck yet. */
    public function cycleTruck(int $i): void
    {
        if (! isset($this->trips[$i]) || ! $this->mayChange()) {
            return;
        }
        $this->trips[$i]['changed'] = true;
        $trucks = $this->city()->trucks();
        $usedFree = collect($this->trips)->except($i)->where('on', true)->pluck('truck_id')->filter()->all();
        $options = $trucks->where('state', 'free')->reject(fn ($t) => $t['id'] === $this->kept || in_array($t['id'], $usedFree, true))->pluck('id')
            ->merge($trucks->where('state', 'busy')->pluck('id'))->push(null)->values();
        $at = $options->search($this->trips[$i]['truck_id'], true);
        $n = ($at === false ? -1 : $at) + 1;
        $next = $options->has($n) ? $options[$n] : $options[0];
        $plate = fn ($id) => $id ? ($trucks->firstWhere('id', $id)['plate'] ?? '#'.$id) : 'no truck';
        $this->trips[$i]['changedNote'] = 'Truck '.$plate($this->trips[$i]['changedFrom'] ??= $this->trips[$i]['truck_id']).' → '.$plate($next);
        $this->trips[$i]['truck_id'] = $next;
        $this->trips[$i]['cap'] = $next ? ($trucks->firstWhere('id', $next)['capacity'] ?? CityTrips::DEFAULT_CAPACITY) : CityTrips::DEFAULT_CAPACITY;
        $this->made = [];
    }

    /** Create every trip switched on (Create all). */
    public function create(): void
    {
        $this->createTrips(collect($this->trips)->filter(fn ($t) => empty($t['madeAs']))->all(), true);
    }

    /** Create only this trip (board 46): the other trips stay as they are. */
    public function createOne(int $i): void
    {
        if (! isset($this->trips[$i]) || ! empty($this->trips[$i]['madeAs'])) {
            return;
        }
        $made = $this->createTrips([$i => ['on' => true] + $this->trips[$i]], false);
        if ($made) {
            $m = $made[0];
            $this->trips[$i]['madeAs'] = ['id' => $m['id'], 'number' => $m['number'],
                'boxes' => Tripinvoice::where(fn ($q) => $q->where('deliverylog_id', $m['id'])->orWhere('deliveryloghub_id', $m['id']))->count()];
            $this->trips[$i]['on'] = false;
        }
    }

    /** @return list<array{id: int, number: string, truck: ?string}> */
    protected function createTrips(array $trips, bool $all): array
    {
        $date = Carbon::parse($this->date ?: today());
        $changed = collect($trips)->filter(fn ($t) => ! empty($t['changed']));
        if ($changed->isNotEmpty() && TripRules::need('change_plan', Auth::user()) === 'reason') {
            if (! in_array($this->planReason, TripRules::reasons(), true)) {
                Notification::make()->title('Pick why you changed the AI plan')->warning()->send();

                return [];
            }
            foreach ($changed as $t) {
                TripRules::record('change_plan', Auth::user(), $this->planReason, ['note' => $t['province'].' › '.collect($t['cities'])->pluck('city')->join(', ').($t['on'] ? '' : ' (switched off)')]);
            }
        }
        $this->city()->made = ['ai' => $this->ai, 'instruction' => trim($this->instruction), 'reason' => $this->planReason];
        try {
            $made = $this->city()->create(array_values($trips), $date);
        } catch (\Throwable $e) {
            report($e);
            Notification::make()->title('Could not create the trips')->body($e->getMessage())->danger()->send();

            return [];
        }
        if ($made) {
            Notification::make()->title(count($made) === 1 && ! $all ? 'Trip '.$made[0]['number'].' created with its boxes · the other trips stay here'
                : count($made).' '.Str::plural('trip', count($made)).' created')->success()->send();
        }
        if ($all) {
            $this->made = $made;
            $this->replan();
            $this->made = $made;
        }

        return $made;
    }

    public function give(int $tripId, int $truckId): void
    {
        $trip = Deliverylog::where('logistichub_id', Auth::user()->logistichub_id)->whereNull('truck_id')->findOrFail($tripId);
        $truck = $this->city()->give($trip, $truckId);
        $this->given = $truck->plate_no.' is on '.$trip->trip_number.' '.($trip->cities()->first()?->province ?? '');
        $this->replan();
    }

    protected function getViewData(): array
    {
        $c = $this->city();
        $places = $c->places();
        $covered = $c->covered();
        $draft = collect($this->trips)->where('on', true)->flatMap(fn ($t) => collect($t['cities'])->pluck('key'))->flip();
        $trucks = $c->trucks();
        $byId = $trucks->keyBy('id');
        $waitingTrips = $c->waitingForTruck();
        $freeTruck = $trucks->where('state', 'free')->reject(fn ($t) => $t['id'] === $this->kept)->first();
        $provinces = $places->reject(fn ($p) => $p['unclear'])->groupBy('province')->map(fn ($g, $p) => [
            'key' => Str::lower($p), 'name' => $p, 'boxes' => $g->sum('boxes'), 'days' => $g->max('days'),
            'planned' => $g->contains(fn ($x) => isset($draft[$x['key']]) || isset($covered[$x['key']])),
            'trip' => $g->map(fn ($x) => $covered[$x['key']] ?? null)->filter()->unique()->join(', '),
            'cities' => $g->sortByDesc('days')->values(),
        ])->sortByDesc('days')->values();
        $addrPage = str_replace('PlanTrips', 'AddressesToCheck', static::class);
        $here = (int) Auth::user()->warehouse_id;
        $out = $here && Coverage::active() ? Coverage::waitingTransfer($here)->countBy('home') : collect();
        $trPage = str_replace('PlanTrips', 'WarehouseTransfers', static::class);

        return [
            'provinces' => $provinces, 'max' => max(1, $provinces->max('boxes') ?? 1), 'waitTotal' => $places->sum('boxes'),
            'unclear' => $places->where('unclear', true)->sum('boxes'),
            'addrUrl' => static::class !== self::class && class_exists($addrPage) && $addrPage::canAccess() ? $addrPage::getUrl(['show' => 'all']) : null,
            'covered' => $covered, 'draft' => $draft,
            'cards' => collect($this->trips)->map(function ($t, $i) use ($byId) {
                $truck = $t['truck_id'] ? ($byId[$t['truck_id']] ?? null) : null;
                $pct = $t['cap'] ? min(100, (int) round($t['load'] / $t['cap'] * 100)) : 0;

                return $t + ['i' => $i, 'truck' => $truck, 'pct' => $pct, 'path' => collect($t['cities'])->pluck('city')->join(', ')];
            }),
            'onTrips' => collect($this->trips)->where('on', true)->filter(fn ($t) => empty($t['madeAs'])),
            'leftTrips' => collect($this->trips)->filter(fn ($t) => empty($t['madeAs']))->count(),
            'tripsPage' => collect(Filament::getCurrentPanel()?->getResources() ?? [])->first(fn ($r) => class_basename($r) === 'DeliverylogResource'),
            'trucks' => $trucks, 'kept' => $this->kept,
            'waitingTrips' => $waitingTrips, 'freeTruck' => $freeTruck,
            'unload' => $c->unloadingNow(),
            'top' => $this->topProvince(),
            'aiOn' => Ai::enabled('trips'),
            // on for the company, but this person is not picked (Settings → AI → Who can use AI)
            'aiHidden' => AiSetting::current()->isOn('trips') && ! AiAccess::allows('trips'),
            'tops' => collect($this->trips)->keys()->mapWithKeys(fn ($i) => [$i => $this->topOptions($i)])->all(),
            'sets' => collect($this->trips)->map(fn ($t) => $t['on'] ? $c->sets(collect($t['cities'])->pluck('key')->all()) : [])->all(),
            'changedAny' => collect($this->trips)->contains(fn ($t) => ! empty($t['changed'])),
            'needPlan' => TripRules::need('change_plan', Auth::user()),
            'reasons' => TripRules::reasons(),
            'transferOut' => $out->map(fn ($n, $w) => ['n' => $n, 'name' => Coverage::name((int) $w)])->values(),
            'arriving' => $here && Coverage::active() ? Coverage::arriving($here) : 0,
            'trUrl' => static::class !== self::class && class_exists($trPage) ? $trPage::getUrl() : null,
            'smsOn' => SmsSettings::on(static::$atHub ? 'out_for_delivery_hub' : 'out_for_delivery'),
            'smsUrl' => class_exists(\App\Filament\Pages\SmsSettings::class) && Filament::getCurrentPanel()?->getId() === 'admin' ? \App\Filament\Pages\SmsSettings::getUrl() : null,
            'hubsOn' => ! static::$atHub && HubAreas::ready() && HubAreas::hubs()->isNotEmpty(),
            'atHub' => static::$atHub, 'notMine' => $c->notMine(),
            'hubName' => static::$atHub ? Logistichub::whereKey(Auth::user()->logistichub_id)->value('hub_name') : null,
            'hubBoxes' => collect($this->hubPlan)->sum('boxes'),
            'directBoxes' => $places->reject(fn ($p) => $p['unclear'])->sum('boxes'),
            'hubColors' => ['#1d6fb8', '#c97a00', '#17895e', '#7a4fd6', '#c2410c', '#0e7490'],
        ];
    }
}
