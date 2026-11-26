<?php

use App\Filament\Company\Pages\BoxPhotos as HubBoxPhotos;
use App\Filament\Company\Pages\LoadTruck;
use App\Filament\Company\Pages\ReturnBoxes as HubReturnBoxes;
use App\Filament\Pages\BoxPhotos;
use App\Filament\Pages\BoxPhotoSettings;
use App\Filament\Pages\Scaninvoice;
use App\Filament\Pages\Scanload;
use App\Filament\Resources\Searchinvs\Pages\ListSearchinvs;
use App\Filament\Warehouse\Pages\Whloaded;
use App\Filament\Warehouse\Pages\Whunloaded;
use App\Mail\BoxPhotosMail;
use App\Models\BoxPhoto;
use App\Models\BoxPhotoEmail;
use App\Models\Consolidator;
use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Logistichub;
use App\Models\PhotoSetting;
use App\Models\Searchinv;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Photos\BoxAlbum;
use App\Support\Photos\BoxPhotos as Photos;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Once;
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
    $this->box = Invoice::where('container_id', $this->container->id)->where('is_verified', false)->firstOrFail();
});

function unloadPage($test)
{
    return Livewire::test(Scaninvoice::class)
        ->set('data.container_id', $test->container->id)
        ->call('scan', $test->box->invoice)
        ->assertSet('lastStatus', 'success');
}

it('lets staff add any number of optional photos to the box just scanned', function () {
    $page = unloadPage($this)
        ->assertSee('Add photo (optional)')
        ->call('setPhotoCondition', 'damaged')
        ->assertSee('Tip: add a photo of this Damaged box')
        ->set('photoNote', 'Corner crushed')
        ->set('boxPhoto', UploadedFile::fake()->image('big.jpg', 3200, 2400))
        ->call('saveBoxPhoto')
        ->assertHasNoErrors()
        ->assertNotified('Photo saved for '.$this->box->invoice)
        ->set('boxPhoto', UploadedFile::fake()->image('label.jpg', 800, 600))
        ->call('saveBoxPhoto')
        ->assertSee('2 photos saved');

    $photos = BoxPhoto::orderBy('id')->get();
    expect($photos)->toHaveCount(2)
        ->and($photos[0]->invoice)->toBe($this->box->invoice)
        ->and($photos[0]->invoice_id)->toBe($this->box->id)
        ->and($photos[0]->step)->toBe('unload')
        ->and($photos[0]->condition)->toBe('damaged')
        ->and($photos[0]->note)->toBe('Corner crushed')
        ->and($photos[0]->container_id)->toBe($this->container->id)
        ->and($photos[0]->user_id)->toBe($this->admin->id)
        ->and($photos[0]->path)->not->toBe($photos[1]->path)
        ->and($photos[0]->fileName())->toBe($this->box->invoice.'_unload_1.jpg')
        ->and($photos[1]->fileName())->toBe($this->box->invoice.'_unload_2.jpg');

    Storage::disk('box')->assertExists($photos[0]->path);
    [$w, $h] = getimagesizefromstring(Storage::disk('box')->get($photos[0]->path));
    expect($w)->toBe(1600)->and($h)->toBe(1200);

    // the next scan starts with no condition
    $next = Invoice::where('container_id', $this->container->id)->where('is_verified', false)->whereKeyNot($this->box->id)->firstOrFail();
    $page->call('scan', $next->invoice)->assertSet('photoCondition', null)->assertSet('sinceBatch', 2);
});

it('never makes a photo required', function () {
    $next = Invoice::where('container_id', $this->container->id)->where('is_verified', false)->whereKeyNot($this->box->id)->firstOrFail();

    unloadPage($this)->call('setPhotoCondition', 'wet')->call('scan', $next->invoice)->assertSet('lastStatus', 'success');

    expect(BoxPhoto::count())->toBe(0);
});

it('does not save a photo before a box is scanned, or where photos are switched off', function () {
    Livewire::test(Scaninvoice::class)->set('data.container_id', $this->container->id)
        ->set('boxPhoto', UploadedFile::fake()->image('a.jpg'))->call('saveBoxPhoto')
        ->assertNotified('Scan the box first, then add its photo.');

    PhotoSetting::current()->update(['places' => ['unload' => false]]);
    Once::flush();
    unloadPage($this)->assertDontSee('Add photo (optional)')
        ->set('boxPhoto', UploadedFile::fake()->image('a.jpg'))->call('saveBoxPhoto');

    expect(BoxPhoto::count())->toBe(0);
});

it('reminds about a batch photo and saves it without an invoice', function () {
    PhotoSetting::current()->update(['batch_every' => 1]);
    Once::flush();

    unloadPage($this)->assertSee('Batch photo?')
        ->set('boxPhoto', UploadedFile::fake()->image('pallet.jpg'))->call('saveBoxPhoto', true)
        ->assertSet('sinceBatch', 0)->assertDontSee('Batch photo?');

    $p = BoxPhoto::sole();
    expect($p->is_batch)->toBeTrue()->and($p->invoice)->toBeNull()->and($p->container_id)->toBe($this->container->id);
});

