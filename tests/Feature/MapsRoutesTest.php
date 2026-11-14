<?php

use App\Filament\Delivery\Pages\Dashboard as DriverDashboard;
use App\Filament\Pages\MapsRoutes;
use App\Filament\Pages\Scanload;
use App\Filament\Pages\TripStops;
use App\Filament\Warehouse\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Maps\GeoPlace;
use App\Models\Maps\TripRoute;
use App\Models\Maps\TripStop;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Maps\LoadOrder;
use App\Support\Maps\MapSettings;
use App\Support\Maps\RoutePlanner;
use App\Support\Maps\TripSorter;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

/** Receivers along a line from the warehouse: Ana is farthest, Maria nearest. */
const MAP_PINS = [
    'Basak' => [10.3400, 123.9500],   // Maria (nearest)
    'Tipolo' => [10.3500, 123.9700],  // Liza
    'Pusok' => [10.3600, 123.9900],   // Jose (priority)
    'Gabi' => [10.3700, 124.0100],    // Ana (farthest)
];

function mapBox(string $no, string $name, string $brgy, string $city, string $phone, array $extra = []): Invoice
{
    return Invoice::create(array_merge([
        'container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'Sender', 'receiver_name' => $name,
        'receiver_address' => 'Purok 1', 'receiver_province' => 'Cebu', 'receiver_city' => $city, 'receiver_barangay' => $brgy,
        'receiver_mobile_no' => $phone, 'boxtype' => 'Regular', 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1,
    ], $extra));
}

function fakeGoogle(): void
{
    Http::fake([
        'maps.googleapis.com/maps/api/geocode/*' => function ($request) {
            foreach (MAP_PINS as $brgy => [$lat, $lng]) {
                if (str_contains($request['address'], $brgy)) {
                    return Http::response(['status' => 'OK', 'results' => [['formatted_address' => $brgy.', Cebu', 'geometry' => ['location' => ['lat' => $lat, 'lng' => $lng], 'location_type' => 'ROOFTOP']]]]);
                }
            }

            return Http::response(['status' => 'ZERO_RESULTS', 'results' => []]);
        },
        'maps.googleapis.com/maps/api/directions/*' => fn ($request) => Http::response(['status' => 'OK', 'routes' => [[
            // the map's own order: keep the stops as sent, but say how far it is
            'waypoint_order' => range(0, substr_count($request['waypoints'], '|') - 1),
            'legs' => array_fill(0, substr_count($request['waypoints'], '|') + 1, ['distance' => ['value' => 5000], 'duration' => ['value' => 600]]),
        ]]]),
    ]);
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $hub = $this->admin->logistichub_id;
    $this->truck = Truck::create(['plate_no' => 'MAP 123', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 40, 'category' => 'Truck', 'description' => '6-wheeler', 'registration_no' => 'RM', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    $this->trip = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today()]);

    $boxes = collect();
    foreach (range(1, 3) as $i) {
        $boxes->push(mapBox("MAR-{$i}", 'Maria Santos', 'Basak', 'Mandaue City', '09171112222'));
    }
    $boxes->push(mapBox('LIZ-1', 'Liza Gomez', 'Tipolo', 'Mandaue City', '09175556666'));
    $boxes->push(mapBox('LIZ-2', 'Liza Gomez', 'Tipolo', 'Mandaue City', '09175556666'));
    $boxes->push(mapBox('JOS-1', 'Jose Ramos', 'Pusok', 'Lapu-Lapu City', '09173334444', ['is_priority' => true]));
    foreach (range(1, 3) as $i) {
        $boxes->push(mapBox("ANA-{$i}", 'Ana Reyes', 'Gabi', 'Cordova', '09179998888'));
    }
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, $boxes);
    AppSetting::put('maps.start.hub.'.$hub, '10.3300, 123.9300');
});

it('puts boxes in truck spots: the first third delivered at the door, the last third next to the cab', function () {
    expect(TripSorter::zones([3, 2, 1, 3]))->toBe(['back', 'middle', 'middle', 'front'])
        ->and(TripSorter::zones([1]))->toBe(['middle'])
        ->and(TripSorter::zones([5, 5, 5]))->toBe(['back', 'middle', 'front']);
});

