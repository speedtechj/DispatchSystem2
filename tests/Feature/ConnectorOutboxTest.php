<?php

use App\Enums\UndoDeliveryReason;
use App\Filament\Pages\ConsolidatorConnections;
use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\Consolidator;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Connectors\Recorder;
use App\Support\Connectors\Rules;
use App\Support\Connectors\Sender;
use App\Support\Connectors\Signer;
use App\Support\TripFlow;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->firstOrFail();
    $this->con = Consolidator::where('code', Invoice::find($this->box->invoice_id)->location_code)->firstOrFail();
});

function pairLink(array $extra = []): ConnectorLink
{
    $l = ConnectorLink::create(array_merge([
        'consolidator_id' => test()->con->id, 'url' => 'https://conn.test', 'mode' => 'push',
        'token' => 'tok-123', 'secret' => 'sec-456', 'key_id' => 'key-1', 'state' => 'online', 'paired_at' => now(),
    ], $extra));
    Recorder::forgetLinks();

    return $l;
}

/** A fake connector: answers every event "saved" with a new row id. */
function fakeConnector(array &$got = []): void
{
    Http::fake(function (Request $r) use (&$got) {
        if (str_ends_with(parse_url($r->url(), PHP_URL_PATH), '/api/v1/events')) {
            $got[] = $r;
            $res = collect($r['events'])->values()->map(fn ($e, $i) => ['id' => $e['id'], 'result' => 'saved', 'row_id' => 900 + $i, 'trackstatus_id' => 15])->all();

            return Http::response(['results' => $res]);
        }
        if (str_contains($r->url(), '/api/v1/results')) {
            return Http::response(['results' => []]);
        }
        if (str_contains($r->url(), '/api/v1/health')) {
            return Http::response(['version' => '2.5.0', 'cms' => ['ok' => true]]);
        }

        return Http::response([], 404);
    });
}

it('keeps nothing while the consolidator has no paired connector', function () {
    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    expect(ConnectorEvent::count())->toBe(0);
});

it('holds Delivered 10 minutes, then sends it signed and stores their row', function () {
    pairLink();
    $got = [];
    fakeConnector($got);

    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    $e = ConnectorEvent::sole();
    expect($e->code)->toBe('ds.delivered')->and($e->state)->toBe('hold')->and($e->priority)->toBe(1)
        ->and($e->payload['by']['name'])->toBe($this->driver->full_name)
        ->and($e->payload['location_code'])->toBe($this->con->code);

    Sender::run(5);
    expect($got)->toBe([]); // still in the hold

    $this->travel(11)->minutes();
    Sender::run(5);
    expect($got)->toHaveCount(1);
    $req = $got[0];
    $path = Signer::pathOf($req->url());
    expect($req->header('Authorization')[0])->toBe('Bearer tok-123')
        ->and(Signer::valid('sec-456', $req->header(Signer::SIGN)[0], (int) $req->header(Signer::TIME)[0], 'POST', $path, $req->body()))->toBeTrue()
        ->and($e->fresh()->state)->toBe('saved')->and($e->fresh()->row_id)->toBe(900);
});

it('never sends a delivery undone inside the hold', function () {
    pairLink();
    $got = [];
    fakeConnector($got);
    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    app(TripAssignment::class)->undoDelivery($this->box->fresh(), $this->driver, UndoDeliveryReason::TappedByMistake, null);

    expect(ConnectorEvent::sole()->state)->toBe('cancelled');
    $this->travel(11)->minutes();
    Sender::run(5);
    expect($got)->toBe([]);
});

