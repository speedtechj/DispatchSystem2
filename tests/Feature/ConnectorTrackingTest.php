<?php

use App\Filament\Pages\ConsolidatorConnections;
use App\Filament\Pages\ConsolidatorTracking;
use App\Models\Ai\AiSetting;
use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\Consolidator;
use App\Models\Invoice;
use App\Models\User;
use App\Support\Connectors\ManualSend;
use App\Support\Connectors\Recorder;
use App\Support\Connectors\Signer;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function connAi(array $features): void
{
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test-1234', 'model_fast' => 'claude-haiku-5-5', 'model_smart' => 'claude-sonnet-5-5', 'monthly_limit' => 20, 'features' => $features]);
    Cache::forget('ai.settings');
}

function connClaude(string $text): array
{
    return ['content' => [['type' => 'text', 'text' => $text]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 500, 'output_tokens' => 80]];
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->inv = Invoice::where('location_code', 'FX')->firstOrFail();
    $this->link = ConnectorLink::create([
        'consolidator_id' => Consolidator::where('code', 'FX')->value('id'), 'url' => 'https://conn.test', 'mode' => 'push',
        'token' => 't', 'secret' => 'sec-1', 'key_id' => 'k1', 'state' => 'online',
        'statuses' => ['ph_branch_id' => 2, 'mapping' => [], 'list' => [
            ['id' => 6, 'name' => 'Unloaded in Philippine Warehouse', 'code' => null, 'branch_id' => 2, 'active' => true],
            ['id' => 7, 'name' => 'Loaded to Truck for Delivery', 'code' => null, 'branch_id' => 2, 'active' => true],
            ['id' => 15, 'name' => 'Delivered', 'code' => null, 'branch_id' => 2, 'active' => true],
        ]],
    ]);
    Recorder::forgetLinks();
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);
});

it('lets the Admin panel send for every box, whatever hub the account is on', function () {
    $hub = \App\Models\Logistichub::where('is_company', true)->firstOrFail();
    $this->admin->forceFill(['logistichub_id' => $hub->id])->save();
    expect(ManualSend::scope($this->admin->fresh(), 'admin'))->toBeNull()
        ->and(ManualSend::scope($this->admin->fresh(), 'company'))->toBe(['type' => 'hub', 'id' => $hub->id]);
});

it('shows a box the way their tracking shows it, next to ours, and the last answer when offline', function () {
    Recorder::record($this->inv, 'ds.delivered', null, ['send_now' => true]);
    $down = false;
    $rows = ['found' => true, 'rows' => [
        ['row_id' => 9, 'date' => '2026-11-27', 'status_id' => 15, 'status' => 'Delivered', 'abroad' => false, 'by' => 'dispatch', 'by_name' => 'Dispatch System · Dan Demo (driver)', 'location' => 'MANILA', 'remarks' => 'Received by sister'],
        ['row_id' => 1, 'date' => '2026-10-20', 'status_id' => 1, 'status' => 'ETA Manila', 'abroad' => true, 'by' => 'staff', 'by_name' => 'Glizel Martinez', 'location' => 'Calgary'],
    ]];
    Http::fake(function () use (&$down, $rows) {
        return $down ? Http::response(['message' => 'down'], 500) : Http::response($rows);
    });

    Livewire::test(ConsolidatorTracking::class)->set('box', $this->inv->invoice)->call('findBox')
        ->assertSee('In their CMS · 2 rows')->assertSee('Glizel Martinez')->assertSee('Received by sister')
        ->assertSee('Dispatch System · Dan Demo (driver)')->assertSee('Ready');
    Http::assertSent(fn (Request $r) => $r->method() === 'GET' && str_contains($r->url(), 'invoice='.$this->inv->invoice) && $r->hasHeader(Signer::SIGN));

    $down = true;
    Livewire::test(ConsolidatorTracking::class)->set('box', $this->inv->invoice)->call('refresh')
        ->assertSee('not answering')->assertSee('Glizel Martinez');
});

