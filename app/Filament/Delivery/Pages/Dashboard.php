<?php

namespace App\Filament\Delivery\Pages;

use App\Enums\FailedDeliveryReason;
use App\Enums\UndoDeliveryReason;
use App\Models\Maps\GeoPlace;
use App\Models\Maps\TripStop;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\Risk;
use App\Support\Ai\VoiceNote;
use App\Support\DriverTrip;
use App\Support\Photos\PhotoShrinker;
use App\Support\Tracking\TrackSettings;
use BackedEnum;
use Filament\Actions\Action;
use Filament\Forms\Components\Radio;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Pages\Dashboard as BaseDashboard;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Support\Icons\Heroicon;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Livewire\Attributes\Locked;
use Livewire\Attributes\Url;
use Livewire\Features\SupportFileUploads\TemporaryUploadedFile;

/**
 * The Driver app: one phone screen. Today (trip, progress, where to go next),
 * Boxes (to deliver / delivered / not delivered), and Scan → deliver with
 * several proof photos, or can't deliver with a reason. Delivering, not-delivered
 * and undo go through App\Services\TripAssignment like everywhere else.
 */
class Dashboard extends BaseDashboard
{
    protected string $view = 'filament.delivery.pages.driver-app';

    /** home, list, scan */
    #[Url(as: 'view')]
    public string $screen = 'home';

    /** Boxes list: todo, delivered, missed */
    public string $tab = 'todo';

    public string $search = '';

    /** The scanned box (tripinvoice id) and what the bottom sheet shows: found, deliver, miss, wrong */
    #[Locked]
    public ?int $boxId = null;

    #[Locked]
    public ?string $sheet = null;

    #[Locked]
    public ?string $wrongText = null;

    /** Photos already uploaded for the open sheet (paths on the public disk). */
    #[Locked]
    public array $photos = [];

    /** @var TemporaryUploadedFile|null */
    public $upload = null;

    public ?string $reason = null;

    public string $note = '';

    /** Just delivered: shows the green bar with Undo. */
    #[Locked]
    public ?int $justDelivered = null;

    #[Locked]
    public int $justPhotos = 0;

    public function mount(): void
    {
        if (request()->boolean('scan')) {
            $this->screen = 'scan';
        } elseif (request()->boolean('list')) {
            $this->screen = 'list';
        }
        if (! in_array($this->screen, ['home', 'list', 'scan'], true)) {
            $this->screen = 'home';
        }
    }

    protected function driverTrip(): DriverTrip
    {
        return once(fn () => DriverTrip::for(Auth::user()));
    }

    // ------------------------------------------------------------------ moving around

    public function go(string $screen): void
    {
        if (in_array($screen, ['home', 'list', 'scan'], true)) {
            $this->screen = $screen;
            $this->closeSheet();
            $this->justDelivered = null;
        }
    }

