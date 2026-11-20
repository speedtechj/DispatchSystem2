<?php

use App\Filament\Pages\PlanTrips;
use App\Filament\Pages\Scaninvoice;
use App\Filament\Pages\WarehouseCoverage;
use App\Filament\Pages\WarehouseTransfers;
use App\Filament\Pages\WhereToUnload;
use App\Models\Container;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Models\Warehouses\CoverageRequest;
use App\Support\Warehouses\Coverage;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->cavite = Warehouse::firstOrFail();
    $this->cavite->forceFill(['name' => 'Cavite warehouse'])->save();
    $this->tarlac = Warehouse::create(['name' => 'Tarlac warehouse', 'address' => 'MacArthur Hwy', 'city' => 'Tarlac City', 'province' => 'Tarlac', 'user_id' => $this->admin->id]);
    $this->admin->forceFill(['warehouse_id' => $this->cavite->id])->save();
    Invoice::query()->update(['is_assigned' => true]);
    Truck::query()->update(['is_assigned' => false]);
    $base = Invoice::firstOrFail();
    $this->box = function (string $prov, string $city, string $no, array $more = []) use ($base) {
        $i = $base->replicate();
        $i->forceFill(array_merge(['invoice' => $no, 'receiver_province' => $prov, 'receiver_city' => $city, 'is_verified' => true, 'is_assigned' => false, 'wh_is_assigned' => false,
            'is_delivered' => false, 'verified_at' => now()->subDay(), 'warehouse_id' => $this->cavite->id, 'set_key' => null, 'receiver_mobile_no' => '09'.random_int(100000000, 999999999)], $more))->save();

        return $i->fresh();
    };
});

function tarlacCovers(): void
{
    foreach (['Tarlac', 'Pangasinan', 'Zambales', 'Bataan', 'Nueva Ecija'] as $p) {
        Coverage::add(test()->tarlac->id, $p, null, test()->admin, true);
    }
}

it('knows the home warehouse of each place, with town exceptions, and changes nothing until it is set', function () {
    expect(Coverage::active())->toBeFalse()->and(Coverage::homeOf('Pangasinan', 'Dagupan'))->toBeNull();
    tarlacCovers();
    Coverage::add($this->cavite->id, 'Pangasinan', 'Rosales', $this->admin);
    expect(Coverage::homeOf('Province of Pangasinan', 'Dagupan City'))->toBe($this->tarlac->id)
        ->and(Coverage::homeOf('pangasinan', 'Rosales'))->toBe($this->cavite->id)
        ->and(Coverage::homeOf('Laguna', 'Calamba'))->toBe($this->cavite->id);
});

it('lets a warehouse ask for a province of another warehouse; the admin moves it', function () {
    tarlacCovers();
    ($this->box)('Bulacan', 'Malolos', 'BUL1');
    Livewire::test(WarehouseCoverage::class)->assertSee('Which warehouse delivers each province')->assertSee('Tarlac warehouse')
        ->set('newProvince.'.$this->tarlac->id, 'Bulacan')->call('addProvince', $this->tarlac->id)
        ->assertSee('Bulacan belongs to Cavite warehouse')->call('resolveConflict');
    expect(Coverage::homeOf('Bulacan', 'Malolos'))->toBe($this->tarlac->id); // the admin moved it

    // a warehouse user can only ask (Laguna has boxes, so it is Cavite's)
    ($this->box)('Laguna', 'Calamba', 'LAG1');
    $wu = User::factory()->create(['warehouse_id' => $this->tarlac->id, 'logistichub_id' => $this->admin->logistichub_id]);
    $this->actingAs($wu);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    Livewire::test(\App\Filament\Warehouse\Pages\WarehouseCoverage::class)
        ->set('newProvince.'.$this->tarlac->id, 'Laguna')->call('addProvince', $this->tarlac->id)->call('resolveConflict');
    expect(Coverage::homeOf('Laguna', 'Calamba'))->not->toBe($this->tarlac->id)
        ->and(CoverageRequest::where('province', 'Laguna')->value('status'))->toBe('pending');
})->skip(fn () => ! method_exists(User::class, 'factory'), 'no user factory');

