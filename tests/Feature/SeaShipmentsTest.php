<?php

use App\Filament\Company\Pages\IncomingShipments;
use App\Filament\Company\Pages\SeaShipment as HubShipmentPage;
use App\Filament\Company\Pages\WrongHub as HubWrongHub;
use App\Filament\Pages\SeaShipment as AdminShipmentPage;
use App\Filament\Pages\SeaShipments as AdminShipments;
use App\Filament\Scan\Pages\ScanApp;
use App\Models\Boxes\SetSplit;
use App\Models\Boxes\WhSection;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\WrongHubBox;
use App\Models\Truck;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\HubDesk;
use App\Support\Shipping\Shipments;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    \App\Support\Boxes\Sections::forget();
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $base = User::where('email', 'company@example.com')->firstOrFail();
    $this->hubUser = $base->replicate()->fill(['email' => 'cebu-crew@example.com', 'first_name' => 'Carla']);
    $this->hubUser->save();
    $this->main = Logistichub::where('hub_code', 'MNL')->firstOrFail();
    $this->cebu = Logistichub::where('hub_code', 'CEB')->firstOrFail();
    $this->davao = Logistichub::create(['hub_code' => 'DVO', 'hub_name' => 'Davao Hub', 'is_active' => true, 'is_company' => true, 'trip_counter' => 0, 'user_id' => $this->admin->id]);
    $wh = $this->admin->warehouse_id ?? Container::value('warehouse_id');
    WhSection::create(['warehouse_id' => $wh, 'code' => 'C', 'name' => 'Cebu hub', 'kind' => 'area', 'provinces' => ['Cebu'], 'logistichub_id' => $this->cebu->id]);
    WhSection::create(['warehouse_id' => $wh, 'code' => 'D', 'name' => 'Davao hub', 'kind' => 'area', 'provinces' => ['Davao del Sur'], 'logistichub_id' => $this->davao->id]);

    $tpl = Invoice::firstOrFail();
    $mk = function (string $no, string $name, string $prov) use ($tpl, $wh) {
        $b = $tpl->replicate()->fill(['invoice' => $no, 'receiver_name' => $name, 'receiver_mobile_no' => '0917'.crc32($name), 'receiver_province' => $prov, 'receiver_city' => 'Somewhere',
            'is_verified' => true, 'is_assigned' => false, 'wh_is_assigned' => false, 'is_delivered' => false, 'warehouse_id' => $wh, 'set_key' => null]);
        $b->save();
        $b->update(['wh_section_id' => \App\Support\Boxes\Sections::forInvoice($b, $wh)?->id]);

        return $b->fresh();
    };
    $this->b1 = $mk('SEA-1', 'Maria Santos', 'Cebu');
    $this->b2 = $mk('SEA-2', 'Maria Santos', 'Cebu');       // stays behind
    $this->b3 = $mk('SEA-3', 'Ana Reyes', 'Cebu');          // lost at the port
    $this->b4 = $mk('SEA-4', 'Joy Lim', 'Davao del Sur');   // wrong hub
    $this->b5 = $mk('SEA-5', 'Ken Sy', 'Cebu');

    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->trip = Deliverylog::create(['truck_id' => Truck::value('id'), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $this->cebu->id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, collect([$this->b1, $this->b3, $this->b4, $this->b5]));
});

function loadAll($test): void
{
    foreach (Tripinvoice::where('deliverylog_id', $test->trip->id)->get() as $r) {
        app(TripAssignment::class)->markLoaded($r);
    }
}