    /** Tap an area on Today: open the boxes list filtered to it. */
    public function area(string $term): void
    {
        $this->search = $term;
        $this->tab = 'todo';
        $this->go('list');
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['todo', 'delivered', 'missed'], true) ? $tab : 'todo';
    }

    public function closeSheet(): void
    {
        $this->deleteUnusedPhotos();
        $this->reset('boxId', 'sheet', 'wrongText', 'photos', 'upload', 'reason', 'note');
    }

    /** The open box, re-checked to be on this driver's trip. */
    protected function box(): ?Tripinvoice
    {
        return $this->boxId ? $this->driverTrip()->boxes()->with('invdata')->find($this->boxId) : null;
    }

    // ------------------------------------------------------------------ scan

    /** Called by the camera, the typed box number, or a tap on a box in the list. */
    public function scan(string $code): void
    {
        $code = trim(preg_replace('/[\x00-\x1F\x7F]+/u', '', $code));
        if ($code === '') {
            return;
        }

        $this->closeSheet();
        $this->justDelivered = null;
        $this->screen = 'scan';

        if (! $this->driverTrip()->trip) {
            $this->wrongText = "You're not on a trip right now.";
            $this->sheet = 'wrong';

            return;
        }

        $box = $this->driverTrip()->boxes()->with('invdata')
            ->where(fn ($q) => $q->where('invoice', $code)->orWhereHas('invdata', fn ($r) => $r->where('invoice', $code)))
            ->latest('id')->first();

        if (! $box) {
            $this->wrongText = "{$code} is not on your truck. Keep it aside and tell the office.";
            $this->sheet = 'wrong';
            $this->dispatch('driver-app-buzz', ok: false);

            return;
        }
        if ($box->is_delivered) {
            $this->wrongText = "{$code} is already delivered.";
            $this->sheet = 'wrong';
            $this->dispatch('driver-app-buzz', ok: false);

            return;
        }

        $this->boxId = $box->id;
        $this->sheet = 'found';
        $this->dispatch('driver-app-buzz', ok: true);
    }

    public function openBox(int $id): void
    {
        $box = $this->driverTrip()->boxes()->find($id);
        if ($box) {
            $this->scan($box->invoice);
        }
    }

    public function startDeliver(): void
    {
        if ($this->box() && ! $this->box()->is_delivered) {
            $this->sheet = 'deliver';
            $this->photos = [];
        }
    }

    public function startMiss(): void
    {
        if ($this->box() && ! $this->box()->is_delivered) {
            $this->sheet = 'miss';
            $this->photos = [];
            $this->reason = FailedDeliveryReason::NoOneHome->value;
        }
    }

    /** Driver voice note: what the driver said becomes the reason and the note. */
    public function voiceFill(string $said): void
    {
        $said = trim($said);
        if ($said === '' || $this->sheet !== 'miss') {
            return;
        }
        try {
            $out = VoiceNote::parse($said);
            if ($out['reason']) {
                $this->reason = $out['reason'];
            }
            $this->note = $out['note'] ?: $said;
        } catch (AiUnavailable $e) {
            $this->note = Str::limit($said, 480, '');
            Notification::make()->title('Saved what you said as the note')->body($e->getMessage())->warning()->send();
        }
    }

    public function backToBox(): void
    {
        $this->deleteUnusedPhotos();
        $this->photos = [];
        $this->sheet = $this->box() ? 'found' : null;
    }

    // ------------------------------------------------------------------ photos

    /** Called by the browser after a (shrunk) photo is uploaded. */
    public function savePhoto(): void
    {
        $box = $this->box();
        if (! $box || ! in_array($this->sheet, ['deliver', 'miss'], true)) {
            $this->reset('upload');

            return;
        }
        if ($this->sheet === 'miss' && count($this->photos) >= 3) {
            $this->reset('upload');

            return;
        }

        $this->validate(['upload' => 'required|image|max:12288'], ['upload.image' => 'That file is not a photo.']);

        $dir = $this->sheet === 'deliver' ? $box->invoice : 'not-delivered/'.$box->invoice;
        $path = $this->upload->store($dir, 'public');
        PhotoShrinker::file('public', $path); // the phone could not make it smaller: do it here
        $this->photos[] = $path;
        $this->reset('upload');
    }

    public function removePhoto(int $index): void
    {
        if (isset($this->photos[$index])) {
            Storage::disk('public')->delete($this->photos[$index]);
            unset($this->photos[$index]);
            $this->photos = array_values($this->photos);
        }
    }

    protected function deleteUnusedPhotos(): void
    {
        foreach ($this->photos as $path) {
            Storage::disk('public')->delete($path);
        }
    }

    // ------------------------------------------------------------------ deliver / can't deliver

    public function confirmDelivered(): void
    {
        $box = $this->box();
        if (! $box || $box->is_delivered) {
            $this->closeSheet();

            return;
        }
        if ($this->photos === []) {
            Notification::make()->title('Take at least one photo first')->warning()->send();

            return;
        }

        // Delivering means the trip is on the road, even if nobody tapped "I take the trip".
        if ($this->driverTrip()->trip) {
            \App\Support\TripFlow::take($this->driverTrip()->trip, Auth::user());
        }
        app(TripAssignment::class)->markDelivered($box, $this->photos);

        $this->justDelivered = $box->id;
        $this->justPhotos = count($this->photos);
        $this->photos = []; // they belong to the box now
        $this->reset('boxId', 'sheet', 'reason', 'note', 'upload');
        $this->dispatch('driver-app-buzz', ok: true);
    }

    /** Undo on the green bar right after delivering. */
    public function undoJust(): void
    {
        $box = $this->justDelivered ? $this->driverTrip()->boxes()->find($this->justDelivered) : null;
        $this->justDelivered = null;
        if (! $box) {
            return;
        }

        try {
            app(TripAssignment::class)->undoDelivery($box, Auth::user(), UndoDeliveryReason::TappedByMistake);
        } catch (\DomainException $e) {
            Notification::make()->title($e->getMessage())->danger()->send();

            return;
        }

        $this->boxId = $box->id;
        $this->sheet = 'found';
    }

    public function saveMissed(): void
    {
        $box = $this->box();
        $reason = FailedDeliveryReason::tryFrom((string) $this->reason);
        if (! $box || ! $reason) {
            return;
        }
        if ($this->driverTrip()->trip) {
            \App\Support\TripFlow::take($this->driverTrip()->trip, Auth::user());
        }

        try {
            app(TripAssignment::class)->recordFailedAttempt($box, Auth::user(), $reason, $this->note ?: null, $this->photos);
        } catch (\DomainException $e) {
            Notification::make()->title($e->getMessage())->warning()->send();

            return;
        }

        $this->photos = [];
        $this->closeSheet();
        Notification::make()->title("{$box->invoice} stays on your truck")->body('The office has been told.')->warning()->send();
    }

    protected static ?string $navigationLabel = 'Today';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedHome;

    protected static ?int $navigationSort = 1;

    // ------------------------------------------------------------------ trip steps

    /** "I take the trip": the leadman confirms the box count; the trip is on the road. */
    public function takeTrip(): void
    {
        $trip = $this->driverTrip()->trip;
        if (! $trip || ! \App\Support\TripFlow::canTake($trip, Auth::user())) {
            return;
        }
        \App\Support\TripFlow::take($trip, Auth::user());
        Notification::make()->title('Trip '.$trip->trip_number.' is yours · '.$trip->fresh()->taken_boxes.' boxes')->body('Drive safe. Customers see you are on the way.')->success()->send();
    }

    /** "Back at the hub": boxes not delivered are scanned back; then the trip closes by itself. */
    public function backAtHub(): void
    {
        $trip = $this->driverTrip()->trip;
        if (! $trip) {
            return;
        }
        \App\Support\TripFlow::back($trip);
        $closed = ! $trip->fresh()->is_active;
        Notification::make()->title($closed ? 'Trip done · truck released' : 'Back at the hub')
            ->body($closed ? 'Every box is delivered or returned.' : 'Give the boxes not delivered to the hub: they are scanned back with Return boxes. Then the trip closes by itself.')->success()->send();
    }

    /** The card at the top of Today for the trip step (none while on the road). */
    protected function stageCard(string $stage, array $p, bool $canTake): ?array
    {
        return [
            'planned' => ['Your next trip', 'Planned. You will see the boxes when the truck is loaded.'],
            'loading' => ['Being loaded', $p['total'].' boxes on the trip so far. Wait for “Trip ready”.'],
            'ready' => ['Trip ready', 'Check the truck. '.($canTake ? 'Tap when you take the trip: you confirm '.$p['total'].' boxes.' : 'The leadman takes the trip.')],
            'back' => ['Back at the hub', $p['left'] ? $p['left'].' not delivered: give them to the hub, they are scanned back with Return boxes. Then the trip closes by itself.' : 'The trip closes by itself.'],
        ][$stage] ?? null;
    }

    public function getTitle(): string|Htmlable
    {
        return 'Today';
    }

    public function getHeading(): string|Htmlable
    {
        $hour = (int) now()->format('G');
        $greeting = $hour < 12 ? 'Good morning' : ($hour < 18 ? 'Good afternoon' : 'Good evening');

        return "{$greeting}, ".Auth::user()?->first_name;
    }

    public function getSubheading(): ?string
    {
        return now()->format('l, F j');
    }

    /** Undo one of today's deliveries (only the driver's own, within 30 minutes). */
    public function undoDeliveryAction(): Action
    {
        return Action::make('undoDelivery')
            ->label('Undo')
            ->icon(Heroicon::OutlinedArrowUturnLeft)
            ->color('gray')
            ->outlined()
            ->size('sm')
            ->modalHeading(fn (array $arguments) => 'Undo delivery of '.$this->ownBox($arguments)?->invoice.'?')
            ->modalDescription('The box goes back on your list. Your photo is kept.')
            ->modalIcon(Heroicon::OutlinedArrowUturnLeft)
            ->modalSubmitActionLabel('Undo delivery')
            ->modalCancelActionLabel('Keep delivered')
            ->modalWidth('md')
            ->schema([
                Radio::make('reason')
                    ->label('Why?')
                    ->options(UndoDeliveryReason::driverOptions())
                    ->default(UndoDeliveryReason::WrongBox->value)
                    ->required()
                    ->live(),
                Textarea::make('note')
                    ->label('Note')
                    ->rows(2)
                    ->maxLength(500)
                    ->required(fn (Get $get) => $get('reason') === UndoDeliveryReason::Other->value),
            ])
            ->action(function (array $data, array $arguments): void {
                $box = $this->ownBox($arguments);

                if (! $box) {
                    Notification::make()->title('That box is not on your trip')->danger()->send();

                    return;
                }

                try {
                    app(TripAssignment::class)->undoDelivery($box, Auth::user(), UndoDeliveryReason::from($data['reason']), $data['note'] ?? null);
                } catch (\DomainException $exception) {
                    Notification::make()->title($exception->getMessage())->danger()->send();

                    return;
                }

                Notification::make()->title('Delivery undone')->body("{$box->invoice} is back on your list.")->success()->send();
            });
    }

    /** The box from the button, re-checked to be on this driver's own trip. */
    protected function ownBox(array $arguments): ?Tripinvoice
    {
        return DriverTrip::for(Auth::user())->boxes()->find($arguments['tripinvoice'] ?? null);
    }

    /** Truck tracking: the driver agrees once to share their location during trips. */
    public function agreeTracking(): void
    {
        Auth::user()->forceFill(['tracking_consent_at' => now()])->save();
    }

    /** "Can't find it" on a stop: the driver's pin, checked by the office in Maps & routes. */
    public function suggestPin(int $stopId, float $lat, float $lng): void
    {
        $trip = $this->driverTrip()->trip;
        $stop = $trip ? TripStop::where('deliverylog_id', $trip->id)->find($stopId) : null;
        if (! $stop?->geo_place_id || abs($lat) > 90 || abs($lng) > 180) {
            return;
        }
        GeoPlace::whereKey($stop->geo_place_id)->update([
            'suggested_lat' => $lat, 'suggested_lng' => $lng, 'suggested_by' => Auth::id(), 'suggested_at' => now(),
        ]);
        Notification::make()->title('Pin sent')->body('The office will check it. Next time the map goes there.')->success()->send();
    }

    public function getWidgets(): array
    {
        return [];
    }

    protected function getViewData(): array
    {
        $trip = $this->driverTrip();
        $has = (bool) $trip->trip;
        $box = $this->box();

        $household = null;
        if ($box?->invdata) {
            $same = $trip->boxes()->whereHas('invdata', fn ($q) => $q
                ->where('receiver_name', $box->invdata->receiver_name)
                ->where('receiver_address', $box->invdata->receiver_address))->get(['id', 'is_delivered']);
            $household = ['count' => $same->count(), 'delivered' => $same->where('is_delivered', true)->count()];
        }

        $stage = $has && \App\Support\TripFlow::ready() ? \App\Support\TripFlow::stage($trip->trip) : null;

        return [
            'trip' => $trip->trip,
            'stage' => $stage,
            'canTake' => $canTake = $stage === 'ready' && \App\Support\TripFlow::canTake($trip->trip, Auth::user()),
            'stageCard' => $has && $stage ? $this->stageCard($stage, $trip->progress(), $canTake) : null,
            'closedTrip' => $closedTrip = ! $has && Auth::user() ? \App\Support\TripFlow::justClosedFor(Auth::user()) : null,
            'closedDelivered' => $closedTrip ? \App\Support\TripFlow::boxes($closedTrip)->where('is_delivered', true)->count() : 0,
            'progress' => $has ? $trip->progress() : null,
            'finished' => $has && $trip->isFinished(),
            'crew' => $trip->crewmates(),
            'priority' => $has && $this->screen === 'home' ? $trip->priority() : collect(),
            'areas' => $has && $this->screen === 'home' ? $trip->areas() : collect(),
            'stops' => $has && $this->screen === 'home' ? $trip->stops() : collect(),
            'tracking' => [
                'trip' => $has && TrackSettings::source((int) $trip->trip->truck_id) !== 'tracker' ? $trip->trip->trip_number : null,
                'consent' => (bool) Auth::user()?->tracking_consent_at,
                'interval' => TrackSettings::int('interval'),
            ],
            'problems' => $has && $this->screen === 'home' ? $trip->problems() : collect(),
            'delivered' => $has && $this->screen === 'home' ? $trip->deliveredToday() : collect(),
            'rows' => $has && $this->screen === 'list' ? $this->listRows() : collect(),
            'counts' => $has && $this->screen === 'list' ? $this->listCounts() : [],
            'box' => $box,
            'risk' => $box && ! $box->is_delivered && Ai::switchedOn('risky') ? Risk::of($box) : null,
            'voiceOn' => Ai::enabled('voice'),
            'household' => $household,
            'reasons' => FailedDeliveryReason::cases(),
            'reasonCase' => FailedDeliveryReason::tryFrom((string) $this->reason),
            'photoUrls' => array_map(fn ($p) => Storage::disk('public')->url($p), $this->photos),
            'just' => $this->justDelivered ? $trip->boxes()->find($this->justDelivered) : null,
            'greeting' => (int) now()->format('G') < 12 ? 'Good morning' : ((int) now()->format('G') < 18 ? 'Good afternoon' : 'Good evening'),
        ];
    }

    protected function listQuery()
    {
        $q = $this->driverTrip()->boxes()->with('invdata', 'latestDeliveryAttempt');
        $term = trim($this->search);
        if ($term !== '') {
            $q->where(fn ($w) => $w->where('invoice', 'like', "%{$term}%")->orWhereHas('invdata', fn ($i) => $i
                ->where('receiver_name', 'like', "%{$term}%")->orWhere('receiver_barangay', 'like', "%{$term}%")->orWhere('receiver_city', 'like', "%{$term}%")));
        }

        return $q;
    }

    protected function listRows()
    {
        $q = $this->listQuery();
        match ($this->tab) {
            'delivered' => $q->where('is_delivered', true)->orderByRaw('COALESCE(delivered_at, updated_at) DESC'),
            'missed' => $q->where('is_delivered', false)->has('deliveryAttempts')->orderBy('invoice'),
            default => $q->where('is_delivered', false)->orderBy('invoice'),
        };

        return $q->limit(200)->get();
    }

    protected function listCounts(): array
    {
        $p = $this->driverTrip()->progress();

        return ['todo' => $p['left'], 'delivered' => $p['delivered'], 'missed' => $p['notDelivered']];
    }
}
