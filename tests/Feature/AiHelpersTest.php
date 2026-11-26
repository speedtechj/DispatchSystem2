<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Pages\Ai\AiAlerts;
use App\Filament\Pages\Ai\AiAsk;
use App\Filament\Pages\Ai\AiManifest;
use App\Filament\Pages\Ai\AiPhotoCheck as AiPhotoCheckPage;
use App\Filament\Pages\Ai\AiRisky;
use App\Filament\Pages\AiSettings;
use App\Models\Ai\AiAlert;
use App\Models\Ai\AiChat;
use App\Models\Ai\AiPhotoCheck;
use App\Models\Ai\AiRiskMark;
use App\Models\Ai\AiSetting;
use App\Models\Ai\AiUsage;
use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\Alerts;
use App\Support\Ai\PhotoCheck;
use App\Support\Ai\Risk;
use App\Support\Photos\BoxPhotos;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

/** A fake Claude answer. */
function claude(string $text, string $stop = 'end_turn', ?array $content = null): array
{
    return ['content' => $content ?? [['type' => 'text', 'text' => $text]], 'stop_reason' => $stop, 'usage' => ['input_tokens' => 1000, 'output_tokens' => 100]];
}

function aiOn(array $features, bool $key = true): void
{
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => $key ? 'sk-ant-test-1234' : null, 'model_fast' => 'claude-haiku-5-5', 'model_smart' => 'claude-sonnet-5-5', 'monthly_limit' => 20, 'features' => $features]);
    Cache::forget('ai.settings');
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    Storage::fake('local');
    Storage::fake('box');
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
});

it('saves the key encrypted, never shows it, and tests the connection', function () {
    Http::fake(['api.anthropic.com/*' => Http::response(claude('OK'))]);

    Livewire::test(AiSettings::class)
        ->set('apiKey', 'sk-ant-secret-9876')->set('enabled.photo_check', true)->set('limit', '15')
        ->call('save')->assertSee('Key saved · ends with 9876')->assertDontSee('sk-ant-secret-9876')
        ->call('test')->assertSet('testOk', true);

    $row = AiSetting::first();
    expect($row->api_key)->toBe('sk-ant-secret-9876')
        ->and(DB::table('ai_settings')->value('api_key'))->not->toContain('secret')
        ->and($row->features)->toBe(['photo_check'])
        ->and(AiUsage::where('feature', 'test')->count())->toBe(2);
    Http::assertSent(fn ($r) => $r->hasHeader('x-api-key', 'sk-ant-secret-9876') && $r['model'] === 'claude-haiku-5-5');
});

it('stays off without a key, when switched off, and when the monthly limit is reached', function () {
    aiOn(['photo_check'], key: false);
    expect(Ai::enabled('photo_check'))->toBeFalse()->and(Ai::whyOff('photo_check'))->toContain('Add the AI key');

    aiOn([]);
    expect(Ai::enabled('photo_check'))->toBeFalse();

    aiOn(['photo_check', 'alerts']);
    AiUsage::create(['feature' => 'x', 'model' => 'm', 'cost' => 25, 'created_at' => now()]);
    expect(Ai::enabled('photo_check'))->toBeFalse()->and(Ai::whyOff('photo_check'))->toContain('limit')
        ->and(Ai::enabled('alerts'))->toBeTrue(); // alerts need no key
});

it('checks a scan photo after it is taken and lets staff open an Invoice Issue', function () {
    aiOn(['photo_check']);
    Http::fake(['api.anthropic.com/*' => Http::response(claude('{"verdict":"damaged","confidence":91,"note":"Corner crushed, side caved in"}'))]);
    $invoice = Invoice::firstOrFail();

    $photo = BoxPhotos::store(UploadedFile::fake()->image('box.jpg', 800, 600), 'unload', $invoice, ['container_id' => $invoice->container_id], $this->admin, 'good');
    $check = AiPhotoCheck::where('box_photo_id', $photo->id)->sole();
    PhotoCheck::run($check);

    expect($check->fresh())->flagged->toBeTrue()->verdict->toBe('damaged')->confidence->toBe(91);

    Livewire::test(AiPhotoCheckPage::class)
        ->assertSee($invoice->invoice)->assertSee('Corner crushed')->assertSee('Damaged · open issue')
        ->call('pick', $check->id)->call('confirmDamaged')->assertSee('Invoice Issue opened');

    $issue = Invoiceissue::latest('id')->first();
    expect($issue->invoice)->toBe($invoice->invoice)->and($issue->attachment_pic)->toHaveCount(1)
        ->and($check->fresh()->decision)->toBe('damaged');
    Storage::disk('public')->assertExists($issue->attachment_pic[0]);
});