it('sorts by barangay with no map key, one stop per receiver', function () {
    Http::preventStrayRequests();
    $route = TripSorter::sort($this->trip);
    $stops = TripSorter::stops($this->trip);

    expect($route->source)->toBe('barangay')
        ->and($stops)->toHaveCount(4)
        ->and($stops->firstWhere('name', 'Maria Santos')->boxes)->toBe(3)
        ->and($stops->sum('boxes'))->toBe(9)
        ->and($stops->pluck('zone')->first())->toBe('back')
        ->and($stops->pluck('zone')->last())->toBe('front')
        ->and(GeoPlace::where('status', 'pending')->count())->toBe(4); // waiting for a map key, no cost
});

it('finds each address once with a Google key and sorts the stops by road from the start pin', function () {
    MapSettings::putKey('google', 'AIza-test');
    fakeGoogle();

    $route = TripSorter::sort($this->trip);
    $stops = TripSorter::stops($this->trip);

    expect($route->source)->toBe('google')
        ->and($route->km)->toBe(20.0) // 4 legs of 5 km, the drive back left out
        ->and($stops->pluck('name')->all())->toBe(['Maria Santos', 'Liza Gomez', 'Jose Ramos', 'Ana Reyes'])
        ->and($stops->first()->zone)->toBe('back')
        ->and($stops->last()->zone)->toBe('front')
        ->and($stops->every(fn ($s) => $s->hasPin() && $s->exact))->toBeTrue();

    // the next trip reads the saved pins: no new look-ups
    $looked = collect(Http::recorded())->filter(fn ($r) => str_contains($r[0]->url(), 'geocode'))->count();
    TripSorter::sort($this->trip);
    expect(collect(Http::recorded())->filter(fn ($r) => str_contains($r[0]->url(), 'geocode'))->count())->toBe($looked);
});

it('sorts by straight line when the map route fails, and puts a stop without a pin next to its barangay', function () {
    MapSettings::putKey('ors', 'ors-test');
    AppSetting::put('maps.provider', 'google'); // no Google key: falls back to OpenRouteService
    expect(MapSettings::provider())->toBe('ors');
    mapBox('X-1', 'Pedro Cruz', 'Tipolo', 'Mandaue City', '09170000001');
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, Invoice::where('invoice', 'X-1')->get());

    Invoice::where('invoice', 'X-1')->update(['receiver_address' => 'Purok 9 near chapel']);
    // Pedro's address is not found
    Http::fake(['api.openrouteservice.org/geocode/*' => function ($request) {
        if (str_contains($request['text'], 'Purok 9')) {
            return Http::response(['features' => []]);
        }
        foreach (MAP_PINS as $brgy => [$lat, $lng]) {
            if (str_contains($request['text'], $brgy)) {
                return Http::response(['features' => [['geometry' => ['coordinates' => [$lng, $lat]], 'properties' => ['layer' => 'street', 'label' => $brgy]]]]);
            }
        }

        return Http::response(['features' => []]);
    }, 'api.openrouteservice.org/optimization' => Http::response('down', 500)]);

    $route = TripSorter::sort($this->trip);
    $names = TripSorter::stops($this->trip)->pluck('name')->all();

    expect($route->source)->toBe('estimate')
        ->and($names)->toBe(['Maria Santos', 'Liza Gomez', 'Pedro Cruz', 'Jose Ramos', 'Ana Reyes'])
        ->and(GeoPlace::where('status', 'not_found')->count())->toBe(1);
});

it('cleans messy addresses with the AI before the map looks them up', function () {
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => ['addresses']]);
    Cache::forget('ai.settings');
    MapSettings::putKey('google', 'AIza-test');
    Http::fake([
        'api.anthropic.com/*' => fn ($request) => Http::response(['content' => [['type' => 'text', 'text' => json_encode(['addresses' => collect(json_decode($request['messages'][0]['content'], true))
            ->map(fn ($a) => ['i' => $a['i'], 'address' => str_replace('Purok 1', 'Purok 1 (fixed)', $a['address'])])->all()])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]),
    ]);
    fakeGoogle();

    $route = TripSorter::sort($this->trip);

    expect($route->ai_fixed)->toBe(4)
        ->and(GeoPlace::whereNotNull('clean')->count())->toBe(4)
        ->and(collect(Http::recorded())->contains(fn ($r) => str_contains($r[0]->url(), 'geocode') && str_contains($r[0]['address'], '(fixed)')))->toBeTrue();
});

