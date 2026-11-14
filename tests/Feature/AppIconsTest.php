<?php

use App\Filament\Pages\AppIcons;
use App\Models\BrandAsset;
use App\Models\User;
use App\Support\Pwa;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Once;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
});

it('uploads a favicon and a driver app icon', function () {
    $this->actingAs($this->admin);
    $versionBefore = Pwa::version();

    Livewire::test(AppIcons::class)
        ->set('data.favicon', UploadedFile::fake()->image('tab.png', 64, 64))
        ->set('data.app_icon', UploadedFile::fake()->image('driver.png', 512, 512))
        ->call('save')
        ->assertHasNoErrors()
        ->assertNotified('Saved');

    $asset = BrandAsset::firstOrFail();
    expect($asset->favicon)->toStartWith('brand/favicon-')
        ->and($asset->app_icon)->toStartWith('brand/app-icon-');

    Once::flush();
    expect(Pwa::faviconUrl())->toContain($asset->favicon)
        ->and(Pwa::version())->not->toBe($versionBefore);

    $this->get('/pwa/delivery/icon-512.png')->assertOk()->assertHeader('Content-Type', 'image/png');
    $this->get('/pwa/delivery/icon-512.png?maskable=1')->assertOk();
    expect(json_encode(Pwa::manifest('delivery')))->toContain('maskable=1');
});

it('refuses an app icon that is too small', function () {
    $this->actingAs($this->admin);

    Livewire::test(AppIcons::class)
        ->set('data.app_icon', UploadedFile::fake()->image('tiny.png', 64, 64))
        ->call('save')
        ->assertHasErrors(['data.app_icon']);
});

it('puts the uploaded favicon on every panel', function () {
    Storage::disk('public')->put('brand/favicon-test.png', 'x');
    BrandAsset::create(['favicon' => 'brand/favicon-test.png']);

    foreach (['/login', '/warehouse/login', '/company/login', '/delivery/login'] as $page) {
        $this->get($page)->assertOk()->assertSee('brand/favicon-test.png', false)->assertSee('data-ds-favicon', false);
    }
});

it('is only for super admins', function () {
    $clerk = User::where('email', 'driver@example.com')->firstOrFail()->replicate(['full_name']);
    $clerk->fill(['email' => 'clerk@example.com', 'password' => 'password'])->save();
    $this->actingAs($clerk);
    expect(AppIcons::canAccess())->toBeFalse();

    $this->actingAs($this->admin);
    $this->get(AppIcons::getUrl())->assertOk()->assertSee('App icon &amp; favicon', false);
});

it('gives the Scan app its own icon and both apps their own name on the phone', function () {
    $this->actingAs($this->admin);

    Livewire::test(AppIcons::class)
        ->set('data.driver_label', 'SC Driver')
        ->set('data.scan_label', 'SC Scan')
        ->set('data.scan_icon', UploadedFile::fake()->image('scan.png', 512, 512))
        ->call('save')->assertHasNoErrors()->assertNotified('Saved');

    $asset = BrandAsset::firstOrFail();
    expect($asset->scan_icon)->toStartWith('brand/scan-icon-')->and($asset->app_icon)->toBeNull()
        ->and($asset->scan_label)->toBe('SC Scan');
    Once::flush();

    $this->get('/pwa/scan/manifest.webmanifest')->assertJsonPath('name', 'SC Scan')->assertJsonPath('short_name', 'SC Scan');
    $this->get('/pwa/delivery/manifest.webmanifest')->assertJsonPath('name', 'SC Driver');

    $scan = Pwa::iconPath('scan', 192);
    $driver = Pwa::iconPath('delivery', 192);
    expect(md5_file($scan))->not->toBe(md5_file($driver));

    Livewire::test(AppIcons::class)->assertSee('SC Scan')->assertSee('SC Driver');
});
