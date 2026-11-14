<?php

use App\Enums\FailedDeliveryReason;
use App\Filament\Pages\SmsLog;
use App\Filament\Pages\SmsSettings as SmsSettingsPage;
use App\Filament\Pages\TruckDay;
use App\Filament\Pages\TruckDetail;
use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Sms\SmsMessage;
use App\Models\Sms\SmsOptout;
use App\Models\Tracking\TruckAlert;
use App\Models\Tracking\TruckDaySummary;
use App\Models\Tracking\TruckPosition;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Maps\TripSorter;
use App\Support\Sms\Phone;
use App\Support\Sms\SmsEvents;
use App\Support\Sms\SmsSettings;
use App\Support\Sms\SmsWriter;
use App\Support\Sms\Templates;
use App\Support\Tracking\AlertChecker;
use App\Support\Tracking\DaySummary;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Livewire\Livewire;

uses(RefreshDatabase::class);

/** One fake for every outside call: Semaphore texts, and the AI answering with $ai($request). */
function smsFakeOutside(?Closure $ai = null): void
{
    Http::fake(function (Request $r) use ($ai) {
        if (str_contains($r->url(), 'semaphore.co/api/v4/messages')) {
            return Http::response([['message_id' => rand(1000, 9999), 'status' => 'Pending']]);
        }
        if (str_contains($r->url(), 'semaphore.co/api/v4/account')) {
            return Http::response(['credit_balance' => 2416]);
        }
        if (str_contains($r->url(), 'anthropic.com') && $ai) {
            return Http::response(['content' => [['type' => 'text', 'text' => $ai($r)]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]);
        }

        return Http::response('unexpected', 500);
    });
}

function smsAiOn(array $features): void
{
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => $features]);
    (fn () => static::$memo = null)->call(new AiSetting);
    Cache::forget('ai.settings');
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $hub = $this->admin->logistichub_id;
    Deliverylog::query()->update(['is_active' => false]);
    $this->truck = Truck::create(['plate_no' => 'SMS 101', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 40, 'category' => 'Truck', 'description' => '6-wheeler', 'registration_no' => 'RS', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => User::where('email', 'driver@example.com')->value('id'), 'user_id' => $this->admin->id]);
    $this->trip = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $mk = fn ($no, $name, $prov, $phone) => Invoice::create(['container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'S', 'receiver_name' => $name, 'receiver_address' => 'Purok 1', 'receiver_province' => $prov, 'receiver_city' => 'City', 'receiver_barangay' => 'Brgy', 'receiver_mobile_no' => $phone, 'boxtype' => 'Regular', 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1]);
    $boxes = collect([$mk('52211', 'Liza Gomez', 'Cebu', '0917 555 6666'), $mk('52212', 'Liza Gomez', 'Cebu', '0917 555 6666'), $mk('52204', 'Jose Ramos', 'Metro Manila', '+63 917 333 4444'), $mk('52228', 'Pedro Cruz', 'Iloilo', '0918 22')]);
    app(TripAssignment::class)->addToDeliveryTrip($this->trip, $boxes);
    TripSorter::sort($this->trip);
    SmsSettings::putKey('semaphore', 'sema-key');
    AppSetting::put('sms.sender', 'DISPATCHPH');
});

it('cleans Philippine numbers and picks the language by province', function () {
    expect(Phone::clean('0917 555 6666'))->toBe('09175556666')->and(Phone::clean('+63 917 333 4444'))->toBe('09173334444')
        ->and(Phone::clean('9171234567'))->toBe('09171234567')->and(Phone::clean('0918 22'))->toBeNull()
        ->and(Templates::langFor('Cebu'))->toBe('ceb')->and(Templates::langFor('Metro Manila'))->toBe('tl')->and(Templates::langFor('Iloilo'))->toBe('en')
        ->and(Templates::parts(str_repeat('a', 160)))->toBe(1)->and(Templates::parts(str_repeat('a', 161)))->toBe(2);
});

