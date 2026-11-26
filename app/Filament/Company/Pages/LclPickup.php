<?php

namespace App\Filament\Company\Pages;

use App\Models\Shipping\SeaShipment;
use App\Models\Tripinvoice;
use App\Support\Photos\PhotoShrinker;
use App\Support\Shipping\Shipments;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;
use Livewire\WithFileUploads;

/**
 * Board 63 · LCL pick-up at the forwarder (phone): count the boxes there, take a photo of the release,
 * press Picked up. Then the hub scans them in as usual.
 */
class LclPickup extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.shipping.lcl-pickup';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'lcl-pickup';

    #[Url(as: 'shipment')]
    #[Locked]
    public int $shipmentId = 0;

    /** intro, count, photo, done */
    #[Locked]
    public string $step = 'intro';

    public string $count = '';

    public $upload = null;

    #[Locked]
    public ?string $photoPath = null;

    public static function canAccess(): bool
    {
        return Shipments::ready() && \Illuminate\Support\Facades\Schema::hasColumn('sea_shipments', 'pickup_count') && Auth::check();
    }

    public function getTitle(): string|Htmlable
    {
        return 'LCL pick-up';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    /** The LCL shipment for this hub, ready to pick up (or just picked up). */
    protected function shipment(): ?SeaShipment
    {
        $s = SeaShipment::find($this->shipmentId ?: (int) request()->query('shipment'));
        $mine = (int) Auth::user()?->logistichub_id;

        return $s && $s->mode === 'lcl' && in_array($s->status, ['arrived', 'picked_up'], true) && Shipments::stopFor($s, $mine) ? $s : null;
    }

    protected function expected(): int
    {
        $s = $this->shipment();
        $stop = $s ? Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) : null;

        return $stop ? Tripinvoice::where('deliverylog_id', $stop->deliverylog_id)->count() : 0;
    }

    public function mount(): void
    {
        $this->shipmentId = (int) request()->query('shipment', $this->shipmentId);
        $s = $this->shipment();
        if ($s?->status === 'picked_up') {
            $this->step = 'done';
        }
    }

    public function start(): void
    {
        if ($this->shipment()) {
            $this->count = $this->count !== '' ? $this->count : (string) $this->expected();
            $this->step = 'count';
        }
    }

    public function bump(int $by): void
    {
        $this->count = (string) max(0, min(9999, (int) $this->count + $by));
    }

    public function toPhoto(): void
    {
        $this->validate(['count' => 'required|integer|min:0|max:9999'], ['count.required' => 'Type the number of boxes.']);
        $this->step = 'photo';
    }

    public function savePhoto(): void
    {
        $this->validate(['upload' => 'required|image|max:12288'], ['upload.image' => 'That file is not a photo.']);
        $path = $this->upload->store(\App\Support\Photos\Storage\PhotoFolders::dir('shipments', \App\Models\Shipping\SeaShipment::whereKey($this->shipmentId)->value('code')), 'public');
        PhotoShrinker::file('public', $path);
        $this->photoPath = $path;
        $this->reset('upload');
        $this->save();
    }

    /** Picked up (with or without the photo). */
    public function save(): void
    {
        $s = $this->shipment();
        if (! $s || $s->status !== 'arrived') {
            return;
        }
        $this->validate(['count' => 'required|integer|min:0|max:9999']);
        $s->update(['pickup_count' => (int) $this->count, 'pickup_photo' => $this->photoPath ?? $s->pickup_photo, 'pickup_by' => Auth::id(), 'pickup_at' => now()]);
        Shipments::move($s->fresh(), 'picked_up');
        $this->step = 'done';
    }

    protected function getViewData(): array
    {
        $s = $this->shipment();
        $expected = $this->expected();

        return [
            's' => $s, 'expected' => $expected, 'n' => (int) $this->count,
            'short' => $this->count !== '' && (int) $this->count < $expected ? $expected - (int) $this->count : 0,
            'scanUrl' => (function () {
                try {
                    return \App\Filament\Scan\Pages\ScanApp::getUrl(panel: 'scan');
                } catch (\Throwable) {
                    return '/scan';
                }
            })(),
            'backUrl' => IncomingShipments::getUrl(),
        ];
    }
}
