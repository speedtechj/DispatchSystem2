<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Models\Deliverylog;
use App\Models\Invoiceissue;
use App\Models\Logistichub;
use App\Models\Shipping\TruckReceipt;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\ScanModes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    $this->main = Logistichub::where('hub_code', 'MNL')->firstOrFail();
    $this->hub = Logistichub::where('hub_code', 'CEB')->firstOrFail();
    $this->trip = Deliverylog::where('logistichub_id', $this->main->id)->firstOrFail();
    $this->rows = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_loaded', true)->take(3)->get();
    Tripinvoice::whereKey($this->rows->modelKeys())->update(['logistichub_id' => $this->hub->id, 'hub_assigned' => false]);
    $base = User::where('email', 'company@example.com')->firstOrFail();
    $this->user = $base->replicate()->fill(['email' => 'rt-'.$base->email]);
    $this->user->save();
});

it('shows Receive truck to hubs reached by truck, and Receive container to hubs reached by sea', function () {
    $this->hub->forceFill(['by_sea' => false])->save();
    expect(array_keys(ScanModes::for($this->user)))->toBe(['pick', 'hub_load', 'return', 'truck_receive']);

    // A sea hub sees Receive truck only while a truck is arriving.
    $this->hub->forceFill(['by_sea' => true])->save();
    expect(array_keys(ScanModes::for($this->user)))->toBe(['pick', 'hub_load', 'return', 'ship_receive', 'truck_receive']);
    Tripinvoice::whereKey($this->rows->modelKeys())->update(['logistichub_id' => $this->main->id]);
    expect(array_keys(ScanModes::for($this->user)))->toBe(['pick', 'hub_load', 'return', 'ship_receive']);
});

it('receives the truck box by box, and opens a Missing box issue for each box not scanned', function () {
    $this->hub->forceFill(['by_sea' => false])->save();
    $this->actingAs($this->user);
    [$a, $b, $c] = $this->rows->pluck('invoice')->all();

    Livewire::test(ScanApp::class)->call('open', 'truck_receive')->assertSee($this->trip->trip_number.' from Manila')
        ->call('pick', $this->trip->id)
        ->call('scan', $a)->assertSet('status', 'success')->assertSee('Received at your hub')
        ->call('dismiss')->call('scan', $a)->assertSet('status', 'warning')->assertSet('message', fn ($m) => str_contains($m, 'already received'))
        ->call('dismiss')->call('scan', $b)->assertSet('status', 'success')
        ->call('finish')->assertSee('2 of 3 boxes received')->assertSee($c)
        ->call('finishReceiving')->assertNotified();

    $r = TruckReceipt::where('deliverylog_id', $this->trip->id)->first();
    expect($r->finished_at)->not->toBeNull()->and($r->missing)->toBe(1)
        ->and(Invoiceissue::where('invoice', $c)->where('remarks', 'like', '%'.$this->trip->trip_number.'%')->exists())->toBeTrue()
        ->and(Invoiceissue::where('invoice', $a)->where('remarks', 'like', '%'.$this->trip->trip_number.'%')->exists())->toBeFalse();

    // Received trucks leave the list.
    expect(\App\Support\Shipping\TruckReceive::trips($this->hub->id))->toBeEmpty();
});

it('asks for the hub photo at Receive truck and Receive container', function () {
    expect(\App\Models\BoxPhoto::STEPS)->toHaveKey('hub_receive')
        ->and(app(\App\Filament\Shared\Shipping\TruckReceiveStation::class)->photoStep())->toBe('hub_receive')
        ->and(app(\App\Filament\Shared\Shipping\ReceiveShipmentStation::class)->photoStep())->toBe('hub_receive')
        ->and(app(\App\Filament\Shared\Shipping\PortCheckStation::class)->photoStep())->toBeNull();
});