it('sends a box for the other warehouse to the transfer at unload', function () {
    tarlacCovers();
    $c = Container::firstOrFail();
    $c->update(['warehouse_id' => $this->cavite->id, 'is_unloaded' => false]);
    $box = ($this->box)('Pangasinan', 'Dagupan', 'PAN1', ['container_id' => $c->id, 'is_verified' => false, 'verified_at' => null]);
    Livewire::test(Scaninvoice::class)->set('data.container_id', $c->id)->call('scan', 'PAN1')
        ->assertSet('lastStatus', 'success')->assertSee('transfer to Tarlac warehouse');
});

it('plans only this warehouse\'s provinces and makes one transfer per warehouse with only its boxes', function () {
    tarlacCovers();
    ($this->box)('Pangasinan', 'Dagupan', 'PAN1');
    ($this->box)('Pangasinan', 'Dagupan', 'PAN2');
    ($this->box)('Cavite', 'Dasmariñas', 'CAV1');

    Livewire::test(PlanTrips::class)->assertSee('Dasmari')->assertDontSee('Dagupan')->assertSee('2 boxes → transfer to Tarlac warehouse');

    Livewire::test(WarehouseTransfers::class)->assertSee('Cavite warehouse → Tarlac warehouse')->assertSee('Pangasinan')
        ->call('create', $this->tarlac->id)->assertSee('created');
    $trip = Whdeliverylog::where('warehouse_id', $this->tarlac->id)->firstOrFail();
    expect(Whtripinvoice::where('whdeliverylog_id', $trip->id)->pluck('invoice_id')->map(fn ($id) => Invoice::find($id)->invoice)->sort()->values()->all())->toBe(['PAN1', 'PAN2']);

    // a Cavite box put on the Tarlac transfer by hand is stopped at loading
    $cav = Invoice::where('invoice', 'CAV1')->first();
    Whtripinvoice::create(['whdeliverylog_id' => $trip->id, 'invoice_id' => $cav->id, 'warehouse_id' => $this->cavite->id, 'user_id' => $this->admin->id, 'truck_id' => $trip->truck_id]);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    $load = Livewire::test(\App\Filament\Warehouse\Pages\Whloaded::class)->set('data.deliverylog_id', $trip->id)
        ->call('scan', 'CAV1')->assertSet('lastStatus', 'warning');
    expect(Whtripinvoice::where('invoice_id', $cav->id)->value('is_loaded'))->toBeFalsy();
    $load->call('scan', 'PAN1')->assertSet('lastStatus', 'success');
    $load->call('scan', 'CAV1')->call('loadAnyway')->call('bypassWith', 'Other');
    expect(Whtripinvoice::where('invoice_id', $cav->id)->value('is_loaded'))->toBeTruthy();
});

it('suggests where to unload a container and moves it there', function () {
    tarlacCovers();
    $c = Container::firstOrFail();
    $c->update(['is_unloaded' => false, 'warehouse_id' => $this->cavite->id]);
    Invoice::where('container_id', $c->id)->update(['is_verified' => false]);
    foreach (range(1, 5) as $n) {
        ($this->box)('Tarlac', 'Capas', 'TW'.$n, ['container_id' => $c->id, 'is_verified' => false]);
    }
    Livewire::test(WhereToUnload::class)->assertSee($c->container_no)->assertSee('Unload at')->call('setWarehouse', $c->id, $this->tarlac->id);
    expect($c->fresh()->warehouse_id)->toBe($this->tarlac->id)
        ->and(Invoice::where('invoice', 'TW1')->value('warehouse_id'))->toBe($this->tarlac->id);
});
