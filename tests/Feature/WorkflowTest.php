<?php

use App\Filament\Delivery\Pages\Deliveryinv;
use App\Filament\Pages\Routeinvoice;
use App\Filament\Pages\Scaninvoice;
use App\Filament\Pages\Scanload;
use App\Filament\Resources\Deliverylogs\Pages\EditDeliverylog;
use App\Filament\Warehouse\Pages\Whunloaded;
use App\Models\AppSetting;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Unmanifested;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Features\SupportLockedProperties\CannotUpdateLockedPropertyException;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
});

function asPanelUser(string $panel, string $email): User
{
    Filament::setCurrentPanel(Filament::getPanel($panel));
    $user = User::where('email', $email)->firstOrFail();
    test()->actingAs($user);

    return $user;
}

describe('trip numbers', function () {
    it('gives every new trip a unique, increasing number for the hub', function () {
        asPanelUser('admin', 'admin@example.com');

        $numbers = collect(range(1, 5))->map(fn () => Deliverylog::create([
            'truck_id' => null, 'trip_day' => 1, 'logistichub_id' => $this->admin->logistichub_id,
            'eta' => now(), 'departure_date' => now(), 'assigned_to' => $this->admin->logistichub_id,
            'user_id' => $this->admin->id,
        ])->trip_number);

        expect($numbers->unique())->toHaveCount(5)
            ->and($numbers->first())->toStartWith('MNL');
    });
});

describe('load truck scan station', function () {
    it('loads a box that is on the selected trip and shows progress', function () {
        asPanelUser('admin', 'admin@example.com');
        $box = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_loaded', false)->firstOrFail();

        Livewire::test(Scanload::class)
            ->set('data.deliverylog_id', $this->trip->id)
            ->call('scan', ' '.strtolower($box->invoice).' ')
            ->assertSet('lastStatus', 'success')
            ->assertSee($box->invoice)
            ->assertSee('Boxes loaded on this trip');

        expect($box->fresh()->is_loaded)->toBeTrue();
    });

    it('asks for a trip before scanning', function () {
        asPanelUser('admin', 'admin@example.com');

        Livewire::test(Scanload::class)
            ->call('scan', 'INV00001')
            ->assertSet('lastStatus', 'warning');
    });

    it('refuses a box that is not on the trip', function () {
        asPanelUser('admin', 'admin@example.com');

        Livewire::test(Scanload::class)
            ->set('data.deliverylog_id', $this->trip->id)
            ->call('scan', 'INV00012')
            ->assertSet('lastStatus', 'danger');
    });

    it('marks the truck as on the road once every box is loaded', function () {
        asPanelUser('admin', 'admin@example.com');
        $page = Livewire::test(Scanload::class)->set('data.deliverylog_id', $this->trip->id);

        AppSetting::put('maps.warn_early', 0); // scanned in any order here
        Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_loaded', false)
            ->pluck('invoice')
            ->each(fn ($invoice) => $page->call('scan', $invoice));

        expect($this->trip->fresh()->is_current)->toBeTrue()
            ->and($this->trip->truck->fresh()->is_assigned)->toBeTrue();
    });
});

describe('unload container scan station', function () {
    it('verifies a manifested box and records problems against it', function () {
        asPanelUser('admin', 'admin@example.com');
        $container = Container::firstOrFail();
        $box = Invoice::where('container_id', $container->id)->where('is_verified', false)->firstOrFail();

        Livewire::test(Scaninvoice::class)
            ->set('data.container_id', $container->id)
            ->call('scan', $box->invoice)
            ->assertSet('lastStatus', 'success')
            ->callAction('reportIssue', data: [
                'boxissue_id' => 1,
                'remarks' => 'Wet box',
                'attachment_pic' => null,
            ])
            ->assertHasActionErrors(['attachment_pic' => 'required']);

        expect($box->fresh()->is_verified)->toBeTrue();
    });

    it('offers to record an unmanifested box', function () {
        asPanelUser('admin', 'admin@example.com');
        $container = Container::firstOrFail();

        $page = Livewire::test(Scaninvoice::class)
            ->set('data.container_id', $container->id)
            ->call('scan', 'NOT-ON-LIST')
            ->assertSet('lastStatus', 'danger')
            ->assertSet('missingCode', 'NOT-ON-LIST')
            ->assertActionVisible('unmanifested');

        expect(Unmanifested::count())->toBe(0);
    });
});

