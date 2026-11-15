<?php

namespace App\Filament\Shared\Shipping;

use App\Models\Deliverylog;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use BackedEnum;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Url;

/**
 * Sea shipments: boxes going by sea (or RoRo) to a partner hub. Admin sees all, Warehouse its own
 * trips, the partner hub what is coming to it ("Incoming shipments").
 */
abstract class SeaShipmentsPage extends Page
{
    protected string $view = 'filament.shipping.list';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedGlobeAsiaAustralia;

    protected static ?string $navigationLabel = 'Sea shipments';

    protected static ?string $title = 'Sea shipments';

    protected static ?string $slug = 'sea-shipments';

    /** Partner hub panel: only what comes to us, no "new shipment". */
    protected static bool $incoming = false;

    #[Url]
    public string $show = 'open';

    public ?int $tripId = null;

    public string $mode = 'container';

    public string $portCheck = 'count';

    public static function canAccess(): bool
    {
        return Shipments::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    public function create(): void
    {
        abort_if(static::$incoming, 403);
        $trip = Shipments::tripsFor($this->hub())->firstWhere('id', $this->tripId);
        if (! $trip) {
            $this->addError('tripId', 'Pick the trip to the port.');

            return;
        }
        $s = Shipments::create($trip, $this->mode, $this->portCheck);
        Notification::make()->title("Sea shipment {$s->code} made")->body('Load the trip as usual (Scan app → Load truck), then fill the van and seal.')->success()->send();
        $this->redirect($this->detailUrl($s->id));
    }

    protected function detailUrl(int $id): string
    {
        $class = str_replace('SeaShipments', 'SeaShipment', static::class);
        $class = str_replace('IncomingShipments', 'SeaShipment', $class);

        return $class::getUrl(['shipment' => $id]);
    }

    protected function getViewData(): array
    {
        $q = Shipments::visible($this->hub())->when(static::$incoming, fn ($q) => $q->where('logistichub_id', (int) Auth::user()?->logistichub_id));
        $list = (clone $q)->when($this->show === 'open', fn ($q) => $q->where('status', '!=', 'received'))->latest('id')->limit(60)->get();

        return [
            'list' => $list->map(fn ($s) => ['s' => $s, 'label' => Shipments::label($s), 'counts' => Shipments::counts($s), 'url' => $this->detailUrl($s->id),
                'steps' => array_keys(Shipments::steps($s))]),
            'incoming' => static::$incoming,
            'trips' => static::$incoming ? collect() : Shipments::tripsFor($this->hub()),
            'modes' => Shipments::MODES,
            'checks' => Shipments::PORT_CHECKS,
            'done' => (clone $q)->where('status', 'received')->count(),
        ];
    }
}
