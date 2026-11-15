<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Models\BoxPhoto;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Unmanifested;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Support\ScanModes;
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
    Storage::fake('public');
    Filament::setCurrentPanel(Filament::getPanel('scan'));
});

/** A copy of a demo user without the super_admin role, so we test the account type alone. */
function scanUser(string $email): User
{
    $base = User::where('email', $email)->firstOrFail();
    $u = $base->replicate()->fill(['email' => 'scan-'.$email]);
    $u->save();

    return $u;
}

it('lets warehouse, partner hub and office accounts in, but not drivers', function () {
    $this->actingAs(scanUser('warehouse@example.com'))->get('/scan')->assertOk()->assertSee('Unload container')->assertSee('Warehouse unload');
    $this->flushSession();
    $this->actingAs(scanUser('company@example.com'))->get('/scan')->assertOk()->assertSee('Hub load')->assertDontSee('Unload container');
    $this->flushSession();
    $this->actingAs(scanUser('admin@example.com'))->get('/scan')->assertOk()->assertSee('Load truck');
    $this->flushSession();
    $this->actingAs(scanUser('driver@example.com'))->get('/scan')->assertForbidden();
});

it('gives each account type its own scans', function () {
    expect(array_keys(ScanModes::for(scanUser('warehouse@example.com'))))->toBe(['unload', 'load', 'wh_load', 'wh_unload', 'return', 'port', 'ret_receive'])
        ->and(array_keys(ScanModes::for(scanUser('company@example.com'))))->toBe(['hub_load', 'return', 'ship_receive'])
        ->and(array_keys(ScanModes::for(scanUser('admin@example.com'))))->toBe(['unload', 'load', 'return', 'port'])
        ->and(ScanModes::for(scanUser('driver@example.com')))->toBe([]);
});

it('unloads a container box by box, with an optional photo, using the same rules as Unload Container', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $container = Container::where('warehouse_id', $user->warehouse_id)->firstOrFail();
    $box = Invoice::where('container_id', $container->id)->where('is_verified', false)->firstOrFail();

    $page = Livewire::test(ScanApp::class)
        ->call('open', 'unload')->assertSet('screen', 'pick')->assertSee($container->container_no)
        ->call('pick', $container->id)->assertSet('screen', 'scan')
        ->call('scan', $box->invoice)
        ->assertSet('status', 'success')->assertSee('Verified · off the container')->assertSee('Add photo · optional')
        ->call('setCondition', 'damaged')->assertSee('What is wrong?')
        ->set('note', 'Corner crushed')
        ->set('boxPhoto', UploadedFile::fake()->image('p.jpg', 2000, 1500))
        ->call('saveBoxPhoto')->assertHasNoErrors();

    expect($box->fresh()->is_verified)->toBeTrue();
    $photo = BoxPhoto::sole();
    expect($photo->step)->toBe('unload')->and($photo->condition)->toBe('damaged')->and($photo->note)->toBe('Corner crushed')
        ->and($photo->container_id)->toBe($container->id)->and($photo->user_id)->toBe($user->id);

    // a box that is not on the manifest
    $page->call('scan', 'NOTONMANIFEST1')->assertSet('status', 'danger')->assertSet('missing', 'NOTONMANIFEST1')
        ->assertSee('Not on this container')
        ->callAction('unmanifested', data: ['attachment_pic' => [UploadedFile::fake()->image('u.jpg')], 'remarks' => 'Found inside'])
        ->assertHasNoActionErrors()->assertSet('missing', null);
    expect(Unmanifested::where('invoice', 'NOTONMANIFEST1')->where('container_id', $container->id)->exists())->toBeTrue();

    $page->call('finish')->assertSet('screen', 'done')->assertSee('Keep scanning')->call('home')->assertSet('screen', 'home');
});

