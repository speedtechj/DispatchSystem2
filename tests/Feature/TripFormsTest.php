<?php

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Truck::query()->update(['is_assigned' => false, 'is_active' => true]);
});

/** [panel id, user email, namespace] for the three panels. */
dataset('panels', [
    'Admin' => ['admin', 'admin@example.com', 'App\\Filament\\Resources\\Deliverylogs\\Pages\\'],
    'Warehouse' => ['warehouse', 'warehouse@example.com', 'App\\Filament\\Warehouse\\Resources\\Deliverylogs\\Pages\\'],
    'Partner hub' => ['company', 'company@example.com', 'App\\Filament\\Company\\Resources\\Deliverylogs\\Pages\\'],
]);

function inPanel(string $panel, string $email): User
{
    $u = User::where('email', $email)->firstOrFail();
    test()->actingAs($u);
    Filament::setCurrentPanel(Filament::getPanel($panel));

    return $u;
}

it('shows the same Delivery trips list in every panel', function (string $panel, string $email, string $ns) {
    inPanel($panel, $email);
    Livewire::test($ns.'ListDeliverylogs')->assertSee('Delivery trips')->assertSee('+ New trip by hand')
        ->assertSee('Trip · made by')->assertTableActionExists('details');
})->with('panels');

it('makes a trip by hand from the New trip page in every panel', function (string $panel, string $email, string $ns) {
    $u = inPanel($panel, $email);
    $truck = Truck::where('logistichub_id', $u->logistichub_id)->first();
    if (! $truck) {
        $truck = Truck::query()->firstOrFail()->replicate();
        $truck->forceFill(['logistichub_id' => $u->logistichub_id, 'plate_no' => 'HUB 101', 'is_assigned' => false])->save();
    }

    $page = Livewire::test($ns.'CreateDeliverylog')->assertSee('New trip by hand')->assertSee('Trip summary')
        ->assertSee($truck->plate_no)->assertSee('Create trip and add boxes');
    $panel === 'company' ? $page->assertDontSee('Where does it go?') : $page->assertSee('Where does it go?');

    $page->call('pickTruck', $truck->id)->call('setDay', 'tomorrow')->set('waybill', 'WB-12345')
        ->assertSee('looks right')->call('createTrip', false)->assertHasNoErrors();

    $trip = Deliverylog::latest('id')->firstOrFail();
    expect($trip->made_by)->toBe('manual')->and((int) $trip->truck_id)->toBe($truck->id)
        ->and((int) $trip->assigned_to)->toBe((int) $u->logistichub_id)
        ->and((string) $trip->departure_date)->toContain(today()->addDay()->toDateString())
        ->and($trip->waybill_number)->toBe('WB-12345')
        ->and((bool) $truck->fresh()->is_assigned)->toBe($panel !== 'company');
})->with('panels');

it('sends a trip to a partner hub from the warehouse', function () {
    $u = inPanel('warehouse', 'warehouse@example.com');
    $hub = User::where('email', 'company@example.com')->value('logistichub_id');
    Livewire::test('App\\Filament\\Warehouse\\Resources\\Deliverylogs\\Pages\\CreateDeliverylog')
        ->call('pickGo', 'hub')->call('pickHub', $hub)->assertSee('→')->call('createTrip', true)->assertHasNoErrors()
        ->assertRedirectContains('ownerRecord=');
    expect((int) Deliverylog::latest('id')->value('assigned_to'))->toBe((int) $hub);
});

it('shows the Edit trip page with tiles, folded details and the boxes tabs in every panel', function (string $panel, string $email, string $ns) {
    $u = inPanel($panel, $email);
    $trip = Deliverylog::create(['trip_day' => 1, 'eta' => today()->addDay(), 'departure_date' => today(),
        'logistichub_id' => $u->logistichub_id, 'assigned_to' => $u->logistichub_id, 'user_id' => $u->id, 'made_by' => 'manual']);
    $inv = Invoice::firstOrFail();
    Tripinvoice::create(['deliverylog_id' => $trip->id, 'logistichub_id' => $u->logistichub_id, 'invoice' => $inv->invoice, 'invoice_id' => $inv->id]
        + ($panel === 'company' ? ['deliveryloghub_id' => $trip->id] : []));

    Livewire::test($ns.'EditDeliverylog', ['record' => $trip->getRouteKey()])
        ->assertSee('Trip '.$trip->trip_number)->assertSee('✎ By hand')->assertSee('✎ Edit details')
        ->assertSee('Not delivered')->assertSee('Priority');

    $rm = collect(glob(app_path(str_replace(['App\\', '\\'], ['', '/'], substr($ns, 0, -6)).'RelationManagers/TripinvoicesRelationManager.php')))->first();
    $class = substr($ns, 0, -6).'RelationManagers\\TripinvoicesRelationManager';
    expect($rm)->not->toBeNull();
    Livewire::test($class, ['ownerRecord' => $trip, 'pageClass' => $ns.'EditDeliverylog'])
        ->assertSee('Boxes on this trip')->assertSee('Not loaded')->assertSee('Problems')->assertSee('+ Assign invoice')
        ->assertTableBulkActionExists('bulkPriority')
        ->callTableBulkAction('bulkPriority', Tripinvoice::where('invoice_id', $inv->id)->get());
    expect((bool) $inv->fresh()->is_priority)->toBeTrue();
})->with('panels');
