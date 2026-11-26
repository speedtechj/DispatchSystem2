<?php

use App\Filament\Pages\PhotoStorage;
use App\Models\AppSetting;
use App\Models\Photos\PhotoFile;
use App\Models\Photos\PhotoTask;
use App\Models\User;
use App\Support\Photos\Storage\OldSystem;
use App\Support\Photos\Storage\PhotoStore;
use App\Support\Photos\Storage\PhotoWork;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    PhotoStore::$fake = true;
    PhotoStore::forgetMemo();
    $this->root = storage_path('framework/testing/photostore-'.getmypid());
    File::deleteDirectory($this->root);
    // the server folders behind the routed disks, in a test folder
    config(['filesystems.disks.public.inner.root' => $this->root.'/public', 'filesystems.disks.box.inner.root' => $this->root.'/private']);
    Storage::forgetDisk(['public', 'box']);
    File::deleteDirectory(storage_path('framework/testing/buckets'));
});

afterEach(function () {
    PhotoStore::$fake = false;
    File::deleteDirectory($this->root);
    File::deleteDirectory(storage_path('framework/testing/buckets'));
});

function bucketOn(string $slot = 'tmp', string $name = 'negosmart'): void
{
    PhotoStore::bucket($slot)->fill(['provider' => 'r2', 'account_id' => 'acc123', 'bucket' => $name, 'access_key' => 'key', 'secret' => 's3cret'])->save();
    PhotoStore::forgetMemo();
    expect(PhotoStore::test($slot)[0])->toBeTrue();
    PhotoStore::forgetMemo();
}

it('saves on the server like before until a bucket is chosen', function () {
    Storage::disk('public')->put('shipments/a.jpg', 'AAA');
    expect(File::exists($this->root.'/public/shipments/a.jpg'))->toBeTrue()
        ->and(PhotoFile::count())->toBe(0)
        ->and(Storage::disk('public')->url('shipments/a.jpg'))->toEndWith('/storage/shipments/a.jpg');
});

it('saves new photos of every disk to the chosen bucket and keeps old ones opening', function () {
    Storage::disk('public')->put('fuel/old.jpg', 'OLD');
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();

    Storage::disk('public')->put('fuel/new.jpg', 'NEW');
    Storage::disk('box')->put('box-photos/2026/11/x.jpg', 'BOX');
    Storage::disk('public')->put('logo/company.png', 'LOGO'); // logos stay on the server

    expect(File::exists($this->root.'/public/fuel/new.jpg'))->toBeFalse()
        ->and(PhotoFile::where('place', 'tmp')->pluck('path')->sort()->values()->all())->toBe(['box-photos/2026/11/x.jpg', 'fuel/new.jpg'])
        ->and(Storage::disk('public')->get('fuel/new.jpg'))->toBe('NEW')
        ->and(Storage::disk('public')->get('fuel/old.jpg'))->toBe('OLD')
        ->and(Storage::disk('box')->get('box-photos/2026/11/x.jpg'))->toBe('BOX')
        ->and(Storage::disk('public')->exists('fuel/new.jpg'))->toBeTrue()
        ->and(Storage::disk('public')->url('fuel/new.jpg'))->toContain('/photo-storage/fake/tmp/fuel/new.jpg')
        ->and(File::exists($this->root.'/public/logo/company.png'))->toBeTrue();

    // a file upload (Filament / Livewire) goes the same way
    Storage::disk('public')->putFileAs('unmanifested', UploadedFile::fake()->image('p.jpg'), 'p.jpg');
    expect(PhotoStore::placeOf('public', 'unmanifested/p.jpg'))->toBe('tmp');

    Storage::disk('public')->delete('fuel/new.jpg');
    expect(PhotoFile::where('path', 'fuel/new.jpg')->exists())->toBeFalse();
});

it('keeps the photo on the server when the bucket does not answer', function () {
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::bucket('tmp')->update(['bucket' => '']); // broken details: not usable
    PhotoStore::forgetMemo();
    Storage::disk('public')->put('fuel/z.jpg', 'Z');
    expect(File::exists($this->root.'/public/fuel/z.jpg'))->toBeTrue();
});

