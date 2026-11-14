<?php

use App\Filament\Delivery\Pages\Dashboard as DriverDashboard;
use App\Filament\Delivery\Pages\Fuel as DriverFuel;
use App\Filament\Pages\Fuel as AdminFuel;
use App\Filament\Pages\FuelSettings;
use App\Filament\Pages\TripFuel as AdminTripFuel;
use App\Filament\Warehouse\Pages\Fuel as WarehouseFuel;
use App\Models\Deliverylog;
use App\Models\Fuel\FuelCash;
use App\Models\Fuel\FuelFill;
use App\Models\Fuel\FuelStatementLine;
use App\Models\Logistichub;
use App\Models\Maps\TripRoute;
use App\Models\Tracking\TruckPosition;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Support\Fuel\Fuel;
use App\Support\Fuel\FuelReader;
use App\Support\Fuel\FuelReport;
use App\Support\Fuel\FuelStatements;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->hub = $this->driver->logistichub_id;
    Deliverylog::query()->update(['is_active' => false]);
    $this->truck = Truck::create(['plate_no' => 'FUE 123', 'logistichub_id' => $this->hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 40, 'category' => 'Truck', 'description' => '6-wheeler', 'registration_no' => 'RF', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear(), 'fuel_type' => 'diesel', 'tank_liters' => 100, 'fuel_card_last4' => '4321']);
    Truckcrew::create(['truck_id' => $this->truck->id, 'crew' => $this->driver->id, 'user_id' => $this->admin->id]);
    $this->trip = Deliverylog::create(['truck_id' => $this->truck->id, 'logistichub_id' => $this->hub, 'assigned_to' => $this->hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
});

function fill(array $over = []): FuelFill
{
    $t = test();

    return Fuel::save(array_merge(['filled_at' => now()->subHour(), 'station' => 'Petron Imus', 'product' => 'Diesel Max', 'liters' => 40, 'total' => 2400, 'vat' => 257.14, 'paid_with' => 'card'], $over), $t->truck, $t->driver, $t->trip);
}

it('knows diesel from gasoline by the product name', function () {
    expect(Fuel::typeOf('Diesel Max'))->toBe('diesel')
        ->and(Fuel::typeOf('V-Power Diesel'))->toBe('diesel')
        ->and(Fuel::typeOf('Shell V-Power'))->toBe('gasoline')
        ->and(Fuel::typeOf('XCS'))->toBe('gasoline')
        ->and(Fuel::typeOf('Petron Turbo Diesel'))->toBe('diesel')
        ->and(Fuel::typeOf('Milk tea'))->toBeNull();
});

it('works out price per liter, km per liter and VAT when a fill is saved', function () {
    $a = fill(['odometer' => 10000, 'filled_at' => now()->subDays(2)]);
    expect($a->price_per_liter)->toBe(60.0)->and($a->vatable)->toBe(2142.86)->and($a->km_since)->toBeNull();
    $b = fill(['odometer' => 10300, 'liters' => 50, 'total' => 3000]);
    expect($b->km_since)->toBe(300)->and($b->km_per_liter)->toBe(6.0);
});

it('checks the company TIN only for ₱1,000 and up', function () {
    Fuel::put('company_tin', '123-456-789-000');
    expect(Fuel::buyerTinOk('123456789000', 2400))->toBeTrue()
        ->and(Fuel::buyerTinOk(null, 2400))->toBeFalse()
        ->and(Fuel::buyerTinOk(null, 800))->toBeNull();
});

it('checks the phone against the truck GPS', function () {
    TruckPosition::insert(['truck_id' => $this->truck->id, 'deliverylog_id' => $this->trip->id, 'lat' => 14.40, 'lng' => 120.94, 'speed' => 0, 'source' => 'app', 'recorded_at' => now()->subMinutes(62)]);
    $near = fill(['lat' => 14.401, 'lng' => 120.941]);
    $far = fill(['lat' => 14.60, 'lng' => 121.00, 'filled_at' => now()->subMinutes(58)]);
    expect($near->gps_ok)->toBeTrue()->and($far->gps_ok)->toBeFalse()->and($far->gps_distance_m)->toBeGreaterThan(5000);
});

