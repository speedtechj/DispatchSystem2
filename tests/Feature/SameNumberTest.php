<?php

use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Pages\Scanload;
use App\Filament\Resources\Searchinvs\Pages\ListSearchinvs;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Boxes\SameNumber;
use App\Support\InvoiceLookup;
use App\Support\Trips\Picking;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function sameAs(string $panel, string $email): void
{
    Filament::setCurrentPanel(Filament::getPanel($panel));
    test()->actingAs(User::where('email', $email)->firstOrFail());
}

/** Board 57: one invoice number on two boxes (two sender companies number their own boxes). */
beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->trip = Deliverylog::firstOrFail();
    $this->a = Tripinvoice::with('invdata')->where('deliverylog_id', $this->trip->id)->where('is_delivered', false)->where('is_loaded', false)->firstOrFail();
    $c2 = Container::firstOrFail()->replicate();
    $c2->forceFill(['container_no' => 'SAME0000002', 'batch_no' => '777'])->save();
    $twin = $this->a->invdata->replicate();
    $twin->forceFill(['container_id' => $c2->id, 'receiver_name' => 'DESIREE SOTELO', 'sender_name' => 'Mark Sotelo', 'receiver_city' => 'GAPAN', 'receiver_province' => 'NUEVA ECIJA', 'receiver_mobile_no' => '09990001234', 'set_key' => null, 'is_delivered' => false])->save();
    $this->twin = $twin;
    $this->b = Tripinvoice::create(['invoice' => $this->a->invoice, 'invoice_id' => $twin->id, 'deliverylog_id' => $this->trip->id,
        'logistichub_id' => $this->a->logistichub_id, 'is_loaded' => false, 'is_delivered' => false]);
    $this->code = $this->a->invoice;
});

it('counts the open boxes, leaves delivered ones out of look-ups', function () {
    expect(SameNumber::count($this->code))->toBe(2)
        ->and(SameNumber::active($this->code))->toHaveCount(2)
        ->and(SameNumber::only($this->code))->toBeNull()
        ->and(SameNumber::suffix(1, 2))->toBe(' · 1 of 2 with this number');

    $this->a->invdata->forceFill(['is_delivered' => true])->save();
    expect(SameNumber::only($this->code)?->id)->toBe($this->twin->id)
        ->and(SameNumber::choice($this->twin))->toMatchArray(['name' => 'DESIREE SOTELO', 'place' => 'Gapan, Nueva Ecija', 'sender' => 'Mark Sotelo']);

    $this->a->forceFill(['is_delivered' => true])->save();
    expect(InvoiceLookup::find($this->code)?->id)->toBe($this->b->id);
});

it('loads both boxes with one number: 1 of 2, 2 of 2, then already loaded both', function () {
    sameAs('admin', 'admin@example.com');
    $page = Livewire::test(Scanload::class)->set('data.deliverylog_id', $this->trip->id);

    $page->call('scan', $this->code)->assertSet('lastStatus', 'success')->assertSee('1 of 2 with this number');
    $page->call('scan', $this->code)->assertSet('lastStatus', 'success')->assertSee('2 of 2 with this number');
    $page->call('scan', $this->code)->assertSet('lastStatus', 'warning')->assertSee('all 2 boxes with number');

    expect($this->a->fresh()->is_loaded)->toBeTruthy()->and($this->b->fresh()->is_loaded)->toBeTruthy();
});

it('picks both boxes with one number', function () {
    if (! Picking::ready()) {
        $this->markTestSkipped('no picking tables');
    }
    $u = User::where('email', 'warehouse@example.com')->firstOrFail();
    expect(Picking::scan($this->trip, $u, $this->code)['title'])->toBe('Picked · 1 of 2 with this number')
        ->and(Picking::scan($this->trip, $u, $this->code)['title'])->toBe('Picked · 2 of 2 with this number')
        ->and(Picking::scan($this->trip, $u, $this->code)['title'])->toBe('Already picked: all 2 with this number');
});

it('asks the driver Which one? by receiver name, and opens the one picked', function () {
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    $this->actingAs(User::where('email', 'driver@example.com')->firstOrFail());

    $page = Livewire::test(Dashboard::class)->call('go', 'scan')
        ->call('scan', $this->code)
        ->assertSet('sheet', 'which')->assertSee('2 boxes have number '.$this->code)
        ->assertSee('DESIREE SOTELO')->assertSee('from Mark Sotelo')
        ->call('pickBox', $this->b->id)
        ->assertSet('sheet', 'found')->assertSet('boxId', $this->b->id);

    // a box not on the list is ignored
    $page->call('closeSheet')->call('scan', $this->code)->call('pickBox', 999999)->assertSet('sheet', 'which');

    // one delivered: no question
    $this->a->forceFill(['is_delivered' => true])->save();
    Livewire::test(Dashboard::class)->call('go', 'scan')->call('scan', $this->code)->assertSet('sheet', 'found')->assertSet('boxId', $this->b->id);
});

it('shows Container · batch and the shared-number chip in Search Invoices', function () {
    sameAs('admin', 'admin@example.com');
    Livewire::test(ListSearchinvs::class)
        ->assertSee('Container · batch')->assertSee('SAME0000002 · 777')
        ->assertSee('⚠ 2 share this number');
});

it('lists both open boxes in Find a box and in the warehouse Search Invoices', function () {
    sameAs('warehouse', 'warehouse@example.com');
    Livewire::test(\App\Filament\Warehouse\Pages\Sections::class)->set('find', $this->code)
        ->assertSee('2 boxes have number '.$this->code)->assertSee('Desiree Sotelo')->assertSee('from Mark Sotelo');
    Livewire::test(\App\Filament\Warehouse\Resources\Searchinvs\Pages\ListSearchinvs::class)
        ->assertSee('SAME0000002 · 777')->assertSee('⚠ 2 share this number');
});
