<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Filament\Warehouse\Pages\Hubloaded;
use App\Filament\Warehouse\Pages\Unloadedcontainer;
use App\Models\BoxPhoto;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\User;
use App\Support\DriverTrip;
use App\Support\ScanModes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('box');
    Storage::fake('public');
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    $base = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->user = $base->replicate()->fill(['email' => 'fast@example.com']);
    $this->user->save();
    $this->actingAs($this->user);
});

it('reads only Code 39 and QR, twice the same, with the camera off after 2 minutes', function () {
    $c = ScanModes::scanner();
    expect($c['formats'])->toBe(['code_39', 'qr_code'])
        ->and($c['confirm'])->toBe(2)->and($c['idleOff'])->toBe(120000)->and($c['hardAfter'])->toBe(3000);
    expect(file_get_contents(resource_path('js/barcode-scanner.js')))->toBe(file_get_contents(public_path('js/app/barcode-scanner.js')));
});

it('counts every trip and container of the list in one question, the same as one by one', function () {
    $hub = (int) $this->user->logistichub_id;
    $load = app(Hubloaded::class);
    $ids = $load->appChoices()->pluck('id')->all();
    $many = $load->progressMany($ids);
    foreach ($ids as $id) {
        $one = app(Hubloaded::class);
        $one->data = ['deliverylog_id' => $id];
        $p = $one->progress();
        expect($many[$id] ?? ['loaded' => 0, 'total' => 0])->toMatchArray(['loaded' => $p['loaded'], 'total' => $p['total']]);
    }
    $un = app(Unloadedcontainer::class);
    $cids = $un->appChoices()->pluck('id')->all();
    expect($cids)->not->toBeEmpty();
    $many = $un->progressMany($cids);
    foreach ($cids as $id) {
        $one = app(Unloadedcontainer::class);
        $one->data = ['container_id' => $id];
        expect($many[$id])->toMatchArray(['loaded' => $one->progress()['loaded'], 'total' => $one->progress()['total']]);
    }
});

it('opens the trip first, then Load next and space; pauses the scanner while a photo is taken', function () {
    $container = Container::where('warehouse_id', $this->user->warehouse_id)->firstOrFail();
    $box = Invoice::where('container_id', $container->id)->where('is_verified', false)->firstOrFail();

    $lw = Livewire::test(ScanApp::class)->call('open', 'unload')->call('pick', $container->id)
        ->assertSet('extrasReady', false)->assertSet('targetInfo.id', $container->id)
        ->call('loadExtras')->assertSet('extrasReady', true)
        ->call('scan', $box->invoice)->assertSet('status', 'success');
    expect($lw->viewData('paused'))->toBeTrue(); // photos are on: wait for Scan next box
    $lw->call('dismiss');
    expect($lw->viewData('paused'))->toBeFalse();
});

it('saves a photo sent in the back, only for a box just scanned', function () {
    $container = Container::where('warehouse_id', $this->user->warehouse_id)->firstOrFail();
    [$box, $other] = Invoice::where('container_id', $container->id)->where('is_verified', false)->take(2)->get();

    Livewire::test(ScanApp::class)->call('open', 'unload')->call('pick', $container->id)->call('scan', $box->invoice)->assertSet('status', 'success');

    $this->postJson(route('scan.box-photo'), ['invoice_id' => $box->id, 'condition' => 'damaged', 'photo' => UploadedFile::fake()->image('p.jpg', 1280, 720)])
        ->assertOk()->assertJsonStructure(['id']);
    $photo = BoxPhoto::latest('id')->first();
    expect($photo->invoice_id)->toBe($box->id)->and($photo->condition)->toBe('damaged')->and($photo->step)->toBe('unload')
        ->and($photo->user_id)->toBe($this->user->id);

    // a box not scanned by this person: refused
    $this->postJson(route('scan.box-photo'), ['invoice_id' => $other->id, 'photo' => UploadedFile::fake()->image('p.jpg')])->assertForbidden();
});