it('makes a sea shipment from a trip, and only seals it when everything is loaded', function () {
    Livewire::test(AdminShipments::class)->assertSee('Trip '.$this->trip->trip_number)
        ->set('tripId', $this->trip->id)->set('portCheck', 'count')->call('create')->assertRedirect();
    $s = SeaShipment::sole();
    expect($s->code)->toBe('CEB-0001')->and($s->status)->toBe('preparing')->and($s->logistichub_id)->toBe($this->cebu->id);

    $page = Livewire::test(AdminShipmentPage::class, ['shipmentId' => $s->id])->assertSee('4 boxes on the trip are not loaded')->assertSee('Type the seal number');
    loadAll($this);
    SetSplit::create(['invoice_id' => $this->b2->id, 'deliverylog_id' => $this->trip->id, 'reason' => 'not_found', 'set_key' => $this->b2->set_key]);

    $page->set('f.seal_no', '0048213')->set('f.van_no', 'MSKU220871')->set('f.cost_freight', '32,500')->set('f.cost_trucking', '3800')->call('save')
        ->call('advance')->call('advance');
    expect($s->fresh()->status)->toBe('to_port');

    // count only: 3 of 4 handed over
    $page->call('advance')->assertSee('Type how many boxes were handed over');
    $page->set('f.port_count', '3')->call('save')->call('advance')->assertSee('left the warehouse but was not handed over at the port');
    expect($s->fresh()->status)->toBe('at_port');

    $page->call('advance')->assertSee('Type the vessel');
    $page->set('f.vessel', 'MV 2GO Masagana')->set('f.eta', today()->addDays(2)->toDateString())->call('save')->call('advance');
    $s->refresh();
    expect($s->status)->toBe('sailed')->and(Shipments::trackText($s))->toContain('by sea · arriving about')
        ->and(Shipments::counts($s)['perBox'])->toBe(9075.0);
});

it('lets the partner hub receive the container, flags wrong-hub and missing boxes', function () {
    loadAll($this);
    $s = Shipments::create($this->trip);
    $s->update(['status' => 'sailed', 'seal_no' => '1', 'vessel' => 'MV X', 'eta' => today()]);

    // the hub cannot put a box on its own truck while it is at sea
    $row = Tripinvoice::where('invoice_id', $this->b1->id)->firstOrFail();
    expect(Shipments::stillAtSea($row)?->id)->toBe($s->id);
    expect((new HubDesk($this->cebu->id))->track('SEA-1')['status'])->toContain('by sea');

    $this->actingAs($this->hubUser);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)->call('open', 'ship_receive')->assertSee($s->code)->call('pick', $s->id)
        ->call('scan', 'SEA-1')->assertSet('status', 'success')->assertSee('box 1 of 2')->assertSee('still in Manila')
        ->call('dismiss')->call('scan', 'SEA-4')->assertSet('status', 'warning')->assertSee('is for Davao Hub')
        ->call('dismiss')->call('scan', 'SEA-5')
        ->call('dismiss')->call('scan', 'SEA-5')->assertSee('already scanned');
    expect(Shipments::stillAtSea($row))->toBeNull();

    Filament::setCurrentPanel(Filament::getPanel('company'));
    $this->get(IncomingShipments::getUrl())->assertOk()->assertSee($s->code);
    Livewire::test(HubShipmentPage::class, ['shipmentId' => $s->id])->assertSee('Not scanned in at the hub yet: SEA-3')
        ->call('finishReceiving');
    expect($s->fresh()->status)->toBe('received')
        ->and(Invoiceissue::where('invoice', 'SEA-3')->count())->toBe(1);

    // wrong hub: send it straight to Davao
    $w = WrongHubBox::sole();
    expect($w->correct_hub_id)->toBe($this->davao->id);
    Livewire::test(HubWrongHub::class)->assertSee('Send to Davao Hub direct')->call('sendToHub', $w->id);
    expect(Tripinvoice::where('invoice_id', $this->b4->id)->value('logistichub_id'))->toBe($this->davao->id)
        ->and($w->fresh()->status)->toBe('sent_hub');

    // a refused box goes back to the warehouse on a return shipment
    Livewire::test(HubWrongHub::class)->set('code', 'SEA-5')->set('reason', 'refused')->call('addBox')->assertHasNoErrors()
        ->call('sendBack', WrongHubBox::where('reason', 'refused')->value('id'))
        ->set('tab', 'return')->assertSee('RET-0001')->assertSee('SEA-5')
        ->set('rf.vessel', 'MV Back')->call('saveReturn')->call('sendReturn')
        ->set('tab', 'report')->assertSee('Refused by receiver');
    $rs = \App\Models\Shipping\ReturnShipment::sole();
    expect($rs->status)->toBe('sent')->and($rs->vessel)->toBe('MV Back')
        ->and(Tripinvoice::where('invoice_id', $this->b5->id)->exists())->toBeTrue(); // still on its trip until it is back

    // the warehouse scans it in: back in the pool, in section C
    $wh = User::where('email', 'warehouse@example.com')->firstOrFail()->replicate()->fill(['email' => 'ret-wh@example.com', 'warehouse_id' => $this->admin->warehouse_id ?? Container::value('warehouse_id')]);
    $wh->save();
    $this->flushSession();
    $this->actingAs($wh);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)->call('open', 'ret_receive')->assertSee('RET-0001')->call('pick', $rs->id)
        ->call('scan', 'SEA-5')->assertSet('status', 'success')->assertSet('route.code', 'C')
        ->call('dismiss')->call('scan', 'SEA-1')->assertSet('status', 'danger');
    expect(Tripinvoice::where('invoice_id', $this->b5->id)->exists())->toBeFalse()
        ->and($this->b5->fresh())->is_returned->toBeTruthy()->is_assigned->toBeFalsy()
        ->and(WrongHubBox::where('invoice_id', $this->b5->id)->value('status'))->toBe('back');

    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    Livewire::test(\App\Filament\Warehouse\Pages\ComingBack::class)->set('tab', 'return')->assertSee('RET-0001')->assertSee('1 / 1 back')
        ->call('finishReturn', $rs->id);
    expect($rs->fresh()->status)->toBe('received');
});

