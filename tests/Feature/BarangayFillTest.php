<?php

use App\Filament\Pages\AddressAi;
use App\Filament\Pages\AddressesToCheck;
use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Invoice;
use App\Models\Maps\BarangayFill;
use App\Models\Maps\ReceiverPlace;
use App\Models\User;
use App\Support\Maps\Barangays;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function brgyAi(bool $on = true): void
{
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test-1234', 'model_fast' => 'claude-haiku-5-5', 'model_smart' => 'claude-sonnet-5-5', 'monthly_limit' => 20, 'features' => $on ? ['addresses'] : []]);
    Cache::forget('ai.settings');
}

function brgyReply(array $items): array
{
    return ['content' => [['type' => 'text', 'text' => json_encode(['items' => $items])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 50, 'output_tokens' => 20]];
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->base = Invoice::firstOrFail();
    $this->box = function (array $over) {
        $i = $this->base->replicate();
        $i->forceFill(array_merge(['invoice' => (string) random_int(70000, 99999), 'is_delivered' => false, 'receiver_city' => 'Marilao', 'receiver_province' => 'Bulacan'], $over))->save();

        return $i->fresh();
    };
    // barangays we know in Marilao from earlier manifests
    foreach (['Lambakin', 'Saog', 'Abangan Norte'] as $b) {
        ($this->box)(['receiver_barangay' => $b, 'receiver_mobile_no' => '0900000'.random_int(1000, 9999), 'is_delivered' => true]);
    }
});

it('queues a box with no barangay and fills it from the same receiver before', function () {
    ($this->box)(['receiver_barangay' => 'Saog', 'receiver_mobile_no' => '0917 222 4410', 'is_delivered' => true]);
    $new = ($this->box)(['receiver_barangay' => '', 'receiver_mobile_no' => '+63 917 222 4410']);

    $f = BarangayFill::where('invoice_id', $new->id)->first();
    expect($f->status)->toBe('pending');
    Barangays::work();
    $f->refresh();
    expect($f->status)->toBe('used')->and($f->source)->toBe('same')->and($f->barangay)->toBe('Saog')
        ->and(Barangays::of($new->fresh()))->toBe('Saog')
        ->and($new->fresh()->receiver_barangay)->toBe(''); // the manifest address is never changed
});

it('asks the AI only when nothing else knows, and sends unsure ones to check', function () {
    brgyAi();
    $sure = ($this->box)(['receiver_barangay' => '', 'receiver_address' => '221 MacArthur Hwy, tapat Petron', 'receiver_mobile_no' => '0918 111 0001']);
    $unsure = ($this->box)(['receiver_barangay' => 'N/A', 'receiver_address' => 'Blk 5 Lot 12 Villa Arcadia Subd., near SM Marilao', 'receiver_mobile_no' => '0918 111 0002']);
    Http::fake(['api.anthropic.com/*' => Http::response(brgyReply([
        ['i' => 0, 'barangay' => 'Abangan Norte', 'confidence' => 93, 'why' => 'MacArthur Hwy near Petron', 'clues' => [], 'candidates' => []],
        ['i' => 1, 'barangay' => 'Lambakin', 'confidence' => 72, 'why' => 'Villa Arcadia is in Lambakin', 'clues' => [['text' => 'Villa Arcadia Subd.', 'kind' => 'subdivision'], ['text' => 'not in address', 'kind' => 'landmark']],
            'candidates' => [['name' => 'Lambakin', 'pct' => 72, 'why' => 'map'], ['name' => 'Saog', 'pct' => 20, 'why' => 'mall'], ['name' => 'Made Up', 'pct' => 8, 'why' => 'x']]],
    ]))]);

    Barangays::work();
    $a = BarangayFill::where('invoice_id', $sure->id)->first();
    $b = BarangayFill::where('invoice_id', $unsure->id)->first();
    expect($a->status)->toBe('used')->and($a->barangay)->toBe('Abangan Norte')
        ->and($b->status)->toBe('check')->and($b->barangay)->toBe('Lambakin')
        ->and(collect($b->candidates)->pluck('name')->all())->toBe(['Lambakin', 'Saog'])   // never a made-up name
        ->and($b->clues)->toHaveCount(1)
        ->and(Barangays::of($unsure->fresh()))->toBeNull();
    Http::assertSent(fn ($r) => ! str_contains($r->body(), (string) $sure->receiver_name) && ! str_contains($r->body(), '0918 111'));
});

