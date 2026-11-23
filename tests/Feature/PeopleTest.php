<?php

use App\Filament\Resources\UserResource\Pages\ListUsers;
use App\Models\Panelcategory;
use App\Models\User;
use App\Models\Workposition;
use App\Support\People\People;
use Database\Seeders\DemoSeeder;
use Filament\Actions\Testing\TestAction;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Hash;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
});

it('lists users with a tab per panel from Settings, nice names and Turned off', function () {
    User::where('email', 'driver@example.com')->update(['first_name' => 'CANDIDO', 'last_name' => 'VISAYA']);
    $page = Livewire::test(ListUsers::class)->assertSuccessful()
        ->assertSee('Candido Visaya')->assertSee('Driver & crew')->assertSee('Turned off')->assertSee('Office');
    // a new panel with people shows as its own tab, with a plain look
    $p = Panelcategory::create(['code' => 'acct', 'description' => 'ACCOUNTING', 'user_id' => $this->admin->id]);
    expect(People::look($p)['label'])->toBe('Accounting')->and(People::look($p)['app'])->toBe('No app yet');
});

it('creates a user in the panel on the right, with positions of the chosen panel only', function () {
    $whse = Panelcategory::where('code', 'whse')->firstOrFail();
    $pos = Workposition::create(['code' => 'CHK', 'position_description' => 'Checker', 'is_crew' => false, 'panelcategory_id' => $whse->id, 'user_id' => $this->admin->id]);
    $other = Workposition::where('panelcategory_id', '!=', $whse->id)->firstOrFail();
    expect(People::positions($whse->id))->toHaveKey($pos->id)->not->toHaveKey($other->id);

    Livewire::test(ListUsers::class)
        ->callAction('create', [
            'first_name' => 'Rosa', 'last_name' => 'Mendoza', 'mobile_number' => '09171112222', 'email' => 'rosa@people.test', 'address' => 'Imus, Cavite',
            'panelcategory_id' => $whse->id, 'logistichub_id' => $this->admin->logistichub_id, 'company_id' => $this->admin->company_id,
            'workposition_id' => $pos->id, 'is_active' => true, 'password' => 'Secret-1234',
        ])->assertHasNoActionErrors();
    $u = User::where('email', 'rosa@people.test')->firstOrFail();
    expect($u->workposition_id)->toBe($pos->id)->and(Hash::check('Secret-1234', $u->password))->toBeTrue();
});

it('edits a user: an empty password keeps the old one', function () {
    $u = User::where('email', 'warehouse@example.com')->firstOrFail();
    $old = $u->password;
    Livewire::test(ListUsers::class)
        ->callAction(TestAction::make('edit')->table($u), ['first_name' => 'Wade', 'password' => ''])
        ->assertHasNoActionErrors();
    expect($u->fresh()->first_name)->toBe('Wade')->and($u->fresh()->password)->toBe($old);
});

it('adds a work position from the form (admin), once', function () {
    $drv = Panelcategory::where('code', 'drv')->firstOrFail();
    $a = People::addPosition('Relief  driver', $drv->id, true, $this->admin->id);
    $b = People::addPosition('relief driver', $drv->id, true, $this->admin->id);
    expect($a->id)->toBe($b->id)->and($a->position_description)->toBe('Relief driver')->and($a->is_crew)->toBeTruthy()
        ->and(People::usesDriverApp($a->load('panelcategory')))->toBeTrue();
});

it('shows the Crew page of a warehouse: trucks with crew, add and take off, new and edit crew', function () {
    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    $this->actingAs($wh);
    $drv = Panelcategory::where('code', 'drv')->firstOrFail();
    $driverPos = Workposition::create(['code' => 'RDR', 'position_description' => 'Relief driver', 'is_crew' => true, 'panelcategory_id' => $drv->id, 'user_id' => $wh->id]);
    $helperPos = Workposition::create(['code' => 'POR', 'position_description' => 'Porter', 'is_crew' => true, 'panelcategory_id' => $wh->panelcategory_id, 'user_id' => $wh->id]);
    $truck = \App\Models\Truck::where('logistichub_id', $wh->logistichub_id)->where('is_active', 1)->firstOrFail();

    $page = Livewire::test(\App\Filament\Warehouse\Pages\Crew::class)->assertSuccessful()->assertSee($truck->plate_no)->assertSee('Add crew to this truck');

    // a helper without sign-in: no email needed
    $page->callAction('newCrew', ['first_name' => 'JOY', 'last_name' => 'santos', 'mobile_number' => '09065517720', 'workposition_id' => $helperPos->id, 'truck_id' => $truck->id, 'is_active' => true])
        ->assertHasNoActionErrors();
    $joy = User::where('first_name', 'JOY')->firstOrFail();
    expect($joy->is_crew)->toBeTruthy()->and($joy->logistichub_id)->toBe($wh->logistichub_id)->and($joy->email)->toEndWith('@crew.invalid')
        ->and(\App\Models\Truckcrew::where('truck_id', $truck->id)->where('crew', $joy->id)->exists())->toBeTrue();

    // a position that uses the Driver app needs an email
    $page->callAction('newCrew', ['first_name' => 'Rommel', 'last_name' => 'Dizon', 'mobile_number' => '0917', 'workposition_id' => $driverPos->id, 'is_active' => true])
        ->assertHasActionErrors(['email' => 'required']);
    $page = Livewire::test(\App\Filament\Warehouse\Pages\Crew::class);
    $page->callAction('newCrew', ['first_name' => 'Rommel', 'last_name' => 'Dizon', 'mobile_number' => '0917', 'workposition_id' => $driverPos->id, 'email' => 'rommel@crew.test', 'password' => 'Secret-1234', 'is_active' => true])
        ->assertHasNoActionErrors();
    $rommel = User::where('email', 'rommel@crew.test')->firstOrFail();
    expect($rommel->panelcategory_id)->toBe($drv->id);

    $page->call('setTab', 'people')->assertSee('Joy Santos')->assertSee('Porter')->assertSee('No sign-in');
    $page->call('setTab', 'trucks')->call('togglePick', $truck->id)->assertSee('Rommel Dizon')
        ->call('addToTruck', $truck->id, $rommel->id);
    expect(\App\Models\Truckcrew::where('truck_id', $truck->id)->where('crew', $rommel->id)->exists())->toBeTrue()->and($rommel->fresh()->is_assigned)->toBeTruthy();
    $page->call('removeFromTruck', $truck->id, $rommel->id);
    expect(\App\Models\Truckcrew::where('crew', $rommel->id)->exists())->toBeFalse();

    // edit: turn off takes them off the truck
    $page->callAction(\Filament\Actions\Testing\TestAction::make('editCrew')->arguments(['id' => $joy->id]), ['is_active' => false])->assertHasNoActionErrors();
    expect($joy->fresh()->is_active)->toBeFalsy()->and(\App\Models\Truckcrew::where('crew', $joy->id)->exists())->toBeFalse();

    // another hub's person cannot be edited from here
    expect(fn () => $page->call('addToTruck', $truck->id, $this->admin->id))->not->toThrow(Exception::class);
});

it('opens the Crew page for a partner hub, with its own hub only', function () {
    $co = User::where('email', 'company@example.com')->firstOrFail();
    Filament::setCurrentPanel(Filament::getPanel('company'));
    $this->actingAs($co);
    Livewire::test(\App\Filament\Company\Pages\Crew::class)->assertSuccessful()->call('setTab', 'people')->assertDontSee('Dan ');
    $this->get('/company/crew')->assertOk();
});