it('sends an undo first, back to the status before, when the delivery was already sent', function () {
    pairLink();
    $got = [];
    fakeConnector($got);
    $inv = Invoice::find($this->box->invoice_id);
    $load = Recorder::record($inv, 'ds.load.1', null, ['send_now' => true, 'state' => 'ready', 'source' => 'x']);
    Sender::run(5);
    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    $this->travel(11)->minutes();
    Sender::run(5);
    $delivered = ConnectorEvent::where('code', 'ds.delivered')->sole();
    expect($delivered->state)->toBe('saved');

    app(TripAssignment::class)->undoDelivery($this->box->fresh(), $this->admin, UndoDeliveryReason::TappedByMistake, null, true);
    $undo = ConnectorEvent::whereNotNull('corrects')->sole();
    expect($undo->corrects)->toBe($delivered->uid)->and($undo->code)->toBe('ds.load.1')
        ->and($undo->state)->toBe('ready')->and($undo->priority)->toBe(1)
        ->and($delivered->fresh()->undone_by)->toBe($undo->uid);
    Sender::run(5);
    expect(end($got)['events'][0]['corrects'])->toBe($delivered->uid);
});

it('sends Load on truck only when the trip leaves', function () {
    pairLink();
    $this->box->forceFill(['is_loaded' => false])->save();
    app(TripAssignment::class)->markLoaded($this->box->fresh());
    $e = ConnectorEvent::where('code', 'ds.load.1')->sole();
    expect($e->state)->toBe('trip');

    $this->trip->forceFill(['taken_at' => null])->save();
    TripFlow::take($this->trip->fresh(), $this->driver);
    expect($e->fresh()->state)->toBe('ready');
});

it('pauses a connector after 5 failed tries and emails the admins once', function () {
    Mail::fake();
    pairLink();
    Http::fake(fn () => Http::response(['message' => 'down'], 500));
    Recorder::record(Invoice::find($this->box->invoice_id), 'ds.delivered', null, ['send_now' => true]);

    for ($i = 0; $i < 5; $i++) {
        ConnectorLink::query()->update(['next_try_at' => null]);
        ConnectorEvent::query()->update(['next_try_at' => null]);
        Sender::run(5);
    }
    $l = ConnectorLink::sole();
    expect($l->state)->toBe('paused')->and($l->fails)->toBe(5)->and($l->mailed_at)->not->toBeNull()
        ->and(ConnectorEvent::sole()->state)->toBe('retry');
});

it('waits without counting a failure when the connector is busy (503)', function () {
    pairLink();
    Http::fake(['*/api/v1/events' => Http::response(['message' => 'Busy'], 503, ['Retry-After' => '15']), '*' => Http::response(['results' => []])]);
    Recorder::record(Invoice::find($this->box->invoice_id), 'ds.delivered', null, ['send_now' => true]);
    Sender::run(5);
    $e = ConnectorEvent::sole();
    expect($e->state)->toBe('ready')->and($e->next_try_at)->not->toBeNull()
        ->and(ConnectorLink::sole()->fails)->toBe(0);
});

it('gives pull connectors their events, signed, and takes their results', function () {
    $l = pairLink(['mode' => 'pull', 'url' => null]);
    $e = Recorder::record(Invoice::find($this->box->invoice_id), 'ds.delivered', null, ['send_now' => true]);

    $sign = function (string $method, string $uri, string $body = '') {
        $t = time();

        return ['X-Connector-Key' => 'key-1', 'X-Connector-Time' => (string) $t, 'X-Connector-Signature' => Signer::make('sec-456', $t, $method, $uri, $body)];
    };

    $this->get('/api/connector/v1/events?after=0&limit=100', ['X-Connector-Key' => 'key-1', 'X-Connector-Time' => (string) time(), 'X-Connector-Signature' => 'sha256=bad'])->assertStatus(401);

    $res = $this->get('/api/connector/v1/events?after=0&limit=100', $sign('GET', '/api/connector/v1/events?after=0&limit=100'));
    $res->assertOk();
    expect($res->json('events.0.id'))->toBe($e->uid)
        ->and(Signer::valid('sec-456', $res->headers->get(Signer::SIGN), (int) $res->headers->get(Signer::TIME), 'RESPONSE', '/api/connector/v1/events', $res->getContent()))->toBeTrue()
        ->and($e->fresh()->state)->toBe('sent');

    $body = json_encode(['results' => [['id' => $e->uid, 'result' => 'saved', 'row_id' => 77]]]);
    $this->call('POST', '/api/connector/v1/results', [], [], [], array_merge(['CONTENT_TYPE' => 'application/json'],
        collect($sign('POST', '/api/connector/v1/results', $body))->mapWithKeys(fn ($v, $k) => ['HTTP_'.strtoupper(str_replace('-', '_', $k)) => $v])->all()), $body)->assertOk();
    expect($e->fresh()->state)->toBe('saved')->and($e->fresh()->row_id)->toBe(77);
});

