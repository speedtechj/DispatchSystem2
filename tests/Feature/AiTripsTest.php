<?php

use App\Filament\Company\Pages\Ai\AiTrips;
use App\Filament\Pages\Ai\AiTrips as AdminTrips;
use App\Filament\Warehouse\Pages\Ai\AiTrips as WarehouseTrips;
use App\Models\Ai\AiSetting;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Support\Ai\TripPlanner;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function tripsAi(bool $key = true): void
{
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => $key ? 'sk-ant-test' : null, 'features' => ['trips']]);
    Cache::forget('ai.settings');
}

function box(string $no, string $name, string $brgy, string $city, string $phone, array $extra = []): Invoice
{
    return Invoice::create(array_merge([
        'container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'Sender', 'receiver_name' => $name,
        'receiver_address' => '1 Street', 'receiver_province' => 'Cebu', 'receiver_city' => $city, 'receiver_barangay' => $brgy,
        'receiver_mobile_no' => $phone, 'boxtype' => 'Regular', 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1,
    ], $extra));
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Invoice::where('is_assigned', false)->update(['is_verified' => false]); // only our test boxes are ready
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $hub = $this->admin->logistichub_id;
    Truck::query()->update(['is_assigned' => true]);
    $this->t1 = Truck::create(['plate_no' => 'AAA 111', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => false, 'capacity' => 12, 'category' => 'Truck', 'description' => '6-wheeler', 'registration_no' => 'R1', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    $this->t2 = Truck::create(['plate_no' => 'BBB 222', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => false, 'capacity' => 8, 'category' => 'Truck', 'description' => 'Elf', 'registration_no' => 'R2', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    // Maria: 10 boxes in Basak (must stay together), plus smaller receivers
    foreach (range(1, 10) as $i) {
        box("MAR-{$i}", 'Maria Santos', 'Basak', 'Mandaue City', '09171112222');
    }
    box('JOS-1', 'Jose Ramos', 'Pusok', 'Lapu-Lapu City', '09173334444', ['is_priority' => true]);
    box('JOS-2', 'Jose Ramos', 'Pusok', 'Lapu-Lapu City', '09173334444');
    foreach (range(1, 5) as $i) {
        box("LIZ-{$i}", 'Liza Gomez', 'Lahug', 'Cebu City', '09175556666');
    }
});

it('groups ready boxes per receiver, by province, city and barangay', function () {
    $units = (new TripPlanner($this->admin, 'delivery'))->units();

    expect($units)->toHaveCount(3)
        ->and($units->firstWhere('name', 'Maria Santos')['n'])->toBe(10)
        ->and($units->firstWhere('name', 'Jose Ramos')['prio'])->toBe(1)
        ->and(TripPlanner::placeKey($units->firstWhere('name', 'Liza Gomez')))->toBe('Cebu › Cebu City › Lahug');
});

it('turns the AI plan into trips without splitting a receiver or overfilling a truck, and creates them with system trip numbers', function () {
    tripsAi();
    // the AI puts everything on the small truck: the rules must fix it
    Http::fake(['api.anthropic.com/*' => Http::response(['content' => [['type' => 'text', 'text' => json_encode(['trips' => [
        ['truck_id' => $this->t2->id, 'places' => ['Cebu › Mandaue City › Basak', 'Cebu › Lapu-Lapu City › Pusok'], 'why' => 'Next to each other'],
        ['truck_id' => $this->t1->id, 'places' => ['Cebu › Cebu City › Lahug', 'Cebu › Mandaue City › Basak'], 'why' => 'Cebu City'],
    ], 'note' => 'Two trips.'])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 10, 'output_tokens' => 10]])]);

    $page = Livewire::test(AdminTrips::class)->call('suggest')->assertSee('Draft · nothing created yet')->assertSee('Two trips.');
    $trips = $page->get('trips');

    // Maria's 10 boxes don't fit the 8-box truck, so they are not on trip 1 but together on trip 2
    $units = (new TripPlanner($this->admin, 'delivery'))->units()->keyBy('key');
    $boxesOf = fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units'])->sum(fn ($k) => $units[$k]['n']);
    expect($trips)->toHaveCount(2)
        ->and($boxesOf($trips[0]))->toBe(2)            // Jose (priority) on the small truck
        ->and($boxesOf($trips[1]))->toBe(5 + 0)         // Liza 5; Maria (10) would overfill 12 → waits
        ->and(collect($trips[1]['places'])->pluck('place'))->not->toContain('Cebu › Mandaue City › Basak');

    $hub = Logistichub::find($this->admin->logistichub_id);
    $next = $hub->hub_code.($hub->trip_counter + 1);
    $page->call('create')->assertSee('2 trips created')->assertSee($next);

    $trip = Deliverylog::where('trip_number', $next)->sole();
    expect($trip->truck_id)->toBe($this->t2->id)
        ->and($this->t2->fresh()->is_assigned)->toBeTruthy()
        ->and(Invoice::whereIn('invoice', ['JOS-1', 'JOS-2'])->where('is_assigned', true)->count())->toBe(2)
        ->and(Invoice::where('invoice', 'like', 'MAR-%')->where('is_assigned', true)->count())->toBe(0);
});

it('still makes a draft without a key, by place order', function () {
    tripsAi(key: false);
    Http::fake();
    Livewire::test(AdminTrips::class)->call('suggest')->assertSee('Made without AI')->assertSee('Pusok')->assertSee('Left for later');
    Http::assertNothingSent();
});

it('blocks creating a trip with more boxes than the truck can carry', function () {
    tripsAi(key: false);
    $page = Livewire::test(AdminTrips::class)->call('suggest');
    $page->call('addPlace', 'Cebu › Mandaue City › Basak', 0)->assertSee('too many');
    $page->call('create')->assertSee('more boxes than truck');
    expect(Deliverylog::count())->toBe(1); // only the demo trip
});

it('makes warehouse transfers to another warehouse', function () {
    tripsAi(key: false);
    $other = Warehouse::create(['name' => 'Tarlac Warehouse', 'address' => 'MacArthur Hwy', 'city' => 'Tarlac City', 'province' => 'Tarlac', 'zip_code' => '2300', 'mobile_number' => '0917', 'email' => 't@example.com', 'user_id' => $this->admin->id]);
    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->flushSession();
    $this->actingAs($wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));

    $page = Livewire::test(WarehouseTrips::class)->call('setMode', 'transfer')->call('suggest');
    $page->assertSee('To warehouse');
    $page->call('setDest', 0, $other->id)->call('create')->assertSee('created');

    $t = Whdeliverylog::latest('id')->first();
    expect($t->warehouse_id)->toBe($other->id)->and($t->trip_number)->toStartWith((string) $wh->warehouse_id)
        ->and(Invoice::where('wh_is_assigned', true)->count())->toBeGreaterThan(0);
});

it('lets a partner hub plan its own trips from the boxes at its hub', function () {
    tripsAi(key: false);
    $co = User::where('email', 'company@example.com')->firstOrFail()->replicate();
    $co->email = 'hubstaff@example.com';
    $co->save();
    $hub = Logistichub::find($co->logistichub_id);
    expect($hub->is_company)->toBeTruthy();
    $truck = Truck::create(['plate_no' => 'CEB 4501', 'logistichub_id' => $hub->id, 'is_active' => true, 'is_assigned' => false, 'capacity' => 40, 'category' => 'Truck', 'description' => 'Elf', 'registration_no' => 'R3', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    $trip = Deliverylog::firstOrFail();
    foreach (Invoice::where('invoice', 'like', 'LIZ-%')->get() as $inv) {
        Tripinvoice::create(['deliverylog_id' => $trip->id, 'logistichub_id' => $hub->id, 'invoice' => $inv->invoice, 'invoice_id' => $inv->id, 'is_loaded' => true]);
    }
    $this->flushSession();
    $this->actingAs($co);
    Filament::setCurrentPanel(Filament::getPanel('company'));

    Livewire::test(AiTrips::class)->call('suggest')->assertSee('Lahug')->call('create')->assertSee('1 trip created');

    $hubTrip = Deliverylog::where('truck_id', $truck->id)->sole();
    expect($hubTrip->trip_number)->toStartWith($hub->hub_code)
        ->and(Tripinvoice::where('deliveryloghub_id', $hubTrip->id)->count())->toBe(5);
});
