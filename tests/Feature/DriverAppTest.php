<?php

use App\Models\User;
use Database\Seeders\DemoSeeder;
use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

beforeEach(fn () => $this->seed(DemoSeeder::class));

it('serves the Driver app manifest', function () {
    $this->get('/pwa/delivery/manifest.webmanifest')
        ->assertOk()
        ->assertHeader('Content-Type', 'application/manifest+json')
        ->assertJsonPath('short_name', 'Driver')
        ->assertJsonPath('start_url', '/delivery')
        ->assertJsonPath('scope', '/delivery')
        ->assertJsonPath('display', 'standalone')
        ->assertJsonPath('shortcuts.0.name', 'Scan a box')
        ->assertJsonCount(3, 'icons');
});

it('draws the app icon as a PNG', function () {
    $response = $this->get('/pwa/delivery/icon-192.png')->assertOk();

    [$width, $height] = getimagesize($response->baseResponse->getFile()->getPathname());
    expect([$width, $height])->toBe([192, 192]);

    $this->get('/pwa/delivery/icon-999.png')->assertNotFound();
});

it('serves the service worker and the offline page', function () {
    $this->get('/sw.js')->assertOk()->assertHeader('Content-Type', 'text/javascript; charset=utf-8')->assertSee("OFFLINE_URL = '/pwa/offline'", false);
    $this->get('/pwa/offline')->assertOk()->assertSee('No signal right now');
});

it('makes only the Delivery panel installable', function () {
    $this->get('/pwa/admin/manifest.webmanifest')->assertNotFound();

    $this->actingAs(User::where('email', 'driver@example.com')->firstOrFail())
        ->get('/delivery')
        ->assertOk()
        ->assertSee('/pwa/delivery/manifest"', false)
        ->assertSee('Install app')
        ->assertSee('Driver on your Home Screen', false);
});

it('leaves the other panels as plain websites', function () {
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail())
        ->get('/deliverylogs')
        ->assertOk()
        ->assertDontSee('manifest.webmanifest', false)
        ->assertDontSee('Install app');
});
