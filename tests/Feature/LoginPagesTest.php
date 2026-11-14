<?php

use App\Filament\Auth\WarehouseLogin;
use App\Models\Companyprofile;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(fn () => $this->seed(DemoSeeder::class));

dataset('sign-in pages', [
    'admin' => ['/login', 'ds-auth--admin', 'Admin'],
    'company' => ['/company/login', 'ds-auth--company', 'Partner hub'],
    'warehouse' => ['/warehouse/login', 'ds-auth--warehouse', 'Warehouse sign in'],
    'delivery' => ['/delivery/login', 'ds-auth--delivery', 'Driver app'],
]);

it('shows each panel its own branded sign-in page', function (string $url, string $design, string $label) {
    $this->get($url)
        ->assertOk()
        ->assertSee($design)
        ->assertSee($label)
        ->assertSee(Companyprofile::first()->company_name);
})->with('sign-in pages');

it('falls back to the app name when no company profile exists', function () {
    Companyprofile::query()->delete();

    $this->get('/warehouse/login')->assertOk()->assertSee(config('app.name'));
});

it('signs a warehouse user in through the branded page', function () {
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));

    Livewire::test(WarehouseLogin::class)
        ->fillForm(['email' => 'warehouse@example.com', 'password' => 'wrong'])
        ->call('authenticate')
        ->assertHasFormErrors(['email']);

    Livewire::test(WarehouseLogin::class)
        ->fillForm(['email' => 'warehouse@example.com', 'password' => 'password'])
        ->call('authenticate')
        ->assertRedirect();

    expect(auth()->user()?->email)->toBe('warehouse@example.com');
});
