<?php

use App\Filament\Pages\WarehouseSections;
use App\Filament\Scan\Pages\ScanApp;
use App\Filament\Warehouse\Resources\Whdeliverylogs\Pages\ListWhdeliverylogs;
use App\Models\Boxes\SetSplit;
use App\Models\Boxes\WhSection;
use App\Models\Boxes\WhSpot;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\TripOverride;
use App\Models\Truck;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use App\Support\Boxes\Crossdock;
use App\Support\Boxes\Sections;
use App\Support\Boxes\TruckSets;
use App\Support\Trips\TripRules;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Sections::forget();
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    $base = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->user = $base->replicate()->fill(['email' => 'sec-wh@example.com']);
    $this->user->save();
    $this->wade = $base->replicate()->fill(['email' => 'wade2@example.com', 'first_name' => 'Wade']);
    $this->wade->save();
    $this->wh = $this->user->warehouse_id;
    $this->tarlac = Warehouse::create(['name' => 'Tarlac Warehouse', 'address' => 'MacArthur Hwy', 'city' => 'Tarlac City', 'province' => 'Tarlac', 'zip_code' => '2300', 'mobile_number' => '0917', 'email' => 't@example.com', 'user_id' => $this->user->id]);
    $this->main = Logistichub::where('is_company', false)->firstOrFail();
    $this->cebu = Logistichub::where('is_company', true)->firstOrFail();

    $mk = fn ($code, $name, $kind, $prov, $extra = []) => WhSection::create(['warehouse_id' => $this->wh, 'code' => $code, 'name' => $name, 'kind' => $kind, 'provinces' => $prov, 'color' => '#1d6fb8'] + $extra);
    $this->A = $mk('A', 'Manila trucks', 'area', ['Metro Manila', 'Cavite'], ['logistichub_id' => $this->main->id]);
    $this->C = $mk('C', 'Cebu hub', 'area', ['Cebu', 'Bohol'], ['logistichub_id' => $this->cebu->id]);
    $this->T = $mk('T', 'Tarlac', 'area', ['Tarlac', 'Nueva Ecija'], ['to_warehouse_id' => $this->tarlac->id]);
    $this->X = $mk('X', 'Check address', 'check', null);

    $demo = Container::where('warehouse_id', $this->wh)->firstOrFail();
    $this->container = $demo->replicate()->fill(['container_no' => 'MSKU7712040', 'is_unloaded' => false, 'is_active' => true]);
    $this->container->save();
    $other = $demo->replicate()->fill(['container_no' => 'OTHR0000001', 'is_unloaded' => false, 'is_active' => true]);
    $other->save();
    $tpl = Invoice::where('container_id', $demo->id)->firstOrFail();
    $box = function (string $no, string $name, string $province, ?int $container = null) use ($tpl) {
        $b = $tpl->replicate()->fill(['invoice' => $no, 'container_id' => $container ?? $this->container->id, 'receiver_name' => $name, 'receiver_mobile_no' => '0917'.crc32($name),
            'receiver_province' => $province, 'receiver_city' => 'Mandaue City', 'is_verified' => false, 'is_assigned' => false, 'wh_is_assigned' => false, 'is_delivered' => false, 'warehouse_id' => $this->wh, 'verified_by' => null, 'wh_section_id' => null, 'set_key' => null]);
        $b->save();

        return $b;
    };
    $this->maria1 = $box('S-101', 'Maria Santos', 'Province of Cebu');
    $this->maria2 = $box('S-102', 'Maria Santos', 'Cebu');
    $this->liza1 = $box('S-201', 'Liza Gomez', 'Cebu');
    $this->liza2 = $box('S-202', 'Liza Gomez', 'Cebu', $other->id);
    $this->rosa = $box('S-301', 'Rosa Lim', 'Tarlac');
    $this->ben = $box('S-302', 'Ben Uy', 'Nueva Ecija');
    $this->nop = $box('S-401', 'Joy Tan', '');
    $this->otherContainer = $other;
    $this->box = $box;
});

function unload($test)
{
    return Livewire::test(ScanApp::class)->call('open', 'unload')->call('pick', $test->container->id)->call('loadExtras');
}

it('finds the section from the province, and sends unclear addresses to Check address', function () {
    expect(Sections::forInvoice($this->maria1)->code)->toBe('C')
        ->and(Sections::forInvoice($this->rosa)->code)->toBe('T')
        ->and(Sections::forInvoice($this->nop)->code)->toBe('X')
        ->and(Sections::forInvoice($this->nop->replicate()->fill(['receiver_province' => 'Leyte']))->code)->toBe('X')
        ->and(Sections::clean('NCR'))->toBe('metro manila');
});

