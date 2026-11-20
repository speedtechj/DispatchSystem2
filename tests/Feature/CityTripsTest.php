<?php

use App\Filament\Pages\PlanTrips;
use App\Filament\Pages\Scanload;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Support\Trips\CityTrips;
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
    // only our sample boxes wait
    Invoice::query()->update(['is_assigned' => true]);
    Truck::query()->update(['is_assigned' => false, 'capacity' => 20]);
    $this->free = Truck::where('logistichub_id', $this->admin->logistichub_id)->where('is_active', true)->orderBy('plate_no')->get();
    $base = Invoice::firstOrFail();
    $this->box = function (string $prov, string $city, int $days, string $no) use ($base) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => $no, 'receiver_province' => $prov, 'receiver_city' => $city, 'receiver_barangay' => 'X', 'is_verified' => true, 'is_assigned' => false,
            'is_delivered' => false, 'verified_at' => now()->subDays($days), 'receiver_mobile_no' => '09'.random_int(100000000, 999999999), 'set_key' => null])->save();

        return $i;
    };
    foreach (range(1, 8) as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 4, 'TAR'.$n);
    }
    foreach (range(1, 6) as $n) {
        ($this->box)('Tarlac', 'Capas', 3, 'CAP'.$n);
    }
    foreach (range(1, 9) as $n) {
        ($this->box)('Bulacan', 'Malolos', 2, 'MAL'.$n);
    }
});

it('plans trips by city: oldest province first, nearby cities fill one truck', function () {
    $plan = (new CityTrips($this->admin))->plan();
    expect($plan['trips'][0]['province'])->toBe('Tarlac')
        ->and(collect($plan['trips'][0]['cities'])->pluck('city')->all())->toBe(['Tarlac City', 'Capas'])
        ->and($plan['trips'][0]['load'])->toBe(14)
        ->and($plan['trips'][0]['truck_id'])->toBe($this->free[0]->id)
        ->and($plan['trips'][1]['province'])->toBe('Bulacan');

    $first = (new CityTrips($this->admin))->plan(['first' => 'Bulacan']);
    expect($first['trips'][0]['province'])->toBe('Bulacan');
});

it('creates trips with numbers now and no boxes; boxes join when scanned onto the truck', function () {
    $page = Livewire::test(PlanTrips::class)->assertSee('Plan trips')->assertSee('Tarlac City')->assertSee('Waiting, by city')->call('create');
    $trip = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->firstOrFail();
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->count())->toBe(0)
        ->and($trip->truck_id)->toBe($this->free[0]->id)
        ->and($this->free[0]->fresh()->is_assigned)->toBeTrue();
    $page->assertSee('created:')->assertSee($trip->trip_number);

    // the planned cities are covered now
    expect(collect((new CityTrips($this->admin))->plan()['trips'])->pluck('province')->all())->not->toContain('Tarlac');

    $load = Livewire::test(Scanload::class)->set('data.deliverylog_id', $trip->id)
        ->call('scan', 'TAR1')->assertSet('lastStatus', 'success');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->where('invoice', 'TAR1')->value('is_loaded'))->toBeTrue()
        ->and(Invoice::where('invoice', 'TAR1')->value('is_assigned'))->toBeTrue();

    // a box of another city: asked first, then added when the office says so
    $load->call('scan', 'MAL1')->assertSet('lastStatus', 'warning')->assertSee('Other city');
    expect(Tripinvoice::where('invoice', 'MAL1')->exists())->toBeFalse();
    $load->call('loadAnyway')->assertSee('Why?')->call('bypassWith', 'Customer called');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->where('invoice', 'MAL1')->value('is_loaded'))->toBeTrue();

    // locked: no more boxes join, and the SMS waits for the lock
    $trip->update(['is_lock' => true]);
    $load->call('scan', 'CAP1')->assertSet('lastStatus', 'danger');
    expect(Tripinvoice::where('invoice', 'CAP1')->exists())->toBeFalse();
});

it('keeps a trip for the next free truck, then Give hands it over', function () {
    Truck::where('id', '!=', $this->free[0]->id)->update(['is_active' => false]);
    $page = Livewire::test(PlanTrips::class)->call('cycleTruck', 0); // free → no truck yet
    expect($page->get('trips')[0]['truck_id'])->toBeNull();
    $page->call('create');
    expect(Deliverylog::whereHas('cities')->count())->toBe(0); // changed the AI plan: a reason first
    $page->assertSee('Why did you change the plan?')->set('planReason', 'Truck problem')->call('create');
    expect(\App\Models\TripOverride::where('rule', 'change_plan')->value('reason'))->toBe('Truck problem');
    $trip = Deliverylog::whereHas('cities')->whereNull('truck_id')->firstOrFail();

    Livewire::test(PlanTrips::class)->assertSee('is free')->assertSee('Give')->call('give', $trip->id, $this->free[0]->id)->assertSee('is on '.$trip->trip_number);
    expect($trip->fresh()->truck_id)->toBe($this->free[0]->id);
});

it('does not text receivers of a city trip before it is locked', function () {
    (new CityTrips($this->admin))->create((new CityTrips($this->admin))->plan()['trips'], today());
    $trip = Deliverylog::whereHas('cities')->firstOrFail();
    Livewire::test(Scanload::class)->set('data.deliverylog_id', $trip->id)->call('scan', 'TAR1');
    expect(\App\Support\Sms\SmsEvents::outForDelivery($trip->fresh()))->toBe(0);
});