it('shows every box of a container with their newest status', function () {
    $c = $this->inv->container;
    $boxes = Invoice::where('container_id', $c->id)->pluck('invoice')->all();
    Http::fake(['*/api/v1/track' => function (Request $r) use ($boxes) {
        $out = [];
        foreach ($r['invoices'] as $i => $b) {
            $out[$b] = $i === 0 ? ['found' => false, 'latest' => null]
                : ['found' => true, 'latest' => ['row_id' => $i, 'date' => '2026-11-27', 'status_id' => 6, 'status' => 'Unloaded in Philippine Warehouse', 'by' => 'staff', 'location' => null]];
        }

        return Http::response(['boxes' => $out]);
    }]);
    $page = Livewire::test(ConsolidatorTracking::class)->set('container', $c->container_no)->call('findContainer')
        ->assertSee('Unloaded in Philippine Warehouse')->assertSee('Not in their CMS');
    $page->call('openGroup', 'missing|Not in their CMS')->assertSee($boxes[0]);
});

it('fills empty mapping rows with AI when the helper is on', function () {
    connAi(['conn_map']);
    Http::fake(['api.anthropic.com/*' => Http::response(connClaude('{"ds.unloaded": 6, "ds.load.1": 7, "ds.delivered": 15, "ds.load.2": 999}'))]);
    $page = Livewire::test(ConsolidatorConnections::class, ['con' => $this->link->consolidator_id])->set('tab', 'map')
        ->call('clearAll')->assertSee('Suggest with AI')->call('aiSuggest');
    $d = $page->get('draft');
    expect($d['ds.unloaded']['id'])->toBe(6)->and($d['ds.unloaded']['tag'])->toBe('AI')
        ->and($d['ds.delivered']['id'])->toBe(15)->and(isset($d['ds.load.2']))->toBeFalse();
});

it('answers Why? on a waiting status, and hides the button when the helper is off', function () {
    $e = Recorder::record($this->inv, 'ds.delivered', null, ['send_now' => true]);
    $e->update(['state' => 'not_found', 'message' => 'Box is not in the CMS']);
    Livewire::test(ConsolidatorConnections::class, ['con' => $this->link->consolidator_id])->set('tab', 'outbox')->assertDontSee('Why?');

    connAi(['conn_why']);
    Http::fake(['api.anthropic.com/*' => Http::response(connClaude('The box is not in their CMS yet. The connector tries again every 10 minutes for 7 days.'))]);
    Livewire::test(ConsolidatorConnections::class, ['con' => $this->link->consolidator_id])->set('tab', 'outbox')
        ->assertSee('Why?')->call('askWhy', $e->id)->assertSee('tries again every 10 minutes');
});

it('explains for their connector, signed, only when the helper is on', function () {
    $sign = function (string $method, string $uri, string $body = '') {
        $t = time();

        return ['HTTP_X_CONNECTOR_KEY' => 'k1', 'HTTP_X_CONNECTOR_TIME' => (string) $t,
            'HTTP_X_CONNECTOR_SIGNATURE' => Signer::make('sec-1', $t, $method, $uri, $body), 'CONTENT_TYPE' => 'application/json'];
    };
    $hello = $this->call('GET', '/api/connector/v1/hello', [], [], [], $sign('GET', '/api/connector/v1/hello'))->assertOk();
    expect($hello->json('features.explain'))->toBeFalse();

    $body = json_encode(['topic' => 'health', 'text' => 'CMS database: Access denied for user', 'version' => '2.6.0', 'location_code' => 'FX']);
    $off = $this->call('POST', '/api/connector/v1/explain', [], [], [], $sign('POST', '/api/connector/v1/explain', $body), $body)->assertOk();
    expect($off->json('message'))->toContain('switched off');

    connAi(['conn_explain']);
    Http::fake(['api.anthropic.com/*' => Http::response(connClaude('The MySQL password in the connector is wrong. Fix it in Settings → Run setup again.'))]);
    $on = $this->call('POST', '/api/connector/v1/explain', [], [], [], $sign('POST', '/api/connector/v1/explain', $body), $body)->assertOk();
    expect($on->json('answer'))->toContain('MySQL password')
        ->and(Signer::valid('sec-1', $on->headers->get(Signer::SIGN), (int) $on->headers->get(Signer::TIME), 'RESPONSE', '/api/connector/v1/explain', $on->getContent()))->toBeTrue();
    expect($this->call('GET', '/api/connector/v1/hello', [], [], [], $sign('GET', '/api/connector/v1/hello'))->json('features.explain'))->toBeTrue();
});