it('knows the step of every scan page', function () {
    expect(app(Scaninvoice::class)->photoStep())->toBe('unload')
        ->and(app(Scanload::class)->photoStep())->toBe('load')
        ->and(app(LoadTruck::class)->photoStep())->toBe('hub_load')
        ->and(app(Whloaded::class)->photoStep())->toBe('wh_load')
        ->and(app(Whunloaded::class)->photoStep())->toBe('wh_unload')
        ->and(app(HubReturnBoxes::class)->photoStep())->toBe('return');
});

function makePhoto(Invoice $box, array $attrs = []): BoxPhoto
{
    return Photos::store(UploadedFile::fake()->image('p.jpg', 400, 300), $attrs['step'] ?? 'unload', $box,
        ['container_id' => $box->container_id] + ($attrs['ctx'] ?? []), User::first(), $attrs['condition'] ?? null);
}

it('finds photos by invoice or container, downloads them and serves them only to signed-in users', function () {
    $a = makePhoto($this->box, ['condition' => 'damaged']);
    $other = Invoice::whereKeyNot($this->box->id)->where('container_id', '!=', $this->container->id)->first()
        ?? Invoice::whereKeyNot($this->box->id)->firstOrFail();
    $b = makePhoto($other);

    Livewire::test(BoxPhotos::class)
        ->assertSee('Search a box to see its photos')->assertDontSee($a->fileName())
        ->set('q', $this->box->invoice)->assertSee($a->fileName())->assertDontSee($b->fileName())->assertSee(User::first()->full_name)
        ->set('q', $this->container->container_no)->assertSee($a->fileName())
        ->set('cond', 'wet')->assertSee('No photos found')
        ->set('cond', 'damaged')->assertSee($a->fileName())
        ->call('clearSearch')->assertSet('q', '')->assertSee('Search a box to see its photos')
        ->assertSee($this->box->invoice) // recent search button
        ->set('selected', ['p:'.$a->id, 'p:'.$b->id])
        ->call('downloadSelected')->assertFileDownloaded();

    $this->get($a->url())->assertOk()->assertHeader('Content-Type', 'image/jpeg');
    $this->get($a->downloadUrl())->assertOk()->assertDownload($this->box->invoice.'_unload_1.jpg');
    auth()->logout();
    $this->get($a->url())->assertForbidden();
});

it('emails the selected photos to the consolidator and keeps a record', function () {
    Mail::fake();
    $con = Consolidator::firstOrFail();
    $con->update(['email' => 'ops@consolidator.example']);
    $this->container->update(['consolidator_id' => $con->id]);
    $this->box->update(['location_code' => $con->code]);
    $p1 = makePhoto($this->box, ['condition' => 'damaged']);
    $p2 = makePhoto($this->box);

    Livewire::test(BoxPhotos::class)
        ->set('q', $this->box->invoice)
        ->set('selected', ['p:'.$p1->id, 'p:'.$p2->id])
        ->mountAction('email')
        ->assertActionDataSet(['to' => ['ops@consolidator.example']])
        ->setActionData(['to' => ['ops@consolidator.example', 'boss@consolidator.example']])
        ->callMountedAction()
        ->assertHasNoActionErrors()
        ->assertNotified('Email sent to ops@consolidator.example, boss@consolidator.example')
        ->assertSet('selected', []);

    Mail::assertSent(BoxPhotosMail::class, fn (BoxPhotosMail $m) => $m->hasTo('ops@consolidator.example')
        && count($m->attachments()) === 2 && str_contains($m->subjectLine, $this->box->invoice));

    $log = BoxPhotoEmail::sole();
    expect($log->status)->toBe('sent')->and($log->photo_ids)->toBe(['p:'.$p1->id, 'p:'.$p2->id])->and($log->consolidator_id)->toBe($con->id);
});

it('shows partner hubs only photos of their own boxes', function () {
    $hubUser = User::where('email', 'company@example.com')->firstOrFail();
    $hub = Logistichub::findOrFail($hubUser->logistichub_id);
    expect((bool) $hub->is_company)->toBeTrue();
    Tripinvoice::where('invoice_id', $this->box->id)->delete();
    $mine = makePhoto($this->box, ['step' => 'hub_load', 'ctx' => ['logistichub_id' => $hub->id]]);
    $notMine = makePhoto(Invoice::whereKeyNot($this->box->id)->whereNotIn('id', Tripinvoice::where('logistichub_id', $hub->id)->select('invoice_id'))->firstOrFail());

    Filament::setCurrentPanel(Filament::getPanel('company'));
    $staff = $hubUser->replicate()->fill(['email' => 'hubstaff@example.com']);
    $staff->save();
    $this->actingAs($staff);

    expect(BoxPhoto::visibleTo(auth()->user())->pluck('id')->all())->toBe([$mine->id]);
    Livewire::test(HubBoxPhotos::class)->set('q', $this->box->invoice)->assertSee($mine->fileName())
        ->set('q', $notMine->invoice)->assertSee('No photos found')->assertDontSee($notMine->fileName());
    $this->get($notMine->url())->assertNotFound();
});

