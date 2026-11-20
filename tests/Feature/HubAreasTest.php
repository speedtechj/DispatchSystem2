<?php

use App\Filament\Company\Pages\MyArea;
use App\Filament\Company\Pages\PlanTrips as HubPlanTrips;
use App\Filament\Pages\HubAreas as HubAreasSettings;
use App\Filament\Pages\HubSetup;
use App\Filament\Pages\PlanTrips;
use App\Models\Deliverylog;
use App\Models\Hubs\HubArea;
use App\Models\Hubs\HubAreaRequest;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Support\Hubs\HubAreas;
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
    Invoice::query()->update(['is_assigned' => true]);
    Truck::query()->update(['is_assigned' => false, 'capacity' => 20]);
    $mk = fn (string $name, string $code, string $prov) => tap(new Logistichub, fn ($h) => $h->forceFill(['hub_name' => $name, 'hub_code' => $code, 'is_company' => true, 'is_active' => true, 'trip_counter' => 0, 'province' => $prov, 'user_id' => $this->admin->id])->save());
    $this->baguio = $mk('Baguio Hub', 'BGO', 'Benguet');
    $this->vigan = $mk('Vigan Hub', 'VGN', 'Ilocos Sur');
    $base = Invoice::firstOrFail();
    $this->box = function (string $prov, string $city, string $brgy, string $no, int $days = 2) use ($base) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => $no, 'receiver_province' => $prov, 'receiver_city' => $city, 'receiver_barangay' => $brgy, 'is_verified' => true, 'is_assigned' => false,
            'is_delivered' => false, 'verified_at' => now()->subDays($days), 'receiver_mobile_no' => '09'.random_int(100000000, 999999999), 'set_key' => null, 'is_priority' => false])->save();

        return $i;
    };
});

it('finds the hub of a box: barangay, then city, then province; one owner per place', function () {
    HubAreas::add($this->baguio->id, 'Benguet', null, null, $this->admin);
    HubAreas::add($this->baguio->id, 'La Union', 'San Fernando', null, $this->admin);
    HubAreas::add($this->vigan->id, 'La Union', 'San Fernando', 'Sevilla', $this->admin);
    $conflict = HubAreas::add($this->vigan->id, 'benguet', null, null, $this->admin);
    expect($conflict['ok'])->toBeFalse()->and($conflict['conflict']->logistichub_id)->toBe($this->baguio->id);

    expect(HubAreas::hubOf(($this->box)('Benguet', 'La Trinidad', 'Pico', 'B1')))->toBe($this->baguio->id)
        ->and(HubAreas::hubOf(($this->box)('La Union', 'San Fernando City', 'Brgy. Sevilla', 'B2')))->toBe($this->vigan->id)
        ->and(HubAreas::hubOf(($this->box)('La Union', 'San Fernando', 'Poro', 'B3')))->toBe($this->baguio->id)
        ->and(HubAreas::hubOf(($this->box)('La Union', 'Agoo', 'X', 'B4')))->toBeNull()
        ->and(HubAreas::hubOf(($this->box)('Pampanga', 'San Fernando', 'Sevilla', 'B5')))->toBeNull(); // same city name, other province

    // a switched-off hub has no area: its boxes go direct
    $this->vigan->forceFill(['is_active' => false])->save();
    expect(HubAreas::hubOf(Invoice::where('invoice', 'B2')->first()))->toBe($this->baguio->id)
        ->and(HubAreas::orphans()->first()['hub'])->toBe('Vigan Hub');
});

