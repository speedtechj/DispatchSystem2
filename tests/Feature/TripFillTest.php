<?php

use App\Filament\Pages\NewBoxes;
use App\Filament\Pages\PlanTrips;
use App\Filament\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Filament\Tables\TripList;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\TripOverride;
use App\Models\Truck;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Trips\CityTrips;
use App\Support\Trips\TripFill;
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
    $base = Invoice::firstOrFail();
    $this->box = function (string $prov, string $city, string $no, ?string $phone = null, ?string $set = null) use ($base) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => $no, 'receiver_province' => $prov, 'receiver_city' => $city, 'receiver_barangay' => 'X', 'is_verified' => true, 'is_assigned' => false,
            'is_delivered' => false, 'is_priority' => false, 'verified_at' => now()->subDays(3), 'receiver_name' => 'R '.$no,
            'receiver_mobile_no' => $phone ?? '09'.random_int(100000000, 999999999), 'set_key' => $set])->save();

        return $i;
    };
    foreach (range(1, 14) as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 'TAR'.$n);
    }
});

it('picks combos whole: urgent first, combos before single boxes, never split', function () {
    $c = fn ($key, $n) => ['key' => $key, 'ids' => range(1, $n), 'n' => $n, 'space' => (float) $n, 'prio' => 0, 'retry' => 0, 'name' => $key, 'barangay' => ''];
    [$picked, $rest] = TripFill::pick(collect([$c('s1', 1), $c('combo', 3), $c('s2', 1), $c('s3', 1)]), 4);
    expect($picked->pluck('key')->all())->toBe(['combo', 's1'])->and($rest->pluck('key')->all())->toBe(['s2', 's3']);
    [$picked] = TripFill::pick(collect([$c('combo', 3), $c('s1', 1), $c('s2', 1)]), 2);
    expect($picked->pluck('key')->all())->toBe(['s1', 's2']); // the combo does not fit: not split

    // a set (same name, phone and city) and one receiver with two names (same phone) are each one combo
    ($this->box)('Pampanga', 'Angeles', 'ANG1', '09170000001');
    ($this->box)('Pampanga', 'Angeles', 'ANG2', '09170000001');
    foreach (['ANG3', 'ANG4'] as $no) {
        ($this->box)('Pampanga', 'Angeles', $no, '09170000002')->update(['receiver_name' => 'Maria Santos']);
    }
    $units = (new CityTrips($this->admin))->waitingUnits()->where('city', 'Angeles');
    $combos = TripFill::combos($units);
    expect($combos)->toHaveCount(2)
        ->and($combos->pluck('kind')->sort()->values()->all())->toBe(['receiver', 'set'])
        ->and($combos->pluck('n')->all())->toBe([2, 2]);
});

it('puts the boxes on the trips at Create (not loaded), up to the truck space', function () {
    Truck::query()->update(['capacity' => 10]);
    ($this->box)('Tarlac', 'Tarlac City', 'COMBO1', '09171111111');
    ($this->box)('Tarlac', 'Tarlac City', 'COMBO2', '09171111111');
    Livewire::test(PlanTrips::class)->call('create');
    $trip = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->firstOrFail();
    $on = Tripinvoice::where('deliverylog_id', $trip->id);
    expect((clone $on)->count())->toBe(10)
        ->and((clone $on)->where('is_loaded', true)->count())->toBe(0)
        ->and((clone $on)->whereIn('invoice', ['COMBO1', 'COMBO2'])->count())->toBe(2) // the combo first, whole
        ->and(TripCity::where('deliverylog_id', $trip->id)->value('planned_boxes'))->toBe(10);
});

