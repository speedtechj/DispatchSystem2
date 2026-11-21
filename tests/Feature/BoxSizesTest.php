<?php

use App\Filament\Pages\Ai\AiTrips as AdminTrips;
use App\Filament\Pages\BoxSizeSettings;
use App\Filament\Scan\Pages\ScanApp;
use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function sizeBox(string $no, string $type, string $name = 'Maria Santos', string $brgy = 'Basak', string $phone = '09171112222'): Invoice
{
    return Invoice::create([
        'container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'Sender', 'receiver_name' => $name,
        'receiver_address' => '1 Street', 'receiver_province' => 'Cebu', 'receiver_city' => 'Mandaue City', 'receiver_barangay' => $brgy,
        'receiver_mobile_no' => $phone, 'boxtype' => $type, 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1,
    ]);
}

function sizeOfName(string $name): BoxSize
{
    return BoxSize::where('name', $name)->firstOrFail();
}

beforeEach(function () {
    (fn () => static::$memo = null)->call(new AppSetting); // kept in memory between tests
    BoxSizes::forget();
    $this->seed(DemoSeeder::class);
    Invoice::query()->update(['boxtype' => 'Medium', 'is_verified' => false]);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
});

it('reads the box types from the manifests, joins spellings, and makes the most common one the normal box', function () {
    foreach (['LARGE', 'Large Box', 'large'] as $i => $t) {
        sizeBox("L{$i}", $t);
    }
    sizeBox('X1', 'X-LARGE');
    sizeBox('X2', 'XL');
    sizeBox('B1', 'Bulilit');

    expect(BoxSizes::key('Large Box'))->toBe('large')
        ->and(BoxSizes::key(' X-LARGE '))->toBe('xlarge')
        ->and(BoxSizes::key('Med. Box'))->toBe('med');

    BoxSizes::sync();
    expect(BoxSize::pluck('name')->sort()->values()->all())->toBe(['Bulilit', 'Large', 'Medium', 'X-Large', 'XL'])
        ->and(sizeOfName('Medium')->is_base)->toBeTrue()
        ->and(sizeOfName('Large')->is_set)->toBeFalse();

    // a second sync adds nothing new
    expect(BoxSizes::sync())->toBe(0);

    // "X-LARGE" and "XL" look like the same box
    $pairs = collect(BoxSizes::lookAlike());
    expect($pairs)->toHaveCount(1)
        ->and($pairs[0]['into']->name)->toBe('XL');
    BoxSizes::join($pairs[0]['from'], $pairs[0]['into']);
    expect(sizeOfName('XL')->spellings)->toContain('xl', 'xlarge')
        ->and(BoxSizes::lookAlike())->toBe([]);
});

it('counts space only once a size is set, and a missing or unknown type is 1', function () {
    sizeBox('L1', 'Large');
    BoxSizes::sync();
    expect(BoxSizes::on())->toBeFalse()           // everything still 1: count boxes as before
        ->and(BoxSizes::spaceOf('Large'))->toBe(1.0);

    BoxSizes::setSpace(sizeOfName('Large'), 1.5);
    expect(BoxSizes::on())->toBeTrue()
        ->and(BoxSizes::spaceOf('LARGE box'))->toBe(1.5)
        ->and(BoxSizes::spaceOf(''))->toBe(1.0)
        ->and(BoxSizes::spaceOf('Never seen'))->toBe(1.0)
        ->and(BoxSizes::fmt(1.5))->toBe('1½')
        ->and(BoxSizes::fmt(0.5))->toBe('½');

    AppSetting::put(BoxSizes::SETTING, '0');
    BoxSizes::forget();
    expect(BoxSizes::on())->toBeFalse()->and(BoxSizes::spaceOf('Large'))->toBe(1.0);
});

it('keeps the real sizes when the normal box changes', function () {
    sizeBox('L1', 'Large');
    sizeBox('X1', 'XL');
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('Large'), 2);
    BoxSizes::setSpace(sizeOfName('XL'), 4);

    BoxSizes::setBase(sizeOfName('Large'));
    expect(sizeOfName('Large')->space)->toBe(1.0)
        ->and(sizeOfName('XL')->space)->toBe(2.0)
        ->and(sizeOfName('Medium')->space)->toBe(0.5)
        ->and(sizeOfName('Medium')->is_base)->toBeFalse();
});