describe('assigning invoices to a trip', function () {
    it('adds selected invoices and skips ones already on a trip', function () {
        asPanelUser('admin', 'admin@example.com');
        $free = Invoice::where('is_assigned', false)->where('is_verified', true)->get();
        $taken = Invoice::where('is_assigned', true)->first();

        $added = app(TripAssignment::class)->addToDeliveryTrip($this->trip, $free->push($taken));

        expect($added)->toBe($free->count() - 1)
            ->and(Invoice::whereIn('id', $free->pluck('id'))->where('is_assigned', false)->count())->toBe(0);
    });

    it('does not let anyone add invoices to a locked trip', function () {
        $this->trip->update(['is_lock' => true]);

        expect(fn () => app(TripAssignment::class)->addToDeliveryTrip($this->trip, Invoice::limit(1)->get()))
            ->toThrow(DomainException::class);
    });

    it('does not allow the trip of the assignment screen to be swapped from the browser', function () {
        asPanelUser('admin', 'admin@example.com');
        $this->get('/routeinvoice?ownerRecord='.$this->trip->id)->assertOk();

        expect(fn () => Livewire::withQueryParams(['ownerRecord' => $this->trip->id])
            ->test(Routeinvoice::class)
            ->set('ownerRecord', 999))
            ->toThrow(CannotUpdateLockedPropertyException::class);
    });

    it('returns a box to the pool when it is removed from a trip', function () {
        $row = Tripinvoice::firstOrFail();

        app(TripAssignment::class)->removeFromDeliveryTrip($row, returned: true);

        $invoice = Invoice::find($row->invoice_id);
        expect(Tripinvoice::find($row->id))->toBeNull()
            ->and($invoice->is_assigned)->toBeFalsy()
            ->and($invoice->is_returned)->toBeTruthy();
    });
});

describe('editing a trip', function () {
    it('keeps the truck marked as in use when the truck did not change', function () {
        asPanelUser('admin', 'admin@example.com');
        $this->trip->truck->update(['is_assigned' => true]);

        Livewire::test(EditDeliverylog::class, ['record' => $this->trip->getRouteKey()])
            ->fillForm(['trip_day' => 2])
            ->call('save');

        expect($this->trip->truck->fresh()->is_assigned)->toBeTruthy();
    });
});

describe('warehouse unloading', function () {
    it('does not move a box to this warehouse when it belongs to another trip', function () {
        $user = asPanelUser('warehouse', 'warehouse@example.com');
        $row = Whtripinvoice::firstOrFail();
        $row->update(['is_loaded' => true]);
        $otherTrip = Whdeliverylog::create([
            'truck_id' => $row->truck_id, 'warehouse_id' => $user->warehouse_id, 'departure_date' => now(),
            'delivery_date' => now(), 'user_id' => $user->id, 'user_whid' => $user->warehouse_id,
        ]);
        $invoice = Invoice::find($row->invoice_id);
        $invoice->update(['warehouse_id' => null]);

        Livewire::test(Whunloaded::class)
            ->set('data.deliverylog_id', $otherTrip->id)
            ->call('scan', $invoice->invoice)
            ->assertSet('lastStatus', 'danger');

        expect($invoice->fresh()->warehouse_id)->toBeNull()
            ->and($row->fresh()->is_unloaded)->toBeFalsy();
    });
});

describe('driver deliveries', function () {
    it('only lets a driver deliver boxes from their own trip', function () {
        asPanelUser('delivery', 'driver@example.com');
        $onTrip = Tripinvoice::where('deliverylog_id', $this->trip->id)->firstOrFail();

        Livewire::test(Deliveryinv::class)
            ->call('scanInvoice', 'INV00012')
            ->assertSet('scannedId', null)
            ->call('scanInvoice', $onTrip->invoice)
            ->assertSet('scannedId', $onTrip->id);
    });

    it('marks the invoice delivered everywhere once the driver confirms', function () {
        $row = Tripinvoice::firstOrFail();

        app(TripAssignment::class)->markDelivered($row, ['proof/photo.jpg']);

        expect($row->fresh()->is_delivered)->toBeTruthy()
            ->and($row->fresh()->delivery_picture)->toBe(['proof/photo.jpg'])
            ->and(Invoice::find($row->invoice_id)->is_delivered)->toBeTruthy();
    });
});

it('hides other hubs\' trips', function () {
    asPanelUser('admin', 'admin@example.com');
    $otherHubTrip = Deliverylog::withoutEvents(fn () => Deliverylog::create([
        'trip_number' => 'CEB999', 'trip_day' => 1, 'logistichub_id' => 2, 'eta' => now(),
        'departure_date' => now(), 'assigned_to' => 2, 'user_id' => $this->admin->id,
    ]));

    $this->get("/deliverylogs/{$otherHubTrip->id}/edit")->assertNotFound();
    $this->get("/deliverylogs/{$this->trip->id}/edit")->assertOk();
});
