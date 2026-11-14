<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Delivery\Pages\Dashboard;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\User;
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
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->actingAs($this->driver);
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_delivered', false)->firstOrFail();
});

it('scans a box, delivers it with several photos, and can undo right away', function () {
    $page = Livewire::test(Dashboard::class)
        ->call('go', 'scan')->assertSet('screen', 'scan')
        ->call('scan', $this->box->invoice)
        ->assertSet('sheet', 'found')->assertSee('On your truck')->assertSee('Deliver this box')
        ->call('startDeliver')->assertSee('Proof of delivery')->assertSee('Take at least 1 photo')
        ->call('confirmDelivered')->assertNotified('Take at least one photo first');

    foreach (['a', 'b', 'c'] as $n) {
        $page->set('upload', UploadedFile::fake()->image("{$n}.jpg", 800, 600))->call('savePhoto');
    }
    $page->assertSee('Delivered · 3 photos')
        ->call('removePhoto', 2)->assertSee('Delivered · 2 photos')
        ->call('confirmDelivered')
        ->assertSet('sheet', null)->assertSee($this->box->invoice.' delivered')->assertSee('Undo');

    $box = $this->box->fresh();
    expect($box->is_delivered)->toBeTruthy()->and($box->delivery_picture)->toHaveCount(2);
    Storage::disk('public')->assertExists($box->delivery_picture[0]);

    $page->call('undoJust')->assertSet('sheet', 'found');
    expect($this->box->fresh()->is_delivered)->toBeFalsy();
});

it("records a box that can't be delivered, with the reason's rules", function () {
    Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->call('startMiss')
        ->assertSee('you deliver it?')
        ->set('reason', FailedDeliveryReason::Other->value)
        ->call('saveMissed')->assertNotified('Please add a note for this reason.')
        ->set('note', 'Gate locked, dog inside')
        ->call('saveMissed')->assertNotified($this->box->invoice.' stays on your truck')->assertSet('sheet', null);

    $attempt = DeliveryAttempt::sole();
    expect($attempt->reason)->toBe(FailedDeliveryReason::Other)->and($attempt->note)->toBe('Gate locked, dog inside')
        ->and($this->box->fresh()->is_delivered)->toBeFalsy();
});

it('refuses a box that is not on the truck or already delivered', function () {
    Livewire::test(Dashboard::class)
        ->call('scan', 'NOT-ON-TRUCK')->assertSet('sheet', 'wrong')->assertSee('is not on your truck')
        ->call('closeSheet')->assertSet('sheet', null);

    $this->box->update(['is_delivered' => true]);
    Livewire::test(Dashboard::class)->call('scan', $this->box->invoice)->assertSet('sheet', 'wrong')->assertSee('already delivered');
});

it('lists boxes by to deliver, delivered and not delivered, with search', function () {
    $other = Tripinvoice::where('deliverylog_id', $this->trip->id)->whereKeyNot($this->box->id)->firstOrFail();

    Livewire::test(Dashboard::class)
        ->call('go', 'list')->assertSee('To deliver')->assertSee($this->box->invoice)
        ->set('search', $this->box->invoice)->assertSee($this->box->invoice)->assertDontSee($other->invoice.'<', false)
        ->set('search', '')->call('setTab', 'delivered')->assertDontSee($this->box->invoice.'</strong>', false)
        ->call('openBox', $this->box->id)->assertSet('screen', 'scan')->assertSet('sheet', 'found');
});

it('opens straight on the camera from the app shortcut', function () {
    $this->get('/delivery?view=scan')->assertOk()->assertSee('Type a box number');
    $this->get('/pwa/delivery/manifest.webmanifest')->assertJsonPath('shortcuts.0.url', '/delivery?view=scan');
});