it('takes this week\'s price from the receipts, or the office price', function () {
    fill(['liters' => 40, 'total' => 2400]);
    fill(['liters' => 10, 'total' => 620]);
    fill(['liters' => 10, 'total' => 610]);
    expect(Fuel::price('diesel')['price'])->toBe(61.0)->and(Fuel::price('gasoline')['price'])->toBeNull();
    Fuel::put('price.gasoline', ['week' => Fuel::weekStart()->toDateString(), 'price' => 66.5]);
    expect(Fuel::price('gasoline'))->toMatchArray(['price' => 66.5, 'from' => 'set by the office']);
    expect(Fuel::weekStart(\Illuminate\Support\Carbon::parse('2026-11-16'))->toDateString())->toBe('2026-11-10'); // Monday → last Tuesday
});

it('estimates the fuel cash of a trip and settles it', function () {
    TripRoute::updateOrCreate(['deliverylog_id' => $this->trip->id], ['km' => 210]);
    Fuel::put('price.diesel', ['week' => Fuel::weekStart()->toDateString(), 'price' => 60]);
    $e = Fuel::estimate($this->trip);
    expect($e['liters'])->toBe(30.0)->and($e['amount'])->toBe(1980.0)->and($e['short'])->toBeFalse(); // 210 ÷ 7 × 60 + 10%

    Livewire::test(AdminTripFuel::class, ['tripId' => $this->trip->id])->assertSee('₱1,980')->set('give', '2000')->call('giveCash');
    $cash = FuelCash::firstOrFail();
    expect($cash->given)->toBe(2000.0)->and($cash->driver_id)->toBe($this->driver->id);

    fill(['paid_with' => 'cash', 'liters' => 25, 'total' => 1500]);
    expect($cash->fresh()->left())->toBe(500.0);
    Livewire::test(AdminTripFuel::class, ['tripId' => $this->trip->id])->set('returned', '500')->call('settle');
    expect($cash->fresh()->settled_at)->not->toBeNull()->and($cash->fresh()->returned)->toBe(500.0);
});