it('texts each receiver once when the trip is on the road, in their language', function () {
    smsFakeOutside();
    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_loaded' => true]);

    $this->artisan('sms:work')->assertSuccessful();
    $this->artisan('sms:work')->assertSuccessful(); // never twice

    $msgs = SmsMessage::where('kind', 'out_for_delivery')->get();
    expect($msgs)->toHaveCount(3)
        ->and($msgs->firstWhere('name', 'Liza Gomez')->message)->toContain('2 ka box nimo')->toContain('52211, 52212')->toContain('SMS 101')
        ->and($msgs->firstWhere('name', 'Liza Gomez')->status)->toBe('sent')
        ->and($msgs->firstWhere('name', 'Jose Ramos')->message)->toContain('ide-deliver ngayong araw')
        ->and($msgs->firstWhere('name', 'Pedro Cruz')->status)->toBe('bad_number');
    Http::assertSentCount(2);
    Http::assertSent(fn (Request $r) => str_contains($r->url(), 'messages') && $r['number'] === '09175556666' && $r['sendername'] === 'DISPATCHPH');
});

it('texts delivered when the last box is delivered, and not delivered with the AI reason from the driver note', function () {
    smsFakeOutside(fn () => 'nobody was home and the gate was closed');
    smsAiOn(['sms_writer']);
    $driver = User::where('email', 'driver@example.com')->first();
    $liza = Tripinvoice::where('deliverylog_id', $this->trip->id)->whereIn('invoice', ['52211', '52212'])->get();

    app(TripAssignment::class)->markDelivered($liza[0], ['x.jpg'], $driver);
    SmsEvents::delivered($liza[0]->fresh());
    expect(SmsMessage::where('kind', 'delivered')->count())->toBe(0); // one box still to go

    app(TripAssignment::class)->markDelivered($liza[1]->fresh(), ['y.jpg'], $driver);
    SmsEvents::delivered($liza[1]->fresh());
    expect(SmsMessage::where('kind', 'delivered')->first()?->message)->toContain('na-deliver na ang box 52211, 52212');

    $jose = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('invoice', '52204')->first();
    $a = app(TripAssignment::class)->recordFailedAttempt($jose, $driver, FailedDeliveryReason::NoOneHome, 'wala tao, sarado gate', ['p.jpg']);
    SmsEvents::notDelivered($a->fresh());
    expect(SmsMessage::where('kind', 'not_delivered')->first()->message)->toContain('nobody was home and the gate was closed');
});

it('does not text a number that said STOP, and stops at the monthly limit', function () {
    smsFakeOutside();
    SmsOptout::create(['number' => '09175556666']);
    AppSetting::put('sms.limit', 0);
    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_loaded' => true]);
    SmsEvents::outForDelivery($this->trip->fresh());

    expect(SmsMessage::where('name', 'Liza Gomez')->value('status'))->toBe('opted_out')
        ->and(SmsMessage::where('name', 'Jose Ramos')->value('status'))->toBe('over_limit');
    Http::assertNothingSent();
});

it('rewrites a text with the AI but never loses a blank', function () {
    smsAiOn(['sms_writer']);
    smsFakeOutside(fn (Request $r) => str_contains(json_encode($r->data()), 'Tagalog') ? 'Hi {name}, na-deliver na ang box {boxes}.' : 'Hi there, box delivered.');

    $ok = SmsWriter::rewrite('Hi {name}, box {boxes} was delivered.', 'tl');
    expect($ok['text'])->toBe('Hi {name}, na-deliver na ang box {boxes}.');
    expect(fn () => SmsWriter::rewrite('Hi {name}, box {boxes} was delivered.', 'short'))->toThrow(RuntimeException::class);

    Livewire::test(SmsSettingsPage::class)->call('edit', 'delivered', 'en')->set('text', 'Hi {name}, box {boxes} was delivered.')->call('ai', 'tl')
        ->assertSet('lang', 'tl')->assertSet('text', 'Hi {name}, na-deliver na ang box {boxes}.')->call('saveText');
    expect(Templates::get('delivered', 'tl'))->toBe('Hi {name}, na-deliver na ang box {boxes}.');
});