it('adds new boxes to a trip with room, then Add anyway with a reason, then a new trip', function () {
    Livewire::test(PlanTrips::class)->call('create');
    $trip = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->firstOrFail(); // 14 of 20
    // a new container: a receiver with 3 boxes and 5 single boxes for Tarlac City
    foreach ([1, 2, 3] as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 'NEWC'.$n, '09172222222');
    }
    foreach (range(1, 5) as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 'NEW'.$n);
    }
    $row = collect(TripFill::newBoxes($this->admin))->firstWhere('city', 'Tarlac City');
    expect($row['kind'])->toBe('open')->and($row['n'])->toBe(8)->and($row['trip']['number'])->toBe($trip->trip_number)
        ->and($row['newN'])->toBe(2); // room 6: the combo of 3 + 3 single boxes

    $page = Livewire::test(NewBoxes::class)->assertSee('New boxes since the trips were made')->assertSee('Add to '.$trip->trip_number)
        ->call('openPick', $row['key'])->assertSee('Combo · receiver')->assertSee('Pick what fits')->assertSee('Add 6 boxes')
        ->call('confirmPick');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->count())->toBe(20)
        ->and(Tripinvoice::where('deliverylog_id', $trip->id)->whereIn('invoice', ['NEWC1', 'NEWC2', 'NEWC3'])->count())->toBe(3);

    // full now: nothing is picked; one box is over the space → Add anyway needs a reason
    $row = collect(TripFill::newBoxes($this->admin))->firstWhere('city', 'Tarlac City');
    expect($row['kind'])->toBe('full')->and($row['n'])->toBe(2);
    $page->call('openPick', $row['key'], true)->assertSee('Pick boxes')->call('toggle', $row['combos'][0]['key'])->assertSee('Add anyway · 1 box')
        ->call('confirmPick');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->count())->toBe(20); // no reason yet
    $page->set('reason', 'It still fits (small box)')->call('confirmPick');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->count())->toBe(21)
        ->and(TripOverride::where('rule', 'truck_full')->where('trip_id', $trip->id)->value('reason'))->toBe('It still fits (small box)');

    // the last box: a new trip, made by the AI
    $row = collect(TripFill::newBoxes($this->admin))->firstWhere('city', 'Tarlac City');
    $page->call('newTrip', $row['key']);
    $new = Deliverylog::whereKeyNot($trip->id)->whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->latest('id')->firstOrFail();
    expect(Tripinvoice::where('deliverylog_id', $new->id)->count())->toBe(1)->and($new->made_by)->toBe('ai')
        ->and(TripFill::newBoxes($this->admin))->toBe([]);
});

it('applies all: boxes to the trip with room, the rest on a new trip, in the warehouse too', function () {
    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->actingAs($wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    Livewire::test(App\Filament\Warehouse\Pages\PlanTrips::class)->call('create');
    foreach (range(1, 8) as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 'APP'.$n);
    }
    Livewire::test(App\Filament\Warehouse\Pages\NewBoxes::class)->assertSee('Apply')->call('applyAll');
    $trips = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->orderBy('id')->get();
    expect($trips)->toHaveCount(2)
        ->and(Tripinvoice::where('deliverylog_id', $trips[0]->id)->count())->toBe(20)
        ->and(Tripinvoice::where('deliverylog_id', $trips[1]->id)->count())->toBe(2)
        ->and(Invoice::where('invoice', 'like', 'APP%')->where('is_assigned', false)->count())->toBe(0);
});

