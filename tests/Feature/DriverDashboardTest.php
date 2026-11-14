<?php

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use Database\Seeders\DemoSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
});

it('opens on the driver\'s trip for today', function () {
    $box = Tripinvoice::where('deliverylog_id', $this->trip->id)->orderBy('id')->firstOrFail();
    Invoice::whereKey($box->invoice_id)->update(['is_priority' => true]);
    app(TripAssignment::class)->markDelivered(Tripinvoice::where('deliverylog_id', $this->trip->id)->orderByDesc('id')->first(), ['p.jpg']);

    $this->actingAs($this->driver)
        ->get('/delivery')
        ->assertOk()
        ->assertSee('Good ')                         // greeting
        ->assertSee($this->trip->trip_number)
        ->assertSee('ABC 1234')                      // truck plate
        ->assertSeeInOrder(['1', 'of 6 delivered'])
        ->assertSee('5 left')
        ->assertSee('Priority boxes')
        ->assertSee($box->invoice)
        ->assertSee('Your stops')                  // sorted stops with Navigate (Maps & routes)
        ->assertSee('Cebu City')
        ->assertSee('Check before handing over')
        ->assertSee('Damaged box')                   // issue reported at unloading
        ->assertSee('Delivered today');
});

it('celebrates when every box is delivered', function () {
    Tripinvoice::where('deliverylog_id', $this->trip->id)->get()
        ->each(fn ($box) => app(TripAssignment::class)->markDelivered($box, ['p.jpg']));

    $this->actingAs($this->driver)
        ->get('/delivery')
        ->assertOk()
        ->assertSee('All 6 boxes delivered')
        ->assertDontSee('Where to go next');
});

it('explains what to do when the driver is not on a trip', function () {
    Truckcrew::where('crew', $this->driver->id)->delete();

    $this->actingAs($this->driver)
        ->get('/delivery')
        ->assertOk()
        ->assertSee("You're not on a trip right now", false)
        ->assertDontSee($this->trip->trip_number);
});

it('does not show boxes from other trips', function () {
    $other = Deliverylog::withoutEvents(fn () => Deliverylog::create([
        'trip_number' => 'OTHER9', 'trip_day' => 1, 'logistichub_id' => 1, 'eta' => now(),
        'departure_date' => now(), 'assigned_to' => 1, 'user_id' => 1, 'is_active' => true,
    ]));
    $moved = Tripinvoice::where('deliverylog_id', $this->trip->id)->orderByDesc('id')->firstOrFail();
    $moved->update(['deliverylog_id' => $other->id]);

    $this->actingAs($this->driver)
        ->get('/delivery')
        ->assertSee('of 5 delivered')
        ->assertDontSee('OTHER9');
});