it('fills trucks by space in the AI trip helper', function () {
    Truck::query()->update(['is_assigned' => true]);
    $hub = $this->admin->logistichub_id;
    $truck = Truck::create(['plate_no' => 'SPC 101', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => false, 'capacity' => 10, 'category' => 'Truck', 'description' => 'Elf', 'registration_no' => 'R1', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    // Maria: 4 XL (2 each = 8 space); Jose: 4 Medium (4 space). 8 boxes would fit 10 by count, not by space.
    foreach (range(1, 4) as $i) {
        sizeBox("MX{$i}", 'XL');
        sizeBox("JM{$i}", 'Medium', 'Jose Ramos', 'Basak', '09173334444');
    }
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('XL'), 2);

    $units = (new TripPlanner($this->admin, 'delivery'))->units();
    expect($units->firstWhere('name', 'Maria Santos')['space'])->toBe(8.0)
        ->and($units->firstWhere('name', 'Maria Santos')['n'])->toBe(4);

    AiSetting::query()->delete();
    AiSetting::create(['api_key' => null, 'features' => ['trips']]); // made without AI: same rules
    (fn () => static::$memo = null)->call(new AiSetting);
    $page = Livewire::test(AdminTrips::class)->call('suggest');
    $trips = $page->get('trips');
    $keys = collect($trips)->flatMap(fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units']));
    expect($keys)->toHaveCount(1); // only one receiver fits by space
    $page->assertSee('/ 10')->assertSee('space')->assertSee('Left for later');

    // forcing both on the truck is blocked
    $page->call('addPlace', 'Cebu › Mandaue City › Basak', 0)->assertSee('too much');
    $page->call('create')->assertSee('needs more space than truck SPC 101');
});

it('shows Settings → Box sizes, sets sizes, joins, sets the base and truck space', function () {
    sizeBox('L1', 'LG');
    sizeBox('L2', 'Large');
    $truck = Truck::first();

    $page = Livewire::test(BoxSizeSettings::class)
        ->assertSee('Box types from your manifests')
        ->assertSee('Normal box = 1')
        ->assertSee('New · not set')
        ->assertSee('These look like the same box')
        ->assertSee('Every box type is still 1');

    $lg = sizeOfName('LG');
    $large = sizeOfName('Large');
    $page->call('join', $lg->id, $large->id)->assertDontSee('These look like the same box');
    $page->call('step', $large->id, 1)->call('step', $large->id, 1)->assertSee('2')->assertDontSee('Every box type is still 1');
    expect($large->fresh()->space)->toBe(2.0)->and($large->fresh()->is_set)->toBeTrue()
        ->and(BoxSizes::spaceOf('LG'))->toBe(2.0);

    $page->call('setTruck', $truck->id, 64);
    expect($truck->fresh()->capacity)->toBe(64);
    $page->call('truckStep', $truck->id, 1);
    expect($truck->fresh()->capacity)->toBe(65);

    $page->call('toggle');
    expect(BoxSizes::on())->toBeFalse();

    $this->get('/box-sizes')->assertOk();
    $this->flushSession();
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    $this->get('/box-sizes')->assertForbidden();
});

it('shows the size and the space used while loading in the Scan app', function () {
    $hub = $this->admin->logistichub_id;
    Deliverylog::query()->update(['is_active' => false]);
    $truck = Truck::create(['plate_no' => 'SPC 202', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 20, 'category' => 'Truck', 'description' => 'Elf', 'registration_no' => 'R2', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $a = sizeBox('SX1', 'XL');
    $b = sizeBox('SM1', 'Medium', 'Jose Ramos', 'Basak', '09173334444');
    app(TripAssignment::class)->addToDeliveryTrip($trip, collect([$a, $b]));
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('XL'), 2);

    $space = BoxSizes::tripSpace($trip->fresh());
    expect($space)->toBe(['loaded' => 0.0, 'total' => 3.0, 'cap' => 20, 'reserve' => 0]);

    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)
        ->call('open', 'load')->call('pick', $trip->id)->assertDontSee('0 / 20 space')->call('loadExtras')
        ->assertSee('0 / 20 space')
        ->call('scan', 'SX1')
        ->assertSee('XL · takes 2 space')
        ->assertSee('2 / 20 space');
});

it('lets the AI find look-alikes the simple check misses, using only real box types', function () {
    sizeBox('B1', 'Bulilit');
    sizeBox('S1', 'Small');
    sizeBox('S2', 'Small');
    BoxSizes::sync();
    expect(BoxSizes::lookAlike())->toBe([]);

    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => ['box_sizes']]);
    (fn () => static::$memo = null)->call(new AiSetting);
    $bulilit = sizeOfName('Bulilit');
    $small = sizeOfName('Small');
    Http::fake(fn () => Http::response(['content' => [['type' => 'text', 'text' => json_encode(['same' => [
        ['from_id' => $bulilit->id, 'into_id' => $small->id, 'why' => 'Bulilit means small'],
        ['from_id' => 999, 'into_id' => $small->id, 'why' => 'made up'],
    ]])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]));

    Livewire::test(BoxSizeSettings::class)
        ->call('askAi')
        ->assertSee('“Bulilit” (1) looks like')
        ->assertSee('Bulilit means small')
        ->call('join', $bulilit->id, $small->id);
    expect(BoxSizes::spaceOf('Bulilit'))->toBe(1.0)
        ->and(sizeOfName('Small')->spellings)->toContain('bulilit');
});
