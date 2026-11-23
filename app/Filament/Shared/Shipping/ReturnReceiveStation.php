<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Shipping\ReturnShipment;
use App\Support\Boxes\Sections;
use App\Support\Shipping\Returns;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Scan app · Receive returns: the warehouse scans in the boxes of a return shipment. */
class ReturnReceiveStation extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'return_shipment_id';
    }

    protected function selectionLabel(): string
    {
        return 'a return shipment';
    }

    protected function shipment(): ?ReturnShipment
    {
        return ReturnShipment::with('hub:id,hub_name')->where('status', 'sent')->find($this->data['return_shipment_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $rs = $this->shipment();
        if (! $rs) {
            $this->scanResult('danger', 'That return shipment is not open for receiving.');

            return;
        }
        $r = Returns::receive($rs, $code, Auth::user()?->warehouse_id, $this->pinInvoice);
        if ($r['status'] === 'which') {
            $this->askWhich($code, $r['boxes']);

            return;
        }
        $this->route = Sections::tile($r['box']?->invoice?->whSection);
        $this->scanResult($r['status'], $r['message'], $r['box']?->invoice);
    }

    public function progress(): array
    {
        $rs = $this->shipment();
        if (! $rs) {
            return ['loaded' => 0, 'total' => 0];
        }
        $c = Returns::counts($rs);

        return ['loaded' => $c['back'], 'total' => $c['total']];
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return null;
    }

    public function photoContext(): array
    {
        return [];
    }

    public function appChoices(): Collection
    {
        return ReturnShipment::with('hub:id,hub_name')->where('status', 'sent')->latest('id')->limit(30)->get()
            ->map(fn ($rs) => ['id' => $rs->id, 'name' => $rs->code.' from '.($rs->hub?->hub_name ?? ''), 'active' => true,
                'sub' => collect([$rs->van_no ? 'Van '.$rs->van_no : null, $rs->eta ? 'ETA '.$rs->eta->format('M j') : null])->filter()->join(' · ') ?: null]);
    }
}
