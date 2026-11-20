<?php

use App\Filament\Pages\Fleet;
use App\Filament\Pages\TruckDuplicates as DupPage;
use App\Filament\Pages\TruckEditor;
use App\Models\Deliverylog;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Support\TruckDuplicates;
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
    $this->keep = Truck::where('logistichub_id', $this->admin->logistichub_id)->firstOrFail();
    $this->keep->update(['plate_no' => 'NAB 2210', 'truck_picture' => null]);
    $this->copy = $this->keep->replicate();
    $this->copy->forceFill(['plate_no' => 'nab-2210', 'is_assigned' => false, 'truck_picture' => 'truckypictures/x.jpg'])->save();
    $this->trip = Deliverylog::create(['truck_id' => $this->copy->id, 'logistichub_id' => $this->keep->logistichub_id, 'assigned_to' => $this->keep->logistichub_id, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
});

it('formats and compares plates', function () {
    expect(TruckDuplicates::key('nab - 2210'))->toBe('NAB2210')
        ->and(TruckDuplicates::format('nab2210'))->toBe('NAB 2210')
        ->and(TruckDuplicates::format(' rnt-4410 '))->toBe('RNT 4410')
        ->and(TruckDuplicates::existing('Nab2210', $this->keep->id)?->id)->toBe($this->copy->id);
});

it('shows the duplicates card on the Trucks page, and Different trucks hides it', function () {
    $other = Truck::where('id', '!=', $this->keep->id)->where('id', '!=', $this->copy->id)->first();
    $flagged = Livewire::test(Fleet::class)->viewData('flagged');
    expect(array_keys($flagged))->toEqualCanonicalizing([$this->keep->id, $this->copy->id])
        ->and($flagged[$this->keep->id])->toBe('nab-2210');
    if ($other) {
        expect($flagged)->not->toHaveKey($other->id);
    }
    Livewire::test(Fleet::class)->assertSee('1 possible duplicate')->assertSee('Compare &amp; keep one', false)->assertSee('Possible duplicate of')
        ->call('notDuplicates', $this->keep->id.','.$this->copy->id)->assertDontSee('possible duplicate');
});

it('merges the copy into the kept truck, then undoes it', function () {
    Truckcrew::create(['truck_id' => $this->copy->id, 'crew' => $this->admin->id, 'user_id' => $this->admin->id]);
    $page = Livewire::test(DupPage::class, ['ids' => $this->keep->id.','.$this->copy->id])
        ->assertSee('Same truck twice?')->assertSee('Becomes inactive')
        ->call('pick', $this->keep->id)->call('doMerge')->assertSee('Merged into NAB 2210')->assertSee('Undo');

    expect($this->trip->fresh()->truck_id)->toBe($this->keep->id)
        ->and(Truckcrew::where('crew', $this->admin->id)->value('truck_id'))->toBe($this->keep->id)
        ->and($this->copy->fresh()->is_active)->toBeFalse()
        ->and($this->copy->fresh()->Note)->toContain('Merged into NAB 2210')
        ->and($this->keep->fresh()->truck_picture)->toBe('truckypictures/x.jpg')
        ->and(TruckDuplicates::groups(null))->toHaveCount(0);
    Livewire::test(Fleet::class)->assertDontSee('nab-2210');

    $page->call('undo');
    expect($this->trip->fresh()->truck_id)->toBe($this->copy->id)
        ->and($this->copy->fresh()->is_active)->toBeTrue()
        ->and($this->keep->fresh()->truck_picture)->toBeNull()
        ->and(TruckDuplicates::groups(null))->toHaveCount(1);
});

it('stops the same plate at Add truck and offers to switch an inactive one back on', function () {
    Livewire::test(TruckEditor::class)->set('data.plate_no', 'NAB2210')->assertSee('is already a truck')
        ->set('data.registration_no', 'R')->set('data.date_registered', '2025-01-01')->set('data.date_expired', '2027-01-01')
        ->call('save')->assertHasErrors(['data.plate_no']);

    $this->trip->delete();
    $this->copy->delete();
    $this->keep->update(['is_active' => false]);
    Livewire::test(TruckEditor::class)->set('data.plate_no', 'nab 2210')->assertSee('already here, but inactive')
        ->call('reactivate', $this->keep->id)->assertRedirect();
    expect($this->keep->fresh()->is_active)->toBeTrue();

    Livewire::test(TruckEditor::class)->set('data.plate_no', 'ztx901')->assertSee('No truck has this plate yet')->assertSee('ZTX 901');
});
