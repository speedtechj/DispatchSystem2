<?php

use App\Filament\Delivery\Pages\Dashboard as DriverDashboard;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\TripOverride;
use App\Models\User;
use App\Support\TripFlow;
use App\Support\Trips\TripLock;
use App\Support\Trips\TripRules;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->trip->truck->update(['is_assigned' => true]);
    \App\Models\TripCrew::where('deliverylog_id', $this->trip->id)->update(['role' => 'Lead Man']);
});

it('checks boxes, truck and crew before the trip can lock', function () {
    $checks = collect(TripLock::checks($this->trip))->keyBy('key');
    expect($checks['boxes']['ok'])->toBeFalse()->and($checks['truck']['ok'])->toBeTrue()->and($checks['crew']['ok'])->toBeTrue()
        ->and(TripLock::missing($this->trip))->toBe('not every box is loaded');

    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_loaded' => true]);
    expect(TripLock::isReady($this->trip))->toBeTrue();
});

it('locks on the Trip page only when ready, or asks the office', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->get(\App\Filament\Pages\Trip::getUrl(['trip' => $this->trip->id]))->assertOk()
        ->assertSee('Lock the trip')->assertSee('All boxes loaded')->assertSee('still to load')->assertSee('Not ready yet');

    // not ready, crew member (not office): the office is asked
    $clerk = User::factory()->create(['is_admin' => false, 'logistichub_id' => $this->admin->logistichub_id]);
    expect(TripLock::lock($this->trip, $clerk))->toBe('office')->and($this->trip->fresh()->is_lock)->toBeFalse();
    $ask = TripOverride::where('rule', 'lock_ready')->where('status', 'pending')->firstOrFail();
    TripRules::decide($ask, true, $this->admin);
    expect($this->trip->fresh()->is_lock)->toBeTrue();

    // ready: locks with no question
    $this->trip->fresh()->update(['is_lock' => false]);
    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_loaded' => true]);
    Livewire::withQueryParams(['trip' => $this->trip->id])->test(\App\Filament\Pages\Trip::class)->callAction('lock');
    expect($this->trip->fresh()->is_lock)->toBeTrue();
});

it('locks by itself when the lead man takes a ready trip; not ready, he cannot take it', function () {
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    $this->actingAs($this->driver);
    Livewire::test(DriverDashboard::class)->assertSee('Being loaded')->assertSee('Not ready: not every box is loaded')->assertDontSee('I take the trip');

    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_loaded' => true]);
    Livewire::test(DriverDashboard::class)->assertSee('it locks by itself')->call('takeTrip');
    $trip = $this->trip->fresh();
    expect($trip->is_lock)->toBeTrue()->and(TripFlow::stage($trip))->toBe('road');

    // switched off in Trip rules: the office must lock it first
    TripLock::setAutoOnTake(false);
    $other = Deliverylog::create(['truck_id' => null, 'logistichub_id' => $trip->logistichub_id, 'assigned_to' => $trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today()]);
    expect(TripLock::autoOnTake())->toBeFalse()->and(TripLock::isReady($other))->toBeFalse();
});
