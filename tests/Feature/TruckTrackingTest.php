<?php

use App\Filament\Delivery\Pages\Dashboard as DriverDashboard;
use App\Filament\Pages\TrackingSettings;
use App\Filament\Pages\TruckDetail;
use App\Filament\Pages\TruckTracking;
use App\Models\AppSetting;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tracking\TruckAlert;
use App\Models\Tracking\TruckPosition;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Maps\TripSorter;
use App\Support\Tracking\AlertChecker;
use App\Support\Tracking\Tracker;
use App\Support\Tracking\TrackSettings;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $hub = $this->admin->logistichub_id;
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Deliverylog::query()->update(['is_active' => false]);
    $this->truck = Truck::create(['plate_no' => 'TRK 777', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 40, 'category' => 'Truck', 'description' => '6-wheeler', 'registration_no' => 'RT', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => $this->driver->id, 'user_id' => $this->admin->id]);
    $this->trip = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $boxes = collect();
    foreach ([['Maria Santos', 'Basak'], ['Liza Gomez', 'Tipolo']] as $i => [$name, $brgy]) {
        $boxes->push(Invoice::create(['container_id' => Container::value('id'), 'invoice' => 'TRK-'.$i, 'sender_name' => 'S', 'receiver_name' => $name, 'receiver_address' => 'Purok 1', 'receiver_province' => 'Cebu', 'receiver_city' => 'Mandaue City', 'receiver_barangay' => $brgy, 'receiver_mobile_no' => '0917000000'.$i, 'boxtype' => 'Regular', 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1]));
    }
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, $boxes);
    TripSorter::sort($this->trip);
    AppSetting::put('maps.start.hub.'.$hub, '10.3300, 123.9000');
});

function pt(float $lat, float $lng, int $minAgo, ?float $speed = null): array
{
    return ['lat' => $lat, 'lng' => $lng, 'speed' => $speed, 'accuracy' => 10, 'at' => now()->subMinutes($minAgo)->getTimestampMs()];
}