it('has the SMS settings and log pages, with a test text', function () {
    smsFakeOutside();
    Livewire::test(SmsSettingsPage::class)->assertSee('Semaphore')->assertSee('Out for delivery')->assertSee('1 text per receiver')
        ->set('testNumber', '0917 123 4567')->call('test')->assertSee('Sent to 0917 123 4567')
        ->call('toggle', 'driver_next')->set('sender', 'MYCO')->call('saveSetup');
    expect(SmsSettings::on('driver_next'))->toBeFalse()->and(SmsSettings::sender())->toBe('MYCO')
        ->and(AppSetting::where('key', 'sms.key.semaphore')->value('value'))->not->toContain('sema-key');

    SmsMessage::create(['kind' => 'out_for_delivery', 'name' => 'Pedro Cruz', 'raw_number' => '0918 22', 'message' => 'Hi Pedro', 'status' => 'bad_number']);
    $this->get(SmsLog::getUrl())->assertOk()->assertSee('Bad number')->assertSee('Credits left')->assertSee('2,416');
});

it('explains a truck alert with the AI and puts the note in the bell', function () {
    smsAiOn(['alert_explain']);
    smsFakeOutside(fn () => json_encode(['note' => 'Probably a lunch break near the market.', 'level' => 'low', 'actions' => ['Mark checked · lunch', 'Call the driver']]));
    foreach (range(40, 0, -5) as $m) {
        TruckPosition::create(['truck_id' => $this->truck->id, 'deliverylog_id' => $this->trip->id, 'lat' => 10.40, 'lng' => 123.80, 'speed' => 0, 'source' => 'app', 'recorded_at' => now()->subMinutes($m)]);
    }
    AlertChecker::run();
    $alert = TruckAlert::where('kind', 'stopped')->first();
    expect($alert->ai_note)->toBe('Probably a lunch break near the market.')->and($alert->ai_level)->toBe('low')->and($alert->ai_actions)->toContain('Call the driver')
        ->and($this->admin->fresh()->notifications()->first()->data['body'])->toContain('✨ Probably a lunch break');

    Livewire::withQueryParams(['truck' => $this->truck->id, 'tab' => 'alerts'])->test(TruckDetail::class)
        ->assertSee('What probably happened')->assertSee('Low concern');
});

it('writes the end-of-day summary with a grade per truck, shows it and emails it', function () {
    smsAiOn(['day_summary']);
    smsFakeOutside(fn () => json_encode(['day' => '1 truck delivered 4 of 4 boxes.', 'trucks' => [['plate' => 'SMS 101', 'summary' => 'Dan delivered everything.', 'good' => 'All delivered', 'bad' => 'Nothing to look at']]]));
    Tripinvoice::where('deliverylog_id', $this->trip->id)->update(['is_delivered' => true, 'delivered_at' => now()]);
    TruckPosition::create(['truck_id' => $this->truck->id, 'deliverylog_id' => $this->trip->id, 'lat' => 10.3, 'lng' => 123.9, 'source' => 'app', 'recorded_at' => now()->subHour()]);

    $s = DaySummary::build(today(), null);
    expect($s->data['day'])->toBe('1 truck delivered 4 of 4 boxes.')
        ->and($s->data['trucks'][0]['grade'])->toBe('A')->and($s->data['trucks'][0]['summary'])->toBe('Dan delivered everything.');

    $this->get(TruckDay::getUrl())->assertOk()->assertSee('The day in short')->assertSee('Dan delivered everything.')->assertSee('Day A');

    Mail::fake();
    AppSetting::put('track.summary_emails', 'boss@example.com');
    $this->artisan('track:summary')->assertSuccessful();
    expect(TruckDaySummary::count())->toBeGreaterThanOrEqual(1);
});