it('shows the section and the set at unload, and does not count a box twice', function () {
    $this->actingAs($this->user);
    unload($this)->call('scan', 'S-101')
        ->assertSet('status', 'success')->assertSet('route.code', 'C')->assertSee('Cebu hub')
        ->assertSee('box 1 of 2')->assertSee('1 more still in this container')
        ->call('dismiss')->call('scan', 'S-201')->assertSee('in another container')
        ->call('dismiss')->call('scan', 'S-401')->assertSet('route.code', 'X')->assertSee('No province in the address.');

    expect($this->maria1->fresh())->wh_section_id->toBe($this->C->id)->sectioned_at->not->toBeNull()->verified_by->toBe($this->user->id);

    $this->flushSession();
    $this->actingAs($this->wade);
    unload($this)->call('scan', 'S-101')->assertSet('status', 'warning')->assertSee('already verified by '.$this->user->first_name);
    unload($this)->call('scan', 'S-102')->assertSee('All 2 boxes are off the container')->assertSee($this->user->first_name)->assertSee('You');
});

it('loads boxes straight onto the truck the office switched on, and the crew can keep one in its section', function () {
    $this->actingAs($this->user);
    $trip = Whdeliverylog::create(['truck_id' => Truck::value('id'), 'warehouse_id' => $this->tarlac->id, 'user_whid' => $this->wh, 'departure_date' => today(), 'delivery_date' => today(), 'is_active' => true, 'user_id' => $this->user->id]);

    // Not switched on: the Tarlac box goes to its section, as always.
    unload($this)->assertDontSee('is here');

    Crossdock::switchOn($trip);
    unload($this)->assertSee('Truck to Tarlac Warehouse is here')
        ->call('scan', 'S-301')->assertSet('route.kind', 'truck')->assertSee('TRUCK')->assertSee('Already loaded')->assertSee('Put in section instead')
        ->call('dismiss')->call('scan', 'S-302')->assertSet('route.kind', 'truck')
        ->call('putInSection')->assertSet('route.code', 'T')
        ->call('dismiss')->call('scan', 'S-101')->assertSet('route.code', 'C')
        ->call('dismiss')->assertSee('1 on truck');

    expect(Whtripinvoice::where('whdeliverylog_id', $trip->id)->pluck('invoice_id')->all())->toBe([$this->rosa->id])
        ->and(Whtripinvoice::where('invoice_id', $this->rosa->id)->value('is_loaded'))->toBeTruthy()
        ->and($this->ben->fresh()->sectioned_at)->not->toBeNull()
        ->and($this->ben->fresh()->wh_is_assigned)->toBeFalse();

    // Locking the trip switches it off by itself.
    $trip->update(['is_lock' => true]);
    expect($trip->fresh()->truck_here)->toBeFalse()
        ->and(Crossdock::here($this->wh))->toBeEmpty();
});

it('lets the office switch the truck on in the transfer trip, only when a section goes there', function () {
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    $trip = Whdeliverylog::create(['truck_id' => Truck::value('id'), 'warehouse_id' => $this->tarlac->id, 'user_whid' => $this->wh, 'departure_date' => today(), 'delivery_date' => today(), 'is_active' => true, 'user_id' => $this->user->id]);

    Livewire::test(ListWhdeliverylogs::class)
        ->callTableAction('truckHere', $trip);
    expect($trip->fresh()->truck_here)->toBeTrue();

    Livewire::test(ListWhdeliverylogs::class)
        ->assertSee('Here, loading')->callTableAction('truckHere', $trip);
    expect($trip->fresh()->truck_here)->toBeFalse();

    $this->T->update(['to_warehouse_id' => null]);
    Sections::forget();
    Livewire::test(ListWhdeliverylogs::class)
        ->callTableAction('truckHere', $trip)->assertNotified('No section goes to Tarlac Warehouse yet');
    expect($trip->fresh()->truck_here)->toBeFalse();
});