it('lets the driver add a fill from the Driver app', function () {
    Storage::fake('public');
    $this->actingAs($this->driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    Livewire::test(DriverDashboard::class)->assertSee('Add fuel');

    Livewire::test(DriverFuel::class)
        ->set('upload', UploadedFile::fake()->image('receipt.jpg', 800, 1200))->call('savePhoto')
        ->assertSet('step', 'check')
        ->set('f.fuel_type', 'gasoline')->assertSee('This truck uses')
        ->set('f.fuel_type', 'diesel')->set('f.liters', '45.5')->set('f.total', '2,730.00')->set('f.vat', '292.50')
        ->call('toOdometer')->assertHasNoErrors()->assertSet('step', 'odometer')
        ->set('f.odometer', '55210')->call('save')->assertSet('step', 'done')->assertSee('Fill saved');

    $f = FuelFill::firstOrFail();
    expect($f->truck_id)->toBe($this->truck->id)->and($f->deliverylog_id)->toBe($this->trip->id)->and($f->price_per_liter)->toBe(60.0)
        ->and($f->receipt_path)->toStartWith('fuel/')->and($f->odometer)->toBe(55210);
    Storage::disk('public')->assertExists($f->receipt_path);
});

it('does not let the driver point the photo at another file', function () {
    $this->actingAs($this->driver);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    Livewire::test(DriverFuel::class)->set('receiptPath', 'other/secret.jpg');
})->throws(\Livewire\Features\SupportLockedProperties\CannotUpdateLockedPropertyException::class);

it('flags wrong fuel, over the tank, two fills close together and the TIN missing', function () {
    Fuel::put('company_tin', '123-456-789-000');
    fill(['product' => 'XCS', 'liters' => 20, 'total' => 1300, 'filled_at' => now()->subMinutes(100)]);
    fill(['liters' => 120, 'total' => 7200, 'filled_at' => now()->subMinutes(30)]);
    $alerts = collect((new FuelReport(null))->alerts())->pluck('title')->join(' | ');
    expect($alerts)->toContain('(diesel) · gasoline on the receipt')->toContain('120 L in one fill')->toContain('two fills in 70 minutes')->toContain('without your company TIN');
});

it('imports a fuel card statement and matches it to the fills', function () {
    $a = fill(['filled_at' => now()->subHours(5), 'liters' => 40]);
    fill(['filled_at' => now()->subHours(2), 'liters' => 30, 'total' => 1800]);
    $at = fn ($h) => now()->subHours($h)->format('m/d/Y H:i');
    $csv = tempnam(sys_get_temp_dir(), 'st');
    file_put_contents($csv, "Petron Fleet Card Statement\nAccount: 0001\n"
        ."Transaction Date,Card Number,Plate No,Station Name,Product,Liters,Amount\n"
        .$at(5).",7000 1234 5678 4321,,Petron Imus,Diesel Max,40.00,\"2,400.00\"\n"
        .$at(2).",7000 1234 5678 4321,,Petron Imus,Diesel Max,36.00,\"2,160.00\"\n"
        .$at(30).",7000 1234 5678 4321,,Petron Bacoor,Diesel Max,50.00,\"3,000.00\"\n"
        .$at(3).",7000 1234 5678 9999,ZZZ 999,Petron Kawit,XCS,10.00,650.00\n");
    $s = FuelStatements::import($csv, 'petron', $this->admin->id, null, 'statement.csv');
    $by = FuelStatementLine::where('fuel_statement_id', $s->id)->orderBy('charged_at')->pluck('status')->all();
    expect($s->lines)->toBe(4)->and($by)->toBe(['no_fill', 'matched', 'no_truck', 'liters_differ'])
        ->and(FuelStatementLine::where('status', 'matched')->value('fuel_fill_id'))->toBe($a->id);
});

it('shows the Fuel page in Admin with every tab, and in Warehouse only its own trucks', function () {
    fill(['station' => 'Petron Imus']);
    $other = Truck::create(['plate_no' => 'OTH 1', 'logistichub_id' => Logistichub::where('id', '!=', $this->hub)->value('id'), 'is_active' => true, 'is_assigned' => false, 'capacity' => 40, 'category' => 'Truck', 'description' => 'x', 'registration_no' => 'RO', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    Fuel::save(['liters' => 10, 'total' => 600, 'station' => 'Shell Far Away'], $other, null, null);

    $this->get(AdminFuel::getUrl())->assertOk()->assertSee('FUE 123')->assertSee('OTH 1');
    foreach (['fills', 'alerts', 'cards', 'prices', 'vat'] as $tab) {
        Livewire::test(AdminFuel::class)->call('setTab', $tab)->assertOk();
    }
    Livewire::test(AdminFuel::class)->call('setTab', 'fills')->assertSee('Shell Far Away');
    $this->get(route('fuel.vat-export', ['month' => now()->format('Y-m'), 'panel' => 'admin']))->assertOk()->assertHeader('content-type', 'text/csv; charset=UTF-8');

    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->actingAs($wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    $this->get(WarehouseFuel::getUrl())->assertOk()->assertSee('FUE 123')->assertDontSee('OTH 1');
    Livewire::test(WarehouseFuel::class)->call('setTab', 'fills')->assertSee('Petron Imus')->assertDontSee('Shell Far Away')->call('savePrices')->assertForbidden();
    $csv = $this->get(route('fuel.vat-export', ['panel' => 'warehouse']))->streamedContent();
    expect($csv)->toContain('Petron Imus')->not->toContain('Shell Far Away');
});

it('saves the fuel settings for each truck', function () {
    $this->get(FuelSettings::getUrl())->assertOk()->assertSee('FUE 123');
    Livewire::test(FuelSettings::class)->set('values.company_tin', '123-456-789-000')->set("trucks.{$this->truck->id}.fuel_type", 'gasoline')
        ->set("trucks.{$this->truck->id}.fuel_card_last4", '12')->call('save')->assertHasErrors(["trucks.{$this->truck->id}.fuel_card_last4"])
        ->set("trucks.{$this->truck->id}.fuel_card_last4", '1111')->call('save')->assertHasNoErrors();
    expect($this->truck->fresh()->fuel_type)->toBe('gasoline')->and(Fuel::companyTin())->toBe('123-456-789-000');
});

it('checks the receipt numbers add up', function () {
    expect(FuelReader::problems(['liters' => 40, 'price_per_liter' => 60, 'total' => 2400]))->toBe([])
        ->and(FuelReader::problems(['liters' => 40, 'price_per_liter' => 60, 'total' => 2600]))->toHaveCount(1)
        ->and(FuelReader::problems(['total' => 2400, 'vatable' => 2000, 'vat' => 257.14]))->toHaveCount(1);
});