it('puts a box on the partner hub trip at their unload scan: full → new hub trip, or Add anyway', function () {
    $hubUser = User::where('email', 'company@example.com')->firstOrFail();
    $hub = (int) $hubUser->logistichub_id;
    $truck = Truck::query()->firstOrFail();
    $t1 = $truck->replicate();
    $t1->forceFill(['logistichub_id' => $hub, 'plate_no' => 'HUB 1', 'capacity' => 2, 'is_assigned' => true, 'is_active' => true])->save();
    $t2 = $truck->replicate();
    $t2->forceFill(['logistichub_id' => $hub, 'plate_no' => 'HUB 2', 'capacity' => 2, 'is_assigned' => false, 'is_active' => true])->save();
    $hubTrip = Deliverylog::create(['truck_id' => $t1->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $hubUser->id]);
    TripCity::create(['deliverylog_id' => $hubTrip->id, 'province' => 'Benguet', 'city' => 'La Trinidad', 'city_key' => 'la trinidad', 'planned_boxes' => 0]);
    $fromManila = Deliverylog::create(['trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $hub, 'user_id' => $this->admin->id]);
    $row = function (string $no, ?string $phone = null) use ($fromManila, $hub) {
        $i = ($this->box)('Benguet', 'La Trinidad', $no, $phone);

        return Tripinvoice::create(['deliverylog_id' => $fromManila->id, 'logistichub_id' => $hub, 'invoice' => $no, 'invoice_id' => $i->id, 'is_loaded' => true]);
    };
    $a = $row('LT1');
    $b = $row('LT2');
    $c = $row('LT3', '09173333333');
    $d = $row('LT4', '09173333333'); // same receiver as LT3: a combo

    expect(TripFill::placeAtHub($a, $hub, $hubUser)['trip'])->toBe($hubTrip->trip_number)
        ->and(TripFill::placeAtHub($b, $hub, $hubUser)['trip'])->toBe($hubTrip->trip_number);
    $full = TripFill::placeAtHub($c, $hub, $hubUser); // 2 of 2: full → new hub trip with HUB 2
    expect($full['kind'])->toBe('new')->and($full['full']['number'])->toBe($hubTrip->trip_number);
    $new = Deliverylog::findOrFail($full['tripId']);
    expect($new->truck_id)->toBe($t2->id)->and($new->made_by)->toBe('ai');
    // the rest of the combo follows its first box
    expect(TripFill::placeAtHub($d, $hub, $hubUser)['tripId'])->toBe($new->id);

    // Add anyway: the combo moves to the full trip; the empty new trip goes away and its truck is free again
    $res = TripFill::hubAddAnyway($c->fresh(), $hubTrip->id, $hubUser, 'Small boxes');
    expect($res['ok'])->toBeTrue()
        ->and(Tripinvoice::where('deliveryloghub_id', $hubTrip->id)->count())->toBe(4)
        ->and(Deliverylog::find($new->id))->toBeNull()
        ->and((bool) $t2->fresh()->is_assigned)->toBeFalse()
        ->and(TripOverride::where('rule', 'truck_full')->where('trip_id', $hubTrip->id)->exists())->toBeTrue();
});

it('is done by itself when every box is delivered; returns wait until scanned back', function () {
    $truck = Truck::where('logistichub_id', $this->admin->logistichub_id)->firstOrFail();
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $this->admin->logistichub_id,
        'assigned_to' => $this->admin->logistichub_id, 'user_id' => $this->admin->id, 'taken_at' => now()->subHours(3)]);
    $rows = Invoice::whereIn('invoice', ['TAR1', 'TAR2'])->get()->map(fn ($i) => Tripinvoice::create(['deliverylog_id' => $trip->id, 'logistichub_id' => $trip->assigned_to,
        'invoice' => $i->invoice, 'invoice_id' => $i->id, 'is_loaded' => true]));
    $rows[0]->update(['is_delivered' => true]);
    $trip->forceFill(['back_at' => now()])->save();
    $st = TripList::status($trip->fresh());
    expect($st['label'])->toBe('Coming back')->and($st['when'])->toBe('1 return to scan at the office');

    Livewire::test(ListDeliverylogs::class)->assertSee('Still at work')->assertSee('Coming back')
        ->assertCanSeeTableRecords([$trip]);

    // the return is scanned back at the office: the trip is done by itself
    app(TripAssignment::class)->returnToInventory($rows[1]->fresh());
    $trip->refresh();
    expect($trip->is_active)->toBeFalsy()->and($trip->release_reason)->toBe('auto')
        ->and($trip->delivery_date?->toDateString())->toBe(today()->toDateString())
        ->and(TripList::status($trip)['label'])->toBe('Done');
    Livewire::test(ListDeliverylogs::class)->assertCanNotSeeTableRecords([$trip])
        ->set('activeTab', 'done')->assertCanSeeTableRecords([$trip]);
});
