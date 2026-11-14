<?php

use App\Enums\FailedDeliveryReason;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\OfflineSubmission;
use App\Models\Tripinvoice;
use App\Models\User;
use Database\Seeders\DemoSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_delivered', false)->firstOrFail();
    $this->send = fn (array $data) => $this->actingAs($this->driver)->post('/delivery-offline/sync', $data + [
        'uuid' => (string) Str::uuid(), 'tripinvoice_id' => $this->box->id, 'at' => now()->subHour()->toIso8601String(),
    ], ['Accept' => 'application/json']);
});

it('gives the phone today\'s boxes and the reasons, only to a driver', function () {
    $this->getJson('/delivery-offline/trip')->assertStatus(401);
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail())->getJson('/delivery-offline/trip')->assertStatus(401);
    $this->flushSession();

    $this->actingAs($this->driver)->getJson('/delivery-offline/trip')->assertOk()
        ->assertJsonPath('trip.id', $this->trip->id)
        ->assertJsonPath('driver.id', $this->driver->id)
        ->assertJsonFragment(['invoice' => $this->box->invoice])
        ->assertJsonStructure(['csrf', 'saved_at', 'boxes' => [['id', 'invoice', 'codes', 'name', 'address', 'delivered']], 'reasons' => [['value', 'label', 'note', 'photo']]]);
});

it('saves a delivery made without signal at the time it happened, once', function () {
    $uuid = (string) Str::uuid();
    $at = now()->subMinutes(90)->startOfMinute();
    $data = ['uuid' => $uuid, 'type' => 'deliver', 'at' => $at->toIso8601String(),
        'photos' => [UploadedFile::fake()->image('a.jpg'), UploadedFile::fake()->image('b.jpg')]];

    ($this->send)($data)->assertOk()->assertJson(['status' => 'saved']);
    ($this->send)($data)->assertOk()->assertJson(['status' => 'saved']); // sent twice: no second delivery

    $box = $this->box->fresh();
    expect($box->is_delivered)->toBeTruthy()
        ->and($box->delivery_picture)->toHaveCount(2)
        ->and($box->delivered_at->equalTo($at))->toBeTrue()
        ->and(OfflineSubmission::count())->toBe(1);
});

it('needs a photo for a delivery and never trusts a time in the future', function () {
    ($this->send)(['type' => 'deliver'])->assertOk()->assertJson(['status' => 'conflict']);
    expect($this->box->fresh()->is_delivered)->toBeFalsy();

    ($this->send)(['type' => 'deliver', 'at' => now()->addDay()->toIso8601String(), 'photos' => [UploadedFile::fake()->image('a.jpg')]])
        ->assertJson(['status' => 'saved']);
    expect($this->box->fresh()->delivered_at->isFuture())->toBeFalse();
});

it("records a box that couldn't be delivered, with its reason and time", function () {
    $at = now()->subMinutes(30)->startOfMinute();
    ($this->send)(['type' => 'miss', 'reason' => FailedDeliveryReason::Other->value, 'note' => 'Gate locked', 'at' => $at->toIso8601String()])
        ->assertOk()->assertJson(['status' => 'saved']);

    $attempt = DeliveryAttempt::sole();
    expect($attempt->reason)->toBe(FailedDeliveryReason::Other)
        ->and($attempt->note)->toBe('Gate locked')
        ->and($attempt->created_at->equalTo($at))->toBeTrue()
        ->and($this->box->fresh()->is_delivered)->toBeFalsy();
});

it('does not force through what the office changed meanwhile', function () {
    $other = User::factory()->create();
    $this->box->update(['is_delivered' => true, 'delivered_by' => $other->id]);

    ($this->send)(['type' => 'deliver', 'photos' => [UploadedFile::fake()->image('a.jpg')]])
        ->assertOk()->assertJson(['status' => 'conflict'])->assertJsonPath('message', fn ($m) => str_contains($m, 'Someone else'));

    ($this->send)(['type' => 'deliver', 'tripinvoice_id' => 999999, 'photos' => [UploadedFile::fake()->image('a.jpg')]])
        ->assertJson(['status' => 'conflict'])->assertJsonPath('message', fn ($m) => str_contains($m, 'no longer on your trip'));

    expect(Storage::disk('public')->allFiles())->toBe([]);
});

it('opens the no-signal page and the service worker keeps it', function () {
    $this->get('/delivery-offline')->assertOk()->assertSee('dso-shell', false)->assertSee('driver-offline.js', false);
    $this->get('/sw.js')->assertOk()->assertSee("DRIVER_SHELL = '/delivery-offline'", false);
});
