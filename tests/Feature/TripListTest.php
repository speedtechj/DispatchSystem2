<?php

use App\Filament\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Filament\Tables\TripList;
use App\Models\Deliverylog;
use App\Models\Invoice;
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
    Invoice::query()->update(['is_assigned' => true]);
    Truck::query()->update(['is_assigned' => false, 'capacity' => 20]);
    $base = Invoice::firstOrFail();
    foreach (range(1, 8) as $n) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => 'TAR'.$n, 'receiver_province' => 'Tarlac', 'receiver_city' => 'Capas', 'receiver_barangay' => 'X', 'is_verified' => true, 'is_assigned' => false,
            'is_delivered' => false, 'verified_at' => now()->subDays(4), 'receiver_mobile_no' => '0917'.random_int(1000000, 9999999), 'set_key' => null])->save();
    }
});

it('saves how each trip was made and shows it in the list, with tabs, filters and details', function () {
    $c = new CityTrips($this->admin);
    $c->made = ['ai' => true, 'instruction' => 'Tarlac first, keep one truck free'];
    $made = $c->create($c->plan()['trips'], today());
    $ai = Deliverylog::findOrFail($made[0]['id']);
    expect($ai->made_by)->toBe('ai')->and($ai->made_note)->toBe('Tarlac first, keep one truck free');

    $c2 = new CityTrips($this->admin);
    $trips = $c2->plan()['trips'];
    $trips[0]['changed'] = true;
    $trips[0]['changedNote'] = 'Truck NAB 2210 → AAX 120';
    $c2->made = ['reason' => 'Truck problem'];
    expect(Deliverylog::find($c2->create($trips, today())[0]['id'] ?? 0)?->made_by)->toBeIn(['changed', null]);

    $page = Livewire::test(ListDeliverylogs::class)->assertSee('Delivery trips')->assertSee('✦ AI')->assertSee('✎ By hand')
        ->assertSee('Trip · made by')->assertSee('Going to');
    $page->set('tableFilters.made.v', 'ai')->assertSee($ai->trip_number)->assertDontSee(Deliverylog::where('made_by', null)->value('trip_number') ?? 'zzz');
    $page->assertTableActionExists('details');
    $html = view('filament.trips.list.details', ['trip' => $ai])->render();
    expect($html)->toContain('How this trip was made')->toContain('Plan trips with the AI: “Tarlac first, keep one truck free”');
    // board 47: every city and municipality as a bullet list, no box counts
    $names = TripList::cityNames($ai);
    expect($names)->not->toBeEmpty()->and($html)->toContain('Cities and municipalities')->toContain('<li>'.e($names[0]).'</li>');
    expect(TripList::madeKey(Deliverylog::whereNull('made_by')->firstOrFail()))->toBe('manual');
});