it('saves the settings and deletes old photos except boxes with an open issue', function () {
    Livewire::test(BoxPhotoSettings::class)
        ->set('places.return', false)->set('keepMonths', 6)->call('save')->assertNotified('Box photo settings saved');
    expect(PhotoSetting::current()->fresh()->allows('return'))->toBeFalse();

    $old = makePhoto($this->box);
    $old->update(['taken_at' => now()->subMonths(7)]);
    $issueBox = Invoice::whereKeyNot($this->box->id)->firstOrFail();
    $kept = makePhoto($issueBox);
    $kept->update(['taken_at' => now()->subMonths(7)]);
    Invoiceissue::forceCreate(['invoice' => $issueBox->invoice, 'invoice_id' => $issueBox->id, 'container_id' => $issueBox->container_id, 'remarks' => 'wet', 'boxissue_id' => 1, 'user_id' => $this->admin->id]);
    $issueBox->update(['is_resolved' => false]);
    $new = makePhoto($this->box);

    $this->artisan('photos:prune')->assertSuccessful();

    expect(BoxPhoto::pluck('id')->all())->toBe([$kept->id, $new->id]);
    Storage::disk('box')->assertMissing($old->path);
});

it('shows all photos of a box from Search Invoice and Track a box', function () {
    makePhoto($this->box, ['condition' => 'wet']);
    makePhoto($this->box, ['step' => 'load']);

    Livewire::test(ListSearchinvs::class)
        ->mountTableAction('photos', Searchinv::find($this->box->id))
        ->assertMountedActionModalSee($this->box->invoice.'_unload_1.jpg')
        ->assertMountedActionModalSee($this->box->invoice.'_load_1.jpg');
});

it('shows every delivery photo in a Delivered card, and not-delivered photos with the reason', function () {
    Storage::fake('public');
    Storage::disk('public')->put('delivery/a.jpg', UploadedFile::fake()->image('a.jpg')->getContent());
    Storage::disk('public')->put('delivery/b.jpg', UploadedFile::fake()->image('b.jpg')->getContent());
    Storage::disk('public')->put('delivery/c.jpg', UploadedFile::fake()->image('c.jpg')->getContent());
    Storage::disk('public')->put('attempts/x.jpg', UploadedFile::fake()->image('x.jpg')->getContent());
    makePhoto($this->box);

    $trip = Deliverylog::firstOrFail();
    $row = Tripinvoice::where('invoice_id', $this->box->id)->first()
        ?? Tripinvoice::forceCreate(['invoice' => $this->box->invoice, 'invoice_id' => $this->box->id, 'deliverylog_id' => $trip->id, 'logistichub_id' => $trip->logistichub_id]);
    $row->forceFill(['is_delivered' => true, 'delivered_at' => now(), 'delivered_by' => $this->admin->id, 'delivery_picture' => ['delivery/a.jpg', 'delivery/b.jpg', 'delivery/c.jpg']])->save();
    DeliveryAttempt::forceCreate(['tripinvoice_id' => $row->id, 'invoice_id' => $this->box->id, 'deliverylog_id' => $row->deliverylog_id, 'user_id' => $this->admin->id,
        'reason' => 'no_one_home', 'note' => 'Gate closed', 'photos' => ['attempts/x.jpg'], 'created_at' => now()->subDay()]);

    $page = Livewire::test(BoxPhotos::class)->set('q', $this->box->invoice)
        ->assertSee('Delivered')->assertSee('3 photos')
        ->assertSee('Not delivered · No one home')->assertSee('Gate closed')
        ->assertSee($this->box->invoice.'_delivered_3.jpg')
        ->set('place', 'delivered')->assertSee($this->box->invoice.'_delivered_1.jpg');

    $album = new BoxAlbum($this->admin);
    $items = $album->forInvoice($this->box->id);
    expect($items->pluck('kind')->countBy()->all())->toBe(['not_delivered' => 1, 'scan' => 1, 'delivered' => 3])
        ->and($items->where('kind', 'delivered')->pluck('name')->all())->toBe([
            $this->box->invoice.'_delivered_1.jpg', $this->box->invoice.'_delivered_2.jpg', $this->box->invoice.'_delivered_3.jpg']);

    Mail::fake();
    $page->set('selected', ['d:'.$row->id.':0', 'd:'.$row->id.':2'])
        ->call('downloadSelected')->assertFileDownloaded()
        ->mountAction('email')->setActionData(['to' => ['ops@example.com']])->callMountedAction()->assertHasNoActionErrors();
    Mail::assertSent(BoxPhotosMail::class, fn ($m) => collect($m->attachments())->map(fn ($a) => $a->as)->all() === [$this->box->invoice.'_delivered_1.jpg', $this->box->invoice.'_delivered_3.jpg']);
});