it('lets the admin move a place and a hub ask for one; the office approves', function () {
    HubAreas::add($this->baguio->id, 'La Union', 'San Fernando', null, $this->admin);
    Livewire::test(HubAreasSettings::class)->assertSee('Which hub delivers each place')->assertSee('Baguio Hub')
        ->set('add.'.$this->vigan->id.'.province', 'La Union')->set('add.'.$this->vigan->id.'.city', 'San Fernando')
        ->call('addPlace', $this->vigan->id)->assertSee('already belongs to Baguio Hub')->call('moveIt');
    expect(HubAreas::owner('La Union', 'San Fernando')->logistichub_id)->toBe($this->vigan->id);

    $hubUser = User::factory()->create(['logistichub_id' => $this->baguio->id, 'is_admin' => false, 'first_name' => 'Liza']);
    $this->actingAs($hubUser);
    Filament::setCurrentPanel(Filament::getPanel('company'));
    Livewire::test(MyArea::class)->assertSee('My delivery area')
        ->set('ask.province', 'La Union')->set('ask.city', 'San Fernando')->set('ask.barangay', 'Catbangen')->set('ask.reason', '20 minutes from our hub')
        ->call('send')->assertSee('Sent: Brgy. Catbangen, San Fernando, La Union');
    $r = HubAreaRequest::firstOrFail();
    expect($r->status)->toBe('pending')->and(HubAreas::pendingCount())->toBe(1);

    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(HubAreasSettings::class)->assertSee('Baguio Hub asks for Brgy. Catbangen')->call('decide', $r->id, true);
    expect(HubAreas::hubOf(($this->box)('La Union', 'San Fernando', 'Catbangen', 'C1')))->toBe($this->baguio->id)
        ->and($r->fresh()->status)->toBe('approved');
});

it('suggests the area of a new hub: its province and the free provinces of its region', function () {
    HubAreas::add($this->vigan->id, 'Ilocos Sur', null, null, $this->admin);
    HubAreas::add($this->baguio->id, 'Pangasinan', 'Rosales', null, $this->admin);
    Livewire::test(HubSetup::class)->assertSee('Add a hub and its area')
        ->set('form.name', 'Dagupan Hub')->set('form.code', 'dgp')->set('form.province', 'Pangasinan')->set('form.city', 'Dagupan City')
        ->call('save')->assertSee('Suggested area')->assertSee('Whole province · the hub is here')->assertSee('Closer than its hub now')
        ->call('toggleLeave', 1) // leave Ilocos Norte or La Union out
        ->call('approve');
    $dgp = Logistichub::where('hub_code', 'DGP')->firstOrFail();
    expect(HubAreas::owner('Pangasinan')->logistichub_id)->toBe($dgp->id)
        ->and(HubAreas::owner('Ilocos Sur')->logistichub_id)->toBe($this->vigan->id) // never taken from another hub
        ->and(HubAreas::owner('Pangasinan', 'Rosales')->logistichub_id)->toBe($this->baguio->id); // "closer" moves only when you say so
});

it('plans one trip per hub, more when the boxes do not fit one truck, and keeps hub boxes off direct trips', function () {
    HubAreas::add($this->baguio->id, 'Benguet', null, null, $this->admin);
    foreach (range(1, 14) as $n) {
        ($this->box)('Benguet', 'La Trinidad', 'Pico', 'LT'.$n, 4);
    }
    foreach (range(1, 12) as $n) {
        ($this->box)('Benguet', 'Itogon', 'X', 'IT'.$n, 2);
    }
    foreach (range(1, 6) as $n) {
        ($this->box)('Tarlac', 'Capas', 'X', 'CAP'.$n, 3);
    }
    $c = new CityTrips($this->admin);
    expect($c->places()->pluck('city')->all())->toBe(['Capas']);
    $hubs = $c->planHubs();
    expect($hubs)->toHaveCount(1)->and($hubs[0]['name'])->toBe('Baguio Hub')->and($hubs[0]['boxes'])->toBe(26)
        ->and($hubs[0]['trips'])->toHaveCount(2)
        ->and(collect($hubs[0]['trips'][0]['cities'])->pluck('city')->all())->toBe(['La Trinidad']);

    $page = Livewire::test(PlanTrips::class)->assertSee('To hubs')->call('setTab', 'hubs')->assertSee('Baguio Hub')->assertSee('Suggested for today')
        ->call('makeHub', $this->baguio->id)->assertSee('to Baguio Hub');
    $trips = Deliverylog::where('assigned_to', $this->baguio->id)->get();
    expect($trips)->not->toBeEmpty()
        ->and(TripCity::whereIn('deliverylog_id', $trips->pluck('id'))->pluck('hub_id')->unique()->all())->toBe([$this->baguio->id]);

    // scanning: a Baguio box joins the Baguio trip; a Capas box does not, and a Baguio box does not join a direct trip
    $hubTrip = $trips->first();
    [$joined] = CityTrips::join($hubTrip, 'LT1');
    expect($joined?->logistichub_id)->toBe($this->baguio->id);
    expect(CityTrips::join($hubTrip, 'CAP1')[1])->toBe('hub:0');
    $page->call('setTab', 'direct')->call('create');
    $direct = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Capas'))->firstOrFail();
    expect(CityTrips::join($direct, 'LT2')[1])->toBe('hub:'.$this->baguio->id)
        ->and(CityTrips::join($direct, 'LT2', false, true)[0])->not->toBeNull(); // with a reason: delivered direct
});

