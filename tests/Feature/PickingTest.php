<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Filament\Warehouse\Pages\Picking as WarehousePicking;
use App\Models\Boxes\WhSection;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Support\ScanModes;
use App\Support\Trips\Picking;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->wh = User::with('panelcategory')->where('email', 'warehouse@example.com')->firstOrFail();
    $this->ben = $this->wh->replicate()->forceFill(['email' => 'ben@pick.test', 'first_name' => 'Ben']);
    $this->ben->save();
    $this->carla = $this->wh->replicate()->forceFill(['email' => 'carla@pick.test', 'first_name' => 'Carla']);
    $this->carla->save();
    $hub = (int) $this->wh->logistichub_id;
    $this->sec = WhSection::create(['warehouse_id' => $this->wh->warehouse_id, 'code' => 'C', 'name' => 'Nueva Ecija', 'color' => '#1d6fb8', 'sort' => 1, 'is_active' => true]);
    $this->trip = Deliverylog::create(['trip_number' => 'PK1', 'logistichub_id' => $hub, 'assigned_to' => $hub, 'truck_id' => Truck::where('logistichub_id', $hub)->value('id'),
        'is_active' => true, 'departure_date' => today(), 'trip_day' => today(), 'eta' => today(), 'user_id' => $this->wh->id]);
    $base = Invoice::firstOrFail();
    $this->rows = collect(['PK01' => '09170000001', 'PK02' => '09170000001', 'PK03' => '09170000003', 'PK04' => '09170000004'])->map(function ($phone, $no) use ($base) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => $no, 'receiver_mobile_no' => $phone, 'receiver_name' => 'R '.$phone, 'wh_section_id' => $this->sec->id, 'set_key' => null, 'is_delivered' => false])->save();

        return Tripinvoice::create(['invoice' => $no, 'invoice_id' => $i->id, 'deliverylog_id' => $this->trip->id, 'logistichub_id' => $this->trip->logistichub_id, 'is_loaded' => false, 'is_delivered' => false]);
    });
    $this->other = Deliverylog::create(['trip_number' => 'PK2', 'logistichub_id' => $hub, 'assigned_to' => $hub, 'is_active' => true, 'departure_date' => today(), 'trip_day' => today(), 'eta' => today(), 'user_id' => $this->wh->id]);
    $i = $base->replicate();
    $i->forceFill(['invoice' => 'PK99', 'wh_section_id' => $this->sec->id])->save();
    Tripinvoice::create(['invoice' => 'PK99', 'invoice_id' => $i->id, 'deliverylog_id' => $this->other->id, 'logistichub_id' => $hub, 'is_loaded' => false]);
});

it('adds Pick boxes to the Scan app for the warehouse and partner hubs', function () {
    expect(ScanModes::for($this->wh))->toHaveKey('pick')
        ->and(ScanModes::for(tap($this->wh->replicate()->forceFill(['email' => 'hub@pick.test', 'panelcategory_id' => \App\Models\Panelcategory::where('code', 'co')->value('id')]))->save()->load('panelcategory')))->toHaveKey('pick');
});

it('suggests free pickers, about one for 40 boxes, the truck crew first', function () {
    DB::table('truckcrews')->insert(['truck_id' => $this->trip->truck_id, 'crew' => $this->carla->id, 'user_id' => $this->wh->id]);
    $s = Picking::suggest($this->trip);
    expect($s['ids'])->toBe([$this->carla->id])->and($s['why'])->toContain('4 boxes: 1 picker');

    Picking::assign($this->other, [$this->carla->id], $this->wh);
    expect(Picking::suggest($this->trip)['ids'])->not->toContain($this->carla->id); // busy on PK2
});

it('picks on many phones: combo n of m, already picked, not for this trip, undo, not found', function () {
    Picking::assign($this->trip, [$this->ben->id, $this->carla->id], $this->wh);

    $r = Picking::scan($this->trip, $this->ben, 'PK01');
    expect($r['title'])->toBe('Picked · combo 1 of 2')->and($r['why'])->toContain('PK02 in section C');
    expect(Picking::scan($this->trip, $this->carla, 'PK02')['title'])->toBe('Picked · combo complete (2)');
    expect(Picking::scan($this->trip, $this->carla, 'PK01')['title'])->toBe('Already picked by Ben');
    expect(Picking::scan($this->trip, $this->ben, 'PK01')['title'])->toBe('You already picked this');
    $bad = Picking::scan($this->trip, $this->ben, 'PK99');
    expect($bad['tone'])->toBe('bad')->and($bad['why'])->toContain('PK2')->and($bad['why'])->toContain('section C');

    $row = $this->rows['PK03'];
    Picking::scan($this->trip, $this->ben, 'PK03');
    expect(Picking::undo($this->trip, $row->id, $this->ben))->toBeTrue()
        ->and($row->fresh()->picked_at)->toBeNull();
    Picking::notFound($this->trip, $this->rows['PK04']->id, $this->carla);
    expect(Picking::progress($this->trip))->toBe(['total' => 4, 'picked' => 2, 'missing' => 1])
        ->and(DB::table('pick_logs')->where('deliverylog_id', $this->trip->id)->pluck('what')->all())
        ->toContain('picked', 'undone', 'not_found', 'wrong', 'assigned');
});

it('lets a picker take a trip with no picker in the Scan app, and scan there', function () {
    $this->actingAs($this->ben);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Picking::assign($this->other, [$this->carla->id], $this->wh); // PK2 is Carla's: not shown to Ben

    $lw = Livewire::test(ScanApp::class)->call('open', 'pick')->assertSet('screen', 'pick')
        ->assertSee('Take this trip')->assertSee('PK1')->assertDontSee('PK2');
    $lw->call('takeTrip', $this->trip->id)->assertSet('screen', 'scan')->assertSee('Section C');
    expect(Picking::isPicker($this->trip, $this->ben))->toBeTrue()
        ->and(Picking::take($this->trip, $this->carla))->toBeFalse(); // already taken

    $lw->call('scan', 'PK03')->assertSet('pickResult.title', 'Picked ✓')->assertSee('↶ Undo');
    $lw->call('undoPick', $this->rows['PK03']->id)->assertSet('pickResult.title', '↶ Undone · back on the list');

    // next time: his one trip opens by itself
    Livewire::test(ScanApp::class)->call('open', 'pick')->assertSet('screen', 'scan')->assertSet('choice', $this->trip->id);
});

it('shows the office Picking page with Use suggestion, pickers and status', function () {
    $this->actingAs($this->wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    Livewire::test(WarehousePicking::class)->assertSee('PK1')->assertSee('Give it a picker')->assertSee('✦ Suggested')
        ->call('useSuggestion', $this->trip->id)->assertSee('Waiting for pickers');
    expect(Picking::pickers($this->trip))->toHaveCount(1);

    $p = Picking::pickers($this->trip)->first();
    Picking::scan($this->trip, $p, 'PK01');
    Livewire::test(WarehousePicking::class)->assertSee('Picking')->assertSee('PK01 picked')
        ->call('undo', $this->rows['PK01']->id);
    expect($this->rows['PK01']->fresh()->picked_at)->toBeNull();
});
