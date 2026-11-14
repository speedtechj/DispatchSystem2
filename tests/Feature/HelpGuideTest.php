<?php

use App\Filament\Company\Pages\HelpGuide as CompanyHelp;
use App\Filament\Pages\HelpGuide as AdminHelp;
use App\Filament\Resources\HelpGuides\Pages\CreateHelpGuide;
use App\Filament\Resources\HelpGuides\Pages\EditHelpGuide;
use App\Livewire\HelpDrawer;
use App\Models\Ai\AiSetting;
use App\Models\Help\HelpGuide;
use App\Models\User;
use App\Support\Help\DefaultGuides;
use App\Support\Help\Help;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function helpAiOn(array $features): void
{
    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => $features]);
    (fn () => static::$memo = null)->call(new AiSetting);
    Cache::flush();
}

function helpAiReply(string $json): void
{
    Http::fake(fn () => Http::response(['content' => [['type' => 'text', 'text' => $json]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]));
}

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Help::forget();
    Help::installDefaults();
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
});

it('installs the built-in guides once, in English and Tagalog', function () {
    expect(HelpGuide::count())->toBe(count(DefaultGuides::all()));
    expect(Help::installDefaults())->toBe(0);

    foreach (HelpGuide::all() as $g) {
        expect($g->title_tl)->not->toBeEmpty("{$g->slug} has no Tagalog title");
        expect($g->steps)->not->toBeEmpty();
        foreach ($g->steps as $s) {
            expect($s['text_tl'] ?? '')->not->toBeEmpty("{$g->slug} step has no Tagalog");
        }
        foreach ($g->related ?? [] as $slug) {
            expect(HelpGuide::where('slug', $slug)->exists())->toBeTrue("{$g->slug} → {$slug}");
        }
    }

    // A deleted guide comes back; an edited one is not touched.
    HelpGuide::where('slug', 'driver-undo')->delete();
    HelpGuide::where('slug', 'load-truck')->update(['title_en' => 'Our way to load']);
    expect(Help::installDefaults())->toBe(1);
    expect(HelpGuide::where('slug', 'load-truck')->value('title_en'))->toBe('Our way to load');
});

it('finds guides in English, Tagalog and Taglish', function () {
    expect(Help::search('print loading list', 'admin')->first()->slug)->toBe('stops-loading');
    expect(Help::search('bakit wala sa inventory ang box', 'admin')->first()->slug)->toBe('inventory-count');
    expect(Help::search('magpadala ng text sa receiver', 'admin')->first()->slug)->toBe('sms-setup');
    expect(Help::search('walang tao sa bahay', 'driver')->first()->slug)->toBe('driver-cant-deliver');
    expect(Help::search('pressed deliver by mistake', 'driver')->first()->slug)->toBe('driver-undo');
    expect(Help::search('xyzzy', 'admin'))->toBeEmpty();
});

it('shows each app only its own guides', function () {
    expect(Help::guides('driver')->pluck('slug'))->toContain('driver-undo')->not->toContain('sms-setup');
    expect(Help::guides('company')->pluck('slug'))->not->toContain('sms-setup');
    expect(Help::guides('scan')->pluck('slug'))->toContain('scan-tips', 'unload-container');

    HelpGuide::where('slug', 'driver-undo')->update(['is_published' => false]);
    Help::forget();
    expect(Help::guides('driver')->pluck('slug'))->not->toContain('driver-undo');
});

it('knows the guide for the page you are on', function () {
    expect(Help::forRoute('filament.admin.pages.scanload', 'admin')->pluck('slug')->all())->toBe(['load-truck']);
    expect(Help::forRoute('filament.warehouse.resources.deliverylogs.index', 'warehouse')->pluck('slug'))->toContain('create-trip');
    expect(Help::forRoute('filament.admin.pages.sms-log', 'admin')->pluck('slug'))->toContain('sms-setup');
    expect(Help::forScanMode('return'))->toBe('return-boxes');
    expect(Help::forScanMode('wh_unload'))->toBe('warehouse-transfer');
});

it('shows the Help Center, a guide, and the "?" in the top bar', function () {
    $this->get('/help')->assertOk()->assertSee('Help guide')->assertSee('Unload a container')->assertSee('ds-help-q', false);
    $this->get('/help?g=load-truck')->assertOk()->assertSee('Load a truck')->assertSee('Do it now')->assertSee(route('filament.admin.pages.scanload'), false);

    $this->flushSession();
    $co = User::where('email', 'company@example.com')->firstOrFail();
    $this->actingAs($co);
    $this->get('/company/help')->assertOk()->assertSee('Make a delivery trip')->assertDontSee('Send SMS to receivers');
});

it('switches to Tagalog and searches live', function () {
    Livewire::test(AdminHelp::class)
        ->call('setLang', 'tl')
        ->assertSee('Gabay at tulong')
        ->assertSee('Mag-unload ng container')
        ->set('q', 'loading list')
        ->assertSee('Pagkakasunod ng stops at ang loading list');
    expect(session('help.lang'))->toBe('tl');
});

it('answers without AI from the best guide', function () {
    Http::fake();
    Livewire::test(AdminHelp::class)
        ->call('ask', 'why is a box not in inventory')
        ->assertSet('answer.guide', 'inventory-count')
        ->assertSet('answer.ai', false)
        ->assertSee('Best matching guide');
    Http::assertNothingSent();
});