it('on the TRUCK screen shows where the customer\'s other boxes are, and brings one from the section', function () {
    $this->actingAs($this->user);
    $trip = Whdeliverylog::create(['truck_id' => Truck::value('id'), 'warehouse_id' => $this->tarlac->id, 'user_whid' => $this->wh, 'departure_date' => today(), 'delivery_date' => today(), 'is_active' => true, 'user_id' => $this->user->id]);
    $ana1 = ($this->box)('S-501', 'Ana Cruz', 'Tarlac');
    $ana1->forceFill(['is_verified' => true, 'wh_section_id' => $this->T->id, 'sectioned_at' => now()])->save();
    $ana2 = ($this->box)('S-502', 'Ana Cruz', 'Tarlac');
    $ana3 = ($this->box)('S-503', 'Ana Cruz', 'Tarlac', $this->otherContainer->id);
    Crossdock::switchOn($trip);

    unload($this)->call('scan', 'S-502')->assertSet('route.kind', 'truck')
        ->assertSee('Box 1 · S-501: in section T. Bring it to the truck too.')
        ->assertSee('in another container')
        ->assertSee('Bring S-501 from section T')
        ->call('addSetBox', $ana1->id)->assertNotified()
        ->assertSee('added, scan it at the truck door')->assertDontSee('Bring S-501 from section T');

    $row = Whtripinvoice::where('whdeliverylog_id', $trip->id)->where('invoice_id', $ana1->id)->first();
    expect($row)->not->toBeNull()->and((bool) $row->is_loaded)->toBeFalse();

    $open = TruckSets::open($trip);
    expect($open)->toHaveCount(1)
        ->and($open[0]['have'])->toBe(1)->and($open[0]['of'])->toBe(3)
        ->and(collect($open[0]['missing'])->pluck('invoice')->all())->toBe(['S-501', 'S-503'])
        ->and($open[0]['missing'][1]['where'])->toContain('not unloaded yet');

    // Truck left: a reason is needed for each box left behind.
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    Livewire::test(ListWhdeliverylogs::class)
        ->callTableAction('truckHere', $trip, data: ['why' => [$ana1->id => 'not_found']])
        ->assertHasTableActionErrors();
    expect($trip->fresh()->truck_here)->toBeTrue();

    Livewire::test(ListWhdeliverylogs::class)
        ->callTableAction('truckHere', $trip, data: ['why' => [$ana1->id => 'not_found', $ana3->id => 'not_arrived']])
        ->assertHasNoTableActionErrors();
    expect($trip->fresh()->truck_here)->toBeFalse()
        ->and(SetSplit::where('whdeliverylog_id', $trip->id)->pluck('reason', 'invoice_id')->all())->toBe([$ana1->id => 'not_found', $ana3->id => 'not_arrived']);
});

it('with the label scan on, saves boxes in a section only when its QR is scanned', function () {
    Sections::setLabelScan($this->wh, true);
    $this->actingAs($this->user);
    unload($this)->call('scan', 'S-101')->assertSee('Then scan the QR on section C')
        ->call('dismiss')->call('scan', 'S-102')
        ->call('dismiss')->call('scan', $this->T->qrText())->assertSet('status', 'warning')->assertSee('are for C, not T')
        ->call('dismiss')->call('scan', $this->C->qrText())->assertSet('status', 'success')->assertSee('2 boxes saved in section C');
    expect($this->maria1->fresh()->sectioned_at)->not->toBeNull();

    Sections::setLabelScan($this->wh, false);
    unload($this)->call('scan', $this->C->qrText())->assertSee('label scan is off');
});

it('stops a box for another hub when loading, and lists customers missing boxes at the end', function () {
    $this->actingAs($this->user);
    unload($this)->call('scan', 'S-101')->call('dismiss')->call('scan', 'S-102')->call('dismiss')->call('scan', 'S-301');

    $truck = Truck::firstOrFail();
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $this->main->id, 'user_id' => $this->user->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    app(TripAssignment::class)->addToDeliveryTrip($trip, Invoice::whereIn('id', [$this->maria1->id, $this->rosa->id])->get());

    $page = Livewire::test(ScanApp::class)->call('open', 'load')->call('pick', $trip->id)
        ->call('scan', 'S-101')->assertSet('status', 'warning')->assertSee('Wrong hub')->assertSee('is for Cebu hub')
        // wrong hub is office only: the crew asks, the office approves, the next scan loads it
        ->call('loadAnyway')->assertSee('office only')->call('askOffice')->assertSet('status', 'warning');
    $ask = TripOverride::where('rule', 'wrong_hub')->sole();
    expect($ask->status)->toBe('pending');
    TripRules::decide($ask, true, null);
    $page->call('dismiss')->call('scan', 'S-101')->assertSee('Too early')->call('loadAnyway')->assertSet('status', 'success')->assertSee('box 1 of 2')->assertSee('not on this trip');
    expect(Tripinvoice::where('invoice_id', $this->maria1->id)->value('loaded_by'))->toBe($this->user->id);

    // splitting a customer is office only too: asked, then approved = the reason is saved
    $page->call('finish')->assertSee('missing boxes')->assertSee('Maria Santos')->assertSee('S-102')
        ->call('splitReason', $this->maria2->id, 'not_found');
    expect(SetSplit::count())->toBe(0);
    TripRules::decide(TripOverride::where('rule', 'split_set')->sole(), true, null);
    expect(SetSplit::sole())->reason->toBe('not_found')->deliverylog_id->toBe($trip->id);
});

