<?php

use App\Filament\Company\Pages\BoxPhotos as CompanyBoxPhotos;
use App\Filament\Pages\BoxPhotos;
use App\Filament\Warehouse\Pages\BoxPhotos as WarehouseBoxPhotos;
use App\Models\Container;
use App\Models\Invoice;
use App\Models\User;
use App\Support\Photos\BoxPhotos as Photos;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('box');
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    $this->container = Container::firstOrFail();
    $this->box = Invoice::where('container_id', $this->container->id)->firstOrFail();
    $this->photo = fn (string $step, ?string $cond = null) => Photos::store(UploadedFile::fake()->image('p.jpg', 640, 360), $step, $this->box,
        ['container_id' => $this->box->container_id], User::first(), $cond);
});

it('keeps the Box Photos look and shows the photos as a gallery by box', function () {
    $a = ($this->photo)('unload', 'damaged');
    $b = ($this->photo)('load');

    Livewire::test(BoxPhotos::class)
        ->assertSee('Every photo of every box, from container to doorstep.')->assertSee('Type or scan')
        ->set('q', $this->box->invoice)
        ->assertSee('All places')->assertSee('Any condition')
        ->assertSee('By box')->assertSee('All photos')->assertSee('Scan photos')
        ->assertSeeHtml('data-tile')->assertSeeHtml('[flex:133_1_12.5rem]')
        ->assertSee('Open '.$a->fileName())->assertSee('Open '.$b->fileName())
        ->assertSee('▶ Slideshow')->assertSee('Delete this photo');
});

it('shows all photos in one gallery, grouped by day', function () {
    $a = ($this->photo)('unload');
    $a->update(['taken_at' => now()->subDays(2)]);
    $b = ($this->photo)('load');

    Livewire::test(BoxPhotos::class)->set('q', $this->box->invoice)->set('arrange', 'all')
        ->assertSet('arrange', 'all')->assertDontSee('Scan photos')
        ->assertSee('Today · '.now()->format('D d M Y'))->assertSee(now()->subDays(2)->format('D d M Y'))
        ->assertSee('Open '.$a->fileName())->assertSee('Open '.$b->fileName());
});

it('uses the same gallery in the warehouse and company panels', function () {
    expect(is_subclass_of(WarehouseBoxPhotos::class, \App\Filament\Shared\BoxPhotosPage::class))->toBeTrue()
        ->and(is_subclass_of(CompanyBoxPhotos::class, \App\Filament\Shared\BoxPhotosPage::class))->toBeTrue();
});

it('gives the full-screen viewer a strip, a slideshow and download in galleries', function () {
    $js = file_get_contents(resource_path('js/photo-viewer.js'));
    expect($js)->toContain('dspv__strip')->toContain('▶ Slideshow')->toContain('⬇ Save');
});

it('reads the photo list again after every search, so the viewer never shows an empty photo', function () {
    ($this->photo)('unload');
    Livewire::test(BoxPhotos::class)->call('searchFor', $this->box->invoice)
        ->assertSeeHtml('x-ref="bpdata"')->assertSeeHtml('get items()')->assertSee('Loading photo…');
});