it('delivers a hub city direct instead, with a reason saved in Overrides', function () {
    HubAreas::add($this->baguio->id, 'Benguet', null, null, $this->admin);
    foreach (range(1, 4) as $n) {
        ($this->box)('Benguet', 'Itogon', 'X', 'IT'.$n, 5);
    }
    Livewire::test(PlanTrips::class)->call('setTab', 'hubs')->call('askDirectCity', $this->baguio->id, 'benguet|itogon')->assertSee('Why?')
        ->call('directWith', 'Priority box')->call('setTab', 'direct')->assertSee('Itogon')->call('create');
    $trip = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Itogon'))->firstOrFail();
    expect(TripCity::where('deliverylog_id', $trip->id)->pluck('hub_id')->all())->toContain($this->baguio->id)
        ->and(CityTrips::join($trip, 'IT1')[0])->not->toBeNull()
        ->and(\App\Models\TripOverride::where('rule', 'direct_hub')->value('reason'))->toBe('Priority box');
});

it('lets a partner hub plan its own trips with its trucks and trip numbers', function () {
    HubAreas::add($this->baguio->id, 'Benguet', null, null, $this->admin);
    HubAreas::add($this->vigan->id, 'Ilocos Sur', null, null, $this->admin);
    $truck = Truck::firstOrFail()->replicate();
    $truck->forceFill(['plate_no' => 'BGO 001', 'logistichub_id' => $this->baguio->id, 'is_active' => true, 'is_assigned' => false, 'capacity' => 5])->save();
    $toHub = Deliverylog::create(['trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $this->baguio->id, 'user_id' => $this->admin->id]);
    foreach (['Benguet|La Trinidad|LT1', 'Benguet|La Trinidad|LT2', 'Benguet|Itogon|IT1', 'Ilocos Sur|Vigan|VG1'] as $row) {
        [$p, $c, $no] = explode('|', $row);
        $inv = ($this->box)($p, $c, 'X', $no);
        Tripinvoice::create(['deliverylog_id' => $toHub->id, 'logistichub_id' => $this->baguio->id, 'invoice' => $no, 'invoice_id' => $inv->id, 'is_loaded' => true]);
        $inv->update(['is_assigned' => true]);
    }
    $hubUser = User::factory()->create(['logistichub_id' => $this->baguio->id, 'is_admin' => false]);
    $this->actingAs($hubUser);
    Filament::setCurrentPanel(Filament::getPanel('company'));
    Livewire::test(HubPlanTrips::class)->assertSee('Arrived, by city')->assertSee('La Trinidad')->assertDontSee('To hubs')
        ->assertSee('1 box here belongs to another hub')->call('create');
    $own = Deliverylog::where('logistichub_id', $this->baguio->id)->firstOrFail();
    expect($own->trip_number)->toStartWith('BGO')->and($own->truck_id)->toBe($truck->id)
        ->and(Tripinvoice::where('deliveryloghub_id', $own->id)->count())->toBe(3)
        ->and(Tripinvoice::where('invoice', 'VG1')->value('deliveryloghub_id'))->toBeNull();
});

it('follows the SMS switches: hub texts have their own switch, one trip can skip the text', function () {
    expect(\App\Support\Sms\SmsSettings::KINDS)->toHaveKey('out_for_delivery_hub');
    $trip = Deliverylog::create(['trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $this->admin->logistichub_id, 'user_id' => $this->admin->id, 'no_sms' => true]);
    expect(\App\Support\Sms\SmsEvents::outForDelivery($trip))->toBe(0);
    \App\Models\AppSetting::put('sms.on.out_for_delivery', '0');
    ($this->box)('Tarlac', 'Capas', 'X', 'CAP1', 3);
    Livewire::test(PlanTrips::class)->assertSee('No SMS (off in');
    // the old AI trip helper is out of the menu
    expect(\App\Filament\Pages\Ai\AiTrips::shouldRegisterNavigation())->toBeFalse()
        ->and(\App\Support\Ai\AiFeatures::ALL['trips'][0])->toBe('Trip helper');
});