it('asks the driver once, then saves locations only during a trip', function () {
    $this->actingAs($this->driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    Livewire::test(DriverDashboard::class)->assertSee('Share your location during trips')->call('agreeTracking')
        ->assertDontSee('Share your location during trips')->assertSee('Sharing location');

    $this->postJson('/delivery-track', ['points' => [pt(10.34, 123.95, 2, 8.9), pt(10.345, 123.955, 1, 9)]])
        ->assertOk()->assertJson(['tracking' => true, 'saved' => 2]);
    expect(TruckPosition::where('truck_id', $this->truck->id)->count())->toBe(2)
        ->and(TruckPosition::first()->speed)->toBe(32.0); // m/s → km/h

    $this->trip->update(['is_active' => false]);
    $this->postJson('/delivery-track', ['points' => [pt(10.35, 123.96, 0)]])->assertJson(['tracking' => false]);
    expect(TruckPosition::count())->toBe(2);
});

it('takes locations from a GPS tracker link, by plate number', function () {
    $token = TrackSettings::trackerToken();
    $this->get("/track/in/{$token}?id=TRK777&lat=10.33&lon=123.91&speed=40")->assertOk()->assertJson(['saved' => 1]);
    $this->post("/track/in/{$token}", ['id' => 'TRK 777', 'lat' => 10.331, 'lon' => 123.912])->assertOk();
    $this->get('/track/in/wrong?id=TRK777&lat=1&lon=1')->assertNotFound();
    expect(TruckPosition::where('source', 'tracker')->count())->toBe(2);
});

it('shows the trucks on a trip, what they are doing, and opens one truck', function () {
    $this->driver->update(['tracking_consent_at' => now()]);
    TruckPosition::insert([
        ['truck_id' => $this->truck->id, 'deliverylog_id' => $this->trip->id, 'lat' => 10.33, 'lng' => 123.90, 'speed' => 30, 'source' => 'app', 'recorded_at' => now()->subMinutes(10)],
        ['truck_id' => $this->truck->id, 'deliverylog_id' => $this->trip->id, 'lat' => 10.34, 'lng' => 123.93, 'speed' => 32, 'source' => 'app', 'recorded_at' => now()->subSeconds(20)],
    ]);
    $card = Tracker::card($this->trip);
    expect($card['state'])->toBe('Moving · 32 km/h')->and($card['kind'])->toBe('ok')->and($card['driver'])->toBe($this->driver->full_name);

    $this->get(TruckTracking::getUrl())->assertOk()->assertSee('TRK 777')->assertSee('Moving · 32 km/h')->assertSee('Open truck');
    Livewire::test(TruckTracking::class)->call('pick', $this->truck->id)->assertDispatched('truck-map')->call('setTab', 'replay')->assertSee('Replay today');

    $this->get(TruckDetail::getUrl(['truck' => $this->truck->id]))->assertOk()->assertSee('Today, step by step')->assertSee('Driven today')->assertSee('Left');
    Livewire::withQueryParams(['truck' => $this->truck->id])->test(TruckDetail::class)
        ->call('setTab', 'history')->assertSee($this->trip->trip_number)->assertSee('Replay')
        ->call('replay', $this->trip->id)->assertDispatched('truck-map');
});

it('raises alerts for a long stop away from the stops and for no location, and closes them', function () {
    foreach (range(40, 0, -5) as $m) {
        TruckPosition::create(['truck_id' => $this->truck->id, 'deliverylog_id' => $this->trip->id, 'lat' => 10.40, 'lng' => 123.80, 'speed' => 0, 'source' => 'app', 'recorded_at' => now()->subMinutes($m)]);
    }
    expect(AlertChecker::run())->toBeGreaterThanOrEqual(1);
    $alert = TruckAlert::where('kind', 'stopped')->first();
    expect($alert)->not->toBeNull()->and($alert->ended_at)->toBeNull()
        ->and($this->admin->fresh()->notifications()->count())->toBeGreaterThan(0);

    // later: no location for 40 minutes
    TruckPosition::query()->update(['recorded_at' => now()->subMinutes(80)]);
    AlertChecker::run();
    expect(TruckAlert::where('kind', 'no_signal')->whereNull('ended_at')->exists())->toBeTrue()
        ->and($alert->fresh()->ended_at)->not->toBeNull();

    Livewire::withQueryParams(['truck' => $this->truck->id, 'tab' => 'alerts'])->test(TruckDetail::class)
        ->assertSee('No location')->set('notes.'.$alert->id, 'Lunch break')->call('check', $alert->id);
    expect($alert->fresh()->note)->toBe('Lunch break')->and($alert->fresh()->checked_by)->toBe($this->admin->id);

    $this->trip->update(['is_active' => false]);
    AlertChecker::run();
    expect(TruckAlert::whereNull('ended_at')->count())->toBe(0);
});

it('shows a partner hub only its own trucks', function () {
    $co = User::where('email', 'company@example.com')->firstOrFail();
    expect(Tracker::hubFor($co, 'company'))->toBe((int) $co->logistichub_id)
        ->and(Tracker::activeTrips(Tracker::hubFor($co, 'company'))->pluck('id'))->not->toContain($this->trip->id)
        ->and(Tracker::hubFor($this->admin, 'admin'))->toBeNull();

    $this->flushSession();
    $this->actingAs($co);
    Filament::setCurrentPanel(Filament::getPanel('company'));
    $this->get(App\Filament\Company\Pages\TruckTracking::getUrl())->assertOk()->assertDontSee('TRK 777');
    $this->get(App\Filament\Company\Pages\TruckDetail::getUrl(['truck' => $this->truck->id]))->assertNotFound();
})->skip(fn () => Logistichub::count() < 2, 'needs two hubs');

it('saves the tracking settings', function () {
    Livewire::test(TrackingSettings::class)->assertSee('Tracker link')
        ->set('sources.'.$this->truck->id, 'tracker')->set('values.interval', '60')->set('values.stopped', '30')
        ->call('save')->assertHasNoErrors();
    expect(TrackSettings::source($this->truck->id))->toBe('tracker')->and(TrackSettings::int('interval'))->toBe(60)->and(TrackSettings::int('stopped'))->toBe(30);

    // a truck with a tracker does not take phone locations
    $this->driver->update(['tracking_consent_at' => now()]);
    $this->actingAs($this->driver)->postJson('/delivery-track', ['points' => [pt(10.34, 123.95, 0)]])->assertJson(['tracking' => false]);
});
