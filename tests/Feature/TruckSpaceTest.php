<?php

use App\Filament\Pages\BoxSizeSettings;
use App\Filament\Scan\Pages\ScanApp;
use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\BoxSizes;
use App\Support\TruckSpace;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    (fn () => static::$memo = null)->call(new AppSetting);
    BoxSizes::forget();
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    $mk = fn ($no, $type, $prov = 'Cebu') => Invoice::create(['container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'S', 'receiver_name' => 'R '.$no,
        'receiver_address' => '1', 'receiver_province' => $prov, 'receiver_city' => 'Mandaue City', 'receiver_barangay' => 'Basak', 'receiver_mobile_no' => '0917'.crc32($no),
        'boxtype' => $type, 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1]);
    Invoice::query()->update(['is_verified' => false]);
    $this->boxes = collect([$mk('TS-1', 'Regular'), $mk('TS-2', 'Regular'), $mk('TS-3', 'Jumbo')]);
    $this->waiting = [$mk('TS-4', 'Regular'), $mk('TS-5', 'Jumbo'), $mk('TS-6', 'Regular', 'Bohol')];
    AppSetting::put(BoxSizes::SETTING, '1');
    BoxSizes::sync();
    BoxSizes::setBase(BoxSize::where('name', 'Regular')->firstOrFail());
    BoxSize::where('name', 'Regular')->update(['length_cm' => 50, 'width_cm' => 40, 'height_cm' => 40]);
    BoxSize::where('name', 'Jumbo')->update(['length_cm' => 60, 'width_cm' => 60, 'height_cm' => 60]);
    BoxSizes::forget();
});

it('works out box space from dimensions and truck space from the cargo box', function () {
    $jumbo = BoxSize::where('name', 'Jumbo')->firstOrFail();
    expect(TruckSpace::spaceFromDims($jumbo))->toBe(2.5); // 216000 / 80000 = 2.7 → 2.5

    $truck = Truck::firstOrFail();
    $truck->update(['capacity' => null, 'cargo_length_cm' => 300, 'cargo_width_cm' => 160, 'cargo_height_cm' => 160, 'fill_pct' => null, 'reserve_pct' => 10]);
    expect(TruckSpace::fit($truck))->toBe(81)       // 7.68 m³ × 85% / 0.08 m³
        ->and(TruckSpace::capacity($truck))->toBe(81)
        ->and(TruckSpace::usable($truck))->toBe(72);   // 10% kept free

    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(BoxSizeSettings::class)->assertSee('From the size: 2½')->call('useDims', $jumbo->id)
        ->call('setTruckDim', $truck->id, 'fill_pct', '90')->call('useFit', $truck->id);
    expect((float) $jumbo->fresh()->space)->toBe(2.5)->and($truck->fresh()->capacity)->toBe(86);
});

it('offers boxes to top up the truck when everything is loaded and there is room', function () {
    $truck = Truck::firstOrFail();
    $truck->update(['capacity' => 7]);
    BoxSize::where('name', 'Jumbo')->update(['space' => 2, 'is_set' => true]);
    BoxSizes::forget();
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $this->admin->logistichub_id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    app(TripAssignment::class)->addToDeliveryTrip($trip, $this->boxes);
    foreach (Tripinvoice::where('deliverylog_id', $trip->id)->get() as $r) {
        app(TripAssignment::class)->markLoaded($r);
    }
    $t = TruckSpace::topUp($trip->fresh('truck'));
    expect($t['room'])->toBe(3.0)->and($t['boxes']->pluck('invoice')->all())->toBe(['TS-4', 'TS-5']); // Bohol is another province

    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)->call('open', 'load')->call('pick', $trip->id)->call('finish')
        ->assertSee('Room for about 3 more')->assertSee('TS-4')
        ->call('topUpAdd', $this->waiting[0]->id)->assertSet('screen', 'scan');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->where('invoice', 'TS-4')->exists())->toBeTrue();
});