it('moves the server photos, then switches to the real bucket and turns Temporary off', function () {
    Storage::disk('public')->put('shipments/1.jpg', 'ONE');
    Storage::disk('box')->put('box-photos/2026/11/2.jpg', 'TWO');
    bucketOn();
    PhotoStore::setTarget('tmp');
    PhotoStore::forgetMemo();

    $move = PhotoWork::startMove('tmp');
    expect($move->total)->toBe(2);
    PhotoWork::work(10);
    expect($move->fresh()->status)->toBe('done')
        ->and(File::exists($this->root.'/public/shipments/1.jpg'))->toBeFalse()
        ->and(Storage::disk('public')->get('shipments/1.jpg'))->toBe('ONE')
        ->and(Storage::disk('box')->get('box-photos/2026/11/2.jpg'))->toBe('TWO');

    bucketOn('real', 'icargo-photos');
    $sw = PhotoWork::startSwitch(true);
    PhotoWork::work(10);
    PhotoStore::forgetMemo();
    expect($sw->fresh()->status)->toBe('done')
        ->and(PhotoStore::target())->toBe('real')
        ->and(PhotoStore::countIn('tmp'))->toBe(0)
        ->and(PhotoStore::bucket('tmp')->is_off)->toBeTrue()
        ->and(Storage::disk('public')->get('shipments/1.jpg'))->toBe('ONE')
        ->and(PhotoStore::placeOf('box', 'box-photos/2026/11/2.jpg'))->toBe('real');
});

it('copies the old system photos with the same path, smaller, and skips what is there', function () {
    // the old site next to wmsv2, same database
    $old = $this->root.'/wms';
    File::ensureDirectoryExists($old.'/storage/app/public/photos/pod');
    File::put($old.'/artisan', '');
    $c = config('database.connections.'.config('database.default'));
    File::put($old.'/.env', "APP_URL=https://wms.example.test\nDB_HOST=".($c['host'] ?? '')."\nDB_DATABASE=".($c['database'] ?? '')."\n");
    $im = imagecreatetruecolor(2400, 1600); // noise: a big photo
    for ($i = 0; $i < 60000; $i++) {
        imagefilledrectangle($im, $x = random_int(0, 2390), $y = random_int(0, 1590), $x + 9, $y + 9, random_int(0, 0xFFFFFF));
    }
    ob_start();
    imagejpeg($im, null, 95);
    $img = (string) ob_get_clean();
    expect(strlen($img))->toBeGreaterThan(400 * 1024);
    File::put($old.'/storage/app/public/photos/pod/INV-1.jpg', $img);
    AppSetting::put('photos.old_folder', $old);
    DB::table('fuel_fills')->exists() || true;
    $u = User::first();
    DB::table('users')->where('id', $u->id)->update(['profile_picture' => 'photos/pod/INV-1.jpg']);
    DB::table('users')->where('id', '!=', $u->id)->limit(1)->update(['profile_picture' => 'photos/pod/GONE.jpg']);

    $find = OldSystem::find();
    expect($find['found'])->toBeTrue()->and($find['same'])->toBeTrue()
        ->and(OldSystem::columns()->firstWhere('column', 'profile_picture'))->not->toBeNull();

    bucketOn();
    $task = OldSystem::scan();
    $byPath = $task->items()->get()->keyBy('path');
    expect($byPath['photos/pod/INV-1.jpg']->found)->toBe('wms')
        ->and($byPath['photos/pod/GONE.jpg']->status)->toBe('missing');

    $task->update(['status' => 'running']);
    PhotoWork::work(15);
    $task->refresh();
    $item = $task->items()->where('path', 'photos/pod/INV-1.jpg')->first();
    expect($task->status)->toBe('done')->and($item->status)->toBe('done')->and($item->checked)->toBeTrue()
        ->and($item->size_after)->toBeLessThan($item->size_before)
        ->and(PhotoStore::placeOf('public', 'photos/pod/INV-1.jpg'))->toBe('tmp')
        ->and(Storage::disk('public')->exists('photos/pod/INV-1.jpg'))->toBeTrue()
        ->and(File::exists($old.'/storage/app/public/photos/pod/INV-1.jpg'))->toBeTrue(); // the old site is never touched

    // copy again: nothing new
    OldSystem::scan()->update(['status' => 'running']);
    PhotoWork::work(5);
    expect($task->fresh()->items()->where('path', 'photos/pod/INV-1.jpg')->value('status'))->toBe('done');
});

it('shows the photo storage page with its tabs and saves a bucket', function () {
    Livewire::test(PhotoStorage::class)
        ->assertSee('Setup checklist')->assertSee('Copy from the old system')
        ->call('setTab', 'bucket')->assertSee('New photos go to')->assertSee('Temporary bucket')
        ->set('form.tmp.account_id', 'acc9')->set('form.tmp.bucket', 'negosmart')->set('form.tmp.access_key', 'AK')->set('form.tmp.secret', 'SEC')
        ->call('saveBucket', 'tmp')->assertSee('Uploaded, read and deleted a test file')
        ->call('setTarget', 'tmp')
        ->call('turnOff', 'tmp')->assertSee('new photos still go here')
        ->call('setTab', 'work')->assertSee('Run here');
    expect(PhotoStore::target())->toBe('tmp')
        ->and(PhotoStore::bucket('tmp')->secret)->toBe('SEC')
        ->and(DB::table('storage_buckets')->value('secret'))->not->toBe('SEC'); // kept encrypted
});