it('lets the admin set up the sections and print the labels', function () {
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->get(WarehouseSections::getUrl())->assertOk()->assertSee('Cebu hub')->assertSee('Print QR labels');

    Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)
        ->call('addRow')->set('rows.4.name', 'Davao hub')->set('rows.4.provinces', ['Davao del Sur', 'cebu'])
        ->call('save')->assertHasErrors('rows')
        ->set('rows.4.provinces', ['Davao del Sur', 'Cotabato'])->set('labelScan', true)->call('save')->assertHasNoErrors();
    expect(WhSection::where('warehouse_id', $this->wh)->count())->toBe(5)
        ->and(WhSection::where('name', 'Davao hub')->value('provinces'))->toBe(['Davao del Sur', 'Cotabato'])
        ->and(Sections::labelScan($this->wh))->toBeTrue();

    $this->get(route('sections.labels', ['warehouse' => $this->wh]))->assertOk()->assertSee('Davao hub')->assertSee('<svg', false);
    $this->flushSession();
    $driver = User::where('email', 'driver@example.com')->firstOrFail()->replicate()->fill(['email' => 'nobody@example.com', 'warehouse_id' => null]);
    $driver->save();
    $this->actingAs($driver)->get(route('sections.labels', ['warehouse' => $this->wh]))->assertForbidden();
});

it('picks provinces from a list: chips with ✕, a province moves from another section, no box counts (board 50b)', function () {
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $page = Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)
        ->assertSee('Receiver provinces')->assertSee('Province · default')->assertDontSee('>Boxes<', false)
        ->call('openPick', 0)->assertSee('Nueva Ecija')->assertSee('In Section T · pick to move it here')
        ->set('pickQ', 'nueva')->assertSee('Nueva Vizcaya')->assertDontSee('Bulacan')
        ->call('addPlace', 'Nueva Ecija')
        ->call('removePlace', 0, 'Cavite')->call('save')->assertHasNoErrors();

    expect($this->A->fresh()->provinces)->toBe(['Metro Manila', 'Nueva Ecija'])
        ->and($this->T->fresh()->provinces)->toBe(['Tarlac']);
});

it('chooses sections by city when switched to City: each city with its province (board 50b)', function () {
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->rosa->update(['receiver_city' => 'San Jose', 'receiver_province' => 'Nueva Ecija']);
    Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)
        ->call('setBy', 'city')->assertSee('Receiver cities and municipalities')->assertSee('City mode')
        ->call('openPick', 2)->set('pickQ', 'san jose')->assertSee('San Jose · Nueva Ecija')
        ->call('addPlace', 'San Jose · Nueva Ecija')->call('save')->assertHasNoErrors();

    Sections::forget();
    expect(Sections::by($this->wh))->toBe('city')
        ->and($this->T->fresh()->cities)->toBe(['San Jose · Nueva Ecija'])
        ->and($this->T->fresh()->provinces)->toBe(['Tarlac', 'Nueva Ecija'])            // kept for Province mode
        ->and(Sections::forInvoice($this->rosa->fresh())->code)->toBe('T')
        ->and(Sections::forInvoice($this->rosa->fresh()->replicate()->fill(['receiver_province' => 'Batangas']))->code)->toBe('X') // San Jose, Batangas
        ->and(Sections::forInvoice($this->maria1)->code)->toBe('X');                  // Cebu has no city set
});

it('uses spots only when switched on, and the crew can tap a spot, scan its QR, or skip (board 50)', function () {
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)->assertDontSee('Spots (optional)')
        ->set('spotsOn', true)->assertSee('Spots (optional)')
        ->call('toggleSpots', 1)->call('addSpot', 1)->call('save')->assertHasNoErrors();
    $spots = WhSpot::where('wh_section_id', $this->C->id)->orderBy('sort')->pluck('code', 'id');
    expect($spots->values()->all())->toBe(['C1', 'C2', 'C3', 'C4'])->and($this->A->fresh()->use_spots)->toBeFalse();

    $this->actingAs($this->user);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Sections::forget();
    $c2 = $spots->search('C2');
    $scan = unload($this)->call('scan', 'S-101')->assertSee('Spot? scan its QR, tap one, or skip')->assertSee('C3')
        ->call('setSpot', $c2)->assertSee('✓ Spot C2');
    expect((int) $this->maria1->fresh()->wh_spot_id)->toBe($c2);

    $scan->call('scan', 'S-102')->call('setSpot')->assertSee('No spot');
    expect($this->maria2->fresh()->wh_spot_id)->toBeNull();

    $scan->call('scan', 'SPOT-'.$spots->search('C4')); // the spot's QR: the last box scanned for section C
    expect($this->maria2->fresh()->wh_spot_id)->toBe($spots->search('C4'));

    $scan->call('scan', 'S-301')->assertDontSee('Spot?'); // section T has no spots

    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
    $this->get(route('sections.labels', ['warehouse' => $this->wh]))->assertOk()->assertSee('Spot C2 · section C');
});
