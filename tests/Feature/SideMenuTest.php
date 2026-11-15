<?php

use App\Models\Shipping\WrongHubBox;
use App\Models\Invoice;
use App\Models\User;
use App\Support\Navigation\Menu;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;

uses(RefreshDatabase::class);

beforeEach(fn () => $this->seed(DemoSeeder::class));

function menuOf(string $panel, string $email): array
{
    test()->actingAs(User::where('email', $email)->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel($panel));
    app()->forgetScopedInstances();

    return collect(Filament::getPanel($panel)->getNavigation())
        ->mapWithKeys(fn ($g) => [($g->getLabel() ?? '') => collect($g->getItems())->map(fn ($i) => $i->getLabel().($i->getBadge() ? ' ('.$i->getBadge().')' : ''))->values()->all()])
        ->all();
}

it('groups the admin menu by the work, with Settings in small folded groups', function () {
    $m = menuOf('admin', 'admin@example.com');
    expect(array_keys($m))->toContain('Boxes', 'Trips & delivery', 'Sea & partner hubs', 'Money', 'Settings · company & people', 'Help')
        ->and($m['Boxes'])->toContain('Find a box', 'Box issues')
        ->and($m['Settings · places & routes'])->toContain('Logistic hubs')
        ->and($m['Settings · company & people'])->toContain('Account types', 'Job positions')
        ->and(array_keys($m))->not->toContain('Scanning', 'Settings', 'User Management');
    $folded = collect(Menu::groups('admin'))->filter->isCollapsed()->map->getLabel()->values()->all();
    expect($folded)->toContain('Settings · trucks & boxes')->not->toContain('Boxes');
});

it('names the warehouse truck scans by what the truck does', function () {
    $m = menuOf('warehouse', 'warehouse@example.com');
    expect($m['Scan on this computer'])->toBe(['Unload container', 'Load delivery truck', 'Return boxes', 'Load transfer truck', 'Receive transfer truck'])
        ->and($m['Trips'])->toContain('Delivery trips', 'Transfers to other warehouses')
        ->and(array_keys($m))->not->toContain('Hub', 'Invoice Management', 'Truck Management');
});

it('shows the partner hub what comes in first, with a number on wrong-hub boxes', function () {
    $user = User::where('email', 'company@example.com')->firstOrFail();
    WrongHubBox::create(['invoice_id' => Invoice::value('id'), 'logistichub_id' => $user->logistichub_id, 'reason' => 'wrong_hub', 'status' => 'waiting']);
    $m = menuOf('company', 'company@example.com');
    expect(array_key_first(array_filter($m, fn ($k) => $k !== '', ARRAY_FILTER_USE_KEY)))->toBe('Coming in')
        ->and($m['Returns'])->toBe(['Wrong hub & returns (1)'])
        ->and($m['Trucks & people'])->toContain('Crew');
});

it('draws the side menu on the pages', function () {
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail())->get('/')->assertOk()->assertSee('Settings · places &amp; routes', false)->assertSee('Find a box');
});

it('draws the warehouse side menu', function () {
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail())->get('/warehouse')->assertOk()->assertSee('Load delivery truck');
});