it('checks proof-of-delivery photos too', function () {
    aiOn(['photo_check']);
    Http::fake(['api.anthropic.com/*' => Http::response(claude('{"verdict":"blurry","confidence":80,"note":"Too dark to see the box"}'))]);
    $box = Tripinvoice::where('is_delivered', false)->firstOrFail();
    Storage::disk('public')->put($box->invoice.'/a.jpg', UploadedFile::fake()->image('a.jpg')->get());

    app(TripAssignment::class)->markDelivered($box, [$box->invoice.'/a.jpg'], $this->admin);
    PhotoCheck::run($c = AiPhotoCheck::where('tripinvoice_id', $box->id)->sole());

    expect($c->fresh())->source->toBe('delivery')->verdict->toBe('blurry')->flagged->toBeTrue();
});

it('does nothing with photos while the photo check is off', function () {
    aiOn([]);
    Http::fake();
    BoxPhotos::store(UploadedFile::fake()->image('box.jpg'), 'unload', Invoice::first(), [], $this->admin, 'good');
    expect(AiPhotoCheck::count())->toBe(0);
    Http::assertNothingSent();
});

it('answers staff questions using look-ups on your own data', function () {
    aiOn(['ask']);
    $invoice = Invoice::firstOrFail();
    Http::fakeSequence('api.anthropic.com/*')
        ->push(claude('', 'tool_use', [['type' => 'tool_use', 'id' => 't1', 'name' => 'find_boxes', 'input' => ['query' => $invoice->invoice]]]))
        ->push(claude("Box {$invoice->invoice} is in the warehouse."));

    Livewire::test(AiAsk::class)
        ->call('ask', "Where is box {$invoice->invoice}?")
        ->assertSee("Box {$invoice->invoice} is in the warehouse.");

    Http::assertSent(fn ($r) => collect($r['messages'])->contains(fn ($m) => is_array($m['content'])
        && ($m['content'][0]['type'] ?? '') === 'tool_result' && str_contains($m['content'][0]['content'], $invoice->invoice)));
});

it('reads a manifest, marks duplicates, and saves only the ticked boxes', function () {
    aiOn(['manifest']);
    $container = Container::where('is_unloaded', false)->firstOrFail();
    $old = Invoice::firstOrFail();
    $old->forceFill(['container_id' => $container->id])->saveQuietly();
    $existing = $old->invoice;
    Http::fake(['api.anthropic.com/*' => Http::response(claude(json_encode(['consolidator' => 'LBC Toronto', 'rows' => [
        ['NEW-1', 'Ana Cruz', 'Jose Ramos', 'Purok 3', 'Pusok', 'Lapu-Lapu City', 'Cebu', '09171234567', '', 'Jumbo', '', 'Lapu2 = Lapu-Lapu City', ''],
        ['NEW-2', 'Ana Cruz', 'Liza Gomez', 'Blk 4', 'Lahug', 'Cebu City', 'Cebu', '', '', 'Regular', '', '', 'No phone'],
        [$existing, 'X', $old->receiver_name, 'Z', 'B', 'C', 'P', '0917', '', '', '', '', ''],
        ['NEW-1', 'Ana Cruz', 'Jose Ramos', 'Purok 3', 'Pusok', 'Lapu-Lapu City', 'Cebu', '09171234567', '', 'Jumbo', '', '', ''],
    ]])))]);
    $csv = UploadedFile::fake()->createWithContent('manifest.csv', "Invoice,Sender,Receiver,Address\nNEW-1,Ana,Jose,Lapu2\n");

    $page = Livewire::test(AiManifest::class)->set('container', $container->id)->set('file', $csv)->call('read')
        ->assertSee('Fixed: Lapu2 = Lapu-Lapu City')->assertSee('Already in')->assertSee('Listed twice')->assertSee('Save 2 boxes');
    $page->call('save');

    expect(Invoice::where('container_id', $container->id)->whereIn('invoice', ['NEW-1', 'NEW-2'])->count())->toBe(2)
        ->and(Invoice::where('invoice', 'NEW-1')->count())->toBe(1)
        ->and(Invoice::where('invoice', 'NEW-1')->value('receiver_city'))->toBe('Lapu-Lapu City');
});

