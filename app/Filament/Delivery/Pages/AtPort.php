<?php

namespace App\Filament\Delivery\Pages;

use App\Models\Tripinvoice;
use App\Support\DriverTrip;
use App\Support\Photos\PhotoShrinker;
use App\Support\Shipping\Shipments;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Livewire\Attributes\Locked;
use Livewire\WithFileUploads;

/**
 * Driver app › At the port: on a sea shipment trip (Count only), the driver types how many
 * boxes the forwarder counted and takes a photo of the receipt. It goes straight to the shipment.
 */
class AtPort extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.delivery.pages.at-port';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'at-port';

    /** intro, count, photo, done */
    #[Locked]
    public string $step = 'intro';

    public string $count = '';

    public $upload = null;

    #[Locked]
    public ?string $receiptPath = null;

    #[Locked]
    public ?float $lat = null;

    #[Locked]
    public ?float $lng = null;

    public static function canAccess(): bool
    {
        return Shipments::ready() && Auth::check();
    }

    public function getTitle(): string|Htmlable
    {
        return 'At the port';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    protected function shipment()
    {
        return Shipments::forDriverPort(DriverTrip::currentTrip(Auth::user()));
    }

    protected function left(): int
    {
        $s = $this->shipment();

        return $s ? Tripinvoice::where('deliverylog_id', $s->deliverylog_id)->where('is_loaded', true)->count() : 0;
    }

    public function mount(): void
    {
        $s = $this->shipment();
        if ($s && $s->port_count !== null) {
            $this->count = (string) $s->port_count;
        }
    }

    public function setPlace(mixed $lat, mixed $lng): void
    {
        $this->lat = is_numeric($lat) && abs((float) $lat) <= 90 ? (float) $lat : null;
        $this->lng = is_numeric($lng) && abs((float) $lng) <= 180 ? (float) $lng : null;
    }

    public function start(): void
    {
        if ($this->shipment()) {
            $this->count = $this->count !== '' ? $this->count : (string) $this->left();
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

    /** Called by the phone after the (shrunk) receipt photo is uploaded. */
    public function savePhoto(): void
    {
        $this->validate(['upload' => 'required|image|max:12288'], ['upload.image' => 'That file is not a photo.']);
        $path = $this->upload->store('shipments/'.now()->format('Y-m'), 'public');
        PhotoShrinker::file('public', $path);
        if ($this->receiptPath) {
            Storage::disk('public')->delete($this->receiptPath);
        }
        $this->receiptPath = $path;
        $this->reset('upload');
        $this->save();
    }

    /** Without a photo (for example the forwarder gives none). */
    public function save(): void
    {
        $s = $this->shipment();
        if (! $s) {
            return;
        }
        $this->validate(['count' => 'required|integer|min:0|max:9999']);
        Shipments::driverPort($s, (int) $this->count, $this->receiptPath, $this->lat, $this->lng);
        $this->step = 'done';
    }

    protected function getViewData(): array
    {
        $s = $this->shipment();
        $left = $this->left();

        return [
            's' => $s, 'left' => $left, 'n' => (int) $this->count,
            'short' => $this->count !== '' && (int) $this->count < $left ? $left - (int) $this->count : 0,
            'receiptUrl' => $this->receiptPath ? Storage::disk('public')->url($this->receiptPath) : null,
        ];
    }
}