it('serves the app files at addresses Plesk does not serve from disk', function () {
    $this->get('/pwa/sw')->assertOk()->assertHeader('Service-Worker-Allowed', '/');
    $this->get('/pwa/delivery/manifest')->assertOk()->assertJsonPath('icons.0.src', fn ($src) => str_contains($src, '/pwa/delivery/icon/192'));
    $this->get('/pwa/delivery/icon/192')->assertOk();
});

it('scans boxes at the port for a full-scan shipment', function () {
    loadAll($this);
    $s = Shipments::create($this->trip, 'container', 'full');
    $s->update(['status' => 'to_port', 'seal_no' => '1']);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)->call('open', 'port')->call('pick', $s->id)
        ->call('scan', 'SEA-1')->assertSet('status', 'success')->assertSee('Handed over at the port')
        ->call('dismiss')->call('scan', 'SEA-2')->assertSet('status', 'danger');
    $c = Shipments::counts($s);
    expect($c['port'])->toBe(1)->and($c['missingPort']->all())->toBe(['SEA-3', 'SEA-4', 'SEA-5']);
    expect(Shipments::blockers($s, 'at_port'))->toBe([]);
});

it('runs RoRo without the port and pick-up steps', function () {
    $s = Shipments::create($this->trip, 'roro');
    expect(array_keys(Shipments::steps($s)))->toBe(['preparing', 'sealed', 'to_port', 'sailed', 'arrived', 'received'])
        ->and(Shipments::label($s, 'sailed'))->toBe('On the ferry')
        ->and($s->port_check)->toBe('off');
});