it('scores risky boxes, writes the text, and warns the driver', function () {
    aiOn(['risky', 'voice']);
    $box = Tripinvoice::where('is_delivered', false)->with('invdata')->firstOrFail();
    $box->invdata->update(['receiver_mobile_no' => '', 'receiver_address' => 'near church']);
    DeliveryAttempt::create(['tripinvoice_id' => $box->id, 'invoice_id' => $box->invoice_id, 'deliverylog_id' => $box->deliverylog_id, 'user_id' => $this->admin->id, 'reason' => FailedDeliveryReason::NoOneHome->value]);

    $risk = Risk::of($box->fresh());
    expect($risk['score'])->toBeGreaterThanOrEqual(70)->and($risk['reasons'])->toContain('No phone number');

    Http::fakeSequence('api.anthropic.com/*')
        ->push(claude('Hi Maria, your box arrives tomorrow. Will someone be home? Reply YES. – Speedtech'))
        ->push(claude('{"reason":"no_one_home","note":"Gate closed. Neighbor says family is in Manila until Friday."}'));
    Livewire::test(AiRisky::class)->assertSee($box->invoice)->call('pick', $box->id)->call('write')
        ->assertSet('message', 'Hi Maria, your box arrives tomorrow. Will someone be home? Reply YES. – Speedtech')
        ->call('markTexted');
    expect(AiRiskMark::where('tripinvoice_id', $box->id)->value('status'))->toBe('texted');

    // the driver sees the warning, and can fill "can't deliver" by voice
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->flushSession();
    $this->actingAs($driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    Livewire::test(Dashboard::class)->call('openBox', $box->id)->assertSee('Heads up · may not be delivered')
        ->call('startMiss')->call('voiceFill', 'Sarado ang gate, nasa Manila daw sila hanggang Biyernes')
        ->assertSet('reason', 'no_one_home')->assertSet('note', 'Gate closed. Neighbor says family is in Manila until Friday.');
});

it('raises alerts without a key and lets staff handle them', function () {
    aiOn(['alerts'], key: false);
    $trip = Deliverylog::firstOrFail();
    $boxes = Tripinvoice::where('deliverylog_id', $trip->id)->get();
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    // 10 boxes "delivered" within 2 minutes
    $start = now()->subHour();
    foreach (range(0, 9) as $i) {
        $b = $boxes[$i % $boxes->count()]->replicate();
        $b->forceFill(['invoice' => 'FAST-'.$i, 'is_delivered' => true, 'delivered_by' => $driver->id, 'delivered_at' => $start->copy()->addSeconds($i * 10)])->save();
    }

    Alerts::run();
    $alert = AiAlert::where('kind', 'drivers')->sole();
    expect($alert->title)->toBe('Too many deliveries too fast')->and($alert->body)->toContain('10 boxes');

    Livewire::test(AiAlerts::class)->assertSee('Too many deliveries too fast')->call('handle', $alert->id, 'checked');
    expect($alert->fresh()->status)->toBe('checked');
    Alerts::run();
    expect($alert->fresh()->status)->toBe('checked'); // not reopened
});

it('lets a receiver ask about their own box only', function () {
    aiOn(['customer_chat']);
    $invoice = Invoice::firstOrFail();
    $invoice->update(['receiver_mobile_no' => '09171234567']);
    $this->flushSession();
    auth()->logout();

    $this->post('/ask-box', ['box' => $invoice->invoice, 'last4' => '9999'])->assertSessionHasErrors('box');
    $this->post('/ask-box', ['box' => $invoice->invoice, 'last4' => '4567'])->assertRedirect();
    $chat = AiChat::sole();

    Http::fake(['api.anthropic.com/*' => Http::response(claude('[STAFF] Pasensya po! Tatawagan kayo ng aming staff ngayong araw.'))]);
    $this->post("/ask-box/{$chat->token}", ['q' => 'Basa ang box pag dating'])->assertRedirect();
    $this->get("/ask-box/{$chat->token}")->assertOk()->assertSee('Tatawagan kayo')->assertSee('Passed to our staff');

    expect($chat->fresh()->needs_staff)->toBeTrue()
        ->and(AiAlert::where('kind', 'customers')->sole()->body)->toContain('Basa ang box');
});

it('hides the AI pages until switched on, and the customer page too', function () {
    aiOn([]);
    expect(AiPhotoCheckPage::canAccess())->toBeFalse();
    $this->get('/ask-box')->assertNotFound();
    aiOn(['photo_check', 'customer_chat']);
    expect(AiPhotoCheckPage::canAccess())->toBeTrue();
    $this->get('/ask-box')->assertOk()->assertSee('Where is my box?');
});