it('loads a delivery truck and refuses a box from another trip', function () {
    $user = scanUser('admin@example.com');
    $this->actingAs($user);
    $trip = Deliverylog::where('logistichub_id', $user->logistichub_id)->whereNotNull('truck_id')->where('is_active', true)->firstOrFail();
    $row = Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', false)->first();
    if (! $row) {
        $row = Tripinvoice::where('deliverylog_id', $trip->id)->firstOrFail();
        $row->update(['is_loaded' => false]);
    }

    Livewire::test(ScanApp::class)
        ->call('open', 'load')->call('pick', $trip->id)
        ->call('scan', $row->invoice)->assertSet('status', 'success')->assertSee('Loaded on the truck')
        ->call('scan', 'NOPE-123')->assertSet('status', 'danger')->assertSee('Keep it aside, scan next');

    expect($row->fresh()->is_loaded)->toBeTruthy();
});

it('does not open a container or trip that is not yours, or a scan your account does not have', function () {
    $user = scanUser('company@example.com');
    $this->actingAs($user);
    $otherTrip = Deliverylog::where('logistichub_id', '!=', $user->logistichub_id)->firstOrFail();

    Livewire::test(ScanApp::class)
        ->call('open', 'unload')->assertSet('screen', 'home')
        ->call('open', 'hub_load')->assertSet('screen', 'pick')
        ->call('pick', $otherTrip->id)->assertSet('screen', 'pick')->assertNotified('That one is not open for you any more.');
});

it('installs as its own app', function () {
    $this->get('/pwa/scan/manifest.webmanifest')->assertOk()->assertJsonPath('short_name', 'Scan')->assertJsonPath('scope', '/scan');
    $this->get('/scan/login')->assertOk()->assertSee('Load and unload, box by box.')->assertSee('/pwa/scan/manifest"', false);
});

it('receives a warehouse transfer and adds the box to this warehouse', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $row = Whtripinvoice::firstOrFail();
    $row->update(['is_loaded' => true, 'is_unloaded' => false]);
    $trip = Whdeliverylog::findOrFail($row->whdeliverylog_id);
    $trip->update(['warehouse_id' => $user->warehouse_id]);
    $invoice = Invoice::findOrFail($row->invoice_id);
    $invoice->update(['warehouse_id' => null]);

    Livewire::test(ScanApp::class)
        ->call('open', 'wh_unload')->call('pick', $trip->id)
        ->call('scan', $invoice->invoice)->assertSet('status', 'success')->assertSee('Received · added to inventory');

    expect($row->fresh()->is_unloaded)->toBeTruthy()
        ->and($invoice->fresh()->warehouse_id)->toBe($user->warehouse_id);
});

it('hides finished and closed containers, with a link to show them', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $base = Container::where('warehouse_id', $user->warehouse_id)->firstOrFail();
    $open = $base->replicate()->fill(['container_no' => 'OPEN0000001', 'is_unloaded' => false, 'is_active' => true]);
    $open->save();
    $full = $base->replicate()->fill(['container_no' => 'FULL0000001', 'is_unloaded' => false, 'is_active' => true]);
    $full->save();
    $closed = $base->replicate()->fill(['container_no' => 'SHUT0000001', 'is_unloaded' => false, 'is_active' => false]);
    $closed->save();
    $box = Invoice::where('container_id', $base->id)->firstOrFail();
    $box->replicate()->fill(['invoice' => 'OPENBOX1', 'container_id' => $open->id, 'is_verified' => false])->save();
    $box->replicate()->fill(['invoice' => 'FULLBOX1', 'container_id' => $full->id, 'is_verified' => true])->save();
    $box->replicate()->fill(['invoice' => 'SHUTBOX1', 'container_id' => $closed->id, 'is_verified' => false])->save();

    Livewire::test(ScanApp::class)
        ->assertSee('waiting')
        ->call('open', 'unload')
        ->assertSee('OPEN0000001')->assertDontSee('FULL0000001')->assertDontSee('SHUT0000001')
        ->assertSee('Show finished')
        ->call('toggleFinished')
        ->assertSee('FULL0000001')->assertSee('SHUT0000001')->assertSee('· closed')->assertSee('Hide finished')
        ->call('pick', $full->id)->assertSet('screen', 'scan'); // still openable to re-check
});
