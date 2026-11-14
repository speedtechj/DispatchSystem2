<?php

use App\Filament\Company\Resources\Trucks\Pages\ListTrucks as HubTrucks;
use App\Filament\Pages\Scaninvoice;
use App\Filament\Resources\ContainerResource;
use App\Filament\Resources\ContainerResource\Pages\ListContainers as AdminContainers;
use App\Filament\Resources\Invoiceissues\InvoiceissueResource;
use App\Filament\Resources\Invoiceissues\Pages\ListInvoiceissues as AdminIssues;
use App\Filament\Resources\Trucks\Pages\ListTrucks as AdminTrucks;
use App\Filament\Shared\Widgets\ModuleBoard;
use App\Filament\Warehouse\Resources\Containers\Pages\ListContainers as WarehouseContainers;
use App\Filament\Warehouse\Resources\Invoiceissues\Pages\ListInvoiceissues as WarehouseIssues;
use App\Filament\Warehouse\Resources\Trucks\Pages\ListTrucks as WarehouseTrucks;
use App\Models\Container;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Truck;
use App\Models\Unmanifested;
use App\Models\User;
use App\Support\Boards\ContainerBoard;
use App\Support\Boards\IssueBoard;
use App\Support\Boards\VehicleBoard;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->container = Container::firstOrFail(); // 12 boxes, 8 scanned in the demo
    $this->truck = Truck::firstOrFail();
    $this->cards = fn ($board) => collect($board->cards())->keyBy('label');
});

function boardPanel(string $panel, string $email): void
{
    Filament::setCurrentPanel(Filament::getPanel($panel));
    test()->actingAs(User::where('email', $email)->firstOrFail());
}

it('records when a box is scanned off the container and shows what is left', function () {
    boardPanel('admin', 'admin@example.com');
    $box = Invoice::where('container_id', $this->container->id)->where('is_verified', false)->firstOrFail();

    Livewire::test(Scaninvoice::class)
        ->set('data.container_id', $this->container->id)
        ->call('scan', $box->invoice)
        ->assertSet('lastStatus', 'success')
        ->assertSee('left')
        ->assertSee('Last scan');

    expect($box->fresh()->verified_at)->not->toBeNull();
});

it('counts containers by state and finds missing boxes once a container is marked unloaded', function () {
    $board = new ContainerBoard(null, fn ($c) => ContainerResource::getUrl('edit', ['record' => $c]));
    expect(($this->cards)($board)['Unloading now']['value'])->toBe('1')
        ->and(($this->cards)($board)['Boxes missing']['value'])->toBe('0');

    $this->container->update(['is_unloaded' => true]);
    expect($this->container->fresh()->unloaded_at)->not->toBeNull();

    $total = Invoice::where('container_id', $this->container->id)->count();
    $scanned = Invoice::where('container_id', $this->container->id)->where('is_verified', true)->count();
    $missing = $total - $scanned;

    $cards = ($this->cards)($board);
    expect($cards['Boxes missing']['value'])->toBe((string) $missing)
        ->and($cards['Boxes missing']['alert'])->toBeTrue()
        ->and($cards['Unloaded this week']['value'])->toBe('1')
        ->and($board->attention()->first()['tag'])->toBe("{$missing} boxes missing")
        ->and($board->attention()->first()['url'])->toContain('/containers/');

    Unmanifested::create(['invoice' => 'XTRA-1', 'container_id' => $this->container->id]);
    expect($board->attention()->pluck('tag'))->toContain('1 unmanifested');
});

it('flags expired and expiring registrations and vehicles without crew', function () {
    $board = new VehicleBoard($this->truck->logistichub_id);
    expect(($this->cards)($board)['Registration']['value'])->toBe('0');

    $this->truck->update(['date_expired' => today()->subDays(3), 'is_assigned' => true]);
    Truck::create([
        'category' => 'Closed van', 'description' => 'Van', 'registration_no' => 'REG-2', 'plate_no' => 'VAN 0002',
        'user_id' => $this->truck->user_id, 'date_registered' => now()->subYear(), 'date_expired' => today()->addDays(9),
        'logistichub_id' => $this->truck->logistichub_id, 'is_active' => true,
    ]);

    $cards = ($this->cards)($board);
    $tags = $board->attention()->pluck('tag');

    expect($cards['Registration']['value'])->toBe('2')
        ->and($cards['Registration']['sub'])->toBe('1 expired · 1 expire within 30 days')
        ->and($cards['On a trip now']['value'])->toBe('1')
        ->and($tags)->toContain('Expired')->toContain('Expires in 9 days')->toContain('No crew')
        ->and($board->attention()->first()['detail'])->toContain('on a trip now');
});