it('pairs from the page, reads their statuses and suggests a mapping', function () {
    Http::fake([
        '*/api/v1/pair' => Http::response(['token' => 't', 'secret' => 's', 'key_id' => 'k', 'connector' => ['name' => 'Forex connector', 'version' => '2.5.0', 'mode' => 'push', 'location_code' => test()->con->code]], 201),
        '*/api/v1/statuses' => Http::response(['ph_branch_id' => 2, 'statuses' => [
            ['id' => 6, 'description' => 'Unloaded in Philippine Warehouse', 'branch_id' => 2, 'is_active' => 1],
            ['id' => 7, 'description' => 'Loaded to Truck for Delivery', 'branch_id' => 2, 'is_active' => 1],
            ['id' => 51, 'description' => 'Loaded to truck - 2nd attempt', 'branch_id' => 2, 'is_active' => 1],
            ['id' => 15, 'description' => 'Delivered', 'branch_id' => 2, 'is_active' => 1],
            ['id' => 3, 'description' => 'ETA Manila', 'branch_id' => 1, 'is_active' => 1],
        ], 'mapping' => []]),
        '*/api/v1/health' => Http::response(['version' => '2.5.0', 'cms' => ['ok' => true]]),
        '*/api/v1/mapping' => Http::response(['saved' => 4, 'retried' => 0]),
    ]);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);

    $page = Livewire::test(ConsolidatorConnections::class, ['con' => $this->con->id])
        ->set('url', 'https://conn.test')->set('code', 'k7q-29m')->call('pair')
        ->assertHasNoErrors()->assertSet('tab', 'map');
    $draft = $page->get('draft');
    expect($draft['ds.delivered']['id'])->toBe(15)->and($draft['ds.load.1']['id'])->toBe(7)
        ->and($draft['ds.load.2']['id'])->toBe(51)->and($draft['ds.unloaded']['id'])->toBe(6);

    $page->call('saveMapping');
    expect(ConnectorLink::sole()->mappings()->count())->toBeGreaterThanOrEqual(4);
    Http::assertSent(fn (Request $r) => $r->method() === 'PUT' && collect($r['rows'])->contains('key', 'ds.delivered'));

    $page->call('setTab', 'outbox')->assertSee('Send now');
    $page->call('setTab', 'conn')->assertSee('Paired');
});

it('turns the hold off with its rule', function () {
    pairLink();
    Rules::save(['hold' => false] + Rules::all());
    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    expect(ConnectorEvent::sole()->state)->toBe('ready');
});

