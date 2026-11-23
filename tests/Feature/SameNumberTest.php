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
        ->and(SameNumber::choice($this->twin))->toMatchArray(['name' => 'Desiree Sotelo', 'place' => 'Gapan, Nueva Ecija', 'sender' => 'Mark Sotelo']);

    $this->a->forceFill(['is_delivered' => true])->save();
    expect(InvoiceLookup::find($this->code)?->id)->toBe($this->b->id);
});

it('asks Which one? at Load truck, then counts: 1 of 2 · name, 2 of 2, already loaded all', function () {
    sameAs('admin', 'admin@example.com');
    $page = Livewire::test(Scanload::class)->set('data.deliverylog_id', $this->trip->id);

    $page->call('scan', $this->code)->assertSet('which.code', $this->code)->assertSee('Which one?')->assertSee('Desiree Sotelo')->assertSee('from Mark Sotelo');
    expect($this->b->fresh()->is_loaded)->toBeFalsy();
    $page->call('chooseWhich', 999999)->assertSet('which.code', $this->code); // not on the list: nothing
    $page->call('chooseWhich', $this->twin->id)->assertSet('which', null)->assertSet('lastStatus', 'success')->assertSee('1 of 2 · Desiree Sotelo');
    expect($this->b->fresh()->is_loaded)->toBeTruthy()->and($this->a->fresh()->is_loaded)->toBeFalsy();

    $page->call('scan', $this->code)->assertSet('which', null)->assertSet('lastStatus', 'success')->assertSee('2 of 2');
    $page->call('scan', $this->code)->assertSet('lastStatus', 'warning')->assertSee('all 2 boxes with number');
    expect($this->a->fresh()->is_loaded)->toBeTruthy();
});

it('asks Which one? when picking, then picks the chosen box', function () {
    if (! Picking::ready()) {
        $this->markTestSkipped('no picking tables');
    }
    $u = User::where('email', 'warehouse@example.com')->firstOrFail();
    $r = Picking::scan($this->trip, $u, $this->code);
    expect($r['status'])->toBe('which')->and($r['boxes'])->toHaveCount(2);
    expect(Picking::scan($this->trip, $u, $this->code, $this->twin->id)['title'])->toBe('Picked · 1 of 2 · Desiree Sotelo')
        ->and($this->b->fresh()->picked_at)->not->toBeNull()
        ->and(Picking::scan($this->trip, $u, $this->code)['title'])->toStartWith('Picked · 2 of 2')
        ->and(Picking::scan($this->trip, $u, $this->code)['title'])->toBe('Already picked: all 2 with this number');
});

it('asks the driver Which one? by receiver name, and opens the one picked', function () {
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    $this->actingAs(User::where('email', 'driver@example.com')->firstOrFail());

    $page = Livewire::test(Dashboard::class)->call('go', 'scan')
        ->call('scan', $this->code)
        ->assertSet('sheet', 'which')->assertSee('2 boxes have number '.$this->code)
        ->assertSee('Desiree Sotelo')->assertSee('from Mark Sotelo')
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

it('asks Which one? at Unload when one container has the number twice; only the picked box is verified', function () {
    $c = $this->a->invdata->container;
    $box = Invoice::where('container_id', $c->id)->where('is_verified', false)->firstOrFail();
    $box2 = $box->replicate();
    $box2->forceFill(['receiver_name' => 'ROSA MENDOZA', 'sender_name' => 'Jun dela Cruz', 'receiver_mobile_no' => '09990005555', 'set_key' => null, 'is_verified' => false])->save();
    $c->forceFill(['is_unloaded' => false, 'is_active' => true])->save();
    sameAs('admin', 'admin@example.com');
    $page = Livewire::test(\App\Filament\Pages\Scaninvoice::class)->set('data.container_id', $c->id);

    $page->call('scan', $box->invoice)->assertSet('which.code', $box->invoice)->assertSee('Rosa Mendoza');
    expect($box->fresh()->is_verified)->toBeFalsy()->and($box2->fresh()->is_verified)->toBeFalsy();
    $page->call('chooseWhich', $box2->id)->assertSet('lastStatus', 'success')->assertSee('1 of 2 · Rosa Mendoza');
    expect($box2->fresh()->is_verified)->toBeTruthy()->and($box->fresh()->is_verified)->toBeFalsy();
    $page->call('scan', $box->invoice)->assertSet('which', null)->assertSee('2 of 2');
    expect($box->fresh()->is_verified)->toBeTruthy();
    $page->call('scan', $box->invoice)->assertSet('lastStatus', 'warning')->assertSee('Already unloaded: all 2');

    expect(SameNumber::inContainer($c->id))->toContain($box->invoice.' is on 2 rows')->toContain('Rosa Mendoza');
});

it('shows the Which one? sheet in the Scan app and loads the tapped box', function () {
    sameAs('scan', 'admin@example.com');
    $page = Livewire::test(\App\Filament\Scan\Pages\ScanApp::class)->call('open', 'load')->call('pick', $this->trip->id)
        ->call('scan', $this->code)->assertSet('status', 'which')->assertSee('2 boxes have number '.$this->code)->assertSee('Not this box');
    $page->call('chooseBox', $this->twin->id)->assertSet('which', null)->assertSet('status', 'success')->assertSet('invoiceId', $this->twin->id);
    expect($this->b->fresh()->is_loaded)->toBeTruthy()->and($this->a->fresh()->is_loaded)->toBeFalsy();
    $page->call('scan', $this->code)->assertSet('status', 'success')->assertSet('invoiceId', $this->a->invoice_id);
});

it('asks Which one? on the partner hub Report a problem page', function () {
    $hubTrip = $this->a->logistichub_id;
    sameAs('admin', 'admin@example.com');
    $open = \App\Support\Shipping\WrongHub::candidates((int) $hubTrip, $this->code);
    expect($open)->toHaveCount(2);
    $w = \App\Support\Shipping\WrongHub::add((int) $hubTrip, $this->code, array_key_first(\App\Models\Shipping\WrongHubBox::REASONS), null, $this->twin->id);
    expect($w?->invoice_id)->toBe($this->twin->id);
});
