<?php

use App\Filament\Pages\Overrides;
use App\Filament\Pages\TripRules as TripRulesSettings;
use App\Models\TripOverride;
use App\Models\User;
use App\Support\Trips\TripRules;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
});

it('sets who can bypass each rule and edits the reasons', function () {
    expect(TripRules::level('truck_full'))->toBe('reason');
    Livewire::test(TripRulesSettings::class)
        ->assertSee('Trip rules and who can bypass')->assertSee('Truck full')
        ->call('setLevel', 'truck_full', 'office')
        ->set('newReason', 'Rain')->call('addReason')->assertSee('Rain');
    expect(TripRules::level('truck_full'))->toBe('office')
        ->and(TripRules::need('truck_full', User::factory()->create(['is_admin' => false])))->toBe('office')
        ->and(TripRules::need('truck_full', $this->admin))->toBe('reason')
        ->and(TripRules::reasons())->toContain('Rain');
});

it('lists overrides and lets the office approve a request', function () {
    $crew = User::factory()->create(['is_admin' => false, 'first_name' => 'Ramon']);
    TripRules::record('topup_other', $crew, 'Customer called', ['trip_number' => 'T-1']);
    $ask = TripRules::ask('wrong_hub', $crew, 'Truck problem', ['trip_number' => 'T-2', 'box' => 'S-9']);
    expect(Overrides::getNavigationBadge())->toBe('1');
    Livewire::test(Overrides::class)
        ->assertSee('Waiting for the office')->assertSee('Ramon')->assertSee('Customer called')
        ->call('decide', $ask->id, true)->assertSee('Approved by');
    expect($ask->fresh()->status)->toBe('approved')->and(TripRules::pendingCount())->toBe(0);
});