it('lists the boxes, ✓ OK confirms, Change picks another one for the receiver\'s other boxes too', function () {
    $one = ($this->box)(['receiver_barangay' => '', 'receiver_name' => 'Ana Cruz', 'receiver_mobile_no' => '0917 999 0001', 'set_key' => null]);
    $two = ($this->box)(['receiver_barangay' => '', 'receiver_name' => 'Ana Cruz', 'receiver_mobile_no' => '0917 999 0001', 'set_key' => null]);
    $jo = ($this->box)(['receiver_barangay' => '', 'receiver_name' => 'Jose Ramos', 'receiver_mobile_no' => '0917 999 0002']);
    foreach ([$one, $two] as $i) {
        BarangayFill::where('invoice_id', $i->id)->update(['status' => 'check', 'source' => 'ai', 'barangay' => 'Lambakin', 'confidence' => 70, 'candidates' => json_encode([['name' => 'Lambakin', 'pct' => 70, 'why' => 'subd'], ['name' => 'Saog', 'pct' => 20, 'why' => 'mall']])]);
    }
    BarangayFill::where('invoice_id', $jo->id)->update(['status' => 'check', 'source' => 'ai', 'barangay' => 'Saog', 'confidence' => 70]);

    $page = Livewire::test(AddressesToCheck::class)->assertSee('Addresses to check')->assertSee('Ana Cruz')->assertSee('Not sure · check')->assertSee('or Saog');
    $page->call('ok', BarangayFill::where('invoice_id', $jo->id)->value('id'));
    expect(BarangayFill::where('invoice_id', $jo->id)->value('status'))->toBe('checked')
        ->and(ReceiverPlace::where('key', 'p9179990002')->value('barangay'))->toBe('Saog');

    $page->call('openBox', BarangayFill::where('invoice_id', $one->id)->value('id'))->assertSee('Pick the barangay')->assertSee('Also use for Ana')
        ->call('pick', 'Saog')->call('useChosen');
    expect(BarangayFill::whereIn('invoice_id', [$one->id, $two->id])->pluck('barangay')->unique()->all())->toBe(['Saog'])
        ->and(BarangayFill::whereIn('invoice_id', [$one->id, $two->id])->pluck('status')->unique()->all())->toBe(['checked']);
    $page->call('setShow', 'check')->assertSee('Nothing to check');
});

it('has its settings: switches, the sure level, and Try it', function () {
    brgyAi();
    Livewire::test(AddressAi::class)->assertSee('AI address cleaning')->assertSee('Fill in a missing barangay')->assertSee('Order it tries')
        ->call('flip', 'landmarks')->call('setLevel', 60)->call('toggleOn');
    expect(Barangays::on('landmarks'))->toBeFalse()->and(Barangays::level())->toBe(60)->and(AiSetting::current()->isOn('addresses'))->toBeFalse();

    brgyAi();
    AppSetting::put('addr.level', '75');
    Http::fake(['api.anthropic.com/*' => Http::sequence()
        ->push(['content' => [['type' => 'text', 'text' => json_encode(['addresses' => [['i' => 0, 'address' => 'Purok 3, San Jose, Meycauayan, Bulacan']]])]], 'usage' => ['input_tokens' => 1, 'output_tokens' => 1]])
        ->push(brgyReply([['i' => 0, 'barangay' => 'Saog', 'confidence' => 72, 'why' => 'SJ', 'clues' => [], 'candidates' => []]]))]);
    Livewire::test(AddressAi::class)->call('setTab', 'try')->set('tryAddress', 'Purok 3, Brgy SJ')->set('tryCity', 'Marilao, Bulacan')->call('runTry')
        ->assertSee('Purok 3, San Jose, Meycauayan, Bulacan')->assertSee('72%')->assertSee('Goes to Addresses to check');
});

it('marks trip stops and remembers where the driver delivered', function () {
    $i = ($this->box)(['receiver_barangay' => '', 'receiver_mobile_no' => '0917 555 0100']);
    expect(Barangays::note($i))->toBe('no barangay');
    BarangayFill::where('invoice_id', $i->id)->update(['status' => 'check', 'barangay' => 'Saog', 'source' => 'ai']);
    expect(Barangays::note($i->fresh()))->toBe('AI guess, not checked');
    Barangays::remember($i, 'Saog', 'driver', 14.8, 120.95, true);
    expect(ReceiverPlace::where('key', 'p9175550100')->first()->lat)->toBe(14.8);
});
