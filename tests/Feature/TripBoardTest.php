<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Company\Resources\Deliverylogs\Pages\ListDeliverylogs as HubTrips;
use App\Filament\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Resources\Deliverylogs\Pages\ListDeliverylogs as AdminTrips;
use App\Filament\Shared\Widgets\TripBoard as TripBoardWidget;
use App\Filament\Warehouse\Resources\Deliverylogs\Pages\ListDeliverylogs as WarehouseTrips;
use App\Filament\Warehouse\Resources\Whdeliverylogs\Pages\ListWhdeliverylogs as WarehouseMoves;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use App\Support\TripBoard;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->trip = Deliverylog::firstOrFail(); // 6 boxes, 3 loaded
    $this->board = TripBoard::make('delivery', $this->trip->logistichub_id);
    $this->statusOf = fn () => $this->board->statusOf($this->board->withProgress($this->board->tripQuery())->findOrFail($this->trip->id));
});

function boardUser(string $panel, string $email): User
{
    Filament::setCurrentPanel(Filament::getPanel($panel));
    $user = User::where('email', $email)->firstOrFail();
    test()->actingAs($user);

    return $user;
}

it('works out the trip status from its boxes', function () {
    expect(($this->statusOf)())->toBe('loading');

    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_loaded' => true]);
    $this->trip->update(['eta' => today()->addDay()]);
    expect(($this->statusOf)())->toBe('road');

    $this->trip->update(['eta' => today()->subDay()]);
    expect(($this->statusOf)())->toBe('late')
        ->and($this->board->whereStatus($this->board->tripQuery(), 'late')->pluck('id')->all())->toBe([$this->trip->id]);

    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_delivered' => true, 'delivered_at' => now()]);
    expect(($this->statusOf)())->toBe('done')
        ->and($this->board->whereStatus($this->board->tripQuery(), 'today')->count())->toBe(1);
});

it('counts problems today and lists the trip under Needs attention', function () {
    $box = Tripinvoice::where('deliverylog_id', $this->trip->id)->firstOrFail();
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    app(TripAssignment::class)->recordFailedAttempt($box, $driver, FailedDeliveryReason::OutOfTime);
    app(TripAssignment::class)->recordFailedAttempt($box, $driver, FailedDeliveryReason::OutOfTime);

    $problems = collect($this->board->cards())->firstWhere('id', 'problems');
    expect($problems['value'])->toBe('2')
        ->and($this->board->attention()->first()['detail'])->toBe('Ran out of time ×2')
        ->and($this->board->breakdown()->first())->toBe(['label' => 'Ran out of time', 'count' => 2]);
});

it('shows the widget and filters the Delivery Log by a card', function () {
    boardUser('admin', 'admin@example.com');

    Livewire::test(AdminTrips::class)
        ->assertSeeLivewire(TripBoardWidget::class)
        ->assertTableColumnFormattedStateSet('trip_status', 'Loading', $this->trip)
        ->filterTable('board', 'loading')
        ->assertCanSeeTableRecords([$this->trip])
        ->filterTable('board', 'done')
        ->assertCanNotSeeTableRecords([$this->trip]);

    Livewire::test(TripBoardWidget::class, ['kind' => 'delivery', 'resource' => DeliverylogResource::class])
        ->assertSee('Being loaded')
        ->assertSee('Boxes delivered per day');
});

it('releases the truck of a finished trip from the widget', function () {
    boardUser('admin', 'admin@example.com');
    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_loaded' => true, 'is_delivered' => true]);
    $this->trip->update(['is_current' => true]);
    $this->trip->truck->update(['is_assigned' => true]);

    Livewire::test(TripBoardWidget::class, ['kind' => 'delivery', 'resource' => DeliverylogResource::class])
        ->assertSee('Truck still in use')
        ->call('releaseTruck', $this->trip->id)
        ->assertNotified();

    expect($this->trip->fresh()->is_active)->toBeFalsy()
        ->and($this->trip->truck->fresh()->is_assigned)->toBeFalsy();
});

it('shows the boards on the warehouse and partner hub trip lists', function () {
    boardUser('warehouse', 'warehouse@example.com');
    Livewire::test(WarehouseTrips::class)->assertSuccessful()->assertSeeLivewire(TripBoardWidget::class);

    $move = Whtripinvoice::firstOrFail()->whdeliverylog;
    Livewire::test(WarehouseMoves::class)
        ->assertSuccessful()
        ->assertTableColumnFormattedStateSet('trip_status', 'Loading', $move);

    Whtripinvoice::where('whdeliverylog_id', $move->id)->update(['is_loaded' => true, 'is_unloaded' => true]);
    Livewire::test(WarehouseMoves::class)->assertTableColumnFormattedStateSet('trip_status', 'Delivered', $move)
        ->filterTable('board', 'today')->assertCanSeeTableRecords([$move]);

    boardUser('company', 'company@example.com');
    Livewire::test(HubTrips::class)->assertSuccessful()->assertSeeLivewire(TripBoardWidget::class);
});
