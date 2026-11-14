<?php

use App\Filament\Pages\AgingLimits;
use App\Filament\Pages\Ai\BoxAging as AgingPageAdmin;
use App\Mail\AgingSummaryMail;
use App\Models\Ai\AgingLimit;
use App\Models\Ai\AiSetting;
use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Aging\AgingNotifier;
use App\Support\Aging\BoxAging;
use App\Support\Aging\LimitSuggester;
use App\Support\Aging\Regions;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Mail;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    AiSetting::create(['features' => ['aging']]);
    Cache::flush();
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->container = Container::firstOrFail();
    Container::whereKey($this->container->id)->update(['unloaded_at' => now()->subDays(9), 'is_unloaded' => true, 'created_at' => now()->subDays(12)]);
    $this->container->refresh();
});

it('knows the region of a province', function () {
    expect(Regions::of('Metro Manila'))->toBe('metro_manila')->and(Regions::of('Cebu'))->toBe('visayas')
        ->and(Regions::of('Davao del Sur'))->toBe('mindanao')->and(Regions::of('Tarlac'))->toBe('luzon');
});

it('finds the stage and age of each box, and which are late', function () {
    $rows = BoxAging::rows(fresh: true)->keyBy('invoice');
    $waiting = $rows->first(fn ($r) => $r['stage'] === 'waiting');
    expect($waiting['days'])->toBe(9)->and($waiting['status'])->toBe('late'); // waiting limit 4/7

    // a box tried and failed counts from the attempt
    $t = Tripinvoice::where('is_delivered', false)->firstOrFail();
    Tripinvoice::whereKey($t->id)->update(['created_at' => now()->subDays(5)]);
    DeliveryAttempt::create(['tripinvoice_id' => $t->id, 'invoice_id' => $t->invoice_id, 'deliverylog_id' => $t->deliverylog_id, 'user_id' => $this->admin->id, 'reason' => 'no_one_home', 'created_at' => now()->subDays(2)]);
    $r = BoxAging::rows(fresh: true)->firstWhere('invoice_id', $t->invoice_id);
    expect($r['stage'])->toBe('failed')->and($r['days'])->toBe(2)->and($r['total'])->toBe(9);
});

it('uses saved limits instead of the standard ones', function () {
    AgingLimit::create(['stage' => 'waiting', 'region' => 'all', 'warn_days' => 10, 'late_days' => 20]);
    $r = BoxAging::rows(fresh: true)->first(fn ($r) => $r['stage'] === 'waiting' && $r['region'] !== 'mindanao');
    expect($r['stageStatus'])->toBe('ok');
});

it('suggests limits from history, or the standard ones when there is too little', function () {
    $s = collect(LimitSuggester::suggest(false));
    expect($s->firstWhere('stage', 'waiting')['reason'])->toContain('Not enough history');

    // 30 delivered boxes that waited 2 to 6 days for a trip
    foreach (range(1, 30) as $i) {
        $inv = Invoice::create(['container_id' => $this->container->id, 'invoice' => "H{$i}", 'sender_name' => 'S', 'receiver_name' => "R{$i}", 'receiver_address' => 'A', 'receiver_province' => 'Cebu', 'receiver_city' => 'Cebu City', 'receiver_barangay' => 'Lahug', 'receiver_mobile_no' => '0917', 'boxtype' => 'R', 'location_code' => 'X', 'is_delivered' => true]);
        $t = Tripinvoice::create(['deliverylog_id' => Deliverylog::value('id'), 'invoice' => "H{$i}", 'invoice_id' => $inv->id, 'logistichub_id' => 1, 'is_loaded' => true, 'is_delivered' => true, 'delivered_at' => now()->subDays(1)]);
        $t->forceFill(['created_at' => now()->subDays(9)->addDays(2 + $i % 5)])->save();
    }
    $w = collect(LimitSuggester::suggest(false))->first(fn ($r) => $r['stage'] === 'waiting' && $r['region'] === 'all');
    expect($w['n'])->toBe(30)->and($w['warn'])->toBeGreaterThanOrEqual(4)->and($w['late'])->toBeGreaterThan($w['warn'])
        ->and($w['reason'])->toContain('3 out of 4');

    Livewire::test(AgingLimits::class)->call('suggest')->assertSee('Suggested from your deliveries')
        ->call('bump', 1, 'late', 2)->assertSee('1 row changed')->call('save');
    expect(AgingLimit::count())->toBeGreaterThan(5);
});

it('shows the dashboard with late boxes and plain reasons without a key', function () {
    Livewire::test(AgingPageAdmin::class)->assertSee('Late now')->assertSee('Why boxes are late')
        ->assertSee('In warehouse, waiting for a trip')->call('pick', 'waiting', 2)->assertSee('8–14 days');
});

it('sends the morning summary to the bell, and email when switched on', function () {
    Mail::fake();
    AgingNotifier::saveSettings(['mail_admin' => true, 'hour' => (int) now()->format('G')]);
    $n = AgingNotifier::tick();
    expect($n)->toBeGreaterThan(0)
        ->and($this->admin->notifications()->count())->toBeGreaterThan(0);
    Mail::assertSent(AgingSummaryMail::class);
    expect(AgingNotifier::tick())->toBe(0); // only once a day
});
