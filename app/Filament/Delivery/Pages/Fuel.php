<?php

namespace App\Filament\Delivery\Pages;

use App\Support\DriverTrip;
use App\Support\Fuel\Fuel as FuelData;
use App\Support\Fuel\FuelReader;
use App\Support\Photos\PhotoShrinker;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Livewire\Attributes\Locked;
use Livewire\WithFileUploads;

/**
 * Driver app › ⛽ Add fuel: photo of the receipt (read by AI when on), check the numbers,
 * card or cash, photo of the odometer, save. The office sees it on the Fuel page.
 */
class Fuel extends Page
{
    use WithFileUploads;

    protected string $view = 'filament.delivery.pages.fuel';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'fuel';

    /** receipt, check, odometer, done */
    #[Locked]
    public string $step = 'receipt';

    public $upload = null;

    #[Locked]
    public ?string $receiptPath = null;

    #[Locked]
    public ?string $odometerPath = null;

    public array $f = [];

    #[Locked]
    public bool $aiRead = false;

    #[Locked]
    public array $aiData = [];

    #[Locked]
    public ?float $lat = null;

    #[Locked]
    public ?float $lng = null;

    #[Locked]
    public ?int $savedId = null;

    public static function canAccess(): bool
    {
        return FuelData::ready() && Auth::check();
    }

    public function mount(): void
    {
        $this->f = $this->blank();
    }

    protected function blank(): array
    {
        return ['station' => '', 'product' => '', 'fuel_type' => '', 'liters' => '', 'price_per_liter' => '', 'total' => '',
            'vatable' => '', 'vat' => '', 'station_tin' => '', 'invoice_no' => '', 'buyer_tin_ok' => '', 'paid_with' => 'card',
            'card_last4' => '', 'odometer' => '', 'filled_at' => now()->format('Y-m-d\TH:i')];
    }

