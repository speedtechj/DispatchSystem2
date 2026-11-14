<?php

namespace App\Filament\Shared\Fuel;

use App\Models\Deliverylog;
use App\Models\Fuel\FuelCash;
use App\Models\Fuel\FuelFill;
use App\Support\Fuel\Fuel;
use App\Support\Maps\TripSorter;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;

/**
 * Delivery Log › trip › Fuel: the fuel cash estimate (trip km ÷ km per liter × this
 * week's price + buffer), cash given, the fills on the trip, and the change returned.
 */
abstract class TripFuelPage extends Page
{
    protected string $view = 'filament.fuel.trip';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $slug = 'trip-fuel';

    #[Url(as: 'trip')]
    #[Locked]
    public int $tripId = 0;

    public string $give = '';

    public string $returned = '';

    public string $note = '';

    public static function canAccess(): bool
    {
        return Fuel::ready() && parent::canAccess();
    }

    public function mount(): void
    {
        $this->tripId = (int) request()->query('trip', $this->tripId);
        $trip = $this->trip();
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
        $this->give = (string) (Fuel::estimate($trip)['amount'] ?? '');
    }

    protected function trip(): ?Deliverylog
    {
        return Deliverylog::with('truck')->find($this->tripId);
    }

    public function getTitle(): string|Htmlable
    {
        return 'Fuel for this trip';
    }

    public function getSubheading(): ?string
    {
        $trip = $this->trip();

        return $trip ? 'Trip '.$trip->trip_number.($trip->truck ? ' · '.$trip->truck->plate_no : '') : null;
    }

    public function giveCash(): void
    {
        $trip = $this->trip();
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
        $amount = round((float) str_replace([',', '₱'], '', $this->give), 2);
        if ($amount <= 0) {
            Notification::make()->title('Type the cash you give the driver')->warning()->send();

            return;
        }
        if (Fuel::cashFor($trip)) {
            Notification::make()->title('Fuel cash was already given for this trip')->warning()->send();

            return;
        }
        $e = Fuel::estimate($trip);
        FuelCash::create([
            'deliverylog_id' => $trip->id, 'truck_id' => $trip->truck_id, 'driver_id' => \App\Models\Truckcrew::where('truck_id', $trip->truck_id)->latest('id')->value('crew'),
            'km' => $e['km'], 'km_per_liter' => $e['kml'], 'price' => $e['price'], 'buffer_pct' => $e['buffer'],
            'estimate' => $e['amount'], 'given' => $amount, 'given_at' => now(), 'given_by' => Auth::id(),
            'note' => trim($this->note) ?: null,
        ]);
        $this->note = '';
        Notification::make()->title('₱'.number_format($amount, 2).' fuel cash given')->success()->send();
    }

    public function settle(): void
    {
        $trip = $this->trip();
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
        $cash = Fuel::cashFor($trip);
        if (! $cash || $cash->settled_at) {
            return;
        }
        $back = round((float) str_replace([',', '₱'], '', $this->returned), 2);
        $cash->update(['returned' => max(0, $back), 'settled_at' => now(), 'settled_by' => Auth::id(), 'note' => trim($this->note) ?: $cash->note]);
        $short = round($cash->given - $cash->spent() - $back, 2);
        Notification::make()->title('Fuel cash settled')
            ->body(abs($short) >= 1 ? ($short > 0 ? '₱'.number_format($short, 2).' not covered by receipts or change.' : '₱'.number_format(-$short, 2).' more than given (paid by the driver?).') : 'Receipts and change add up.')
            ->{abs($short) >= 1 ? 'warning' : 'success'}()->send();
    }

    public function undoCash(): void
    {
        $trip = $this->trip();
        abort_unless($trip && TripSorter::canSee(Auth::user(), $trip), 404);
        $cash = Fuel::cashFor($trip);
        if ($cash && ! $cash->settled_at && $cash->given_at->gt(now()->subHour())) {
            $cash->delete();
            Notification::make()->title('Fuel cash removed')->send();
        }
    }

    protected function getViewData(): array
    {
        $trip = $this->trip();
        $cash = Fuel::cashFor($trip);

        return [
            'trip' => $trip,
            'est' => Fuel::estimate($trip),
            'cash' => $cash,
            'fills' => FuelFill::where('deliverylog_id', $trip->id)->orderBy('filled_at')->get(),
            'minKm' => Fuel::cashMinKm(),
        ];
    }
}