it('summarises box problems', function () {
    $board = new IssueBoard;
    $cards = ($this->cards)($board);

    expect($cards['Issues this week']['value'])->toBe('1')
        ->and($cards['Containers with issues']['value'])->toBe('1')
        ->and($board->charts()[0]['rows']->first())->toBe(['label' => 'Damaged box', 'count' => 1])
        ->and($board->photos())->toHaveCount(1);
});

it('shows the widgets on all seven lists', function () {
    boardPanel('admin', 'admin@example.com');
    Livewire::test(AdminContainers::class)->assertSuccessful()->assertSeeLivewire(ModuleBoard::class);
    Livewire::test(AdminTrucks::class)->assertSuccessful()->assertSeeLivewire(ModuleBoard::class);
    Livewire::test(AdminIssues::class)->assertSuccessful()->assertSeeLivewire(ModuleBoard::class);

    Livewire::test(ModuleBoard::class, ['board' => 'containers', 'resource' => ContainerResource::class])
        ->assertSee('Waiting to unload')->assertSee('Boxes unloaded per day');

    boardPanel('warehouse', 'warehouse@example.com');
    Livewire::test(WarehouseContainers::class)->assertSuccessful()->assertSeeLivewire(ModuleBoard::class);
    Livewire::test(WarehouseTrucks::class)->assertSuccessful()->assertSeeLivewire(ModuleBoard::class);
    Livewire::test(WarehouseIssues::class)->assertSuccessful()->assertSeeLivewire(ModuleBoard::class);

    boardPanel('company', 'company@example.com');
    Livewire::test(HubTrucks::class)->assertSuccessful()->assertSeeLivewire(ModuleBoard::class);
});

it('shows only open issues in the slider and removes one when it is resolved', function () {
    boardPanel('admin', 'admin@example.com');
    $issue = Invoiceissue::firstOrFail();

    $widget = Livewire::test(ModuleBoard::class, ['board' => 'issues', 'resource' => InvoiceissueResource::class])
        ->assertSee('Open issues')
        ->assertSee('Mark resolved')
        ->assertSee($issue->invoice);

    $widget->call('resolveIssue', $issue->id)
        ->assertNotified("{$issue->invoice} marked resolved")
        ->assertDispatched('issue-resolved')
        ->assertSee('No open issues')
        ->assertDontSee('Mark resolved');

    expect(Invoice::where('invoice', $issue->invoice)->value('is_resolved'))->toBeTruthy()
        ->and((new IssueBoard)->photos())->toHaveCount(0);

    // Switching Resolved off again in the list brings it back
    Invoice::where('invoice', $issue->invoice)->update(['is_resolved' => false]);
    $widget->dispatch('issue-resolved')->assertSee('Mark resolved');
});

it('tells the widget when the Resolved switch in the list changes', function () {
    boardPanel('admin', 'admin@example.com');
    $issue = Invoiceissue::firstOrFail();

    Livewire::test(AdminIssues::class)
        ->call('updateTableColumnState', 'invdata.is_resolved', (string) $issue->getKey(), true)
        ->assertDispatched('issue-resolved');

    expect(Invoice::where('invoice', $issue->invoice)->value('is_resolved'))->toBeTruthy();
});

it('puts every open issue in the slider, not only the newest', function () {
    $first = Invoiceissue::firstOrFail();
    $others = Invoice::where('container_id', $this->container->id)->where('invoice', '!=', $first->invoice)->get();

    // 2 issues for each of the other boxes: well over the old limit of 12
    foreach ([1, 2] as $type) {
        foreach ($others as $box) {
            Invoiceissue::create(['invoice' => $box->invoice, 'container_id' => $this->container->id, 'boxissue_id' => $type, 'user_id' => $first->user_id]);
        }
    }

    $open = Invoiceissue::count();
    expect($open)->toBeGreaterThan(12)
        ->and((new IssueBoard)->photos())->toHaveCount($open);

    Invoice::where('invoice', $first->invoice)->update(['is_resolved' => true]);
    expect((new IssueBoard)->photos())->toHaveCount($open - 1)
        ->and((new IssueBoard)->photos()->pluck('title'))->not->toContain($first->invoice);
});