    public function getTitle(): string|Htmlable
    {
        return 'Add fuel';
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    /** Phone location when the fill is added: compared with the truck GPS. */
    public function setPlace(mixed $lat, mixed $lng): void
    {
        $this->lat = is_numeric($lat) && abs((float) $lat) <= 90 ? (float) $lat : null;
        $this->lng = is_numeric($lng) && abs((float) $lng) <= 180 ? (float) $lng : null;
    }

    /** Called by the browser after a (shrunk) photo is uploaded. */
    public function savePhoto(): void
    {
        $this->validate(['upload' => 'required|image|max:12288'], ['upload.image' => 'That file is not a photo.']);
        $path = $this->upload->store(\App\Support\Photos\Storage\PhotoFolders::dir('fuel', rescue(fn () => FuelData::truckFor(Auth::user(), DriverTrip::currentTrip(Auth::user()))?->plate_no, null, false)), 'public');
        PhotoShrinker::file('public', $path);
        $this->reset('upload');

        if ($this->step === 'odometer') {
            if ($this->odometerPath) {
                Storage::disk('public')->delete($this->odometerPath);
            }
            $this->odometerPath = $path;
            if ($this->f['odometer'] === '' && ($km = FuelReader::odometer($path))) {
                $this->f['odometer'] = (string) $km;
            }

            return;
        }

        if ($this->receiptPath) {
            Storage::disk('public')->delete($this->receiptPath);
        }
        $this->receiptPath = $path;
        $read = FuelReader::receipt($path);
        $this->aiRead = $read !== [];
        $this->aiData = $read;
        foreach ($read as $k => $v) {
            if (array_key_exists($k, $this->f)) {
                $this->f[$k] = (string) $v;
            }
        }
        if (isset($read['buyer_tin'])) {
            $this->f['buyer_tin_ok'] = FuelData::buyerTinOk($read['buyer_tin'], (float) ($read['total'] ?? 0)) === false ? '0' : '1';
        }
        if (isset($read['filled_at'])) {
            $this->f['filled_at'] = str_replace(' ', 'T', $read['filled_at']);
        }
        $this->step = 'check';
    }

    public function noReceiptPhoto(): void
    {
        $this->step = 'check';
    }

    public function toOdometer(): void
    {
        $this->validateFill();
        $this->step = 'odometer';
    }

    public function back(): void
    {
        $this->step = match ($this->step) { 'odometer' => 'check', default => 'receipt' };
    }

    protected function validateFill(): void
    {
        foreach (['liters', 'total', 'price_per_liter', 'vat', 'vatable'] as $k) {
            $this->f[$k] = str_replace([',', '₱', ' '], '', (string) $this->f[$k]);
        }
        $this->validate([
            'f.liters' => 'required|numeric|min:1|max:1000',
            'f.total' => 'required|numeric|min:1|max:200000',
            'f.price_per_liter' => 'nullable|numeric|min:10|max:300',
            'f.vat' => 'nullable|numeric|min:0',
            'f.vatable' => 'nullable|numeric|min:0',
            'f.fuel_type' => 'required|in:diesel,gasoline',
            'f.paid_with' => 'required|in:card,cash',
            'f.station' => 'nullable|string|max:120',
            'f.product' => 'nullable|string|max:80',
            'f.filled_at' => 'required|date',
        ], [
            'f.liters.required' => 'Type the liters on the receipt.',
            'f.total.required' => 'Type the total amount.',
            'f.fuel_type.required' => 'Diesel or gasoline?',
        ]);
    }

    public function save(): void
    {
        $this->validateFill();
        $this->validate(['f.odometer' => 'nullable|integer|min:1|max:9999999']);
        $driver = Auth::user();
        $trip = DriverTrip::currentTrip($driver);
        $truck = FuelData::truckFor($driver, $trip);
        if (! $truck) {
            Notification::make()->title('No truck for you yet')->body('Ask the office to put you on a truck, then add the fill again.')->danger()->send();

            return;
        }
        $at = \Illuminate\Support\Carbon::parse($this->f['filled_at']);
        $fill = FuelData::save([
            ...$this->f,
            'filled_at' => $at->gt(now()) ? now() : $at,
            'buyer_tin_ok' => $this->f['buyer_tin_ok'] === '' ? null : $this->f['buyer_tin_ok'] === '1',
            'receipt_path' => $this->receiptPath, 'odometer_path' => $this->odometerPath,
            'lat' => $this->lat, 'lng' => $this->lng, 'ai_read' => $this->aiRead, 'ai_data' => $this->aiData ?: null,
        ], $truck, $driver, $trip);
        $this->savedId = $fill->id;
        $this->step = 'done';
    }

    public function another(): void
    {
        $this->reset(['receiptPath', 'odometerPath', 'aiRead', 'aiData', 'savedId']);
        $this->f = $this->blank();
        $this->step = 'receipt';
    }

    protected function getViewData(): array
    {
        $driver = Auth::user();
        $trip = DriverTrip::currentTrip($driver);
        $truck = FuelData::truckFor($driver, $trip);
        $cash = FuelData::cashFor($trip);
        $prev = $truck ? \App\Models\Fuel\FuelFill::where('truck_id', $truck->id)->whereNotNull('odometer')->latest('filled_at')->first() : null;
        $odo = (int) $this->f['odometer'];
        $kmSince = $prev && $odo > $prev->odometer && $odo - $prev->odometer < 5000 ? $odo - $prev->odometer : null;
        $liters = (float) $this->f['liters'];

        return [
            'trip' => $trip, 'truck' => $truck, 'cash' => $cash,
            'aiOn' => FuelReader::on(),
            'wrongFuel' => $truck?->fuel_type && $this->f['fuel_type'] && $truck->fuel_type !== $this->f['fuel_type'],
            'problems' => $this->step === 'check' ? FuelReader::problems($this->f) : [],
            'receiptUrl' => $this->receiptPath ? Storage::disk('public')->url($this->receiptPath) : null,
            'odometerUrl' => $this->odometerPath ? Storage::disk('public')->url($this->odometerPath) : null,
            'prevOdo' => $prev?->odometer, 'kmSince' => $kmSince, 'kml' => $kmSince && $liters > 0 ? round($kmSince / $liters, 1) : null,
            'needTin' => (float) $this->f['total'] >= 1000 && FuelData::companyTin() !== '',
            'companyTin' => FuelData::companyTin(), 'companyName' => (string) FuelData::setting('company_name', ''),
            'saved' => $this->savedId ? \App\Models\Fuel\FuelFill::find($this->savedId) : null,
        ];
    }
}
