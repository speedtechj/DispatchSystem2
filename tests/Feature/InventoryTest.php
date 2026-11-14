<?php

use App\Filament\Resources\Inventories\Pages\ListInventories as AdminInventory;
use App\Filament\Warehouse\Pages\Whunloaded;
use App\Filament\Warehouse\Resources\Inventories\Pages\ListInventories as WarehouseInventory;
use App\Filament\Warehouse\Resources\Inventories\Widgets\InventoryAllWidget;
use App\Models\Deliverylog;
use App\Models\Inventory;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->calgary = Warehouse::where('name', 'Calgary Warehouse')->firstOrFail();
    $this->box = fn (string $invoice) => Invoice::where('invoice', $invoice)->firstOrFail();
    $this->floor = fn (?int $warehouseId = null) => Inventory::onFloor($warehouseId)->pluck('invoice')->sort()->values()->all();
});

function inventoryUser(string $panel, string $email): User
{
    Filament::setCurrentPanel(Filament::getPanel($panel));
    $user = User::where('email', $email)->firstOrFail();
    test()->actingAs($user);

    return $user;
}

/** A leftover trip row whose trip was deleted (old data without foreign keys). */
function leftoverTripRow(Invoice $box): void
{
    DB::statement('PRAGMA defer_foreign_keys = ON'); // the test transaction is rolled back, never checked
    Tripinvoice::where('invoice_id', $box->id)->update(['deliverylog_id' => 999999, 'is_loaded' => true]);
}

it('counts boxes that are not on any trip, and drops boxes loaded on a truck', function () {
    // Demo: INV1-3 loaded on the trip, INV4-6 on the trip but not loaded,
    // INV7-8 waiting for a warehouse truck, INV9+ not unloaded from the container yet.
    expect(($this->floor)())->toBe(['INV00004', 'INV00005', 'INV00006', 'INV00007', 'INV00008']);

    app(TripAssignment::class)->returnToInventory(Tripinvoice::where('invoice', 'INV00004')->firstOrFail());
    expect(($this->floor)())->toContain('INV00004'); // back on the floor with no trip row at all
});

it('ignores trip rows whose trip no longer exists', function () {
    leftoverTripRow(($this->box)('INV00005'));

    expect(($this->floor)())->toContain('INV00005');

    inventoryUser('admin', 'admin@example.com');
    Livewire::test(AdminInventory::class)
        ->assertSuccessful()
        ->assertTableColumnStateSet('currentTrip.deliverylog.trip_number', null, Inventory::where('invoice', 'INV00005')->first());
});

it('lets a box with a leftover row go on a new trip, and cleans leftovers on request', function () {
    $box = ($this->box)('INV00005');
    leftoverTripRow($box);
    inventoryUser('admin', 'admin@example.com');

    $this->artisan('inventory:clean')->expectsOutputToContain('--fix')->assertSuccessful();
    expect(Tripinvoice::where('invoice_id', $box->id)->count())->toBe(1); // report only

    expect(app(TripAssignment::class)->addToDeliveryTrip(Deliverylog::firstOrFail(), [$box]))->toBe(1);

    leftoverTripRow(($this->box)('INV00006'));
    $this->artisan('inventory:clean --fix')->assertSuccessful();
    expect(Tripinvoice::whereDoesntHave('deliverylog')->count())->toBe(0)
        ->and(($this->box)('INV00006')->is_assigned)->toBeFalsy();
});

it('moves a box to Tarlac only when Tarlac unloads it', function () {
    $tarlac = Warehouse::create(['name' => 'Tarlac Warehouse', 'address' => 'Tarlac', 'city' => 'Tarlac City', 'province' => 'Tarlac', 'user_id' => 1]);
    $tarlacUser = User::where('email', 'warehouse@example.com')->firstOrFail()->replicate(['full_name']);
    $tarlacUser->fill(['email' => 'tarlac@example.com', 'warehouse_id' => $tarlac->id, 'password' => 'password'])->save();
    $tarlacUser->syncRoles(User::where('email', 'warehouse@example.com')->first()->roles);

    $row = Whtripinvoice::whereHas('invoice', fn ($q) => $q->where('invoice', 'INV00007'))->firstOrFail();
    $toTarlac = Whdeliverylog::create([
        'truck_id' => $row->truck_id, 'warehouse_id' => $tarlac->id, 'user_whid' => $this->calgary->id,
        'departure_date' => now(), 'delivery_date' => now()->addDay(), 'user_id' => $row->user_id, 'trip_number' => 'TAR-1',
    ]);
    $row->update(['whdeliverylog_id' => $toTarlac->id]);

    // Waiting in Calgary for the truck: still Calgary's.
    expect(($this->floor)($this->calgary->id))->toContain('INV00007')
        ->and(($this->floor)($tarlac->id))->toBe([]);

    // Loaded on the truck: in neither warehouse, shown as on the way to Tarlac.
    $row->update(['is_loaded' => true]);
    expect(($this->floor)($this->calgary->id))->not->toContain('INV00007')
        ->and(($this->floor)($tarlac->id))->toBe([]);

    inventoryUser('warehouse', 'tarlac@example.com');
    Livewire::test(InventoryAllWidget::class)->assertSeeInOrder(['On the way here', '1']);

    // Unloaded in Tarlac: now Tarlac's.
    Livewire::test(Whunloaded::class)
        ->set('data.deliverylog_id', $toTarlac->id)
        ->call('scan', 'INV00007')
        ->assertSet('lastStatus', 'success');

    expect(($this->floor)($tarlac->id))->toBe(['INV00007'])
        ->and(($this->floor)($this->calgary->id))->not->toContain('INV00007');

    Livewire::test(WarehouseInventory::class)->assertSuccessful()->assertCanSeeTableRecords(Inventory::where('invoice', 'INV00007')->get());
});
