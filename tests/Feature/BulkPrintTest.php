<?php

use App\Filament\Pages\PrintSettings;
use App\Filament\Resources\Deliverylogs\Pages\EditDeliverylog;
use App\Filament\Resources\Deliverylogs\RelationManagers\TripinvoicesRelationManager;
use App\Http\Controllers\InvoiceController;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
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
    config(['snappy.pdf.binary' => '/nowhere/wkhtmltopdf', 'snappy.pdf.search' => false]);
});

it('prints up to 15 receipts in one go, and refuses more', function () {
    $ids = Invoice::limit(3)->pluck('id')->join(',');
    // the PDF program is not installed here: the page explains it instead of crashing
    $this->get('/tripinv/print?ids='.$ids)->assertStatus(503)->assertSee('wkhtmltopdf');
    $this->get('/tripinv/print?ids='.implode(',', range(1, 16)))->assertStatus(422);
    $this->get('/tripinv/print')->assertStatus(422);
    auth()->logout();
    $this->get('/tripinv/print?ids='.$ids)->assertRedirect();
});

it('opens the receipts of the ticked boxes from the trip, at most 15', function () {
    $trip = Deliverylog::firstOrFail();
    $boxes = Tripinvoice::where('deliverylog_id', $trip->id)->get();

    Livewire::test(TripinvoicesRelationManager::class, ['ownerRecord' => $trip, 'pageClass' => EditDeliverylog::class])
        ->assertTableBulkActionExists('printSelected')
        ->callTableBulkAction('printSelected', $boxes->take(2))
        ->assertHasNoTableBulkActionErrors();

    // more than 15 selected: a message instead of a print
    foreach (range(1, 16) as $i) {
        $b = $boxes->first()->replicate();
        $inv = Invoice::find($b->invoice_id)->replicate();
        $inv->invoice = 'P'.$i;
        $inv->save();
        $b->forceFill(['invoice_id' => $inv->id, 'invoice' => $inv->invoice])->save();
    }
    Livewire::test(TripinvoicesRelationManager::class, ['ownerRecord' => $trip, 'pageClass' => EditDeliverylog::class])
        ->callTableBulkAction('printSelected', Tripinvoice::where('deliverylog_id', $trip->id)->get())
        ->assertNotified();
});

it('lets Admin change how many receipts one print may hold', function () {
    Livewire::test(PrintSettings::class)->assertSet('bulkLimit', 15)
        ->set('bulkLimit', 500)->call('save')->assertHasErrors('bulkLimit')
        ->set('bulkLimit', 20)->call('save')->assertHasNoErrors();

    expect(InvoiceController::bulkLimit())->toBe(20);
    config(['snappy.pdf.binary' => '/nowhere/wkhtmltopdf', 'snappy.pdf.search' => false]);
    $this->get('/tripinv/print?ids='.implode(',', range(1, 16)))->assertStatus(503); // 16 is fine now (no PDF program here)
    $this->get('/tripinv/print?ids='.implode(',', range(1, 21)))->assertStatus(422);
});
