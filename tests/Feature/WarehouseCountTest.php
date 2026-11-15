<?php

use App\Filament\Pages\CostPerBox;
use App\Filament\Scan\Pages\ScanApp;
use App\Filament\Warehouse\Pages\ComingBack;
use App\Filament\Warehouse\Pages\Sections as WarehouseSectionsView;
use App\Models\Boxes\WhCount;
use App\Models\Boxes\WhSection;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Shipping\WrongHubBox;
use App\Models\User;
use App\Support\Boxes\Sections;
use App\Support\ScanModes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Sections::forget();
    $base = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->user = $base->replicate()->fill(['email' => 'count-wh@example.com']);
    $this->user->save();
    $wh = $this->user->warehouse_id;
    $this->C = WhSection::create(['warehouse_id' => $wh, 'code' => 'C', 'name' => 'Cebu hub', 'kind' => 'area', 'provinces' => ['Cebu']]);
    $this->D = WhSection::create(['warehouse_id' => $wh, 'code' => 'D', 'name' => 'Davao hub', 'kind' => 'area', 'provinces' => ['Davao del Sur']]);
    $tpl = Invoice::firstOrFail();
    $mk = fn ($no, $sec) => tap($tpl->replicate()->fill(['invoice' => $no, 'is_verified' => true, 'is_delivered' => false, 'is_assigned' => false, 'warehouse_id' => $wh, 'wh_section_id' => $sec, 'set_key' => null]))->save();
    $this->a = $mk('CNT-1', $this->C->id);
    $this->b = $mk('CNT-2', $this->C->id);
    $this->c = $mk('CNT-3', $this->D->id);
});

it('counts a section with the Scan app, moves a box in, and lists what is missing', function () {
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    $this->actingAs($this->user);
    expect(array_keys(ScanModes::for($this->user)))->toContain('count');

    Livewire::test(ScanApp::class)->call('open', 'count')->assertSee('Section C')->call('pick', $this->C->id)
        ->call('scan', 'CNT-1')->assertSet('status', 'success')->assertSee('counted in section C')
        ->call('dismiss')->call('scan', 'CNT-3')->assertSee('moved to section C (it was in D)')
        ->call('dismiss')->call('scan', 'CNT-1')->assertSet('status', 'warning')
        ->call('finish')->assertSee('1 missing: CNT-2')->assertSee('1 moved in')
        ->call('closeCount');

    expect(Invoice::where('invoice', 'CNT-3')->value('wh_section_id'))->toBe($this->C->id)
        ->and(WhCount::sole())->found->toBe(2)->missing->toBe(1)->moved_in->toBe(1);
});

it('shows the sections, finds a box and lists boxes coming back in the Warehouse panel', function () {
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    $this->actingAs($this->user);
    Livewire::test(WarehouseSectionsView::class)->assertSee('Cebu hub')->assertSee('Print QR labels')
        ->set('find', 'cnt-2')->assertSee('Section C · Cebu hub');

    $cebu = Logistichub::where('is_company', true)->firstOrFail();
    WrongHubBox::create(['invoice_id' => $this->a->id, 'logistichub_id' => $cebu->id, 'reason' => 'refused', 'status' => 'waiting']);
    WrongHubBox::create(['invoice_id' => $this->b->id, 'logistichub_id' => $cebu->id, 'reason' => 'wrong_hub', 'correct_hub_id' => $cebu->id + 99, 'status' => 'waiting']);
    $this->get(ComingBack::getUrl())->assertOk();
    Livewire::test(ComingBack::class)->assertSee('CNT-1')->assertSee('Back to the warehouse')->assertDontSee('Add a box');
    Livewire::test(ComingBack::class)->call('sendBack', 1)->assertForbidden();
});

it('shows the cost per box for each hub', function () {
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->get(CostPerBox::getUrl())->assertOk()->assertSee('Cost per box')->assertSee('Container vs RoRo');
    $rows = (new \App\Support\CostReport)->rows();
    expect($rows)->toBeInstanceOf(\Illuminate\Support\Collection::class);
});
