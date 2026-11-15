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
    // Truck A is still on the demo trip: the new trip is the next trip waiting.
    expect(TripFlow::crew($trip)->pluck('user_id')->all())->toBe([$this->driver->id])
        ->and(TripFlow::stage($trip))->toBe('waiting')
        ->and(TripFlow::nextAfter($this->trip)?->id)->toBe($trip->id);

    // Mark is sick-cover for this trip only: the truck team stays the same.
    TripFlow::setCrew($trip, [$this->sub->id], 'sick');
    $row = TripCrew::where('deliverylog_id', $trip->id)->sole();
    expect($row->user_id)->toBe($this->sub->id)->and($row->replaces_user_id)->toBe($this->driver->id)->and($row->reason)->toBe('sick')
        ->and(Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew')->all())->toBe([$this->driver->id])
        ->and(TripFlow::tripFor($this->sub))->toBeNull()                    // waits for the truck
        ->and(TripFlow::tripFor($this->driver)?->id)->toBe($this->trip->id);

    // The demo trip closes: the next trip starts, Mark sees it.
    TripFlow::release($this->trip, 'done');
    expect(TripFlow::stage($trip->fresh()))->toBe('planned')
        ->and($trip->fresh()->truck->is_assigned)->toBeTrue()
        ->and(TripFlow::tripFor($this->sub)?->id)->toBe($trip->id)
        ->and(TripFlow::tripFor($this->driver))->toBeNull();
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

it('shows today\'s crew board with the warnings, and puts people on trucks', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->sub->update(['is_crew' => true]);
    $this->trip->update(['is_lock' => true]);
    $this->trip->forceFill(['ready_at' => now()->subHour()])->saveQuietly();

    Livewire::test(\App\Filament\Pages\CrewBoard::class)
        ->assertSee($this->trip->truck->plate_no)->assertSee($this->trip->trip_number.' · Ready')
        ->assertSee('nobody took it yet')->assertSee('Mark '.$this->sub->last_name.' has no truck')
        ->call('addCrew', $this->trip->truck_id, $this->sub->id)
        ->assertDontSee('has no truck');
    expect(Truckcrew::where('truck_id', $this->trip->truck_id)->pluck('crew')->sort()->values()->all())->toBe(collect([$this->driver->id, $this->sub->id])->sort()->values()->all())
        ->and(TripFlow::crew($this->trip)->pluck('user_id')->all())->toContain($this->sub->id); // the trip did not leave yet: it follows
});

it('plans more trips for one truck: they start one after the other', function () {
    $mk = fn () => Deliverylog::create(['truck_id' => $this->trip->truck_id, 'logistichub_id' => $this->trip->logistichub_id, 'assigned_to' => $this->trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $second = $mk();
    $third = $mk();
    expect(TripFlow::stage($second))->toBe('waiting')->and(TripFlow::stage($third))->toBe('waiting')
        ->and(TripFlow::tripFor($this->driver)?->id)->toBe($this->trip->id);

    TripFlow::release($this->trip, 'done');
    expect(TripFlow::tripFor($this->driver)?->id)->toBe($second->id)
        ->and(TripFlow::stage($third->fresh()))->toBe('waiting')
        ->and(TripFlow::nextAfter($second->fresh())?->id)->toBe($third->id);

    TripFlow::release($second->fresh(), 'done');
    expect(TripFlow::tripFor($this->driver)?->id)->toBe($third->id)->and(TripFlow::stage($third->fresh()))->not->toBe('waiting');
});

it('shows one trip on one page: steps, crew, warnings, next trip, and the office buttons', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $next = Deliverylog::create(['truck_id' => $this->trip->truck_id, 'logistichub_id' => $this->trip->logistichub_id, 'assigned_to' => $this->trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);

    $this->get(\App\Filament\Pages\Trip::getUrl(['trip' => $this->trip->id]))->assertOk()
        ->assertSee('1 Planned')->assertSee('Leadman took the trip')->assertSee('Crew on this trip')
        ->assertSee($this->driver->full_name)->assertSee('Next trip waiting for')->assertSee($next->trip_number);
    $this->get(\App\Filament\Pages\Trip::getUrl(['trip' => $next->id]))->assertOk()
        ->assertSee('is still on trip '.$this->trip->trip_number)->assertSee('Next trip · waits for the truck');

    Livewire::withQueryParams(['trip' => $this->trip->id])->test(\App\Filament\Pages\Trip::class)
        ->callAction('lock')->callAction('tripCrew', data: ['crew' => [$this->sub->id], 'reason' => 'sick'])
        ->assertSee('instead of '.$this->driver->full_name);
    expect($this->trip->fresh()->is_lock)->toBeTrue()->and(TripFlow::stage($this->trip->fresh()))->toBe('ready');

    Livewire::withQueryParams(['trip' => $this->trip->id])->test(\App\Filament\Pages\Trip::class)
        ->callAction('releasetruct', data: ['reason' => 'cancelled']);
    expect($this->trip->fresh()->release_reason)->toBe('cancelled')->and(TripFlow::stage($next->fresh()))->toBe('planned');

    // The trip list opens the page.
    Livewire::test(ListDeliverylogs::class)->assertSee(\App\Filament\Pages\Trip::getUrl(['trip' => $next->id]), false);
});
