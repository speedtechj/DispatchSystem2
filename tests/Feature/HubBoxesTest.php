<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Company\Widgets\HubOverview;
use App\Filament\Resources\Logistichubs\Pages\ListLogistichubs;
use App\Filament\Widgets\HubBoxesWidget;
use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\HubBoxes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->main = Logistichub::where('hub_code', 'MNL')->firstOrFail();
    $this->cebu = Logistichub::where('hub_code', 'CEB')->firstOrFail();
    $this->trip = Deliverylog::where('logistichub_id', $this->main->id)->firstOrFail(); // 6 boxes, 3 loaded
    $this->counts = fn (Logistichub $hub) => HubBoxes::forHub($hub->id)->only(['boxes_waiting', 'boxes_loading', 'boxes_out', 'boxes_today', 'boxes_month', 'failed_today']);
});

function hubUser(string $panel, string $email): void
{
    Filament::setCurrentPanel(Filament::getPanel($panel));
    test()->actingAs(User::where('email', $email)->firstOrFail());
}

it('follows a box from the main hub to a partner hub and to the customer', function () {
    expect(($this->counts)($this->main))->toMatchArray(['boxes_waiting' => 0, 'boxes_loading' => 3, 'boxes_out' => 3])
        ->and(($this->counts)($this->cebu))->toMatchArray(['boxes_waiting' => 0, 'boxes_loading' => 0, 'boxes_out' => 0]);

    // Two loaded boxes are handed to Cebu: they leave Main's count and wait at Cebu
    $handed = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_loaded', true)->take(2)->get();
    Tripinvoice::whereKey($handed->modelKeys())->update(['logistichub_id' => $this->cebu->id, 'hub_assigned' => false]);

    expect(($this->counts)($this->main)['boxes_out'])->toBe(1)
        ->and(($this->counts)($this->cebu)['boxes_waiting'])->toBe(2);

    // Cebu puts them on its own trip: loading, then out, then one delivered and one failed
    $hubTrip = $this->trip->replicate(['trip_number'])->fill(['logistichub_id' => $this->cebu->id, 'assigned_to' => $this->cebu->id, 'trip_number' => 'CEB-1']);
    $hubTrip->save();
    Tripinvoice::whereKey($handed->modelKeys())->update(['deliveryloghub_id' => $hubTrip->id, 'hub_assigned' => true, 'is_loaded_hub' => false]);
    expect(($this->counts)($this->cebu))->toMatchArray(['boxes_waiting' => 0, 'boxes_loading' => 2, 'boxes_out' => 0]);

    Tripinvoice::whereKey($handed->modelKeys())->update(['is_loaded_hub' => true]);
    expect(($this->counts)($this->cebu)['boxes_out'])->toBe(2);

    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    $first = Tripinvoice::findOrFail($handed[0]->id);
    app(TripAssignment::class)->markDelivered($first, ['deliveries/x.jpg'], $driver);
    app(TripAssignment::class)->recordFailedAttempt(Tripinvoice::findOrFail($handed[1]->id), $driver, FailedDeliveryReason::OutOfTime);

    expect(($this->counts)($this->cebu))->toMatchArray(['boxes_out' => 1, 'boxes_today' => 1, 'boxes_month' => 1, 'failed_today' => 1])
        ->and(($this->counts)($this->main)['boxes_today'])->toBe(0);
});

it('warns a partner hub about boxes waiting too long', function () {
    Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_loaded', true)
        ->update(['logistichub_id' => $this->cebu->id, 'hub_assigned' => false]);
    $this->trip->update(['eta' => today()->subDays(3)]);

    $late = HubBoxes::waitingTooLong($this->cebu->id);
    expect($late['count'])->toBe(3)->and($late['oldest'])->not->toBeNull();

    hubUser('company', 'company@example.com');
    Livewire::test(HubOverview::class)
        ->assertSee('Your boxes right now')
        ->assertSee('3 boxes are waiting for a trip')
        ->assertSee('Plan a trip');
});

it('shows boxes by hub on the admin dashboard and sorts them', function () {
    hubUser('admin', 'admin@example.com');

    Livewire::test(HubBoxesWidget::class)
        ->assertSee('Boxes by hub')
        ->assertSeeInOrder(['Manila Main Hub', 'Cebu Partner Hub'])
        ->call('sortBy', 'name')
        ->assertSet('sortBy', 'name')
        ->assertSeeInOrder(['Cebu Partner Hub', 'Manila Main Hub']);

    $this->get('/')->assertOk()->assertSeeLivewire(HubBoxesWidget::class);
});

it('adds box columns to the Logistic Hubs list', function () {
    hubUser('admin', 'admin@example.com');
    Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_loaded', true)->take(2)
        ->update(['logistichub_id' => $this->cebu->id, 'hub_assigned' => false]);

    Livewire::test(ListLogistichubs::class)
        ->assertSuccessful()
        ->assertTableColumnStateSet('boxes_waiting', 2, $this->cebu)
        ->assertTableColumnStateSet('boxes_waiting', null, $this->main)
        ->sortTable('boxes_waiting', 'desc')
        ->assertCanSeeTableRecords([$this->cebu, $this->main], inOrder: true)
        ->sortTable('boxes_on_trucks', 'desc')
        ->assertCanSeeTableRecords([$this->main, $this->cebu], inOrder: true);
});

it('works out the same counts quickly as the full query', function () {
    foreach (Logistichub::all() as $hub) {
        $slow = HubBoxes::query()->whereKey($hub->id)->first()->only(['boxes_loading', 'boxes_out', 'boxes_today', 'boxes_month', 'failed_today']);
        $fast = collect(HubBoxes::counts(true)[$hub->id] ?? [])->only(array_keys($slow))->all() + array_fill_keys(array_keys($slow), 0);
        expect(array_map('intval', $fast))->toEqual(array_map('intval', $slow));
    }
});
