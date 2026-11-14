<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Delivery\Pages\Deliveryinv;
use App\Filament\Resources\Deliverylogs\Pages\EditDeliverylog;
use App\Filament\Resources\Deliverylogs\RelationManagers\TripinvoicesRelationManager;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->firstOrFail();
});

function asDriver(): void
{
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    test()->actingAs(test()->driver);
}

it('lets a driver record why a box was not delivered', function () {
    asDriver();

    Livewire::test(Deliveryinv::class)
        ->callTableAction('cantDeliver', $this->box, data: [
            'reason' => FailedDeliveryReason::NoOneHome->value,
            'note' => 'Gate locked',
            'photos' => [UploadedFile::fake()->image('house.jpg')],
        ])
        ->assertHasNoTableActionErrors()
        ->assertSee('Not delivered · No one home');

    $attempt = DeliveryAttempt::firstOrFail();

    expect($attempt->reason)->toBe(FailedDeliveryReason::NoOneHome)
        ->and($attempt->note)->toBe('Gate locked')
        ->and($attempt->photos)->toHaveCount(1)
        ->and($attempt->user_id)->toBe($this->driver->id)
        ->and($this->box->fresh()->is_delivered)->toBeFalse(); // the box stays on the truck
});

it('asks for a photo or a note when the reason needs one', function () {
    asDriver();

    Livewire::test(Deliveryinv::class)
        ->callTableAction('cantDeliver', $this->box, data: ['reason' => FailedDeliveryReason::NoOneHome->value])
        ->assertHasTableActionErrors(['photos' => 'required']);

    Livewire::test(Deliveryinv::class)
        ->callTableAction('cantDeliver', $this->box, data: ['reason' => FailedDeliveryReason::Refused->value])
        ->assertHasTableActionErrors(['note' => 'required']);

    Livewire::test(Deliveryinv::class)
        ->callTableAction('cantDeliver', $this->box, data: ['reason' => FailedDeliveryReason::OutOfTime->value])
        ->assertHasNoTableActionErrors();

    expect(DeliveryAttempt::count())->toBe(1);
});

it('tells the dispatcher who created the trip', function () {
    app(TripAssignment::class)->recordFailedAttempt($this->box, $this->driver, FailedDeliveryReason::PhoneUnreachable);
    app(TripAssignment::class)->recordFailedAttempt($this->box, $this->driver, FailedDeliveryReason::OutOfTime);

    $dispatcher = $this->trip->user;
    expect($dispatcher->notifications()->count())->toBe(2)
        ->and($dispatcher->notifications()->get()->pluck('data.body')->join(' '))->toContain('attempt 2');
});

it('does not record an attempt for a box that is already delivered', function () {
    app(TripAssignment::class)->markDelivered($this->box, ['proof.jpg']);

    expect(fn () => app(TripAssignment::class)->recordFailedAttempt($this->box->fresh(), $this->driver, FailedDeliveryReason::OutOfTime))
        ->toThrow(DomainException::class);
});

it('only lets drivers report boxes on their own trip', function () {
    asDriver();
    $otherTrip = Deliverylog::withoutEvents(fn () => Deliverylog::create([
        'trip_number' => 'X1', 'trip_day' => 1, 'logistichub_id' => 1, 'eta' => now(),
        'departure_date' => now(), 'assigned_to' => 1, 'user_id' => 1, 'is_active' => true,
    ]));
    $this->box->update(['deliverylog_id' => $otherTrip->id]);

    Livewire::test(Deliveryinv::class)->assertCanNotSeeTableRecords([$this->box]);
    expect(DeliveryAttempt::count())->toBe(0);
});

it('shows the reason to the office on the trip', function () {
    app(TripAssignment::class)->recordFailedAttempt($this->box, $this->driver, FailedDeliveryReason::Rescheduled, 'Friday please');

    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs(User::where('email', 'admin@example.com')->first());

    Livewire::test(TripinvoicesRelationManager::class, [
        'ownerRecord' => $this->trip,
        'pageClass' => EditDeliverylog::class,
    ])
        ->loadTable()
        ->assertTableColumnFormattedStateSet('latestDeliveryAttempt.reason', 'Asked for another day', $this->box)
        ->assertTableActionVisible('deliveryAttempts', $this->box)
        ->mountTableAction('deliveryAttempts', $this->box)
        ->assertHasNoErrors();

    $history = view('filament.delivery-attempts', ['attempts' => $this->box->deliveryAttempts()->with('user', 'deliverylog')->get()])->render();

    expect($history)->toContain('Friday please')->toContain('Dan Demo')->toContain('Trip '.$this->trip->trip_number);
});
