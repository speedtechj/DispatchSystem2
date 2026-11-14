<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Pages\ReturnBoxes;
use App\Filament\Pages\Routeinvoice;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->orderBy('id')->firstOrFail();
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();

    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
});

it('takes a scanned undelivered box off the trip and back to Assign invoices', function () {
    app(TripAssignment::class)->recordFailedAttempt($this->box, $this->driver, FailedDeliveryReason::NoOneHome, 'Gate locked', ['p.jpg']);

    Livewire::test(ReturnBoxes::class)
        ->set('data.deliverylog_id', $this->trip->id)
        ->call('scan', $this->box->invoice)
        ->assertSet('lastStatus', 'success')
        ->assertSet('returnedCount', 1)
        ->assertSee('No one home')                  // driver's reason on the result card
        ->assertSee('Gate locked');

    $invoice = Invoice::find($this->box->invoice_id);
    expect(Tripinvoice::find($this->box->id))->toBeNull()
        ->and($invoice->is_assigned)->toBeFalse()
        ->and($invoice->is_returned)->toBeTrue()
        ->and(DeliveryAttempt::where('invoice_id', $invoice->id)->count())->toBe(1); // history kept

    // Ready to be put on the next trip, with the reason shown.
    $this->get('/routeinvoice?ownerRecord='.$this->trip->id)->assertOk();
    Livewire::withQueryParams(['ownerRecord' => $this->trip->id])
        ->test(Routeinvoice::class)
        ->assertCanSeeTableRecords([$invoice])
        ->assertTableColumnFormattedStateSet('latestDeliveryAttempt.reason', 'No one home', $invoice);
});

it('refuses boxes that were delivered or are on another trip', function () {
    app(TripAssignment::class)->markDelivered($this->box, ['p.jpg']);

    Livewire::test(ReturnBoxes::class)
        ->set('data.deliverylog_id', $this->trip->id)
        ->call('scan', $this->box->invoice)
        ->assertSet('lastStatus', 'danger')
        ->call('scan', 'INV00012')
        ->assertSet('lastStatus', 'danger')
        ->assertSet('returnedCount', 0);

    expect(Tripinvoice::find($this->box->id))->not->toBeNull();
});

it('says when a box was already returned', function () {
    app(TripAssignment::class)->returnToInventory($this->box);

    Livewire::test(ReturnBoxes::class)
        ->set('data.deliverylog_id', $this->trip->id)
        ->call('scan', $this->box->invoice)
        ->assertSet('lastStatus', 'warning');
});

it('only lists this hub\'s trips that still have undelivered boxes', function () {
    Deliverylog::withoutEvents(fn () => Deliverylog::create([
        'trip_number' => 'OTHERHUB1', 'trip_day' => 1, 'logistichub_id' => 2, 'eta' => now(),
        'departure_date' => now(), 'assigned_to' => 2, 'user_id' => 1,
    ]));

    Livewire::test(ReturnBoxes::class)
        ->assertSee($this->trip->trip_number)
        ->assertDontSee('OTHERHUB1');

    Tripinvoice::where('deliverylog_id', $this->trip->id)->get()
        ->each(fn ($box) => app(TripAssignment::class)->markDelivered($box, ['p.jpg']));

    Livewire::test(ReturnBoxes::class)->assertDontSee($this->trip->trip_number.' ·');
});

it('returns a partner hub box to the hub\'s own list', function () {
    $this->box->update(['hub_assigned' => true, 'deliveryloghub_id' => $this->trip->id, 'is_loaded_hub' => true]);

    app(TripAssignment::class)->returnToHubInventory($this->box);

    $box = $this->box->fresh();
    expect($box)->not->toBeNull()
        ->and($box->hub_assigned)->toBeFalse()
        ->and($box->deliveryloghub_id)->toBeNull()
        ->and(Invoice::find($box->invoice_id)->is_returned)->toBeTrue();
});
