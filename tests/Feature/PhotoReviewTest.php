<?php

use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Pages\BoxPhotoSettings;
use App\Models\AppSetting;
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
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $open = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_delivered', false)->get();
    $this->box = $open->first();
    $this->other = $open->first(fn ($b) => $b->invoice !== $this->box->invoice);
});

function onDriverApp(): void
{
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    test()->actingAs(test()->driver);
}

it('keeps the delivery open when another box is read by accident', function () {
    expect($this->other)->not->toBeNull();
    onDriverApp();

    $page = Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->call('startDeliver')
        ->set('upload', UploadedFile::fake()->image('door.jpg', 800, 600))->call('savePhoto');

    // the same box read again: nothing changes
    $page->call('scan', $this->box->invoice)->assertSet('sheet', 'deliver')->assertSet('otherCode', null)
        ->assertSee('Delivered · 1 photo');

    // another box: the sheet and its photo stay, the driver is asked
    $page->call('scan', $this->other->invoice)
        ->assertSet('sheet', 'deliver')->assertSet('boxId', $this->box->id)
        ->assertSet('otherCode', $this->other->invoice)
        ->assertSee('Another box read: '.$this->other->invoice)->assertSee('This delivery stays open')
        ->assertSee('Delivered · 1 photo');

    // ✕ stays on this box
    $page->set('otherCode', null)->assertDontSee('Another box read');

    // Open it: goes to the other box
    $page->call('scan', $this->other->invoice)->call('openOther')
        ->assertSet('sheet', 'found')->assertSet('boxId', $this->other->id)->assertSet('otherCode', null);
});

it('keeps the cannot-deliver sheet open too', function () {
    onDriverApp();

    Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->call('startMiss')
        ->call('scan', $this->other->invoice)
        ->assertSet('sheet', 'miss')->assertSet('otherCode', $this->other->invoice)->assertSee('This box stays open');
});

it('still opens the next box when nothing is being done', function () {
    onDriverApp();

    Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->assertSet('sheet', 'found')
        ->call('scan', $this->other->invoice)->assertSet('sheet', 'found')->assertSet('boxId', $this->other->id);
});

it('shows bigger proof photos that open full screen', function () {
    onDriverApp();

    Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->call('startDeliver')
        ->set('upload', UploadedFile::fake()->image('a.jpg', 800, 600))->call('savePhoto')
        ->set('upload', UploadedFile::fake()->image('b.jpg', 800, 600))->call('savePhoto')
        ->assertSeeHtml('ds-dr__grid is-big')->assertSee('1 / 2')->assertSee('2 / 2')->assertSee('⤢ Open')
        ->assertSeeHtml('dsPhotoViewer');
});

it('saves how long the Scan app waits before using a photo', function () {
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $admin->assignRole('super_admin');
    $this->actingAs($admin);

    expect((int) AppSetting::get('photos.auto_use', 3))->toBe(3);
    Livewire::test(BoxPhotoSettings::class)->assertSet('autoUse', 3)
        ->set('autoUse', 0)->call('save')->assertHasNoErrors();
    expect((int) AppSetting::get('photos.auto_use', 3))->toBe(0);

    Livewire::test(BoxPhotoSettings::class)->set('autoUse', 30)->call('save')->assertHasErrors('autoUse');
});

it('ships the photo viewer and never reloads the driver app over an open sheet', function () {
    $viewer = file_get_contents(resource_path('js/photo-viewer.js'));
    expect($viewer)->toContain('window.dsPhotoViewer')->toContain('window.dsPhotoCheck')->toContain("detail: { paused }");

    $offline = file_get_contents(resource_path('js/driver-offline.js'));
    expect($offline)->toContain(".ds-sa__sheet, .dspv");

    expect(collect(\Filament\Support\Facades\FilamentAsset::getScripts())->map->getId()->all())->toContain('photo-viewer');
});
