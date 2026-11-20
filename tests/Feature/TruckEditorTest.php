<?php

use App\Filament\Pages\TruckEditor;
use App\Models\RentalCompany;
use App\Models\Truck;
use App\Models\User;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->own = Truck::where('logistichub_id', $this->admin->logistichub_id)->firstOrFail();
});

it('adds a rental truck from the new form', function () {
    $co = RentalCompany::create(['name' => 'JRS Trucking']);
    $this->get(TruckEditor::getUrl())->assertOk()->assertSee('Add a truck')->assertSee('Who owns it')->assertSee('How it shows on the Trucks page');

    Livewire::test(TruckEditor::class)
        ->set('data.plate_no', 'rnt 9001')->set('data.registration_no', 'REG-9001')
        ->call('pickKind', '10w')->assertSet('data.capacity', 80)
        ->call('stepSpace', -5)->assertSet('data.capacity', 75)
        ->call('setOwnership', 'rental')->set('data.rental_company_id', $co->id)
        ->call('setRateWay', 'day')->set('data.rate', '4800')->set('data.rental_driver', 'Boy Santos')
        ->set('data.date_registered', today()->subYear()->format('Y-m-d'))->set('data.date_expired', today()->addYear()->format('Y-m-d'))
        ->assertSee('about 75 boxes')->assertSee('₱4,800 a day')
        ->call('save')->assertHasNoErrors()->assertRedirect();

    $t = Truck::where('plate_no', 'RNT 9001')->firstOrFail();
    expect($t->category)->toBe('10-wheeler')->and($t->capacity)->toBe(75)->and($t->ownership)->toBe('rental')
        ->and((float) $t->rate_day)->toBe(4800.0)->and($t->rate_trip)->toBeNull()->and($t->rental_driver)->toBe('Boy Santos')
        ->and($t->logistichub_id)->toBe($this->admin->logistichub_id)->and($t->user_id)->toBe($this->admin->id);
});

it('edits a truck, keeps its own kind name, and checks the plate and the company', function () {
    $this->own->update(['category' => 'Six Wheeler']);
    $other = $this->own->replicate();
    $other->forceFill(['plate_no' => 'ZZZ 1'])->save();

    Livewire::test(TruckEditor::class, ['truckId' => $this->own->id])
        ->assertSet('data.kind', '6w')
        ->set('data.plate_no', $other->plate_no)->call('setOwnership', 'rental')->set('data.rental_company_id', null)
        ->call('save')->assertHasErrors(['data.plate_no', 'data.rental_company_id'])
        ->set('data.plate_no', 'NEW 222')->call('setOwnership', 'own')->call('toggleActive')
        ->call('save')->assertHasNoErrors();

    $t = $this->own->fresh();
    expect($t->plate_no)->toBe('NEW 222')->and($t->category)->toBe('Six Wheeler')->and($t->is_active)->toBeFalse()->and($t->ownership)->toBe('own');
});

it('links Edit and Add truck to the new form', function () {
    $this->get(\App\Filament\Pages\TruckProfile::getUrl(['truck' => $this->own->id]))->assertOk()->assertSee(TruckEditor::getUrl(['truck' => $this->own->id]), false);
    $this->get(\App\Filament\Pages\Fleet::getUrl())->assertOk()->assertSee(TruckEditor::getUrl(), false);
    $this->get(\App\Filament\Pages\RentalTrucks::getUrl())->assertOk();
});