it('lists only trips to hubs reached by sea, searchable, and lets you change the trip or remove the shipment', function () {
    $luzon = Logistichub::create(['hub_code' => 'PAM', 'hub_name' => 'Pampanga Hub', 'is_active' => true, 'is_company' => true, 'trip_counter' => 0, 'user_id' => $this->admin->id]);
    $mk = fn ($hub) => Deliverylog::create(['truck_id' => Truck::value('id'), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $hub->id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $toLuzon = $mk($luzon);
    $toDavao = $mk($this->davao);

    expect(\App\Support\Shipping\Islands::islandOf($this->cebu))->toBe('visayas')
        ->and(\App\Support\Shipping\Islands::islandOf($this->davao))->toBe('mindanao')
        ->and(\App\Support\Shipping\Islands::bySea($luzon))->toBeFalse();

    Livewire::test(AdminShipments::class)
        ->assertSee('Trip '.$this->trip->trip_number)->assertSee('Trip '.$toDavao->trip_number)->assertDontSee('Pampanga Hub')
        ->assertSee('1 trip to hubs reached by truck is not listed')
        ->set('tripSearch', 'davao')->assertDontSee('Trip '.$this->trip->trip_number.' →')->assertSee('Trip '.$toDavao->trip_number)
        ->set('tripSearch', '')->set('island', 'visayas')->assertDontSee('Trip '.$toDavao->trip_number.' →')
        ->set('island', '')->set('allTrips', true)->assertSee('Pampanga Hub')
        ->set('allTrips', false)->call('pickTrip', $this->trip->id)->assertSee('Visayas')->call('create');

    // the admin marks Pampanga as reached by sea (RoRo): now it is listed
    Livewire::test(\App\Filament\Pages\HubIslands::class)->assertSee('Pampanga Hub')->call('toggleSea', $luzon->id)->call('setPort', $this->davao->id, 'Davao Sasa Port');
    expect(\App\Support\Shipping\Islands::bySea($luzon->fresh()))->toBeTrue()
        ->and(\App\Support\Shipping\Islands::port($this->davao->fresh()))->toBe('Davao Sasa Port');

    // wrong trip: change it to the Davao trip, then remove the shipment
    $s = SeaShipment::sole();
    Livewire::test(AdminShipmentPage::class, ['shipmentId' => $s->id])->assertSee('Change trip')
        ->call('openChange')->assertSee('Trip '.$toDavao->trip_number)->call('changeTrip', $toDavao->id);
    $s->refresh();
    expect($s->deliverylog_id)->toBe($toDavao->id)->and($s->logistichub_id)->toBe($this->davao->id)->and($s->code)->toStartWith('DVO-')
        ->and($s->port_to)->toBe('Davao Sasa Port');

    Livewire::test(AdminShipmentPage::class, ['shipmentId' => $s->id])->call('removeShipment')->assertRedirect();
    expect(SeaShipment::count())->toBe(0)->and(Deliverylog::find($toDavao->id))->not->toBeNull()
        ->and(Tripinvoice::where('deliverylog_id', $this->trip->id)->count())->toBe(4);

    // after sealing there is no change or remove
    $s2 = Shipments::create($this->trip);
    $s2->update(['status' => 'sealed']);
    expect(Shipments::remove($s2))->toBeFalse();
    Livewire::test(AdminShipmentPage::class, ['shipmentId' => $s2->id])->assertDontSee('Remove shipment');
});

it('lets the driver type the count at the port and take the receipt photo', function () {
    \Illuminate\Support\Facades\Storage::fake('public');
    loadAll($this);
    $s = Shipments::create($this->trip, 'container', 'count');
    $s->update(['status' => 'to_port', 'seal_no' => '1', 'shipping_line' => '2GO', 'port_from' => 'Manila North Harbor']);
    Deliverylog::where('id', '!=', $this->trip->id)->update(['is_active' => false]);
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    \App\Models\Truckcrew::create(['truck_id' => $this->trip->truck_id, 'crew' => $driver->id, 'user_id' => $this->admin->id]);
    $this->flushSession();
    $this->actingAs($driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));

    Livewire::test(\App\Filament\Delivery\Pages\Dashboard::class)->assertSee('At the port · '.$s->code);
    Livewire::test(\App\Filament\Delivery\Pages\AtPort::class)
        ->assertSee('Left the warehouse: 4 boxes')->call('start')->assertSet('count', '4')
        ->call('bump', -1)->assertSee('1 box short')
        ->call('toPhoto')->assertSet('step', 'photo')
        ->set('upload', \Illuminate\Http\UploadedFile::fake()->image('slip.jpg', 800, 1200))->call('savePhoto')
        ->assertSet('step', 'done')->assertSee('3 of 4 boxes');
    $s->refresh();
    expect($s->port_count)->toBe(3)->and($s->port_by)->toBe($driver->id)->and($s->port_receipt)->toStartWith('shipments/')
        ->and($s->status)->toBe('at_port');
    expect(Shipments::counts($s)['port'])->toBe(3);
});

it('puts more hubs in one container: each hub receives only its own boxes, then passes it on', function () {
    $this->cebu->forceFill(['by_sea' => true, 'port' => 'Port of Cebu'])->save();
    $this->davao->forceFill(['by_sea' => true, 'port' => 'Port of Davao'])->save();
    $bohol = Logistichub::create(['hub_code' => 'BOH', 'hub_name' => 'Bohol Hub', 'is_active' => true, 'is_company' => true, 'trip_counter' => 0, 'user_id' => $this->admin->id]);
    $bohol->forceFill(['by_sea' => true, 'port' => 'Port of Cebu'])->save();
    $mkTrip = fn ($hub) => Deliverylog::create(['truck_id' => Truck::value('id'), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $hub->id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $tripB = $mkTrip($bohol);
    $tripD = $mkTrip($this->davao);
    $b6 = Invoice::where('invoice', 'SEA-5')->first()->replicate()->fill(['invoice' => 'SEA-6', 'receiver_name' => 'Jun Cruz', 'receiver_mobile_no' => '0917000', 'receiver_province' => 'Bohol', 'wh_is_assigned' => false, 'is_assigned' => false, 'set_key' => null, 'wh_section_id' => null]);
    $b6->save();
    app(TripAssignment::class)->addToDeliveryTrip($tripB, collect([$b6]));
    Tripinvoice::where('deliverylog_id', $tripB->id)->update(['logistichub_id' => $bohol->id]);

    // Different ports cannot share a container.
    Livewire::test(AdminShipments::class)->call('pickTrip', $this->trip->id)->call('pickTrip', $tripD->id)
        ->assertSee('Different ports')->call('create')->assertHasErrors('tripId');
    expect(SeaShipment::count())->toBe(0);

    Livewire::test(AdminShipments::class)->call('pickTrip', $this->trip->id)->call('pickTrip', $tripB->id)
        ->assertSee('One container for 2 hubs')->assertSee('Make 1 shipment · 2 hubs')->call('create')->assertRedirect();
    $s = SeaShipment::sole();
    expect(Shipments::tripIds($s))->toBe([$this->trip->id, $tripB->id])
        ->and(Shipments::loadZone($tripB->id))->toMatchArray(['zone' => 'front', 'stop' => 2])
        ->and(Shipments::loadZone($this->trip->id))->toMatchArray(['zone' => 'back', 'stop' => 1])
        ->and(Shipments::counts($s)['onTrip'])->toBe(5);

    loadAll($this);
    Tripinvoice::where('deliverylog_id', $tripB->id)->update(['is_loaded' => true]);
    $s->update(['status' => 'sailed']);

    // Cebu: only its own boxes; the Bohol box stays in the container.
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    $this->actingAs($this->hubUser);
    Livewire::test(ScanApp::class)->call('open', 'ship_receive')->call('pick', $s->id)
        ->call('scan', 'SEA-6')->assertSet('status', 'warning')->assertSet('route.name', 'For Bohol Hub: leave it in the container')
        ->call('dismiss')->call('scan', 'SEA-1')->assertSet('status', 'success')
        ->call('finish')->assertSee('pass on to Bohol Hub')->call('finishReceiving');
    $s->refresh();
    expect($s->status)->toBe('sailed')
        ->and(Shipments::currentStop($s)->logistichub_id)->toBe($bohol->id)
        ->and(collect($s->status_log)->last()['status'])->toBe('passed')
        ->and(Invoiceissue::where('invoice', 'SEA-6')->exists())->toBeFalse()
        ->and(Invoiceissue::where('invoice', 'SEA-3')->exists())->toBeTrue();

    // Bohol: its turn now.
    $boholUser = $this->hubUser->replicate()->fill(['email' => 'bohol@example.com', 'logistichub_id' => $bohol->id]);
    $boholUser->save();
    $this->actingAs($boholUser);
    Livewire::test(ScanApp::class)->call('open', 'ship_receive')->call('pick', $s->id)
        ->call('scan', 'SEA-1')->assertSet('status', 'warning')->assertSet('message', fn ($m) => str_contains($m, 'already received at Cebu'))
        ->call('dismiss')->call('scan', 'SEA-6')->assertSet('status', 'success')
        ->call('finish')->call('finishReceiving');
    expect($s->fresh()->status)->toBe('received');
});
