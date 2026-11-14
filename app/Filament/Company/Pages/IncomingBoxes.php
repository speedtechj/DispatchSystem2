<?php

namespace App\Filament\Company\Pages;

use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\HubDesk;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Forms\Components\DatePicker;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Livewire\Attributes\Url;

/** Boxes handed to this hub and waiting for a trip, by area. Pick areas, then create a trip with them. */
class IncomingBoxes extends Page
{
    protected string $view = 'filament.company.pages.incoming-boxes';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedInboxArrowDown;

    protected static ?string $navigationLabel = 'Incoming boxes';

    protected static ?string $title = 'Incoming boxes';

    protected static ?int $navigationSort = 2;

    /** areas or oldest */
    #[Url]
    public string $show = 'areas';

    /** Area keys (md5 of the city) picked for the next trip. */
    public array $picked = [];

    public static function getNavigationBadge(): ?string
    {
        $count = static::desk()->waiting()->count();

        return $count ? number_format($count) : null;
    }

    public static function getNavigationBadgeColor(): ?string
    {
        return 'info';
    }

    public static function desk(): HubDesk
    {
        return new HubDesk((int) Auth::user()->logistichub_id);
    }

    public function getSubheading(): ?string
    {
        $count = static::desk()->waiting()->count();

        return number_format($count).' '.str('box')->plural($count).' handed to your hub, waiting for a trip. Pick areas to plan a trip.';
    }

    public function togglePick(string $key): void
    {
        $this->picked = in_array($key, $this->picked, true)
            ? array_values(array_diff($this->picked, [$key]))
            : [...$this->picked, $key];
    }

    public function clearPicks(): void
    {
        $this->picked = [];
    }

    /** Waiting box ids in the picked areas (re-checked against the database). */
    protected function pickedIds(): array
    {
        return static::desk()->areas()->whereIn('key', $this->picked)->pluck('ids')->flatten()->all();
    }

    public function createTripAction(): Action
    {
        return Action::make('createTrip')
            ->label('Create trip with these boxes')
            ->icon(Heroicon::OutlinedTruck)
            ->modalHeading(fn () => 'New trip with '.count($this->pickedIds()).' boxes')
            ->modalDescription('The trip is created for your hub and the boxes are put on it. You can still add or remove boxes on the trip page.')
            ->modalSubmitActionLabel('Create trip')
            ->modalWidth('lg')
            ->schema([
                Select::make('truck_id')
                    ->label('Truck')
                    ->options(fn () => static::desk()->freeTrucks()->mapWithKeys(fn ($t) => [$t->id => $t->plate_no.' · '.($t->capacity ?: HubDesk::DEFAULT_CAPACITY).' boxes']))
                    ->required()
                    ->helperText('Only free, active trucks of your hub.'),
                DatePicker::make('departure_date')->label('Leaves on')->default(today())->required(),
                DatePicker::make('eta')->label('Expected back (ETA)')->default(today())->required(),
                TextInput::make('trip_day')->label('Trip days')->numeric()->minValue(1)->default(1)->required(),
            ])
            ->action(function (array $data): void {
                $ids = $this->pickedIds();

                if ($ids === []) {
                    Notification::make()->title('Pick at least one area first')->warning()->send();

                    return;
                }

                $trip = DB::transaction(function () use ($data, $ids): Deliverylog {
                    $hub = (int) Auth::user()->logistichub_id;
                    $trip = Deliverylog::create($data + ['logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => Auth::id()]);
                    app(TripAssignment::class)->addToHubTrip($trip, static::desk()->waiting()->whereKey($ids)->get());

                    return $trip;
                });

                $added = Tripinvoice::where('deliveryloghub_id', $trip->id)->count();
                $this->picked = [];

                Notification::make()->title("Trip {$trip->trip_number} created")->body("{$added} boxes are on it. Load them with Load Truck.")->success()->send();

                $this->redirect(DeliverylogResource::getUrl('edit', ['record' => $trip]));
            });
    }

    protected function getViewData(): array
    {
        $desk = static::desk();
        $areas = $desk->areas();
        $picked = $areas->whereIn('key', $this->picked);
        $boxes = $picked->sum('boxes');
        $capacity = $desk->capacity();

        return [
            'areas' => $areas,
            'max' => max(1, $areas->max('boxes') ?? 0),
            'oldest' => $this->show === 'oldest' ? $desk->oldestWaiting() : collect(),
            'pickedBoxes' => $boxes,
            'pickedCount' => $picked->count(),
            'trucksNeeded' => $boxes ? (int) ceil($boxes / $capacity) : 0,
            'capacity' => $capacity,
            'freeTrucks' => $desk->freeTrucks()->count(),
        ];
    }
}