it('adds our standard statuses: theirs where similar, ours where missing, then maps and saves', function () {
    pairLink();
    $list = [
        ['id' => 6, 'description' => 'Unloaded in Philippine Warehouse', 'branch_id' => 2, 'is_active' => 1],
        ['id' => 7, 'description' => 'Loaded to Truck for Delivery', 'branch_id' => 2, 'is_active' => 1],
        ['id' => 15, 'description' => 'Delivered', 'branch_id' => 2, 'is_active' => 1],
    ];
    Http::fake([
        '*/api/v1/statuses' => function (Request $r) use (&$list) {
            if ($r->method() === 'GET') {
                return Http::response(['ph_branch_id' => 2, 'statuses' => $list, 'mapping' => []]);
            }
            $out = [];
            foreach ($r['statuses'] as $i => $s) {
                $id = 58 + $i;
                $list[] = ['id' => $id, 'description' => $s['name'], 'branch_id' => 2, 'is_active' => 1];
                $out[] = ['name' => $s['name'], 'key' => $s['key'], 'id' => $id, 'result' => 'added'];
            }

            return Http::response(['added' => count($out), 'statuses' => $out], 201);
        },
        '*/api/v1/mapping' => Http::response(['saved' => 15, 'retried' => 0]),
    ]);
    \App\Support\Connectors\Sender::refreshStatuses(ConnectorLink::sole());
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);

    $page = Livewire::test(ConsolidatorConnections::class, ['con' => $this->con->id])->set('tab', 'map')
        ->call('openStandard')->assertSee('Add our standard statuses')->assertSee('Already there · #15');
    $rows = collect($page->instance()->standardRows())->keyBy('code');
    expect($rows['ds.unloaded']['choice'])->toBe('theirs')->and($rows['ds.unloaded']['similar']['id'])->toBe(6)
        ->and($rows['ds.delivered']['choice'])->toBe('exact')
        ->and($rows['ds.waiting_next_try']['choice'])->toBe('ours');

    $page->call('setStd', 'ds.load.1', 'ours')->call('addStandard');
    Http::assertSent(fn (Request $r) => $r->method() === 'POST' && str_ends_with($r->url(), '/api/v1/statuses')
        && collect($r['statuses'])->pluck('name')->contains('Out for delivery')
        && ! collect($r['statuses'])->pluck('name')->contains('Delivered')
        && ! collect($r['statuses'])->pluck('name')->contains('Arrived at Philippine Warehouse'));
    $m = ConnectorLink::sole()->mappings()->pluck('trackstatus_id', 'key');
    expect($m['ds.unloaded'])->toBe(6)->and($m['ds.delivered'])->toBe(15)->and($m['ds.delivered_damaged'])->toBe(15)
        ->and($m['ds.load.1'])->toBeGreaterThanOrEqual(58)->and($m['ds.back_to_hub.3'])->toBe($m['ds.back_to_hub.2']);
    Http::assertSent(fn (Request $r) => $r->method() === 'PUT');
});

it('shows the GRANT line when their connector may not add statuses', function () {
    pairLink(['statuses' => ['ph_branch_id' => 2, 'list' => [['id' => 15, 'name' => 'Delivered', 'code' => null, 'branch_id' => 2, 'active' => true]], 'mapping' => []]]);
    Http::fake(['*/api/v1/statuses' => Http::response(['message' => 'No INSERT', 'grant' => "GRANT INSERT ON `cms`.`trackstatuses` TO 'dc'@'localhost';"], 403)]);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);
    Livewire::test(ConsolidatorConnections::class, ['con' => $this->con->id])->set('tab', 'map')
        ->call('openStandard')->call('addStandard')->assertSet('stdGrant', "GRANT INSERT ON `cms`.`trackstatuses` TO 'dc'@'localhost';")
        ->assertSee('GRANT INSERT ON');
    expect(ConnectorLink::sole()->mappings()->count())->toBe(0);
});

it('asks to update an old connector that cannot add statuses', function () {
    pairLink(['statuses' => ['ph_branch_id' => 2, 'list' => [['id' => 15, 'name' => 'Delivered', 'code' => null, 'branch_id' => 2, 'active' => true]], 'mapping' => []]]);
    Http::fake(['*/api/v1/statuses' => Http::response(['message' => 'Not Found'], 404)]);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);
    Livewire::test(ConsolidatorConnections::class, ['con' => $this->con->id])->set('tab', 'map')
        ->call('openStandard')->call('addStandard')->assertNotified('Update their connector first');
});

it('hides the place rows until asked, and says which address failed', function () {
    pairLink(['statuses' => ['ph_branch_id' => 2, 'list' => [['id' => 15, 'name' => 'Delivered', 'code' => null, 'branch_id' => 2, 'active' => true]], 'mapping' => []]]);
    \App\Models\Warehouse::query()->first()?->update(['name' => 'Zamboanga Test Warehouse']);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);
    Livewire::test(ConsolidatorConnections::class, ['con' => $this->con->id])->set('tab', 'map')
        ->assertDontSee('Zamboanga Test Warehouse')->call('togglePlaces')->assertSee('Zamboanga Test Warehouse');

    expect(\App\Support\Connectors\Client::short('cURL error 6: Could not resolve host: x.test (see https://curl.se)', 'https://x.test/api/v1/pair'))
        ->toContain('x.test was not found (DNS)')->toContain('[cURL 6: Could not resolve host: x.test');
});