it('keeps the staff order once a stop is dragged, and puts new boxes at the end', function () {
    TripSorter::sort($this->trip);
    $ana = TripStop::where('name', 'Ana Reyes')->first();
    TripSorter::move($this->trip, $ana->id, 0);

    expect(TripSorter::stops($this->trip)->first()->name)->toBe('Ana Reyes')
        ->and(TripSorter::stops($this->trip)->first()->zone)->toBe('back')
        ->and(TripRoute::where('deliverylog_id', $this->trip->id)->value('locked'))->toBeTrue();

    mapBox('NEW-1', 'Carlo Lim', 'Talamban', 'Cebu City', '09170000002');
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, Invoice::where('invoice', 'NEW-1')->get());
    TripSorter::ensure($this->trip);

    expect(TripSorter::stops($this->trip)->pluck('name')->first())->toBe('Ana Reyes')
        ->and(TripSorter::stops($this->trip)->pluck('name')->last())->toBe('Carlo Lim');
});

it('tells the loading crew what to load next and warns about a box that is too early', function () {
    TripSorter::sort($this->trip);
    $next = LoadOrder::next($this->trip);
    $last = TripSorter::stops($this->trip)->last();
    expect($next['stop'])->toBe($last->stop_no)->and($next['zone'])->toBe('front');

    $page = Livewire::test(Scanload::class)->set('data.deliverylog_id', $this->trip->id)->assertSee('Load next');
    $first = TripSorter::stops($this->trip)->first();
    $doorBox = Invoice::find(Tripinvoice::find($first->box_ids[0])->invoice_id)->invoice;

    $page->call('scan', $doorBox);
    $page->assertSet('lastStatus', 'warning')->assertSet('early.code', $doorBox)->assertSee('Too early');
    expect(Tripinvoice::find($first->box_ids[0])->is_loaded)->toBeFalse();

    $page->call('loadAnyway')->assertSet('lastStatus', 'success');
    expect(Tripinvoice::find($first->box_ids[0])->is_loaded)->toBeTrue();

    AppSetting::put('maps.warn_early', 0);
    $page->call('scan', Invoice::find(Tripinvoice::find($first->box_ids[1])->invoice_id)->invoice)->assertSet('lastStatus', 'success');
    AppSetting::put('maps.warn_early', 1);

    $frontBox = Invoice::find(Tripinvoice::find($last->box_ids[0])->invoice_id)->invoice;
    $page->call('scan', $frontBox)->assertSet('lastStatus', 'success')->assertSet('spot.zone', 'front');
});

it('shows the stops page with the map, the truck and the loading list', function () {
    $this->get(TripStops::getUrl(['trip' => $this->trip->id]))->assertOk()->assertSee('Delivery order')->assertSee('Ana Reyes')->assertSee('load #1');
    Livewire::withQueryParams(['trip' => $this->trip->id])->test(TripStops::class)->call('resort')->assertDispatched('trip-map');

    $stops = TripSorter::stops($this->trip);
    $html = $this->get(route('trip.loading-list', $this->trip))->assertOk()->assertSee('Loading list')->getContent();
    expect(strpos($html, 'FRONT'))->toBeLessThan(strpos($html, 'BACK'))
        ->and(strpos($html, $stops->last()->name))->toBeLessThan(strpos($html, $stops->first()->name));
});

it('does not sort a trip that goes to another hub', function () {
    $other = Logistichub::where('id', '!=', $this->admin->logistichub_id)->value('id');
    $this->trip->update(['assigned_to' => $other]);

    expect(TripSorter::ensure($this->trip->fresh()))->toBeNull();
    $this->get(TripStops::getUrl(['trip' => $this->trip->id]))->assertOk()->assertSee('All boxes are one stop');
})->skip(fn () => Logistichub::count() < 2, 'needs two hubs');

it('shows the driver the stops with Navigate, and takes a pin when they cannot find the house', function () {
    TripSorter::sort($this->trip);
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => $driver->id, 'user_id' => $this->admin->id]);
    $this->trip->update(['is_active' => true]);
    $this->actingAs($driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));

    $stop = TripSorter::stops($this->trip)->first();
    Livewire::test(DriverDashboard::class)->assertSee('Your stops')->assertSee('Navigate')->assertSee('Google Maps')->assertSee('Waze')
        ->call('suggestPin', $stop->id, 10.341, 123.951);

    $place = GeoPlace::find($stop->geo_place_id);
    expect($place->suggested_lat)->toBe(10.341);

    // the office uses the driver's pin
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(MapsRoutes::class)->assertSee('Pins from drivers')->call('acceptSuggestion', $place->id);
    expect($place->fresh()->lat)->toBe(10.341)->and($place->fresh()->status)->toBe('manual');
});