it('counts the driver trip in one question, the same as before', function () {
    $driver = User::whereHas('panelcategory', fn ($q) => $q->where('code', 'drv'))->get()->first(fn ($u) => DriverTrip::for($u)->trip);
    if (! $driver) {
        $this->markTestSkipped('No driver with a trip in the demo data.');
    }
    $t = DriverTrip::for($driver);
    $t->boxes()->limit(1)->update(['is_delivered' => true]);
    $b = $t->boxes()->where('is_delivered', false)->first();
    \App\Models\DeliveryAttempt::create(['tripinvoice_id' => $b->id, 'invoice_id' => $b->invoice_id, 'deliverylog_id' => $t->trip->id, 'user_id' => $driver->id, 'reason' => 'no_one_home']);
    $p = $t->progress();
    expect($p['total'])->toBe($t->boxes()->count())
        ->and($p['delivered'])->toBe($t->boxes()->where('is_delivered', true)->count())
        ->and($p['notDelivered'])->toBe($t->boxes()->where('is_delivered', false)->has('deliveryAttempts')->count())
        ->and($p['notDelivered'])->toBe(1);
});

it('has no property named like an action, so every button works in the browser', function () {
    foreach ([ScanApp::class, \App\Filament\Delivery\Pages\Dashboard::class, \App\Filament\Shared\Trips\PickingPage::class] as $class) {
        $r = new ReflectionClass($class);
        $props = collect($r->getProperties(ReflectionProperty::IS_PUBLIC))->reject->isStatic()->map->getName();
        $methods = collect($r->getMethods(ReflectionMethod::IS_PUBLIC))->reject->isStatic()->map->getName();
        expect($props->intersect($methods)->values()->all())->toBe([], $class);
    }
});

it('always opens a back camera and never keeps the front camera by itself (board 52)', function () {
    $js = file_get_contents(resource_path('js/barcode-scanner.js'));
    expect($js)->toContain("facingMode: { exact: 'environment' }")
        ->toContain("localStorage.removeItem('bb-scanner-camera')") // old saved camera (could be the front one) forgotten
        ->toContain('filter((c) => !isFront(c.label))')            // a black picture tries back cameras only
        ->not->toContain('this.$el.getClientRects()');            // buttons that hide themselves no longer stop the camera

    $container = Container::where('warehouse_id', $this->user->warehouse_id)->firstOrFail();
    Livewire::test(ScanApp::class)->call('open', 'unload')->call('pick', $container->id)
        ->assertSee('Switch camera')->assertSee('Choose the camera')->assertSee('Use a back camera?');
});

it('shows the start screen at once, then the to-do counts and Continue (board 54)', function () {
    $container = Container::where('warehouse_id', $this->user->warehouse_id)->firstOrFail();
    $box = Invoice::where('container_id', $container->id)->where('is_verified', false)->firstOrFail();

    $lw = Livewire::test(ScanApp::class)->assertSee('Daily work')->assertSee('Between warehouses')->assertSee('···')
        ->assertDontSee('Continue · ');
    $lw->call('open', 'unload')->call('pick', $container->id)->call('scan', $box->invoice)->call('home');
    $lw->assertSet('homeReady', false)->call('loadHome')
        ->assertSee('Continue · Unload container')->assertSee($container->container_no)->assertSee('to do');

    $lw->call('continueLast')->assertSet('screen', 'scan')->assertSet('mode', 'unload')->assertSet('choice', $container->id);
});

it('keeps the text of the Pick boxes messages readable on every colour', function () {
    // a general ".ds-sa .is-bad" rule once made the text the same pink as the message box
    expect(file_get_contents(resource_path('css/filament/admin/theme.css')))
        ->toContain('.ds-sa .ds-pk__toast.is-bad { --c: #ff8a80; color: #fff; }')       // dark glass, white words (board 56)
        ->toContain('background: rgb(10 18 25 / .8)');
    expect(file_get_contents(resource_path('js/barcode-scanner.js')))->toContain('window.dsResultSound');
});
