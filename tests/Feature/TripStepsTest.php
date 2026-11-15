<?php

use App\Filament\Delivery\Pages\Dashboard as DriverDashboard;
use App\Filament\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Models\Deliverylog;
use App\Models\TripCrew;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\DriverTrip;
use App\Support\TripFlow;
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
    $this->sub = $this->driver->replicate()->fill(['email' => 'mark@example.com', 'first_name' => 'Mark']);
    $this->sub->save();
});

it('copies the truck team onto a new trip, follows team changes until the trip leaves, and swaps for one trip only', function () {
    $trip = Deliverylog::create(['truck_id' => $this->trip->truck_id, 'logistichub_id' => $this->trip->logistichub_id, 'assigned_to' => $this->trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    expect(TripFlow::crew($trip)->pluck('user_id')->all())->toBe([$this->driver->id])
        ->and(TripFlow::stage($trip))->toBe('planned');

    // Mark is sick-cover for this trip only: the truck team stays the same.
    TripFlow::setCrew($trip, [$this->sub->id], 'sick');
    $row = TripCrew::where('deliverylog_id', $trip->id)->sole();
    expect($row->user_id)->toBe($this->sub->id)->and($row->replaces_user_id)->toBe($this->driver->id)->and($row->reason)->toBe('sick')
        ->and(Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew')->all())->toBe([$this->driver->id])
        ->and(TripFlow::tripFor($this->sub)?->id)->toBe($trip->id)
        ->and(TripFlow::tripFor($this->driver)?->id)->toBe($this->trip->id); // Ramon still has the older trip of the truck
});

it('goes Ready → On the road → Back → Closed, and the truck releases itself', function () {
    $this->trip->truck->update(['is_assigned' => true]);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    $this->actingAs($this->driver);

    expect(TripFlow::stage($this->trip))->toBe('loading');
    Livewire::test(DriverDashboard::class)->assertSee('Being loaded')->assertDontSee('I take the trip');

    $this->trip->update(['is_lock' => true]);
    Livewire::test(DriverDashboard::class)->assertSee('Trip ready')->assertSee('I take the trip · 6 boxes')->call('takeTrip');
    $trip = $this->trip->fresh();
    expect(TripFlow::stage($trip))->toBe('road')->and($trip->taken_by)->toBe($this->driver->id)->and($trip->taken_boxes)->toBe(6);

    $rows = Tripinvoice::where('deliverylog_id', $trip->id)->orderBy('id')->get();
    foreach ($rows->take(5) as $r) {
        app(TripAssignment::class)->markDelivered($r, ['p.jpg']);
    }
    expect($trip->fresh()->is_active)->toBeTrue();
    Livewire::test(DriverDashboard::class)->assertSee('Back at the hub')->call('backAtHub');
    expect(TripFlow::stage($trip->fresh()))->toBe('back');

    // The last box is scanned back at the hub: the trip closes by itself.
    app(TripAssignment::class)->returnToInventory($rows->last());
    $trip = $trip->fresh();
    expect($trip->is_active)->toBeFalse()->and($trip->release_reason)->toBe('auto')->and($trip->truck->fresh()->is_assigned)->toBeFalse();

    Livewire::test(DriverDashboard::class)->assertSee('done · truck released')->assertSee('All 5 boxes delivered');
});

it('closes the trip when the last box is delivered, even without Back at the hub', function () {
    foreach (Tripinvoice::where('deliverylog_id', $this->trip->id)->get() as $r) {
        app(TripAssignment::class)->markDelivered($r, ['p.jpg']);
    }
    expect($this->trip->fresh()->is_active)->toBeFalse()->and($this->trip->fresh()->closed_at)->not->toBeNull();
});

it('lets the office change the crew of a trip and release the truck with a reason', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(ListDeliverylogs::class)->assertSee('Loading')
        ->callTableAction('tripCrew', $this->trip, data: ['crew' => [$this->sub->id], 'reason' => 'day_off'])->assertHasNoTableActionErrors();
    expect(TripFlow::crew($this->trip)->pluck('user_id')->all())->toBe([$this->sub->id])
        ->and(DriverTrip::currentTrip($this->sub)?->id)->toBe($this->trip->id)
        ->and(DriverTrip::currentTrip($this->driver))->toBeNull();

    Livewire::test(ListDeliverylogs::class)->callTableAction('releasetruct', $this->trip, data: ['reason' => 'broke_down'])->assertHasNoTableActionErrors();
    expect($this->trip->fresh()->is_active)->toBeFalse()->and($this->trip->fresh()->release_reason)->toBe('broke_down');
});