it('saves map keys encrypted, tests them, and reads pasted start pins', function () {
    Http::fake(['maps.googleapis.com/*' => Http::response(['status' => 'OK', 'results' => [['formatted_address' => 'Basak, Mandaue City', 'geometry' => ['location' => ['lat' => 10.34, 'lng' => 123.95], 'location_type' => 'APPROXIMATE'], 'partial_match' => true]]])]);

    Livewire::test(MapsRoutes::class)
        ->assertSee('What the system uses now')->assertSee('Barangay order')
        ->set('key', 'AIza-SECRET-123')->call('saveKey')
        ->call('test')->assertSee('The key works')
        ->set('starts.wh:1', '10.3157, 123.8854')->call('saveStarts')
        ->call('toggleAi')->call('togglePriority');

    expect(AppSetting::where('key', 'maps.key.google')->value('value'))->not->toContain('AIza-SECRET')
        ->and(MapSettings::key('google'))->toBe('AIza-SECRET-123')
        ->and(MapSettings::provider())->toBe('google')
        ->and(MapSettings::startPin('wh', 1))->toBe([10.3157, 123.8854])
        ->and(AiSetting::current()->isOn('addresses'))->toBeTrue()
        ->and(MapSettings::priorityFirst())->toBeTrue()
        ->and(MapSettings::parsePin('not a pin'))->toBeNull();
});

it('untangles a straight-line route', function () {
    $order = RoutePlanner::local([0, 0], ['a' => [0, 3], 'b' => [0, 1], 'c' => [0, 2]]);
    expect($order)->toBe(['b', 'c', 'a']);
});

it('gives the warehouse and the partner hub their own Maps & routes page and the stops page, without the keys', function () {
    TripSorter::sort($this->trip);
    $place = GeoPlace::where('status', 'pending')->first();
    $place->update(['status' => 'not_found']);

    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    $wh->update(['logistichub_id' => $this->admin->logistichub_id]);
    $this->actingAs($wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));

    $this->get(App\Filament\Warehouse\Pages\MapsRoutes::getUrl())->assertOk()
        ->assertSee('What the system uses now')->assertSee('set by Admin')->assertDontSee('Paste your Google Maps key');
    Livewire::test(App\Filament\Warehouse\Pages\MapsRoutes::class)
        ->set('pins.'.$place->id, '10.30, 123.90')->call('savePin', $place->id)
        ->set('key', 'AIza-from-warehouse')->call('saveKey');
    expect($place->fresh()->status)->toBe('manual')->and(MapSettings::key('google'))->toBeNull();

    $this->get(App\Filament\Warehouse\Pages\TripStops::getUrl(['trip' => $this->trip->id]))->assertOk()->assertSee('Delivery order');
    Livewire::test(ListDeliverylogs::class)->assertSee('Stops &amp; loading', false);

    // a partner hub only sees places on its own trips
    $co = User::where('email', 'company@example.com')->firstOrFail();
    $this->flushSession(); // a new person signs in
    $this->actingAs($co);
    Filament::setCurrentPanel(Filament::getPanel('company'));
    $this->get(App\Filament\Company\Pages\MapsRoutes::getUrl())->assertOk()->assertSee('Start of every route')->assertDontSee('Purok 1, Basak');
    $place->update(['suggested_lat' => 1, 'suggested_lng' => 1, 'suggested_at' => now()]);
    Livewire::test(App\Filament\Company\Pages\MapsRoutes::class)->call('acceptSuggestion', $place->id)->call('toggleAi');
    expect($place->fresh()->lat)->toBe(10.3)->and((bool) AiSetting::query()->first()?->isOn('addresses'))->toBeFalse();
});

it('saves the stops on the driver phone so Navigate works without signal', function () {
    TripSorter::sort($this->trip);
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => $driver->id, 'user_id' => $this->admin->id]);
    $this->trip->update(['is_active' => true]);

    $data = $this->actingAs($driver)->getJson('/delivery-offline/trip')->assertOk()->json();
    $first = TripSorter::stops($this->trip)->first();

    expect($data['stops'])->toHaveCount(4)
        ->and($data['stops'][0]['no'])->toBe(1)
        ->and($data['stops'][0]['name'])->toBe($first->name)
        ->and($data['stops'][0]['boxes'])->toBe($first->box_ids)
        ->and($data['stops'][0]['go'])->toContain('Philippines'); // no pin yet: the address is sent

    expect(file_get_contents(resource_path('js/driver-offline.js')))->toContain('data-dso="nav"')->toContain('works offline with a downloaded map');
});
