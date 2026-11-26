<?php

use App\Filament\Pages\WarehouseTransfers;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Support\Warehouses\Coverage;
use App\Support\Warehouses\TransferDraft;
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
    $this->cavite = Warehouse::firstOrFail();
    $this->cavite->forceFill(['name' => 'Cavite warehouse'])->save();
    $this->tarlac = Warehouse::create(['name' => 'Tarlac warehouse', 'address' => 'MacArthur Hwy', 'city' => 'Tarlac City', 'province' => 'Tarlac', 'user_id' => $this->admin->id]);
    $this->admin->forceFill(['warehouse_id' => $this->cavite->id])->save();
    foreach (['Tarlac', 'Pangasinan'] as $p) {
        Coverage::add($this->tarlac->id, $p, null, $this->admin, true);
    }
    Invoice::query()->update(['is_assigned' => true]);
    // two free trucks: space 3 and 2
    Truck::query()->update(['is_active' => false]);
    $this->big = Truck::where('logistichub_id', $this->admin->logistichub_id)->firstOrFail();
    $this->big->forceFill(['is_active' => true, 'is_assigned' => false, 'capacity' => 3, 'plate_no' => 'BIG 300'])->save();
    $this->small = $this->big->replicate();
    $this->small->forceFill(['capacity' => 2, 'plate_no' => 'SML 200'])->save();
    $base = Invoice::firstOrFail();
    $this->tx = function (string $prov, string $no, string $phone, array $more = []) use ($base) {
        $i = $base->replicate();
        $i->forceFill(array_merge(['invoice' => $no, 'receiver_province' => $prov, 'receiver_city' => 'Town', 'is_verified' => true, 'is_assigned' => false, 'wh_is_assigned' => false,
            'is_delivered' => false, 'verified_at' => now()->subDays(2), 'warehouse_id' => $this->cavite->id, 'set_key' => null, 'receiver_mobile_no' => $phone, 'is_priority' => false], $more))->save();

        return $i;
    };
});

it('shows the space a transfer needs and warns when the truck is too full', function () {
    ($this->tx)('Pangasinan', 'P1', '09170000001');
    ($this->tx)('Pangasinan', 'P2', '09170000002');
    ($this->tx)('Tarlac', 'T1', '09170000003');
    ($this->tx)('Tarlac', 'T2', '09170000004');
    ($this->tx)('Cavite', 'C1', '09170000005'); // Cavite's own: not a transfer

    Livewire::test(WarehouseTransfers::class)
        ->assertSee('To Tarlac warehouse')->assertSee('Only your warehouses show here')
        ->assertSee('Space 4 of 3')->assertSee('Too full')->assertSee('Create anyway')
        ->call('pickTruck', $this->tarlac->id, $this->small->id)->assertSee('Space 4 of 2');
});

it('drafts trucks by space, never splits a receiver, and creates the trips', function () {
    ($this->tx)('Pangasinan', 'P1', '09170000001', ['is_priority' => true]);
    ($this->tx)('Pangasinan', 'P1B', '09170000001'); // same receiver as P1
    ($this->tx)('Tarlac', 'T1', '09170000003');
    ($this->tx)('Tarlac', 'T2', '09170000004');
    ($this->tx)('Tarlac', 'T3', '09170000006');
    ($this->tx)('Tarlac', 'T4', '09170000007'); // 6 boxes, 5 space of trucks: 1 waits

    $draft = (new TransferDraft($this->admin, $this->cavite->id))->make();
    expect($draft['trips'])->toHaveCount(2)->and($draft['left'])->toBe(1)
        ->and(collect($draft['trips'])->pluck('dest')->unique()->all())->toBe([$this->tarlac->id]);

    $page = Livewire::test(WarehouseTransfers::class)->call('askAi')
        ->assertSee('Tarlac warehouse · 1 of 2')->assertSee('Left for later · 1 box')->assertSee('Nothing is created until you press Create');

    // a smaller truck on the big trip is too full and cannot be created
    $page->call('pickDraftTruck', 0, $this->small->id); // taken by trip 2: ignored
    expect($page->get('draft')['trips'][0]['truck_id'])->toBe($this->big->id);

    $page->call('createAllDraft');
    $trips = Whdeliverylog::where('warehouse_id', $this->tarlac->id)->get();
    expect($trips)->toHaveCount(2);
    $onTrip = fn ($no) => Whtripinvoice::where('invoice_id', Invoice::where('invoice', $no)->value('id'))->value('whdeliverylog_id');
    expect($onTrip('P1'))->not->toBeNull()->toBe($onTrip('P1B')) // never split
        ->and(Whtripinvoice::where('whdeliverylog_id', $trips->firstWhere('truck_id', $this->big->id)->id)->count())->toBeLessThanOrEqual(3)
        ->and(Whtripinvoice::where('whdeliverylog_id', $trips->firstWhere('truck_id', $this->small->id)->id)->count())->toBeLessThanOrEqual(2);
    $page->assertSee('All created');
});

it('blocks a draft trip on a truck that is too small', function () {
    foreach (range(1, 3) as $n) {
        ($this->tx)('Tarlac', 'T'.$n, '0917000001'.$n);
    }
    $before = Whdeliverylog::count();
    $page = Livewire::test(WarehouseTransfers::class)->call('askAi');
    expect($page->get('draft')['trips'])->toHaveCount(1);
    $page->call('pickDraftTruck', 0, $this->small->id)->assertSee('Too full')->assertSee('Pick a bigger truck')
        ->call('createDraft', 0);
    expect(Whdeliverylog::count())->toBe($before);
    $page->call('manual')->assertSee('Manual, like before');
});