it('answers in your own words with AI, only from the guides', function () {
    helpAiOn(['help_ask']);
    helpAiReply('{"answer": "I-scan ang box sa Return Boxes, babalik ito sa inventory.", "guide": "return-boxes"}');
    $this->actingAs(User::where('email', 'company@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('company'));

    Livewire::test(CompanyHelp::class)
        ->call('ask', 'paano ibalik yung box na di na deliver')
        ->assertSet('answer.ai', true)
        ->assertSet('answer.guide', 'return-boxes')
        ->assertSee('I-scan ang box sa Return Boxes');

    Http::assertSent(function ($r) {
        $body = json_encode($r->data());

        return str_contains($r->url(), 'anthropic.com') && str_contains($body, 'return-boxes') && ! str_contains($body, 'sms-setup');
    });
});

it('ignores a guide the AI made up', function () {
    helpAiOn(['help_ask']);
    helpAiReply('{"answer": "Press the magic button.", "guide": "magic"}');

    $out = Help::ask('how do I fly', 'admin', 'en');
    expect($out['ai'])->toBeTrue()->and($out['guide'])->toBeNull();
});

it('falls back to search when the AI fails', function () {
    helpAiOn(['help_ask']);
    Http::fake(fn () => Http::response('down', 500));

    $out = Help::ask('print loading list', 'admin', 'en');
    expect($out['ai'])->toBeFalse()->and($out['guide'])->toBe('stops-loading');
});

it('counts "Was this helpful?" once per person', function () {
    $page = Livewire::test(AdminHelp::class, ['g' => 'create-trip']);
    $page->call('vote', true)->call('vote', true)->call('vote', false)->assertSee('Thanks for telling us');
    $g = HelpGuide::where('slug', 'create-trip')->first();
    expect($g->helpful_yes)->toBe(1)->and($g->helpful_no)->toBe(0)->and($g->views)->toBe(1);
});

it('opens the help panel on the page guide, and in the phone apps', function () {
    Livewire::test(HelpDrawer::class, ['app' => 'admin', 'route' => 'filament.admin.pages.scanload'])
        ->assertDontSee('Load a truck')
        ->dispatch('open-help')
        ->assertSet('g', 'load-truck')
        ->assertSee('Load a truck')
        ->assertDontSee('Do it now') // already on that page
        ->call('back')
        ->assertSee('Help for this page')
        ->call('close')
        ->assertSet('open', false);

    Livewire::test(HelpDrawer::class, ['app' => 'driver', 'route' => 'filament.delivery.pages.dashboard'])
        ->dispatch('open-help')
        ->assertSet('g', null)
        ->assertSee('Undo a delivery')
        ->assertSee('is-phone', false)
        ->dispatch('open-help', slug: 'driver-offline')
        ->assertSee('No signal');

    Livewire::test(HelpDrawer::class, ['app' => 'scan'])
        ->dispatch('open-help', slug: 'sms-setup') // not a Scan app guide
        ->assertSet('g', null);
});

it('puts a "?" in the Scan app and the Driver app', function () {
    $this->flushSession();
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    $this->get('/scan')->assertOk()->assertSee('ds-sa__help', false)->assertSee('scan-tips', false);

    $this->flushSession();
    $this->actingAs(User::where('email', 'driver@example.com')->firstOrFail());
    $this->get('/delivery')->assertOk()->assertSee('ds-sa__help', false);
});

it('lets the admin edit and add guides, keeping built-in screenshots', function () {
    $g = HelpGuide::where('slug', 'unload-container')->first();
    expect($g->steps[0]['image'])->toBe('images/help/scan-home.jpg');

    Livewire::test(EditHelpGuide::class, ['record' => $g->getRouteKey()])
        ->assertFormSet(['title_en' => 'Unload a container'])
        ->fillForm(['title_en' => 'Unload a container (our way)', 'title_tl' => 'Mag-unload (paraan namin)'])
        ->call('save')
        ->assertHasNoFormErrors();

    $g->refresh();
    expect($g->title_en)->toBe('Unload a container (our way)')
        ->and($g->steps[0]['image'])->toBe('images/help/scan-home.jpg')
        ->and($g->updated_by)->toBe($this->admin->id);

    Livewire::test(CreateHelpGuide::class)
        ->fillForm([
            'title_en' => 'Close the warehouse', 'slug' => 'close-warehouse', 'topic' => 'boxes', 'apps' => ['warehouse', 'scan'],
            'summary_en' => 'What to check before you lock up.',
            'steps' => [['title_en' => 'Count the floor', 'text_en' => 'Check the Inventories number.', 'title_tl' => '', 'text_tl' => '']],
        ])
        ->call('create')
        ->assertHasNoFormErrors();

    expect(Help::guides('warehouse')->pluck('slug'))->toContain('close-warehouse');
    expect(Help::guides('admin')->pluck('slug'))->not->toContain('close-warehouse');
});

it('keeps the guide editor for admins only', function () {
    $this->get('/help-guides')->assertOk()->assertSee('Unload a container');

    $this->flushSession();
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    $this->get('/help-guides')->assertStatus(403);
});
