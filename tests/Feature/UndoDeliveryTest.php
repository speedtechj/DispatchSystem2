<?php

use App\Enums\UndoDeliveryReason;
use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Delivery\Pages\Deliveryinv;
use App\Filament\Resources\Deliverylogs\Pages\EditDeliverylog;
use App\Filament\Resources\Deliverylogs\RelationManagers\TripinvoicesRelationManager;
use App\Filament\Tables\DeliveryAttemptColumns;
use App\Models\Deliverylog;
use App\Models\DeliveryReversal;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->firstOrFail();

    $this->deliver = fn () => app(TripAssignment::class)->markDelivered($this->box, ['deliveries/door.jpg'], $this->driver);
});

function driverPanel(): void
{
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    test()->actingAs(test()->driver);
}

it('records when and by whom a box was delivered', function () {
    ($this->deliver)();

    $box = $this->box->fresh();
    expect($box->is_delivered)->toBeTruthy()
        ->and($box->delivered_by)->toBe($this->driver->id)
        ->and($box->delivered_at)->not->toBeNull();
});

it('lets the driver undo from the toast right after delivering', function () {
    ($this->deliver)();
    driverPanel();

    Livewire::test(Deliveryinv::class)
        ->dispatch('undo-delivery', tripinvoiceId: $this->box->id)
        ->assertNotified('Delivery undone');

    $reversal = DeliveryReversal::firstOrFail();
    expect($this->box->fresh()->is_delivered)->toBeFalsy()
        ->and($reversal->reason)->toBe(UndoDeliveryReason::TappedByMistake)
        ->and($reversal->photos)->toBe(['deliveries/door.jpg'])
        ->and($reversal->by_office)->toBeFalse();
});

it('shows Undo on the dashboard for 30 minutes, then Office only', function () {
    $this->travelTo(today()->setTime(10, 0)); // not near midnight: the list is today's deliveries
    ($this->deliver)();
    driverPanel();

    $this->travelTo(now()->addMinutes(10));
    Livewire::test(Dashboard::class)->assertSee('20 min left')->assertDontSee('Office only');

    $this->travelTo(now()->addMinutes(25));
    Livewire::test(Dashboard::class)->assertSee('Office only')->assertDontSee('min left');
});

it('lets the driver undo from the dashboard with a reason', function () {
    ($this->deliver)();
    driverPanel();

    Livewire::test(Dashboard::class)
        ->callAction('undoDelivery', data: ['reason' => UndoDeliveryReason::Other->value], arguments: ['tripinvoice' => $this->box->id])
        ->assertHasActionErrors(['note' => 'required']);

    Livewire::test(Dashboard::class)
        ->callAction('undoDelivery', data: ['reason' => UndoDeliveryReason::WrongBox->value], arguments: ['tripinvoice' => $this->box->id])
        ->assertHasNoActionErrors()
        ->assertNotified('Delivery undone');

    expect($this->box->fresh()->is_delivered)->toBeFalsy()
        ->and(DeliveryReversal::first()->reason)->toBe(UndoDeliveryReason::WrongBox)
        ->and($this->trip->user->notifications()->count())->toBeGreaterThan(0);
});

it('refuses a driver undo after 30 minutes or for someone else\'s delivery', function () {
    ($this->deliver)();

    $this->travelTo(now()->addMinutes(31));
    expect(fn () => app(TripAssignment::class)->undoDelivery($this->box->fresh(), $this->driver, UndoDeliveryReason::WrongBox))
        ->toThrow(DomainException::class, 'too late');

    $this->travelBack();
    $other = User::where('email', '!=', $this->driver->email)->where('email', 'like', '%@example.com')->where('id', '!=', $this->admin->id)->firstOrFail();
    expect(fn () => app(TripAssignment::class)->undoDelivery($this->box->fresh(), $other, UndoDeliveryReason::WrongBox))
        ->toThrow(DomainException::class);

    expect($this->box->fresh()->is_delivered)->toBeTruthy();
});

it('lets the office mark a box as not delivered any time and tells the driver', function () {
    ($this->deliver)();
    $this->travelTo(now()->addDays(2));

    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);

    Livewire::test(TripinvoicesRelationManager::class, ['ownerRecord' => $this->trip, 'pageClass' => EditDeliverylog::class])
        ->callTableAction('undoDelivery', $this->box, data: ['reason' => UndoDeliveryReason::ReceiverDidNotGetIt->value, 'note' => 'Customer called'])
        ->assertHasNoTableActionErrors()
        ->assertNotified('Marked as not delivered');

    $reversal = DeliveryReversal::firstOrFail();
    expect($this->box->fresh()->is_delivered)->toBeFalsy()
        ->and($reversal->by_office)->toBeTrue()
        ->and($reversal->delivered_by)->toBe($this->driver->id)
        ->and($this->driver->notifications()->count())->toBe(1);

    $html = view('filament.delivery-attempts', ['attempts' => DeliveryAttemptColumns::history($this->box->fresh())])->render();
    expect($html)->toContain('Delivery undone')->toContain('Receiver says they did not get the box')->toContain('Customer called');
});
