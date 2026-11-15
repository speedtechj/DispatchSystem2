<?php

use App\Filament\Pages\WarehouseSections;
use App\Filament\Scan\Pages\ScanApp;
use App\Models\AppSetting;
use App\Models\Boxes\SetSplit;
use App\Models\Boxes\WhSection;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Truck;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use App\Support\Boxes\Sections;
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
});

function unload($test)
{
    return Livewire::test(ScanApp::class)->call('open', 'unload')->call('pick', $test->container->id);
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

it('loads boxes straight onto a waiting truck, and the crew can keep one in its section', function () {
    $this->actingAs($this->user);
    $trip = Whdeliverylog::create(['truck_id' => Truck::value('id'), 'warehouse_id' => $this->tarlac->id, 'user_whid' => $this->wh, 'departure_date' => today(), 'delivery_date' => today(), 'is_active' => true, 'user_id' => $this->user->id]);

    unload($this)->call('openTruckPicker')->assertSee('Which truck is waiting?')->assertSee('Tarlac Warehouse')
        ->call('truckStart', $trip->id)->assertSee('Truck '.$trip->trip_number)
        ->call('scan', 'S-301')->assertSet('route.kind', 'truck')->assertSee('Put in section instead')
        ->call('dismiss')->call('scan', 'S-302')->assertSet('route.kind', 'truck')
        ->call('putInSection')->assertSet('route.code', 'T')
        ->call('dismiss')->call('scan', 'S-101')->assertSet('route.code', 'C')
        ->call('dismiss')->assertSee('on truck');

    expect(Whtripinvoice::where('whdeliverylog_id', $trip->id)->pluck('invoice_id')->all())->toBe([$this->rosa->id])
        ->and(Whtripinvoice::where('invoice_id', $this->rosa->id)->value('is_loaded'))->toBeTruthy()
        ->and($this->ben->fresh()->sectioned_at)->not->toBeNull()
        ->and($this->ben->fresh()->wh_is_assigned)->toBeFalse();

    $status = \App\Support\Boxes\Crossdock::counts(\App\Support\Boxes\Crossdock::active($this->container->id));
    expect($status)->toMatchArray(['onTruck' => 1, 'inSection' => 1, 'inContainer' => 0, 'section' => 'T']);

    unload($this)->call('truckPause', true)->call('truckStop');
    expect(\App\Support\Boxes\Crossdock::active($this->container->id))->toBeNull();
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
        ->call('loadAnyway')->assertSet('status', 'success')->assertSee('box 1 of 2')->assertSee('not on this trip');
    expect(\App\Models\Tripinvoice::where('invoice_id', $this->maria1->id)->value('loaded_by'))->toBe($this->user->id);

    $page->call('finish')->assertSee('missing boxes')->assertSee('Maria Santos')->assertSee('S-102')
        ->call('splitReason', $this->maria2->id, 'not_found');
    expect(SetSplit::sole())->reason->toBe('not_found')->deliverylog_id->toBe($trip->id);
});

it('lets the admin set up the sections and print the labels', function () {
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->get(WarehouseSections::getUrl())->assertOk()->assertSee('Cebu hub')->assertSee('Print QR labels');

    Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)
        ->call('addRow')->set('rows.4.name', 'Davao hub')->set('rows.4.provinces', 'Davao del Sur, cebu')
        ->call('save')->assertHasErrors('rows')
        ->set('rows.4.provinces', 'Davao del Sur, Cotabato')->set('labelScan', true)->call('save')->assertHasNoErrors();
    expect(WhSection::where('warehouse_id', $this->wh)->count())->toBe(5)
        ->and(WhSection::where('name', 'Davao hub')->value('provinces'))->toBe(['Davao del Sur', 'Cotabato'])
        ->and(Sections::labelScan($this->wh))->toBeTrue();

    $this->get(route('sections.labels', ['warehouse' => $this->wh]))->assertOk()->assertSee('Davao hub')->assertSee('<svg', false);
    $this->flushSession();
    $driver = User::where('email', 'driver@example.com')->firstOrFail()->replicate()->fill(['email' => 'nobody@example.com', 'warehouse_id' => null]);
    $driver->save();
    $this->actingAs($driver)->get(route('sections.labels', ['warehouse' => $this->wh]))->assertForbidden();
});
