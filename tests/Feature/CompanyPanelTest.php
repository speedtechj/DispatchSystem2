<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Company\Pages\HubDrivers;
use App\Filament\Company\Pages\IncomingBoxes;
use App\Filament\Company\Pages\NotDelivered;
use App\Filament\Company\Pages\TrackBox;
use App\Filament\Company\Widgets\HubOverview;
use App\Filament\Company\Widgets\HubToday;
use App\Filament\Company\Widgets\HubWeekScore;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\HubDesk;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->hub = Logistichub::where('hub_code', 'CEB')->firstOrFail();
    $this->user = User::where('email', 'company@example.com')->firstOrFail();
    $mainTrip = Deliverylog::where('logistichub_id', '!=', $this->hub->id)->firstOrFail();
    $mainTrip->update(['eta' => today()->subDays(3)]);

    // 3 loaded boxes from the main trip are handed to Cebu
    $this->handed = Tripinvoice::where('deliverylog_id', $mainTrip->id)->where('is_loaded', true)->get();
    Tripinvoice::whereKey($this->handed->modelKeys())->update(['logistichub_id' => $this->hub->id, 'hub_assigned' => false]);
    Invoice::whereKey($this->handed->pluck('invoice_id'))->update(['receiver_city' => 'Talisay City']);

    // Cebu has a driver and a free truck
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail()->replicate(['full_name']);
    $this->driver->fill(['email' => 'cebu-driver@example.com', 'logistichub_id' => $this->hub->id, 'is_crew' => true, 'password' => 'password'])->save();
    $this->truck = Truck::firstOrFail()->replicate()->fill(['plate_no' => 'CEB 0001', 'registration_no' => 'REG-CEB', 'logistichub_id' => $this->hub->id, 'is_assigned' => false, 'capacity' => 2]);
    $this->truck->save();
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => $this->driver->id, 'user_id' => $this->user->id]);

    Filament::setCurrentPanel(Filament::getPanel('company'));
    $this->actingAs($this->user);
    $this->desk = new HubDesk($this->hub->id);
});

it('groups incoming boxes by area and creates a trip from the picked areas', function () {
    $area = $this->desk->areas()->first();
    expect($area)->toMatchArray(['city' => 'Talisay City', 'boxes' => 3, 'oldest' => 3])
        ->and($this->desk->capacity())->toBe(2);

    Livewire::test(IncomingBoxes::class)
        ->assertSee('Talisay City')
        ->call('togglePick', $area['key'])
        ->assertSee('3 boxes from 1 area')
        ->assertSee('About 2 trucks at 2 boxes each')
        ->callAction('createTrip', data: ['truck_id' => $this->truck->id, 'departure_date' => today(), 'eta' => today()->addDay(), 'trip_day' => 1])
        ->assertHasNoActionErrors()
        ->assertRedirect();

    $trip = Deliverylog::where('logistichub_id', $this->hub->id)->latest('id')->firstOrFail();
    expect(Tripinvoice::where('deliveryloghub_id', $trip->id)->where('hub_assigned', true)->count())->toBe(3)
        ->and($this->desk->waiting()->count())->toBe(0);
});

it('lists failed boxes by reason and puts them on another trip or returns them', function () {
    $tripA = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $this->hub->id, 'assigned_to' => $this->hub->id, 'user_id' => $this->user->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today()]);
    $tripB = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $this->hub->id, 'assigned_to' => $this->hub->id, 'user_id' => $this->user->id, 'trip_day' => 1, 'eta' => today()->addDay(), 'departure_date' => today()->addDay()]);
    app(TripAssignment::class)->addToHubTrip($tripA, Tripinvoice::whereKey($this->handed->modelKeys())->get());

    [$first, $second] = Tripinvoice::whereKey($this->handed->modelKeys())->orderBy('id')->take(2)->get();
    app(TripAssignment::class)->recordFailedAttempt($first, $this->driver, FailedDeliveryReason::OutOfTime);
    app(TripAssignment::class)->recordFailedAttempt($second, $this->driver, FailedDeliveryReason::OutOfTime);

    $group = $this->desk->retryList()->first();
    expect($group['reason'])->toBe(FailedDeliveryReason::OutOfTime)->and($group['boxes'])->toHaveCount(2);

    Livewire::test(NotDelivered::class)
        ->assertSee('Ran out of time')
        ->callAction('move', data: ['trip' => $tripB->id], arguments: ['box' => $first->id])
        ->assertNotified("{$first->invoice} is on trip {$tripB->trip_number}")
        ->callAction('return', arguments: ['box' => $second->id])
        ->assertNotified("{$second->invoice} returned");

    expect($first->fresh()->deliveryloghub_id)->toBe($tripB->id)
        ->and($second->fresh()->deliveryloghub_id)->toBeNull()
        ->and(Invoice::find($second->invoice_id)->is_returned)->toBeTruthy()
        ->and($this->desk->retryList()->first()['boxes'])->toHaveCount(1);
});

it('ranks drivers and tracks a box from arrival to delivery', function () {
    $trip = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $this->hub->id, 'assigned_to' => $this->hub->id, 'user_id' => $this->user->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today()]);
    $box = Tripinvoice::findOrFail($this->handed->first()->id);
    app(TripAssignment::class)->addToHubTrip($trip, [$box]);
    app(TripAssignment::class)->recordFailedAttempt($box->fresh(), $this->driver, FailedDeliveryReason::OutOfTime);
    app(TripAssignment::class)->markDelivered($box->fresh(), ['deliveries/x.jpg'], $this->driver);

    $row = $this->desk->drivers()->firstWhere('name', $this->driver->full_name);
    expect($row)->toMatchArray(['delivered' => 1, 'failed' => 1, 'firstTry' => 0, 'truck' => 'CEB 0001']);

    $story = $this->desk->track($box->invoice);
    expect($story['status'])->toBe('Delivered')
        ->and($story['events']->pluck('title')->all())->toContain('Delivered', 'Not delivered: Ran out of time', 'Handed to your hub', 'Out for delivery');

    Livewire::test(TrackBox::class)->call('scanCode', strtolower($box->invoice))
        ->assertSet('code', $box->invoice)->assertSee('What happened')->assertSee('Handed to your hub');
    Livewire::test(TrackBox::class)->call('scanCode', 'NOT-OURS')
        ->assertSee('is not one of your hub');
    Livewire::test(HubDrivers::class)->assertSee($this->driver->full_name)->set('days', 7)->assertSuccessful();
});

it('shows the new dashboard and pages', function () {
    Livewire::test(HubOverview::class)->assertSee('Plan a trip')->assertSee('Your boxes right now')->assertSee('3 boxes are waiting');
    $trip = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $this->hub->id, 'assigned_to' => $this->hub->id, 'user_id' => $this->user->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today()]);
    app(TripAssignment::class)->addToHubTrip($trip, [Tripinvoice::findOrFail($this->handed->first()->id)]);

    Livewire::test(HubToday::class)->assertSee('Drivers today')->assertSee('waiting 2+ days')
        ->assertSee($this->driver->full_name)->assertDontSee($this->user->full_name);
    Livewire::test(HubWeekScore::class)->assertSee('Delivered this week')->assertSee('Your hub score');

    foreach ([IncomingBoxes::class, HubDrivers::class, NotDelivered::class, TrackBox::class] as $page) {
        $this->get($page::getUrl())->assertOk();
    }
    $this->get('/company')->assertOk()->assertSee('Incoming boxes');
});
