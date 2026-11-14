<?php

use App\Filament\Pages\AppIcons;
use App\Filament\Widgets\InstallApps;
use App\Models\User;
use App\Models\Warehouse;
use App\Support\InstallLinks;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
});

it('follows the app address, or the one Admin types, and warns about local addresses', function () {
    config(['app.url' => 'http://127.0.0.1:8001']);
    expect(InstallLinks::url('scan'))->toBe('http://127.0.0.1:8001/scan')
        ->and(InstallLinks::problem())->toContain('only works on this computer')
        ->and(InstallLinks::problem('https://dispatchsystem.test'))->toContain('.test')
        ->and(InstallLinks::problem('https://app.icargoxpress.net'))->toBeNull();

    config(['app.url' => 'https://app.icargoxpress.net']);
    expect(InstallLinks::url('driver'))->toBe('https://app.icargoxpress.net/delivery');

    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(AppIcons::class)
        ->assertSee('Install QR codes')->assertSee('Print poster')
        ->set('installBase', 'not a url')->call('saveInstallBase')->assertHasErrors('installBase')
        ->set('installBase', 'https://go.icargoxpress.net/')->call('saveInstallBase')->assertHasNoErrors();
    expect(InstallLinks::url('scan'))->toBe('https://go.icargoxpress.net/scan');
});

it('downloads the QR code and prints posters with the place name, for signed-in staff only', function () {
    config(['app.url' => 'https://app.icargoxpress.net']);
    $this->get('/install-qr/scan.png')->assertRedirect();

    $this->actingAs($this->admin);
    $png = $this->get('/install-qr/scan.png')->assertOk()->assertHeader('Content-Type', 'image/png');
    expect(substr($png->getContent(), 1, 3))->toBe('PNG');

    $this->get('/install-qr/driver/poster')->assertOk()->assertSee('Install the')->assertSee('app.icargoxpress.net/delivery')->assertSee('<svg', false);
    $this->get('/install-qr/scan/stickers')->assertOk()->assertSee('app.icargoxpress.net/scan');
    $this->get('/install-qr/other/poster')->assertNotFound();

    // the warehouse poster carries the warehouse name
    $wh = User::where('email', 'warehouse@example.com')->firstOrFail()->replicate();
    $wh->email = 'whstaff@example.com';
    $wh->save();
    $this->flushSession();
    $this->actingAs($wh)->get('/install-qr/scan/poster')->assertOk()->assertSee(Warehouse::find($wh->warehouse_id)->name);
});

it('shows the install page in the warehouse and partner hub panels, and the dashboard card can be hidden', function () {
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    $this->get('/warehouse/install-apps')->assertOk()->assertSee('Print stickers (6 per page)');
    $this->get('/warehouse')->assertOk()->assertSee('Install the apps on your phone');
    $this->flushSession();
    $this->actingAs(User::where('email', 'company@example.com')->firstOrFail());
    $this->get('/company/install-apps')->assertOk()->assertSee('/install-qr/driver/poster', false);
    $this->flushSession();
    $this->actingAs($this->admin);
    $this->get('/')->assertOk()->assertSee('Install the apps on your phone');

    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(InstallApps::class)->call('hide');
    expect(InstallLinks::hiddenFor($this->admin))->toBeTrue();
    $this->get('/')->assertOk()->assertDontSee('Install the apps on your phone');
});
