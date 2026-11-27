<?php

use App\Filament\Pages\BoxPhotos;
use App\Models\Ai\AiSetting;
use App\Models\BoxPhotoEmail;
use App\Models\Container;
use App\Models\Consolidator;
use App\Models\Invoice;
use App\Models\User;
use App\Support\Ai\EmailLanguages;
use App\Support\Photos\BoxPhotos as Photos;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('box');
    Mail::fake();
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->admin->assignRole('super_admin');
    $this->actingAs($this->admin);
    $this->box = Invoice::whereNotNull('container_id')->firstOrFail();
    $this->photo = Photos::store(UploadedFile::fake()->image('p.jpg', 640, 480), 'unload', $this->box, ['container_id' => $this->box->container_id], $this->admin, 'damaged');
    $this->con = Consolidator::first() ?? Consolidator::create(['code' => 'FX', 'company_name' => 'Forex Cargo', 'email' => 'claims@forex.test']);
    $this->con->update(['email' => 'claims@forex.test']);
    Container::whereKey($this->box->container_id)->update(['consolidator_id' => $this->con->id]);
    Invoice::whereKey($this->box->id)->update(['location_code' => $this->con->code]);
});

it('searches only on Enter: nothing while typing, exact box first, at least 3', function () {
    $page = Livewire::test(BoxPhotos::class)
        ->assertSeeHtml('x-model="draft"')->assertDontSeeHtml('wire:model.live.debounce.400ms="q"')
        ->assertSee('Press Enter to search')->assertSee('🔍 Search');

    $page->call('searchFor', 'IN')->assertSet('q', 'IN')->assertSee('Type at least 3 letters or numbers');
    $page->call('searchFor', '  '.$this->box->invoice.' ')->assertSet('q', $this->box->invoice)
        ->assertSee('Exact box')->assertSee($this->photo->fileName());

    // a part of the number: similar numbers, marked as such
    $page->call('searchFor', substr($this->box->invoice, 1))->assertSee('Similar numbers');
    expect(session('box-photos.recent'))->toContain($this->box->invoice);
});

it('makes table searches wait for Enter in Find a box and Box issues', function () {
    expect(file_get_contents(resource_path('js/search-enter.js')))->toContain('.fi-ta-search-field input');
    foreach ([\App\Filament\Resources\Searchinvs\SearchinvResource::class, \App\Filament\Resources\Invoiceissues\InvoiceissueResource::class] as $r) {
        expect(file_get_contents((new ReflectionClass($r))->getFileName()))->toContain('->searchOnBlur()');
    }
});

it('emails the photos of one box from its card, written by AI in the language of the consolidator', function () {
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => ['issues']]);
    (fn () => static::$memo = null)->call(new AiSetting);
    Cache::flush();
    $asked = null;
    Http::fake(function (Request $r) use (&$asked) {
        $asked = $r->data();

        return Http::response(['content' => [['type' => 'text', 'text' => json_encode(['subject' => 'Mga litrato · box', 'body' => "Magandang araw po,\n\nAng box ay may sira."])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]);
    });
    $key = 'p:'.$this->photo->id;

    $page = Livewire::test(BoxPhotos::class)->call('searchFor', $this->box->invoice)
        ->assertSee('✉ Email photos')->assertSee('✉ Email this photo')
        ->mountAction('email', ['keys' => [$key]])
        ->assertActionDataSet(['to' => ['claims@forex.test'], 'lang' => 'en', 'keys' => [$key]])
        ->setActionData(['lang' => 'tl', 'english' => true])
        ->callAction(\Filament\Actions\Testing\TestAction::make('aiWrite')->schemaComponent('message', schema: 'mountedActionSchema0'))
        ->assertActionDataSet(['message' => "Magandang araw po,\n\nAng box ay may sira.", 'subject' => 'Mga litrato · box']);

    $d = \App\Support\Ai\BoxEmailWriter::draft((new \App\Support\Photos\BoxAlbum($this->admin))->resolve([$key]), 'tl', true);
    expect($d)->toBe(['subject' => 'Mga litrato · box', 'body' => "Magandang araw po,\n\nAng box ay may sira."]);
    expect(json_encode($asked))->toContain('Tagalog')->toContain('English')->toContain($this->box->invoice);
});

it('remembers the language for the consolidator and sends the email', function () {
    $key = 'p:'.$this->photo->id;
    Livewire::test(BoxPhotos::class)->call('searchFor', $this->box->invoice)
        ->callAction('email', ['to' => ['claims@forex.test'], 'lang' => 'ilo', 'english' => false, 'subject' => 'Ladawan', 'message' => 'Naimbag nga aldaw', 'keys' => [$key]], ['keys' => [$key]])
        ->assertHasNoActionErrors();

    expect(BoxPhotoEmail::firstOrFail()->photo_ids)->toBe([$key])
        ->and(EmailLanguages::for($this->con->id))->toBe('ilo');
});
