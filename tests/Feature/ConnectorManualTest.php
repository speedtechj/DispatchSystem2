<?php

use App\Filament\Pages\ConsolidatorConnections;
use App\Filament\Pages\SendStatus as AdminSendStatus;
use App\Filament\Company\Pages\SendStatus as CompanySendStatus;
use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\Consolidator;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Connectors\Backfill;
use App\Support\Connectors\ManualSend;
use App\Support\Connectors\Recorder;
use App\Support\Connectors\Rules;
use App\Support\Connectors\Sender;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->firstOrFail();
    $this->inv = Invoice::find($this->box->invoice_id);
    $this->link = ConnectorLink::create([
        'consolidator_id' => Consolidator::where('code', $this->inv->location_code)->value('id'), 'url' => 'https://conn.test', 'mode' => 'push',
        'token' => 't', 'secret' => 's', 'key_id' => 'k', 'state' => 'online',
    ]);
    Recorder::forgetLinks();
});

it('lets admins and users with the switch send manually, never drivers', function () {
    $driver = User::where('email', 'driver@example.com')->firstOrFail();
    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    $wh->syncRoles([]); // the demo gives everyone super_admin; a normal warehouse user has no admin role
    expect(ManualSend::allowed($this->admin))->toBeTrue()
        ->and(ManualSend::allowed($driver))->toBeFalse()
        ->and(ManualSend::allowed($wh))->toBeFalse();
    $wh->forceFill(['can_send_status' => true])->save();
    $driver->forceFill(['can_send_status' => true])->save();
    expect(ManualSend::allowed($wh->fresh()))->toBeTrue()->and(ManualSend::allowed($driver->fresh()))->toBeFalse();
});

it('puts a manual status in the Outbox with its real time, the note and the reason (staff only)', function () {
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);
    $when = now()->subHours(2)->startOfMinute();

    Livewire::test(AdminSendStatus::class)
        ->set('scan', $this->inv->invoice.' 9999999')->call('addScan')
        ->assertSet('boxes', [$this->inv->id])->assertSee('9999999 not added')
        ->call('pickCode', 'ds.delivered')->set('at', $when->format('Y-m-d\TH:i'))
        ->set('note', 'Received by sister')->call('send')->assertHasErrors(['reason'])
        ->set('reason', 'Driver phone broken, delivered on paper')->call('send')->assertHasNoErrors()
        ->assertSee('1 statuses put in the Outbox');

    $e = ConnectorEvent::sole();
    expect($e->manual)->toBeTrue()->and($e->state)->toBe('hold')->and($e->code)->toBe('ds.delivered')
        ->and($e->happened_at->equalTo($when))->toBeTrue()
        ->and($e->payload['note'])->toBe('Received by sister')
        ->and($e->payload['reason'])->toBe('Manual · Driver phone broken, delivered on paper')
        ->and($e->payload['by']['name'])->toBe($this->admin->full_name);
});

it('adds a whole trip, and a partner hub only gets its own boxes', function () {
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);
    $n = Tripinvoice::where('deliverylog_id', $this->trip->id)->count();
    Livewire::test(AdminSendStatus::class)->set('fromKind', 'trip')->set('from', $this->trip->trip_number)->call('addFrom')
        ->assertSee($n.' boxes added');

    $co = User::where('email', 'company@example.com')->firstOrFail();
    $co->forceFill(['can_send_status' => true])->save();
    Filament::setCurrentPanel(Filament::getPanel('company'));
    $this->actingAs($co->fresh());
    Livewire::test(CompanySendStatus::class)->set('scan', $this->inv->invoice)->call('addScan')
        ->assertSet('boxes', [])->assertSee('not in');
});

it('backfills the history once, oldest first, after the live statuses and 200 a minute', function () {
    $this->inv->forceFill(['is_verified' => true, 'verified_at' => now()->subDays(3), 'is_delivered' => false])->saveQuietly();
    $this->box->forceFill(['is_loaded' => true])->saveQuietly();
    $this->trip->forceFill(['taken_at' => now()->subDay(), 'trip_number' => $this->trip->trip_number])->saveQuietly();

    $p = Backfill::preview($this->link, 'container', $this->inv->container?->container_no, null, null, false);
    expect($p['boxes'])->toBeGreaterThan(0)->and($p['statuses'])->toBeGreaterThanOrEqual(2);

    $n = Backfill::start($this->link, 'container', $this->inv->container?->container_no, null, null, false, $this->admin);
    expect($n)->toBe($p['statuses'])
        ->and(Backfill::start($this->link, 'container', $this->inv->container?->container_no, null, null, false, $this->admin))->toBe(0);
    $mine = ConnectorEvent::where('invoice_id', $this->inv->id)->orderBy('happened_at')->pluck('code')->all();
    expect($mine[0])->toBe('ds.unloaded')->and($mine)->toContain('ds.load.1');
    expect(ConnectorEvent::where('priority', Backfill::PRIORITY)->count())->toBe($n);

    // a live status goes before the backfill
    $live = Recorder::record($this->inv, 'ds.delivered', null, ['send_now' => true]);
    $got = [];
    Http::fake(function (Request $r) use (&$got) {
        if (str_ends_with(parse_url($r->url(), PHP_URL_PATH), '/api/v1/events')) {
            $got[] = collect($r['events'])->pluck('id')->all();

            return Http::response(['results' => collect($r['events'])->map(fn ($e) => ['id' => $e['id'], 'result' => 'saved', 'row_id' => 1])->all()]);
        }

        return Http::response(['results' => []]);
    });
    Sender::run(5);
    expect($got[0][0])->toBe($live->uid)->and($got)->toHaveCount(1);

    // night only: nothing of the backfill in the day
    ConnectorEvent::query()->update(['state' => 'ready']);
    Rules::save(['night' => true] + Rules::all());
    $this->travelTo(now()->setTimezone('America/Edmonton')->setTime(12, 0));
    expect(Sender::waiting($this->link)->where('priority', Backfill::PRIORITY)->count())->toBe(0);
    $this->travelTo(now()->setTimezone('America/Edmonton')->setTime(23, 0));
    expect(Sender::waiting($this->link)->where('priority', Backfill::PRIORITY)->count())->toBeGreaterThan(0);
});

it('previews and starts a backfill from the Outbox tab', function () {
    $this->inv->forceFill(['is_verified' => true, 'verified_at' => now()->subDays(3)])->saveQuietly();
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);
    Livewire::test(ConsolidatorConnections::class, ['con' => $this->link->consolidator_id])->set('tab', 'outbox')
        ->assertSee('Backfill: send the history')->call('previewBackfill')->assertSee('Statuses to send')
        ->call('startBackfill')->assertNotified()->assertSee('backfill statuses waiting')
        ->call('cancelBackfill');
    expect(ConnectorEvent::where('priority', Backfill::PRIORITY)->where('state', 'cancelled')->count())->toBeGreaterThan(0);
});
