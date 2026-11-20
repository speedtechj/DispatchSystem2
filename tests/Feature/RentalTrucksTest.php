<?php

use App\Models\Deliverylog;
use App\Models\RentalCompany;
use App\Models\Truck;
use App\Models\User;
use App\Support\Rentals;
use App\Support\TripFlow;
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
    $this->co = RentalCompany::create(['name' => 'JRS Trucking', 'phone' => '0917']);
    $this->rent = $this->own->replicate();
    $this->rent->forceFill(['plate_no' => 'RNT 4410', 'registration_no' => 'RNT', 'is_assigned' => false, 'ownership' => 'rental',
        'rental_company_id' => $this->co->id, 'rate_trip' => 3500, 'rental_driver' => 'Boy Santos'])->save();
});

it('shows a rental truck only on the days it is booked, after the own trucks', function () {
    expect(TripFlow::truckOptions($this->admin->logistichub_id))->not->toHaveKey($this->rent->id);

    Rentals::toggleDay($this->rent, today());
    $opts = TripFlow::truckOptions($this->admin->logistichub_id);
    expect($opts)->toHaveKey($this->rent->id)
        ->and($opts[$this->rent->id])->toContain('rental, ₱3,500 a trip')
        ->and(array_key_last($opts))->toBe($this->rent->id);

    Livewire::test(\App\Filament\Pages\CrewBoard::class)->assertSee('RNT 4410');
    Rentals::toggleDay($this->rent, today());
    Livewire::test(\App\Filament\Pages\CrewBoard::class)->assertDontSee('RNT 4410');
});

it('notes the rental driver and the cost on the trip (per trip, per day once a day, per km)', function () {
    $mk = fn () => Deliverylog::create(['truck_id' => $this->rent->id, 'logistichub_id' => $this->own->logistichub_id, 'assigned_to' => $this->own->logistichub_id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $a = $mk();
    expect($a->rental_driver)->toBe('Boy Santos')->and((float) $a->rental_cost)->toBe(3500.0)->and($a->rental_rate)->toBe('trip');

    $this->rent->update(['rate_trip' => null, 'rate_day' => 4800]);
    $b = $mk();
    expect((float) $b->rental_cost)->toBe(0.0)->and($b->rental_rate)->toBe('day'); // the day is already paid by trip $a

    $this->rent->update(['rate_day' => null, 'rate_km' => 28]);
    $c = $mk();
    expect($c->rental_cost)->toBeNull();
    $c->update(['rental_km' => 100]);
    expect((float) $c->fresh()->rental_cost)->toBe(2800.0);

    $this->get(\App\Filament\Pages\Trip::getUrl(['trip' => $a->id]))->assertOk()->assertSee('Rental cost')->assertSee('Boy Santos')->assertSee('JRS Trucking');
});

it('shows the trucks as cards with filters, and one truck with its tabs and booked days', function () {
    $this->own->update(['date_expired' => today()->addDays(10)]);
    Livewire::test(\App\Filament\Pages\Fleet::class)
        ->assertSee('RNT 4410')->assertSee('Not booked')->assertSee('Registration expires in 10 days')
        ->call('setFilter', 'rental')->assertSee('RNT 4410')->assertDontSee($this->own->plate_no)
        ->set('search', 'zzz')->assertSee('No trucks here');

    Livewire::withQueryParams(['truck' => $this->rent->id])->test(\App\Filament\Pages\TruckProfile::class)
        ->assertSee('RNT 4410')->call('setTab', 'rental')->assertSee('Booked days')->assertSee('₱3,500 a trip')
        ->call('toggleDay', today()->toDateString());
    expect(Rentals::isBooked($this->rent))->toBeTrue();

    Livewire::withQueryParams(['truck' => $this->own->id])->test(\App\Filament\Pages\TruckProfile::class)
        ->call('setTab', 'details')->call('toggleActive');
    expect($this->own->fresh()->is_active)->toBeFalse();
});

it('lists the month of rental trips, downloads it, and adds a rental company', function () {
    Rentals::toggleDay($this->rent, today());
    Deliverylog::create(['truck_id' => $this->rent->id, 'logistichub_id' => $this->own->logistichub_id, 'assigned_to' => $this->own->logistichub_id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);

    Livewire::test(\App\Filament\Pages\RentalTrucks::class)
        ->assertSee('RNT 4410 · JRS Trucking')->assertSee('₱3,500')
        ->call('download')->assertFileDownloaded('rental-trucks-'.today()->format('Y-m').'.csv')
        ->set('newName', 'Mabuhay Haulers')->call('addCompany')->assertSee('Mabuhay Haulers');
    expect(RentalCompany::where('name', 'Mabuhay Haulers')->exists())->toBeTrue();
});
