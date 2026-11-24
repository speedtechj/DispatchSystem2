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
use App\Support\Shipping\SeaTrucks;
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


/** Board 62: one truck to the port for all the trips of a sea shipment; RoRo and LCL. */
function twoHubShipment($test): array
{
    $test->cebu->forceFill(['by_sea' => true, 'port' => 'Port of Cebu'])->save();
    $bohol = Logistichub::create(['hub_code' => 'BOH', 'hub_name' => 'Bohol Hub', 'is_active' => true, 'is_company' => true, 'trip_counter' => 0, 'user_id' => $test->admin->id]);
    $bohol->forceFill(['by_sea' => true, 'port' => 'Port of Cebu'])->save();
    $t2 = Truck::firstOrFail()->replicate()->fill(['plate_no' => 'ZZZ 2222']);
    $t2->save();
    $tripB = Deliverylog::create(['truck_id' => $t2->id, 'logistichub_id' => $test->admin->logistichub_id, 'assigned_to' => $bohol->id, 'user_id' => $test->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $b6 = Invoice::where('invoice', 'SEA-5')->first()->replicate()->fill(['invoice' => 'SEA-6', 'receiver_name' => 'Jun Cruz', 'receiver_mobile_no' => '0917000', 'receiver_province' => 'Bohol', 'wh_is_assigned' => false, 'is_assigned' => false, 'set_key' => null, 'wh_section_id' => null]);
    $b6->save();
    app(TripAssignment::class)->addToDeliveryTrip($tripB, collect([$b6]));
    Tripinvoice::where('deliverylog_id', $tripB->id)->update(['logistichub_id' => $bohol->id]);
    $s = Shipments::create([$test->trip, $tripB]);

    return [$s, $tripB, $t2, $bohol];
}

it('puts every trip of a shipment on the main truck: one load screen, other trips go with it', function () {
    [$s, $tripB, $t2] = twoHubShipment($this);
    $stopB = Shipments::stopOf($s, $tripB->id);
    expect($stopB->carrier_trip_id)->toBeNull()->and($stopB->own_truck_id)->toBe($t2->id)
        ->and($tripB->fresh()->truck_id)->toBe($this->trip->truck_id)
        ->and(SeaTrucks::riderTripIds())->toBe([$tripB->id])
        ->and(SeaTrucks::carriedBy($this->trip->id))->toBe([$this->trip->id, $tripB->id])
        ->and(SeaTrucks::carrierTrip($tripB->id))->toBe($this->trip->id)
        ->and(SeaTrucks::trucks($s))->toHaveCount(1);

    // the Bohol trip is not loaded on its own; the main trip loads the Bohol box too
    $page = Livewire::test(\App\Filament\Pages\Scanload::class);
    expect(array_keys($page->instance()->getSchema('form')->getComponent('deliverylog_id')->getOptions()))->not->toContain($tripB->id);
    $page->set('data.deliverylog_id', $this->trip->id)->call('scan', 'SEA-6')->assertSet('lastStatus', 'success');
    expect(Tripinvoice::where('invoice', 'SEA-6')->value('is_loaded'))->toBeTruthy()
        ->and($page->instance()->progress())->toMatchArray(['loaded' => 1, 'total' => 5]);

    // the office page says it goes with the main truck
    Livewire::test(AdminShipmentPage::class, ['shipmentId' => $s->id])->assertSee('Goes with')->assertSee('Truck to the port')->assertSee('Use its own truck');
});

it('lets a trip keep its own truck (a second truck): wrong truck when loaded on the other', function () {
    [$s, $tripB, $t2] = twoHubShipment($this);
    expect(SeaTrucks::ownTruck($s, $tripB->id))->toBeTrue()
        ->and($tripB->fresh()->truck_id)->toBe($t2->id)
        ->and(SeaTrucks::riderTripIds())->toBe([])
        ->and(SeaTrucks::trucks($s))->toHaveCount(2);

    Livewire::test(\App\Filament\Pages\Scanload::class)->set('data.deliverylog_id', $this->trip->id)
        ->call('scan', 'SEA-6')->assertSet('lastStatus', 'danger')->assertSee('Wrong truck: SEA-6 goes on ZZZ 2222');

    SeaTrucks::setCost($s, $this->trip->id, 6000);
    SeaTrucks::setCost($s, $tripB->id, 4000);
    expect($s->fresh()->cost())->toBe(10000.0);

    // back with the main truck
    expect(SeaTrucks::goWithMain($s->fresh(), $tripB->id))->toBeTrue()->and($tripB->fresh()->truck_id)->toBe($this->trip->truck_id);
    // taking the trip out gives its truck back
    expect(Shipments::removeStop($s->fresh(), $tripB->id))->toBeTrue()->and($tripB->fresh()->truck_id)->toBe($t2->id);
});

it('runs RoRo from the driver: on the ship, off the ship, then each hub in turn', function () {
    [$s, $tripB] = twoHubShipment($this);
    $s->update(['mode' => 'roro', 'status' => 'sealed']);
    expect(SeaTrucks::roroFor($tripB->fresh()))->toBeNull()                        // the Bohol trip goes with the main truck
        ->and(SeaTrucks::roroNext($s, $this->trip->id))->toBe(['to_port', 'Leaving for the port']);
    foreach (['to_port', 'sailed', 'arrived'] as $k) {
        expect(SeaTrucks::roroStep($s->fresh(), $this->trip->id, $k))->toBeTrue();
    }
    $s->refresh();
    expect($s->status)->toBe('arrived')->and(collect($s->status_log)->last()['driver'])->toBeTrue()
        ->and(SeaTrucks::roroNext($s, $this->trip->id))->toBe(['stop:'.$this->trip->id, 'Arrived at '.$this->cebu->hub_name]);
    SeaTrucks::roroStep($s, $this->trip->id, 'stop:'.$this->trip->id);
    expect(Shipments::trackText($s->fresh(), $this->trip->id))->toBe('Our truck is at '.$this->cebu->hub_name)
        ->and(SeaTrucks::roroNext($s->fresh(), $this->trip->id)[1])->toBe('Arrived at Bohol Hub')
        ->and(SeaTrucks::roroStep($s->fresh(), $this->trip->id, 'sailed'))->toBeFalse();       // not the next step
});

it('ships LCL with a forwarder: its own steps, no seal, forwarder and waybill before it ships', function () {
    $this->cebu->forceFill(['by_sea' => true, 'port' => 'Port of Cebu'])->save();
    $s = Shipments::create($this->trip, 'lcl');
    expect($s->port_check)->toBe('count')
        ->and(array_values(Shipments::steps($s)))->toBe(['Preparing', 'Loaded', 'Truck to the forwarder', 'Handed to the forwarder', 'Shipped by the forwarder', 'Ready to pick up', 'Picked up', 'Received']);
    foreach (Tripinvoice::where('deliverylog_id', $this->trip->id)->get() as $r) {
        app(TripAssignment::class)->markLoaded($r);
    }
    expect(Shipments::blockers($s->fresh(), 'sealed'))->not->toContain('Type the seal number.');

    Livewire::test(AdminShipmentPage::class, ['shipmentId' => $s->id])->assertSee('Forwarder')->assertDontSee('Container van no.')
        ->set('f.forwarder', '2GO Logistics')->set('f.waybill_no', '2GO-55120')->set('f.charge_basis', 'cbm')->set('f.charge_rate', '1,450')
        ->set('f.pick_up_at', '2GO Cebu, Pier 3')->call('save')->assertHasNoErrors();
    $s->refresh();
    expect($s->charge_rate)->toBe(1450.0)->and(Shipments::blockers($s, 'sailed'))->toBe([]);
    $s->update(['status' => 'arrived']);
    expect(Shipments::trackText($s->fresh()))->toBe('Ready to pick up at 2GO Cebu, Pier 3');
});
