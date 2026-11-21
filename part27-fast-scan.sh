#!/usr/bin/env bash
#
# Dispatch System — Part 27: Faster Scan app and Driver app
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part27-fast-scan.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 21 files"

# ---------------------------------------------------------------- app/Filament/Delivery/Pages/Dashboard.php
mkdir -p 'app/Filament/Delivery/Pages'
cat > 'app/Filament/Delivery/Pages/Dashboard.php' <<'DISPATCH_FILE_END_0'
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
        // not locked yet: it locks by itself when every check is green (Trip rules); otherwise the office locks it
        if (! $trip->is_lock) {
            if (! \App\Support\Trips\TripLock::autoOnTake() || ! \App\Support\Trips\TripLock::isReady($trip)) {
                Notification::make()->title('Trip not ready')->body('Not ready: '.\App\Support\Trips\TripLock::missing($trip).'. Call the office.')->warning()->send();

                return;
            }
            \App\Support\Trips\TripLock::lock($trip, Auth::user());
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
    protected function stageCard(string $stage, array $p, bool $canTake, string $missing = ''): ?array
    {
        return [
            'planned' => ['Your next trip', 'Planned. You will see the boxes when the truck is loaded.'],
            'loading' => $canTake
                ? ['Trip ready', 'Every box is loaded, the truck and crew are set. Tap when you take the trip: it locks by itself and you confirm '.$p['total'].' boxes.']
                : ['Being loaded', $p['total'].' boxes on the trip so far.'.($missing ? ' Not ready: '.$missing.'.' : '').' Wait for “Trip ready”.'],
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
        $prog = $has ? $trip->progress() : null; // once per tap

        return [
            'trip' => $trip->trip,
            'stage' => $stage,
            'canTake' => $canTake = ($stage === 'ready' || ($stage === 'loading' && (\App\Support\Trips\TripLock::autoOnTake() && \App\Support\Trips\TripLock::isReady($trip->trip))))
                && \App\Support\TripFlow::canTake($trip->trip, Auth::user()),
            'stageCard' => $has && $stage ? $this->stageCard($stage, $prog, $canTake, $stage === 'loading' ? \App\Support\Trips\TripLock::missing($trip->trip) : '') : null,
            'nextTrip' => $has && \App\Support\TripFlow::queueReady() ? \App\Support\TripFlow::nextAfter($trip->trip) : null,
            'closedTrip' => $closedTrip = ! $has && Auth::user() ? \App\Support\TripFlow::justClosedFor(Auth::user()) : null,
            'closedDelivered' => $closedTrip ? \App\Support\TripFlow::boxes($closedTrip)->where('is_delivered', true)->count() : 0,
            'progress' => $prog,
            'finished' => $has && $prog['total'] > 0 && $prog['left'] === 0,
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
            'counts' => $has && $this->screen === 'list' ? ['todo' => $prog['left'], 'delivered' => $prog['delivered'], 'missed' => $prog['notDelivered']] : [],
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
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Scan/Pages/ScanApp.php
mkdir -p 'app/Filament/Scan/Pages'
cat > 'app/Filament/Scan/Pages/ScanApp.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Scan\Pages;

use App\Models\Ai\AiPhotoCheck;
use App\Models\Boxes\SetSplit;
use App\Models\BoxPhoto;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\PhotoSetting;
use App\Models\Unmanifested;
use App\Models\Whdeliverylog;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\PhotoCheck;
use App\Support\BoxSizes;
use App\Support\Photos\BoxPhotos;
use App\Support\ScanModes;
use App\Support\Trips\TripRules;
use App\Support\TruckSpace;
use Filament\Actions\Action;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Panel;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;
use Livewire\Features\SupportFileUploads\TemporaryUploadedFile;

/**
 * The Scan app. One phone screen with four steps: start → pick → scan → done.
 * Scanning is done by the existing scan pages (Unload Container, Load Truck, …):
 * this page only picks the right one for the signed-in person and shows the result.
 */
class ScanApp extends Page
{
    protected string $view = 'filament.scan.app';

    protected static ?string $title = 'Scan';

    #[Locked]
    public string $screen = 'home';

    #[Locked]
    public ?string $mode = null;

    #[Locked]
    public ?int $choice = null;

    /** Result of the last scan, from the scan page that handled it. */
    #[Locked]
    public ?string $status = null;

    #[Locked]
    public ?string $message = null;

    #[Locked]
    public ?int $invoiceId = null;

    /** Box not on the container's manifest (Unload container only). */
    #[Locked]
    public ?string $missing = null;

    /** Boxes returned on this screen (Return boxes counts them as it goes). */
    #[Locked]
    public int $returned = 0;

    #[Locked]
    public int $sessionScans = 0;

    /** Load truck: the box was too early (its spot is nearer the door than what is loaded now). */
    #[Locked]
    public ?array $early = null;

    /** Load truck: where the box just loaded goes. */
    #[Locked]
    public ?array $spot = null;

    /** Unload: the section (or waiting truck) of the box just scanned. */
    #[Locked]
    public ?array $route = null;

    /** The box's set: "2 of 3 · 1 more still in this container". */
    #[Locked]
    public ?array $setInfo = null;

    /** Partner hub unload: the hub trip the box went on (board 45d). */
    public ?array $hubTrip = null;

    /** Load truck: the box is for another hub. */
    #[Locked]
    public ?array $wrongHub = null;

    /** Show the finished and closed ones on the pick list too (greyed out). */
    public bool $showFinished = false;

    /** The chosen trip or container as shown in the bar (kept, so it is not looked up on every tap). */
    public ?array $targetInfo = null;

    /** Load next, space, "Room for more": loaded right after the scan screen shows (board 51). */
    public bool $extrasReady = false;

    /** Pick boxes: the last result (title, why, tone, undo). */
    public ?array $pickResult = null;

    public ?string $condition = null;

    public string $note = '';

    /** @var TemporaryUploadedFile|null */
    public $boxPhoto = null;

    public static function getRoutePath(Panel $panel): string
    {
        return '/';
    }

    public function getTitle(): string|Htmlable
    {
        return 'Scan';
    }

    public function getHeading(): string
    {
        return '';
    }

    protected function modes(): array
    {
        return ScanModes::for(Auth::user());
    }

    protected function mode(): ?array
    {
        return $this->mode ? ($this->modes()[$this->mode] ?? null) : null;
    }

    /** The existing scan page for this mode, set to the chosen container or trip. */
    protected function station(?int $choice = null, ?string $modeKey = null): ?object
    {
        $mode = $modeKey ? ($this->modes()[$modeKey] ?? null) : $this->mode();
        if (! $mode) {
            return null;
        }

        $station = app($mode['class']);
        $station->data = [$mode['field'] => $choice ?? $this->choice];
        if (property_exists($station, 'returnedCount')) {
            $station->returnedCount = $this->returned;
        }

        return $station;
    }

    // ------------------------------------------------------------------ steps

    public function open(string $mode): void
    {
        if (! isset($this->modes()[$mode])) {
            return;
        }
        $this->mode = $mode;
        $this->choice = null;
        $this->showFinished = false;
        $this->screen = 'pick';
        $this->clearResult();
        // Pick boxes: one trip given to you opens by itself.
        if ($mode === 'pick' && ($mine = $this->station()?->appChoices()->where('mine', true)) && $mine->count() === 1) {
            $this->pick($mine->first()['id']);
        }
    }

    /** Pick boxes: take a trip that has no picker yet. */
    public function takeTrip(int $id): void
    {
        $trip = $this->mode === 'pick' ? $this->station()?->appChoices()->firstWhere('id', $id) : null;
        $model = $trip ? Deliverylog::find($id) : null;
        if (! $model || ! \App\Support\Trips\Picking::take($model, Auth::user())) {
            Notification::make()->title('Someone else took that trip.')->warning()->send();

            return;
        }
        $this->pick($id);
    }

    /** Pick boxes: all picked, go on with Load truck for the same trip. */
    public function goLoad(): void
    {
        $trip = $this->choice;
        $key = collect(['load', 'hub_load'])->first(fn ($k) => isset($this->modes()[$k]));
        if (! $key) {
            return;
        }
        $this->open($key);
        if ($trip && $this->station()?->appChoices()->contains('id', $trip)) {
            $this->pick($trip);
        }
    }

    /** Pick boxes: picked by mistake. */
    public function undoPick(int $rowId): void
    {
        $trip = $this->mode === 'pick' && $this->choice ? Deliverylog::find($this->choice) : null;
        if ($trip && \App\Support\Trips\Picking::isPicker($trip, Auth::user()) && \App\Support\Trips\Picking::undo($trip, $rowId, Auth::user())) {
            $this->pickResult = ['title' => '↶ Undone · back on the list', 'why' => 'Put the box back where it was.', 'tone' => 'warn', 'undo' => null, 'code' => $this->pickResult['code'] ?? ''];
            $this->status = 'warning';
        }
    }

    /** Pick boxes: the box is not in its section. */
    public function notFound(int $rowId): void
    {
        $trip = $this->mode === 'pick' && $this->choice ? Deliverylog::find($this->choice) : null;
        if ($trip && \App\Support\Trips\Picking::isPicker($trip, Auth::user()) && \App\Support\Trips\Picking::notFound($trip, $rowId, Auth::user())) {
            $this->pickResult = ['title' => 'Marked not found', 'why' => 'The office sees it on Picking. Keep picking the rest.', 'tone' => 'warn', 'undo' => null, 'code' => ''];
            $this->status = 'warning';
        }
    }

    public function pick(int $id): void
    {
        $station = $this->station();
        $target = $station?->appChoices()->firstWhere('id', $id);
        if (! $target) {
            Notification::make()->title('That one is not open for you any more.')->warning()->send();

            return;
        }
        $this->targetInfo = ['id' => $id, 'name' => $target['name'] ?? '', 'sub' => $target['sub'] ?? null];
        $this->extrasReady = false;
        $this->choice = $id;
        $this->returned = 0;
        $this->screen = 'scan';
        $this->clearResult();
    }

    /** Called by the scan screen once it shows. */
    public function loadExtras(): void
    {
        $this->extrasReady = true;
    }

    public function toggleFinished(): void
    {
        $this->showFinished = ! $this->showFinished;
    }

    /**
     * Containers or trips for a scan, with progress. Started ones first, then not started;
     * finished (100%) and closed ones are marked so the list can hide them.
     */
    public function choiceList(string $modeKey): Collection
    {
        $station = $this->station(null, $modeKey);
        if (! $station) {
            return collect();
        }

        $choices = $station->appChoices()->values();
        // one database question for all of them when the scan can do that
        $many = method_exists($station, 'progressMany') ? $station->progressMany($choices->pluck('id')->all()) : null;

        return $choices->map(function (array $c, int $i) use ($modeKey, $many) {
            $p = $many !== null ? ($many[$c['id']] ?? ['loaded' => 0, 'total' => 0]) : $this->station($c['id'], $modeKey)->progress();
            $done = (int) ($p['loaded'] ?? 0);
            $total = (int) ($p['total'] ?? 0);

            return $c + [
                'done' => $done, 'total' => $total, 'order' => $i,
                'finished' => ! ($c['active'] ?? true) || ($total > 0 && $done >= $total),
            ];
        })->sortBy(fn ($c) => [$c['finished'] ? 2 : ($c['done'] > 0 ? 0 : 1), $c['order']])->values();
    }

    /** "2 waiting" for each scan on the start screen (kept for a minute). */
    protected function waitingCounts(): array
    {
        $user = Auth::user();

        return cache()->remember('scan-app.waiting.'.$user?->id, 60, fn () => collect(array_keys($this->modes()))
            ->mapWithKeys(fn ($key) => [$key => $this->choiceList($key)->where('finished', false)->count()])->all());
    }

    public function home(): void
    {
        cache()->forget('scan-app.waiting.'.Auth::id());
        $this->reset('mode', 'choice', 'returned');
        $this->screen = 'home';
        $this->clearResult();
    }

    public function back(): void
    {
        $this->screen = 'pick';
        $this->choice = null;
        $this->clearResult();
    }

    public function finish(): void
    {
        $this->screen = 'done';
        $this->clearResult();
    }

    public function dismiss(): void
    {
        $this->clearResult();
    }

    protected function clearResult(): void
    {
        $this->reset('status', 'message', 'invoiceId', 'missing', 'condition', 'note', 'boxPhoto', 'early', 'spot', 'route', 'setInfo', 'wrongHub', 'bypass', 'hubTrip', 'pickResult');
    }

    /** Called by the camera or the typed box number. */
    public function scan(string $code): void
    {
        $this->runScan($code);
    }

    /** Trip rules: the reason buttons (or "Ask the office") after "load it anyway". */
    public ?array $bypass = null;

    /** A city top-up the crew said no to (trip id => true). */
    public array $topUpSkipped = [];

    protected function bypassCtx(string $code): array
    {
        $kind = in_array($this->mode, ['wh_load'], true) ? 'transfer' : 'delivery';
        $model = $kind === 'transfer' ? Whdeliverylog::class : Deliverylog::class;

        return ['kind' => $kind, 'trip_id' => $this->choice, 'trip_number' => $this->choice ? $model::whereKey($this->choice)->value('trip_number') : null,
            'invoice_id' => Invoice::where('invoice', $code)->latest('id')->value('id'), 'box' => $code];
    }

    /** After "too early", "wrong hub", "other city" or "truck full": load that box anyway (with a reason, or ask the office). */
    public function loadAnyway(): void
    {
        $code = $this->early['code'] ?? $this->wrongHub['code'] ?? null;
        if (! $code) {
            return;
        }
        $rule = TripRules::ruleOf($this->early, $this->wrongHub);
        $ctx = $this->bypassCtx($code);
        $need = TripRules::need($rule, Auth::user(), $ctx['trip_id'], $ctx['invoice_id']);
        if ($need === 'free') {
            $this->runScan($code, true);

            return;
        }
        $this->bypass = ['rule' => $rule, 'code' => $code, 'need' => $need, 'title' => TripRules::RULES[$rule][0]];
    }

    public function bypassWith(string $reason): void
    {
        if (! $this->bypass || $this->bypass['need'] !== 'reason' || ! in_array($reason, TripRules::reasons(), true)) {
            return;
        }
        $b = $this->bypass;
        TripRules::record($b['rule'], Auth::user(), $reason, $this->bypassCtx($b['code']));
        $this->bypass = null;
        $this->runScan($b['code'], true);
    }

    public function askOffice(): void
    {
        if (! $this->bypass) {
            return;
        }
        $b = $this->bypass;
        TripRules::ask($b['rule'], Auth::user(), null, $this->bypassCtx($b['code']));
        $this->clearResult();
        $this->status = 'warning';
        $this->message = "Asked the office about {$b['code']}. Keep it aside: when they approve, scan it again.";
    }

    public function cancelBypass(): void
    {
        $this->bypass = null;
    }

    /** City top-up at loading: add the suggested city to the trip. */
    public function cityTopUpAdd(string $key): void
    {
        $station = $this->station();
        if ($this->mode === 'load' && $station && method_exists($station, 'addTopUpCity')) {
            $station->data['deliverylog_id'] = $this->choice;
            $station->addTopUpCity($key);
        }
    }

    public function cityTopUpSkip(): void
    {
        $this->topUpSkipped[(int) $this->choice] = true;
    }

    // ------------------------------------------------------------------ sections, truck waiting, sets

    /** Partner hub unload: Add anyway to the full trip (space is an estimate). */
    public function hubAnyway(): void
    {
        $station = $this->station();
        if (! $this->hubTrip || ! $station || ! method_exists($station, 'hubAnyway')) {
            return;
        }
        $station->hubTrip = $this->hubTrip;
        $station->hubAnyway();
        $this->hubTrip = $station->hubTrip;
    }

    /** Unload: take the box off the waiting truck and keep it in its section. */
    public function putInSection(): void
    {
        $station = $this->station();
        if ($this->mode !== 'unload' || ! $this->invoiceId || ! $station || ! method_exists($station, 'putInSection') || ! $station->putInSection($this->invoiceId)) {
            return;
        }
        $this->route = $station->route;
        $this->message = $station->lastMessage;
    }

    /** Unload: put the box on a spot of its section, or Skip (spots are optional, board 50). */
    public function setSpot(?int $spotId = null): void
    {
        $station = $this->station();
        if ($this->mode !== 'unload' || ! $this->invoiceId || ! $station || ! method_exists($station, 'setSpot') || ! $station->setSpot($this->invoiceId, $spotId)) {
            return;
        }
        $this->route = $station->route;
        $this->message = $station->lastMessage;
    }

    /** Unload, TRUCK screen: bring another box of the customer from its section onto the truck too. */
    public function addSetBox(int $boxId): void
    {
        $station = $this->station();
        if ($this->mode !== 'unload' || ! $this->invoiceId || ! $station || ! method_exists($station, 'addSetBox')) {
            return;
        }
        $code = $station->addSetBox($this->invoiceId, $boxId);
        if (! $code) {
            Notification::make()->title('That box cannot go on the truck now (it is on another trip or not in this warehouse).')->warning()->send();

            return;
        }
        $this->setInfo = $station->setInfo;
        Notification::make()->title($code.' added to the truck: bring it and scan it at the truck door (Load transfer truck).')->success()->send();
    }

    /** Load truck, Done screen: room left on the truck, add a waiting box to this trip. */
    public function topUpAdd(int $invoiceId): void
    {
        $station = $this->station();
        if ($this->mode !== 'load' || ! $station || ! $station->appChoices()->contains('id', $this->choice)) {
            return;
        }
        $trip = Deliverylog::with('truck')->find($this->choice);
        if (! $trip || ! TruckSpace::topUp($trip)['boxes']->contains('id', $invoiceId)) {
            Notification::make()->title('That box does not fit or is not free any more.')->warning()->send();

            return;
        }
        try {
            app(TripAssignment::class)->addToDeliveryTrip($trip, Invoice::whereKey($invoiceId)->get());
        } catch (\DomainException $e) {
            Notification::make()->title($e->getMessage())->warning()->send();

            return;
        }
        Notification::make()->title(Invoice::whereKey($invoiceId)->value('invoice').' added to trip '.$trip->trip_number.': scan it onto the truck')->success()->send();
        $this->pick($this->choice);
    }

    /** Count a section, Done screen: close the count. */
    public function closeCount(): void
    {
        $station = $this->station();
        if ($this->mode === 'count' && $station && method_exists($station, 'closeCount') && ($r = $station->closeCount())) {
            Notification::make()->title('Count closed: '.$r['found'].' found, '.count($r['missing']).' missing'.($r['moved'] ? ', '.$r['moved'].' moved in' : ''))->success()->send();
            $this->home();
        }
    }

    /** Receive truck / Receive container, Done screen: boxes not scanned get a Missing box issue. */
    public function finishReceiving(): void
    {
        $station = $this->station();
        if (! $station || ! method_exists($station, 'finishReceiving')) {
            return;
        }
        $made = $station->finishReceiving();
        if ($made === null) {
            return;
        }
        cache()->forget('scan-app.waiting.'.Auth::id());
        Notification::make()->title('Received')->body($made ? $made.' missing '.str('box')->plural($made).': a Missing box issue was opened for each.' : 'Every box arrived.')->success()->send();
        $this->home();
    }

    /** Load truck, Done screen: why a box of a customer's set stays behind. */
    public function splitReason(int $invoiceId, string $reason): void
    {
        $station = $this->station();
        if ($station && method_exists($station, 'recordSplit')) {
            $station->recordSplit($invoiceId, $reason);
        }
    }

    protected function runScan(string $code, bool $force = false): void
    {
        $station = $this->station();
        if (! $station || ! $this->choice || $this->screen !== 'scan') {
            return;
        }

        if ($force && property_exists($station, 'forceLoad')) {
            $station->forceLoad = true;
        }
        $station->scan($code);
        session()->forget('filament.notifications'); // this screen shows its own result

        $this->clearResult();
        $this->status = $station->lastStatus;
        $this->message = $station->lastMessage;
        $this->invoiceId = $station->lastInvoiceId;
        $this->missing = property_exists($station, 'missingCode') ? $station->missingCode : null;
        if (property_exists($station, 'returnedCount')) {
            $this->returned = $station->returnedCount;
        }
        $this->early = property_exists($station, 'early') ? $station->early : null;
        $this->spot = property_exists($station, 'spot') ? $station->spot : null;
        $this->route = property_exists($station, 'route') ? $station->route : null;
        $this->setInfo = property_exists($station, 'setInfo') ? $station->setInfo : null;
        $this->wrongHub = property_exists($station, 'wrongHub') ? $station->wrongHub : null;
        $this->hubTrip = property_exists($station, 'hubTrip') ? $station->hubTrip : null;
        $this->pickResult = property_exists($station, 'pick') ? $station->pick : null;

        if ($this->status === 'success') {
            if ($this->invoiceId && $this->photosOn()) {
                // photos of this box may be sent in the back (ScanPhotoController) for a while
                $ok = collect(session('scan-app.photo-ok', []))->filter(fn ($v) => ($v['at'] ?? 0) > now()->subHours(2)->timestamp)->take(-40)->all();
                $ok[$this->invoiceId] = ['mode' => $this->mode, 'choice' => $this->choice, 'at' => now()->timestamp];
                session(['scan-app.photo-ok' => $ok]);
            }
            $this->sessionScans++;
            $key = 'scan-app.today.'.now()->toDateString();
            session([$key => session($key, 0) + 1]);
        }

        $this->dispatch('scan-app-result', status: $this->status);
    }

    // ------------------------------------------------------------------ photos

    protected function photoStep(): ?string
    {
        return $this->station()?->photoStep();
    }

    public function photosOn(): bool
    {
        $step = $this->photoStep();

        return $step !== null && PhotoSetting::current()->allows($step);
    }

    public function setCondition(?string $condition): void
    {
        $this->condition = array_key_exists((string) $condition, BoxPhoto::CONDITIONS) ? $condition : null;
    }

    public function saveBoxPhoto(): void
    {
        $invoice = $this->status === 'success' && $this->invoiceId ? Invoice::find($this->invoiceId) : null;
        if (! $invoice || ! $this->photosOn()) {
            $this->reset('boxPhoto');

            return;
        }

        $this->validate(['boxPhoto' => 'required|image|max:12288'], ['boxPhoto.image' => 'That file is not a photo.']);

        $station = $this->station();
        BoxPhotos::store($this->boxPhoto, $station->photoStep(), $invoice, $station->photoContext(), Auth::user(), $this->condition, $this->note ?: null);
        $this->reset('boxPhoto');
    }

    /** Photos of the last box at this step. */
    public function shots(): Collection
    {
        $step = $this->photoStep();

        return $this->invoiceId && $step
            ? BoxPhoto::where('invoice_id', $this->invoiceId)->where('step', $step)->orderBy('id')->get()
            : collect();
    }

    // ------------------------------------------------------------------ wrong box

    public function unmanifestedAction(): Action
    {
        return Action::make('unmanifested')
            ->label('Record as unmanifested')
            ->modalHeading(fn () => "Unmanifested box {$this->missing}")
            ->modalDescription('This box is in the container but not on its manifest. Take a photo and add a note.')
            ->schema([
                FileUpload::make('attachment_pic')->label('Photo')->image()->disk('public')->directory('unmanifested')->visibility('private')->required(),
                Textarea::make('remarks')->label('Notes')->rows(3),
            ])
            ->visible(fn () => filled($this->missing) && $this->mode === 'unload')
            ->action(function (array $data): void {
                Unmanifested::create([
                    'invoice' => $this->missing,
                    'container_id' => $this->choice,
                    'attachment_pic' => $data['attachment_pic'] ?? null,
                    'remarks' => $data['remarks'] ?? null,
                ]);
                Notification::make()->title("Unmanifested box {$this->missing} recorded")->success()->send();
                $this->clearResult();
            });
    }

    // ------------------------------------------------------------------ view

    protected function getViewData(): array
    {
        $user = Auth::user();
        $modes = $this->modes();
        $mode = $this->mode();

        $choices = collect();
        $finishedCount = 0;
        if ($this->screen === 'pick' && $mode) {
            $all = $this->choiceList($this->mode);
            $finishedCount = $all->where('finished', true)->count();
            $choices = $this->showFinished ? $all : $all->where('finished', false)->values();
        }

        $progress = ['loaded' => 0, 'total' => 0];
        $target = null;
        $loadNext = null;
        $team = [];
        $trucks = [];
        $openSets = [];
        $countResult = null;
        $receiveResult = null;
        $topUp = null;
        if (in_array($this->screen, ['scan', 'done'], true) && $mode && $this->choice) {
            $station = $this->station();
            $progress = $station->progress();
            $target = ($this->targetInfo['id'] ?? null) === $this->choice ? $this->targetInfo : $station->appChoices()->firstWhere('id', $this->choice);
            $extras = $this->extrasReady || $this->screen === 'done';
            $loadNext = $extras && $this->screen === 'scan' && method_exists($station, 'loadNext') ? $station->loadNext() : null;
            $team = $extras && method_exists($station, 'team') ? $station->team() : [];
            $pickGroups = $this->mode === 'pick' && $this->screen === 'scan' ? $station->groups() : [];
            $trucks = $extras && $this->mode === 'unload' && method_exists($station, 'truckStatus') ? $station->truckStatus() : [];
            $openSets = $this->screen === 'done' && method_exists($station, 'openSets') ? $station->openSets() : [];
            $countResult = $this->screen === 'done' && method_exists($station, 'countResult') ? $station->countResult() : null;
            $receiveResult = $this->screen === 'done' && method_exists($station, 'receiveResult') ? $station->receiveResult() : null;
            // Box sizes: space on the truck while loading (a big box takes more).
            if ($extras && in_array($this->mode, ['load', 'hub_load'], true) && BoxSizes::on() && ($trip = Deliverylog::with('truck')->find($this->choice))) {
                $space = BoxSizes::tripSpace($trip, $this->mode === 'hub_load');
                if ($this->screen === 'done' && $this->mode === 'load' && ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total']) {
                    $topUp = TruckSpace::topUp($trip);
                }
            }
        }

        $todayPhotos = BoxPhoto::where('user_id', $user?->id)->whereDate('taken_at', today());

        return [
            'modes' => $modes,
            'def' => $mode,
            'place' => ScanModes::place($user),
            'firstName' => $user?->first_name ?: 'there',
            'initials' => mb_strtoupper(mb_substr($user?->first_name ?? '', 0, 1).mb_substr($user?->last_name ?? '', 0, 1)) ?: '·',
            'greeting' => now()->hour < 12 ? 'Good morning' : (now()->hour < 18 ? 'Good afternoon' : 'Good evening'),
            'today' => [
                'scans' => (int) session('scan-app.today.'.now()->toDateString(), 0),
                'photos' => (clone $todayPhotos)->count(),
                'problems' => (clone $todayPhotos)->whereIn('condition', ['damaged', 'wet', 'open'])->distinct()->count('invoice_id'),
            ],
            'choices' => $choices,
            'finishedCount' => $finishedCount,
            'waiting' => $this->screen === 'home' ? $this->waitingCounts() : [],
            'progress' => $progress,
            'target' => $target,
            'loadNext' => $loadNext,
            'team' => $team,
            'trucks' => $trucks,
            'openSets' => $openSets,
            'countResult' => $countResult,
            'receiveResult' => $receiveResult,
            'topUp' => $topUp,
            'extrasReady' => $this->extrasReady || $this->screen !== 'scan',
            'paused' => $this->screen === 'scan' && (($this->status !== null && ($this->status !== 'success' || $this->photosOn())) || $this->bypass !== null),
            'cityTopUp' => $this->extrasReady && $this->mode === 'load' && $this->choice && empty($this->topUpSkipped[(int) $this->choice]) && ($st = $this->station()) && method_exists($st, 'cityTopUp')
                ? (function () use ($st) {
                    $st->data['deliverylog_id'] = $this->choice;

                    return $st->cityTopUp();
                })() : null,
            'bypassReasons' => TripRules::reasons(),
            'noReason' => collect($openSets)->filter(fn ($o) => collect($o['missing'])->contains(fn ($m) => ! $m['reason']))->count(),
            'splitReasons' => SetSplit::REASONS,
            'box' => $box = ($this->invoiceId ? Invoice::find($this->invoiceId) : null),
            'space' => $space ?? null,
            'pickGroups' => $pickGroups ?? [],
            'boxSize' => $box && BoxSizes::on() ? ['name' => BoxSizes::nameOfType($box->boxtype), 'space' => BoxSizes::spaceOf($box->boxtype)] : null,
            'conditions' => BoxPhoto::CONDITIONS,
            'shots' => $this->status === 'success' ? $this->shots() : collect(),
            ...$this->aiPhotoFlag(),
        ];
    }

    /** AI photo check: the newest photo of this person that the AI thinks looks damaged while they marked it Good. */
    protected function aiPhotoFlag(): array
    {
        if ($this->screen !== 'scan' || ! Ai::switchedOn('photo_check')) {
            return ['aiFlag' => null, 'aiPending' => false];
        }
        $mine = AiPhotoCheck::where('source', 'scan')
            ->whereIn('box_photo_id', BoxPhoto::where('user_id', Auth::id())->where('taken_at', '>=', now()->subMinutes(20))->select('id'));

        return [
            'aiFlag' => (clone $mine)->where('flagged', true)->whereNull('decision')
                ->where(fn ($q) => $q->whereNull('worker_said')->orWhere('worker_said', 'good'))->latest('id')->first(),
            'aiPending' => (clone $mine)->whereNull('checked_at')->where('created_at', '>=', now()->subMinutes(3))->exists(),
        ];
    }

    public function aiFlagAnswer(int $id, bool $damaged): void
    {
        $check = AiPhotoCheck::whereIn('box_photo_id', BoxPhoto::where('user_id', Auth::id())->select('id'))->find($id);
        if (! $check || $check->decision) {
            return;
        }
        if ($damaged) {
            BoxPhoto::whereKey($check->box_photo_id)->update(['condition' => $check->verdict === 'wet' ? 'wet' : ($check->verdict === 'open' ? 'open' : 'damaged')]);
            PhotoCheck::confirm($check, Auth::user());
        } else {
            PhotoCheck::dismiss($check, Auth::user());
        }
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Shared/LoadTripPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/LoadTripPage.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Invoice;
use Filament\Notifications\Notification;
use App\Models\Tripinvoice;
use App\Models\Boxes\SetSplit;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Boxes\BoxSets;
use App\Support\Maps\LoadOrder;
use App\Support\Maps\TripSorter;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station: crew scans each box as it goes onto the truck of a trip.
 *
 * Used by the admin hub (Scanload), the warehouse hub (Hubloaded) and partner
 * hubs (LoadTruck, which loads boxes handed over to the hub's own trips).
 */
abstract class LoadTripPage extends Page
{
    use ScansInvoices;
    use \App\Filament\Concerns\BypassesTripRules;

    protected string $view = 'filament.pages.scanload';

    protected static string|\BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowUpTray;

    /** Partner-hub mode: invoices are linked via deliveryloghub_id / is_loaded_hub. */
    protected static bool $atHub = false;

    /** Set by "Load it anyway" after a "too early" warning. */
    public bool $forceLoad = false;

    /** The last box that was too early to load (see LoadOrder). */
    public ?array $early = null;

    /** Where the box just loaded goes: ['zone' => 'front', 'stop' => 7]. */
    public ?array $spot = null;

    /** The box is for another hub than the trip goes to. */
    public ?array $wrongHub = null;

    /** The box's set on this truck: "Maria Santos · 2 of 3 · still to load X-103 (C)". */
    public ?array $setInfo = null;

    public function mount(): void
    {
        $this->form->fill();
    }

    protected function tripColumn(): string
    {
        return static::$atHub ? 'deliveryloghub_id' : 'deliverylog_id';
    }

    protected function loadedColumn(): string
    {
        return static::$atHub ? 'is_loaded_hub' : 'is_loaded';
    }

    protected function tripOptionsQuery(): Builder
    {
        return Deliverylog::query()
            ->with('destination:id,hub_name')
            ->where('logistichub_id', Auth::user()->logistichub_id)
            ->whereNotNull('truck_id')
            ->where('is_active', true)
            ->latest('id');
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('deliverylog_id')
                    ->label('Trip')
                    ->placeholder('Choose the trip you are loading')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage'))
                    ->options(fn () => $this->tripOptionsQuery()
                        ->get()
                        ->mapWithKeys(fn (Deliverylog $trip) => [
                            $trip->id => $trip->trip_number.($trip->destination ? ' → '.$trip->destination->hub_name : ''),
                        ])),
            ]);
    }

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a trip';
    }

    /** The selected trip, re-checked against what this user may load. */
    protected function selectedTrip(): ?Deliverylog
    {
        return $this->tripOptionsQuery()->find($this->data['deliverylog_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $trip = $this->selectedTrip();

        if (! $trip) {
            $this->scanResult('danger', 'That trip is no longer open for loading.');

            return;
        }

        $tripinvoice = Tripinvoice::with('invdata')
            ->where($this->tripColumn(), $trip->id)
            ->where('invoice', $code)
            ->latest('id')
            ->first();

        $this->bypass = null;
        $box = $tripinvoice?->invdata ?? Invoice::where('invoice', $code)->where('is_delivered', false)->latest('id')->first();
        // Truck full: the box does not fit in the truck's space (only for trucks with a space set).
        if ($box && ! static::$atHub && ! $tripinvoice?->{$this->loadedColumn()} && ($full = \App\Support\Trips\TripSpace::overFull($trip, $box))
            && ! $this->skips('truck_full', $trip->id, $box->id)) {
            $this->early = null;
            $this->wrongHub = ['kind' => 'full', 'code' => $code, 'for' => $full['used'].' of '.$full['cap'].' space used', 'section' => $box->whSection?->code ?? '—',
                'color' => $box->whSection?->color, 'trip' => $trip->trip_number, 'space' => $full['space'], 'province' => $box->receiver_province];
            $this->scanResult('warning', "Truck full: {$code} does not fit ({$full['used']} of {$full['cap']} space used).", $box);

            return;
        }

        // Trip planned by city: a waiting box of one of its cities joins the trip now.
        $cityTrip = ! static::$atHub && \App\Support\Trips\CityTrips::isCityTrip($trip);
        if (! $tripinvoice && $cityTrip) {
            [$joined, $why] = \App\Support\Trips\CityTrips::join($trip, $code, $box ? $this->skips('topup_other', $trip->id, $box->id) : $this->forceLoad,
                $box ? $this->skips('direct_hub', $trip->id, $box->id) : false);
            if ($joined) {
                $tripinvoice = $joined;
            } elseif ($why === 'other-city') {
                $inv = Invoice::where('invoice', $code)->latest('id')->first();
                $place = \Illuminate\Support\Str::title(trim($inv?->receiver_city.', '.$inv?->receiver_province, ', '));
                $this->early = null;
                $this->wrongHub = ['kind' => 'city', 'code' => $code, 'for' => $place, 'section' => $inv?->whSection?->code ?? '—', 'color' => $inv?->whSection?->color,
                    'trip' => \App\Models\TripCity::where('deliverylog_id', $trip->id)->pluck('city')->join(', ')];
                $this->forceLoad = false;
                $this->scanResult('warning', "Other city: {$code} is for {$place}. Trip {$trip->trip_number} goes to {$this->wrongHub['trip']}.", $inv);

                return;
            } elseif (is_string($why) && str_starts_with($why, 'hub:')) {
                // the box goes to a partner hub, or is ours while this trip goes to a hub
                $inv = Invoice::where('invoice', $code)->latest('id')->first();
                $hubId = (int) substr($why, 4);
                $place = \Illuminate\Support\Str::title(trim($inv?->receiver_city.', '.$inv?->receiver_province, ', '));
                $goes = $hubId ? \App\Support\Hubs\HubAreas::name($hubId) : 'our own trucks (direct to the customer)';
                $this->early = null;
                $this->wrongHub = ['kind' => 'hub', 'code' => $code, 'for' => $place, 'home' => $goes, 'section' => $inv?->whSection?->code ?? '—', 'color' => $inv?->whSection?->color,
                    'trip' => $trip->trip_number];
                $this->forceLoad = false;
                $this->scanResult('warning', "Not for this trip: {$code} ({$place}) goes ".($hubId ? "to {$goes}" : 'with our own trucks').'.', $inv);

                return;
            } elseif ($why) {
                $this->scanResult('danger', $why, $this->invoicesMatching($code)->first());

                return;
            }
        }

        if (! $tripinvoice && static::$atHub && $box && \App\Support\Hubs\HubAreas::ready()
            && ($other = \App\Support\Hubs\HubAreas::hubOf($box)) && $other !== (int) Auth::user()?->logistichub_id) {
            // a box of another hub's area came to this hub by mistake
            $mine = \App\Support\Hubs\HubAreas::name((int) Auth::user()?->logistichub_id);
            $place = \Illuminate\Support\Str::title(trim($box->receiver_city.', '.$box->receiver_province, ', '));
            $this->scanResult('danger', "Not for {$mine}: {$code} is for ".\App\Support\Hubs\HubAreas::name($other)." ({$place}). Not loaded: put it aside and tell the office.", $box);

            return;
        }

        if (! $tripinvoice) {
            $elsewhere = Tripinvoice::with(['deliverylog:id,trip_number', 'invdata'])
                ->where('invoice', $code)
                ->latest('id')
                ->first();

            $this->scanResult(
                'danger',
                $elsewhere
                    ? "{$code} belongs to trip {$elsewhere->deliverylog?->trip_number}, not {$trip->trip_number}."
                    : "{$code} is not on trip {$trip->trip_number}.",
                $elsewhere?->invdata ?? $this->invoicesMatching($code)->first(),
            );

            return;
        }

        if (static::$atHub && \App\Support\Shipping\Shipments::ready() && ($sea = \App\Support\Shipping\Shipments::stillAtSea($tripinvoice))) {
            $this->scanResult('danger', "{$code} is still on sea shipment {$sea->code}".($sea->eta ? ' (arriving about '.$sea->eta->format('M j').')' : '').'. Receive the container first (Scan app → Receive container).', $tripinvoice->invdata);

            return;
        }

        if ($tripinvoice->{$this->loadedColumn()}) {
            $who = $tripinvoice->loaded_by && $tripinvoice->loaded_by !== Auth::id() ? User::find($tripinvoice->loaded_by)?->first_name : null;
            $when = $tripinvoice->loaded_at ? \Illuminate\Support\Carbon::parse($tripinvoice->loaded_at)->format('g:i A') : null;
            $this->scanResult('warning', "{$code} was already loaded".($who ? " by {$who}" : '').($when ? " at {$when}" : '').'. Not counted again.', $tripinvoice->invdata);

            return;
        }

        $this->early = null;
        $this->spot = null;
        $this->wrongHub = null;
        $this->setInfo = null;
        if (! $this->skips('wrong_hub', $trip->id, $tripinvoice->invoice_id) && ($wrong = $this->wrongHubFor($trip, $tripinvoice))) {
            $this->wrongHub = $wrong;
            $this->scanResult('warning', "Wrong hub: {$code} is for {$wrong['for']} (section {$wrong['section']}). This trip goes to {$wrong['trip']}.", $tripinvoice->invdata);

            return;
        }
        if (! $this->skips('load_order', $trip->id, $tripinvoice->invoice_id) && ! $cityTrip && ($early = LoadOrder::tooEarly($trip, $tripinvoice, static::$atHub))) {
            $this->early = $early;
            $this->scanResult('warning', "Too early: {$code} is for stop {$early['stop']}".($early['place'] ? " ({$early['place']})" : '').'. It goes in later, nearer the door. Load stop '.$early['nextStop'].' first.', $tripinvoice->invdata);

            return;
        }
        $this->forceLoad = false;

        app(TripAssignment::class)->markLoaded($tripinvoice, atHub: static::$atHub);
        $tripinvoice->forceFill(['loaded_by' => Auth::id(), 'loaded_at' => now()])->saveQuietly();
        $this->spot = TripSorter::zoneMap($trip)[$tripinvoice->id] ?? null;
        // One container, more hubs: the hub that unloads last goes deep inside.
        if (! $this->spot && ! static::$atHub && \App\Support\Shipping\Shipments::ready()) {
            $this->spot = \App\Support\Shipping\Shipments::loadZone($trip->id);
        }
        if ($tripinvoice->invdata) {
            $this->setInfo = BoxSets::onTrip($tripinvoice->invdata, $trip, $this->tripColumn(), $this->loadedColumn());
        }

        $this->scanResult('success', "{$code} loaded.", $tripinvoice->invdata);
    }

    /** The box's section is for another partner hub than the one this trip goes to. */
    protected function wrongHubFor(Deliverylog $trip, Tripinvoice $tripinvoice): ?array
    {
        $section = $tripinvoice->invdata?->whSection;
        $to = static::$atHub ? null : $trip->assigned_to;
        if (! $section || ! $section->logistichub_id || ! $to || (int) $section->logistichub_id === (int) $to) {
            return null;
        }

        return ['code' => $tripinvoice->invoice, 'for' => $section->name ?: $section->goesTo(), 'section' => $section->code, 'color' => $section->color,
            'trip' => $trip->destination?->hub_name ?? 'another hub'];
    }

    /**
     * Trip by city, every waiting box of its cities loaded, and room left: the best nearby city to top up with.
     *
     * @return array{room: int, key: string, city: string, province: string, boxes: int, days: int, section: ?string}|null
     */
    public function cityTopUp(): ?array
    {
        $trip = $this->selectedTrip();
        if (! $trip || static::$atHub || $trip->is_lock || ! \App\Support\Trips\CityTrips::isCityTrip($trip)) {
            return null;
        }
        $mine = \App\Models\TripCity::where('deliverylog_id', $trip->id)->get();
        $keys = $mine->map(fn ($c) => \Illuminate\Support\Str::lower((string) $c->province).'|'.$c->city_key)->flip();
        $ct = new \App\Support\Trips\CityTrips(Auth::user());
        $places = $ct->places();
        if ($places->contains(fn ($p) => isset($keys[$p['key']])) || ! Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->exists()) {
            return null; // still boxes of its own cities to load
        }
        $cap = \App\Support\Trips\TripSpace::capacity($trip) ?? \App\Support\TruckSpace::capacity($trip->truck);
        $room = (int) floor($cap - \App\Support\Trips\TripSpace::used($trip));
        if ($room < 5) {
            return null;
        }
        $covered = $ct->covered();
        $prov = \Illuminate\Support\Str::lower((string) $mine->first()?->province);
        $best = $places->reject(fn ($p) => $p['unclear'] || isset($keys[$p['key']]) || isset($covered[$p['key']]) || $p['space'] > $room)
            ->sortBy(fn ($p) => [\Illuminate\Support\Str::lower($p['province']) === $prov ? 0 : 1, -$p['days'], -$p['boxes']])->first();
        if (! $best) {
            return null;
        }
        $section = Invoice::where('is_verified', true)->where('is_assigned', false)->where('receiver_city', 'like', '%'.\Illuminate\Support\Str::before($best['city'], ' ').'%')
            ->whereNotNull('wh_section_id')->with('whSection')->first()?->whSection?->code;

        return ['room' => $room, 'key' => $best['key'], 'city' => $best['city'], 'province' => $best['province'], 'boxes' => $best['boxes'], 'days' => $best['days'], 'section' => $section,
            'same' => \Illuminate\Support\Str::lower($best['province']) === $prov];
    }

    /** Add the suggested city: its boxes join when scanned. */
    public function addTopUpCity(string $key): void
    {
        $trip = $this->selectedTrip();
        $top = $this->cityTopUp();
        if (! $trip || ! $top || $top['key'] !== $key) {
            Notification::make()->title('That top-up is not possible any more.')->warning()->send();

            return;
        }
        \App\Models\TripCity::create(['deliverylog_id' => $trip->id, 'province' => $top['province'], 'city' => $top['city'],
            'city_key' => \Illuminate\Support\Str::after($key, '|'), 'planned_boxes' => $top['boxes']]);
        Notification::make()->title($top['city'].' added to '.$trip->trip_number.': scan its '.$top['boxes'].' boxes'.($top['section'] ? ' (section '.$top['section'].')' : ''))->success()->send();
    }

    /** Customers whose boxes are not all on the truck, for the Done screen. */
    public function openSets(): array
    {
        $trip = $this->selectedTrip();

        return $trip ? BoxSets::openOnTrip($trip, $this->tripColumn(), $this->loadedColumn()) : [];
    }

    /** Why a box of a set stays behind. */
    public function recordSplit(int $invoiceId, string $reason): bool
    {
        $trip = $this->selectedTrip();
        if (! $trip || ! array_key_exists($reason, SetSplit::REASONS)) {
            return false;
        }
        $ok = collect($this->openSets())->pluck('missing')->flatten(1)->contains('id', $invoiceId);
        if (! $ok) {
            return false;
        }
        $need = \App\Support\Trips\TripRules::need('split_set', Auth::user(), $trip->id, $invoiceId);
        $ctx = ['trip_id' => $trip->id, 'trip_number' => $trip->trip_number, 'invoice_id' => $invoiceId, 'box' => Invoice::whereKey($invoiceId)->value('invoice'), 'data' => ['split' => $reason]];
        if ($need === 'office') {
            \App\Support\Trips\TripRules::ask('split_set', Auth::user(), SetSplit::REASONS[$reason], $ctx);

            return true;
        }
        if ($need === 'reason' && ! SetSplit::where('invoice_id', $invoiceId)->where('deliverylog_id', $trip->id)->exists()) {
            \App\Support\Trips\TripRules::record('split_set', Auth::user(), SetSplit::REASONS[$reason], $ctx);
        }
        $split = SetSplit::updateOrCreate(['invoice_id' => $invoiceId, 'deliverylog_id' => $trip->id],
            ['reason' => $reason, 'user_id' => Auth::id(), 'set_key' => Invoice::whereKey($invoiceId)->value('set_key')]);
        if ($split->wasRecentlyCreated) {
            BoxSets::textRestFollows($split, $trip, $this->tripColumn(), $this->loadedColumn());
        }

        return true;
    }

    /** Who loaded how many boxes on this trip. */
    public function team(): array
    {
        $id = $this->data['deliverylog_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = Tripinvoice::where($this->tripColumn(), $id)->where($this->loadedColumn(), true)->whereNotNull('loaded_by')
            ->selectRaw('loaded_by, count(*) n')->groupBy('loaded_by')->pluck('n', 'loaded_by');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }


    /** What to load next on the selected trip (null when the trip has no sorted stops). */
    public function loadNext(): ?array
    {
        $trip = $this->selectedTrip();

        return $trip ? LoadOrder::next($trip, static::$atHub) : null;
    }

    /** @return array{loaded: int, total: int} */
    public function progress(): array
    {
        $tripId = $this->data['deliverylog_id'] ?? null;

        if (! $tripId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $query = Tripinvoice::where($this->tripColumn(), $tripId);

        return [
            'loaded' => (clone $query)->where($this->loadedColumn(), true)->count(),
            'total' => $query->count(),
            'last' => (clone $query)->where($this->loadedColumn(), true)->max('updated_at'),
        ];
    }

    /**
     * Progress of many trips in one database question (the Scan app trip list).
     *
     * @param  list<int>  $ids
     * @return array<int, array{loaded: int, total: int}>
     */
    public function progressMany(array $ids): array
    {
        if (! $ids) {
            return [];
        }
        $col = $this->tripColumn();
        $loaded = $this->loadedColumn();

        return Tripinvoice::whereIn($col, $ids)->selectRaw("{$col} as t, count(*) as total, sum(case when {$loaded} = 1 then 1 else 0 end) as loaded")
            ->groupBy($col)->toBase()->get()
            ->mapWithKeys(fn ($r) => [(int) $r->t => ['loaded' => (int) $r->loaded, 'total' => (int) $r->total]])->all();
    }

    public function household(): array
    {
        $tripId = (int) ($this->data['deliverylog_id'] ?? 0);

        return $this->householdRows($this->lastInvoice(), function (Invoice $box) use ($tripId): array {
            $onTrip = Tripinvoice::with('deliverylog:id,trip_number')->where('invoice_id', $box->id)->latest('id')->first();

            return [
                'trip' => $onTrip?->deliverylog?->trip_number,
                'done' => (bool) ($onTrip?->{$this->loadedColumn()} && (int) $onTrip->{$this->tripColumn()} === $tripId),
            ];
        });
    }

    public function photoStep(): ?string
    {
        return static::$atHub ? 'hub_load' : 'load';
    }

    public function photoContext(): array
    {
        return [
            'deliverylog_id' => $this->data['deliverylog_id'] ?? null,
            'warehouse_id' => Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        return $this->tripOptionsQuery()->latest('id')->limit(60)->get()
            ->map(fn (Deliverylog $t) => ['id' => $t->id, 'name' => 'Trip '.$t->trip_number, 'active' => (bool) ($t->is_active ?? true),
                'sub' => $t->destination?->hub_name ? 'To '.$t->destination->hub_name : ($t->departure_date ? 'Leaves '.$t->departure_date : null)]);
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Shared/UnloadContainerPage.php
mkdir -p 'app/Filament/Shared'
cat > 'app/Filament/Shared/UnloadContainerPage.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Shared;

use App\Filament\Concerns\ScansInvoices;
use App\Models\Boxes\WhSection;
use App\Models\Boxes\WhSpot;
use App\Models\Boxissue;
use App\Models\Container;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Unmanifested;
use App\Models\User;
use App\Models\Whtripinvoice;
use App\Support\Boxes\BoxSets;
use App\Support\Boxes\Crossdock;
use App\Support\Boxes\Sections;
use App\Support\Boxes\TruckSets;
use App\Support\Warehouses\Coverage;
use Filament\Actions\Action;
use Filament\Forms\Components\FileUpload;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Livewire\Attributes\Locked;

/**
 * Scan station for unloading a shipping container: every box scanned is
 * marked verified. Boxes that are damaged can be reported, and boxes that
 * are not on the manifest can be recorded as unmanifested.
 */
abstract class UnloadContainerPage extends Page
{
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    /** The last code that was not found in the container (for the unmanifested form). */
    #[Locked]
    public ?string $missingCode = null;

    /** Where the box just scanned goes: a section tile, or the waiting truck. */
    public ?array $route = null;

    /** The box's set: "Maria Santos · 2 of 3 · 1 more still in this container". */
    public ?array $setInfo = null;

    abstract protected function containerQuery(): Builder;

    public function mount(): void
    {
        $this->form->fill();
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->statePath('data')
            ->components([
                Select::make('container_id')
                    ->label('Container')
                    ->placeholder('Choose the container you are unloading')
                    ->searchable()
                    ->live()
                    ->required()
                    ->afterStateUpdated(fn () => $this->reset('lastInvoiceId', 'lastStatus', 'lastMessage', 'missingCode'))
                    ->options(fn () => $this->containerQuery()
                        ->with('consolidator:id,company_name')
                        ->latest('id')
                        ->get()
                        ->mapWithKeys(fn (Container $container) => [
                            $container->id => collect([
                                $container->container_no,
                                $container->batch_no ? 'batch '.$container->batch_no : null,
                                $container->batch_year,
                                $container->consolidator?->company_name,
                            ])->filter()->join(' · '),
                        ])),
            ]);
    }

    protected function selectionField(): ?string
    {
        return 'container_id';
    }

    protected function selectionLabel(): string
    {
        return 'a container';
    }

    public function stationHeading(): string
    {
        return 'Unload the container';
    }

    public function stationDescription(): string
    {
        return 'Pick the container, then scan each box as it comes off. Scanned boxes are marked verified.';
    }

    public function stationIcon(): string
    {
        return 'heroicon-o-archive-box-arrow-down';
    }

    public function progressLabel(): string
    {
        return 'Boxes verified in this container';
    }

    protected function selectedContainer(): ?Container
    {
        return $this->containerQuery()->find($this->data['container_id'] ?? null);
    }

    protected function handleScan(string $code): void
    {
        $container = $this->selectedContainer();

        if (! $container) {
            $this->scanResult('danger', 'That container is not available any more.');

            return;
        }

        $this->missingCode = null;
        $this->route = null;
        $this->setInfo = null;

        if ($section = Sections::fromCode($code)) {
            $this->placeInSection($container, $section);

            return;
        }
        if ($spot = Sections::spotFromCode($code)) {
            $this->placeOnSpot($container, $spot);

            return;
        }

        $invoice = Invoice::where('container_id', $container->id)->where('invoice', $code)->first();

        if (! $invoice) {
            $this->missingCode = $code;
            $other = $this->invoicesMatching($code)->first();

            $this->scanResult(
                'danger',
                $other
                    ? "{$code} is manifested in another container ({$other->container?->container_no})."
                    : "{$code} is not on this container's manifest.",
                $other,
            );

            return;
        }

        if ($invoice->is_verified) {
            $who = $invoice->verified_by && $invoice->verified_by !== Auth::id() ? User::find($invoice->verified_by)?->first_name : null;
            $when = $invoice->verified_at ? Carbon::parse($invoice->verified_at)->format('g:i A') : null;
            $this->route = Sections::tile($invoice->whSection);
            $this->scanResult('warning', "{$code} was already verified".($who ? " by {$who}" : '').($when ? " at {$when}" : '').'. Not counted again.', $invoice);

            return;
        }

        $invoice->forceFill(['is_verified' => true, 'verified_at' => now(), 'verified_by' => Auth::id()])->save();

        $this->scanResult('success', $this->sendToSection($container, $invoice), $invoice);
    }

    /** After the box is verified: pick its section, or load it straight onto the waiting truck. */
    protected function sendToSection(Container $container, Invoice $invoice): string
    {
        $code = $invoice->invoice;
        $warehouseId = $this->warehouseId($container);
        $section = Sections::forInvoice($invoice, $warehouseId);
        $this->setInfo = BoxSets::atUnload($invoice);

        // Two warehouses: a box that another warehouse delivers goes to the transfer for it.
        if ($home = Coverage::transferTo($invoice, $warehouseId)) {
            $to = Sections::of($warehouseId)->first(fn ($s) => (int) $s->to_warehouse_id === $home);
            if ($to) {
                $section = $to;
            } else {
                $name = Coverage::name($home);
                $invoice->forceFill(['wh_section_id' => null, 'sectioned_at' => now()])->save();
                $this->route = ['kind' => 'transfer', 'code' => 'T', 'name' => 'Transfer → '.$name, 'color' => '#c97a00'];

                return "{$code} verified · transfer to {$name}.";
            }
        }

        if (! $section) {
            return "{$code} verified.";
        }

        if ($trip = Crossdock::load($invoice, $warehouseId, $section)) {
            $invoice->forceFill(['wh_section_id' => $section->id, 'sectioned_at' => null])->save();
            $this->route = ['kind' => 'truck', 'code' => 'TRUCK', 'name' => $trip->warehouse?->name ?? $section->goesTo(), 'trip' => $trip->trip_number, 'plate' => $trip->truck?->plate_no, 'color' => '#e2700c'];
            $this->setInfo = TruckSets::card($invoice, $trip, $warehouseId) ?? $this->setInfo;

            return "{$code} verified · onto truck {$trip->trip_number}.";
        }

        $label = Sections::labelScan($warehouseId);
        $invoice->forceFill(['wh_section_id' => $section->id, 'sectioned_at' => $label ? null : now()]
            + (\Illuminate\Support\Facades\Schema::hasColumn('invoices', 'wh_spot_id') ? ['wh_spot_id' => null] : []))->save();
        $this->route = Sections::tile($section) + ['pending' => $label, 'why' => $section->kind === 'check' ? Sections::whyCheck($invoice) : null]
            + $this->spotChoice($section, $invoice);

        return "{$code} verified · section {$section->code}.";
    }

    /** Spots of the section (optional, board 50): the crew scans the spot's QR, taps one, or skips. */
    protected function spotChoice(WhSection $section, Invoice $invoice): array
    {
        $spots = Sections::spotsOf($section);

        return $spots->isEmpty() ? [] : ['spots' => $spots->map(fn ($p) => ['id' => $p->id, 'code' => $p->code])->values()->all(), 'spot' => null, 'invoiceId' => $invoice->id];
    }

    /** Put the box on a spot of its section, or no spot (Skip). */
    public function setSpot(int $invoiceId, ?int $spotId): bool
    {
        $container = $this->selectedContainer();
        $invoice = $container ? Invoice::where('container_id', $container->id)->find($invoiceId) : null;
        if (! $invoice || ! $invoice->wh_section_id) {
            return false;
        }
        $spot = $spotId ? WhSpot::where('wh_section_id', $invoice->wh_section_id)->find($spotId) : null;
        if ($spotId && ! $spot) {
            return false;
        }
        $invoice->forceFill(['wh_spot_id' => $spot?->id])->save();
        $section = $invoice->whSection;
        $this->route = Sections::tile($section) + $this->spotChoice($section, $invoice);
        $this->route['spot'] = $spot?->code ?? 'skip';
        $this->lastInvoiceId = $invoice->id;
        $this->lastStatus = 'success';
        $this->lastMessage = $spot ? "{$invoice->invoice} on spot {$spot->code}." : "{$invoice->invoice} in section {$section?->code} (no spot).";

        return true;
    }

    /** A spot's QR was scanned: the last box this person scanned for that section goes on it. */
    protected function placeOnSpot(Container $container, WhSpot $spot): void
    {
        $box = Invoice::where('container_id', $container->id)->where('verified_by', Auth::id())->where('wh_section_id', $spot->wh_section_id)
            ->orderByDesc('verified_at')->orderByDesc('id')->first();
        $this->route = Sections::tile($spot->section);
        if (! $box) {
            $this->scanResult('warning', "Spot {$spot->code}: none of your boxes are for section {$spot->section?->code}.");

            return;
        }
        $this->setSpot($box->id, $spot->id);
        $this->scanResult('success', "{$box->invoice} on spot {$spot->code}.", $box);
        $this->route = Sections::tile($spot->section) + $this->spotChoice($spot->section, $box);
        $this->route['spot'] = $spot->code;
    }

    /** Section-label scan (when switched on): the boxes this person scanned for that section are now there. */
    protected function placeInSection(Container $container, WhSection $section): void
    {
        $warehouseId = $this->warehouseId($container);
        if (! Sections::labelScan($warehouseId)) {
            $this->scanResult('warning', 'The section label scan is off: boxes are saved in their section when you scan them.');

            return;
        }
        $pending = Invoice::where('container_id', $container->id)->where('verified_by', Auth::id())
            ->whereNotNull('wh_section_id')->whereNull('sectioned_at')->get();
        $here = Crossdock::here($warehouseId)->pluck('id');
        if ($here->isNotEmpty()) {
            $onTruck = Whtripinvoice::whereIn('whdeliverylog_id', $here)->whereIn('invoice_id', $pending->pluck('id'))->pluck('invoice_id')->all();
            $pending = $pending->reject(fn ($b) => in_array($b->id, $onTruck, true));
        }
        $mine = $pending->where('wh_section_id', $section->id);
        $other = $pending->where('wh_section_id', '!=', $section->id);
        $this->route = Sections::tile($section);

        if ($mine->isEmpty()) {
            $this->scanResult('warning', $other->isNotEmpty()
                ? 'Wrong section: your '.$other->count().' '.str('box')->plural($other->count()).' '.($other->count() === 1 ? 'is' : 'are').' for '.$other->map(fn ($b) => $b->whSection?->code)->unique()->join(', ').', not '.$section->code.'.'
                : "Section {$section->code}: none of your boxes are waiting for it.");

            return;
        }
        Invoice::whereIn('id', $mine->pluck('id'))->update(['sectioned_at' => now()]);
        $this->scanResult('success', $mine->count().' '.str('box')->plural($mine->count())." saved in section {$section->code}"
            .($other->isNotEmpty() ? ' · '.$other->count().' still for '.$other->map(fn ($b) => $b->whSection?->code)->unique()->join(', ') : '').'.');
    }

    protected function warehouseId(?Container $container): ?int
    {
        return $container?->warehouse_id ?? Auth::user()?->warehouse_id;
    }

    // ------------------------------------------------------------------ truck here (switched on in the transfer trip)

    /** "Put in section instead": take the box off the truck and keep it in its section. */
    public function putInSection(int $invoiceId): bool
    {
        $container = $this->selectedContainer();
        $invoice = $container ? Invoice::where('container_id', $container->id)->find($invoiceId) : null;
        $trip = $invoice ? Crossdock::tripOf($invoice, $this->warehouseId($container)) : null;
        if (! $trip || ! Crossdock::unload($invoice, $trip)) {
            return false;
        }
        $section = $invoice->whSection ?? Sections::forInvoice($invoice, $this->warehouseId($container));
        $invoice->forceFill(['wh_section_id' => $section?->id, 'sectioned_at' => now()])->save();
        $this->route = Sections::tile($section);
        $this->lastInvoiceId = $invoice->id;
        $this->lastStatus = 'success';
        $this->lastMessage = "{$invoice->invoice} stays in section ".($section?->code ?? '').'. It goes on the next truck.';

        return true;
    }

    /** TRUCK screen: "Bring it to the truck too" for another box of the customer that is in its section. */
    public function addSetBox(int $ofInvoiceId, int $boxId): ?string
    {
        $container = $this->selectedContainer();
        $of = $container ? Invoice::where('container_id', $container->id)->find($ofInvoiceId) : null;
        $warehouseId = $this->warehouseId($container);
        $trip = $of ? Crossdock::tripOf($of, $warehouseId) : null;
        $box = $trip ? TruckSets::add($of, $boxId, $trip, $warehouseId) : null;
        if (! $box) {
            return null;
        }
        $this->setInfo = TruckSets::card($of, $trip, $warehouseId);

        return $box->invoice;
    }

    /** The trucks here now at this warehouse (switched on in their transfer trip). */
    public function truckStatus(): array
    {
        return Crossdock::status($this->warehouseId($this->selectedContainer()));
    }

    /** Who scanned how many boxes off this container. */
    public function team(): array
    {
        $id = $this->data['container_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = Invoice::where('container_id', $id)->whereNotNull('verified_by')->selectRaw('verified_by, count(*) n')->groupBy('verified_by')->pluck('n', 'verified_by');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    /** @return array{loaded: int, total: int, last?: ?string, issues?: int, unmanifested?: int} */
    /**
     * Progress of many containers in one database question (the Scan app list).
     *
     * @param  list<int>  $ids
     * @return array<int, array{loaded: int, total: int}>
     */
    public function progressMany(array $ids): array
    {
        if (! $ids) {
            return [];
        }

        return Invoice::whereIn('container_id', $ids)->selectRaw('container_id as c, count(*) as total, sum(case when is_verified = 1 then 1 else 0 end) as loaded')
            ->groupBy('container_id')->toBase()->get()
            ->mapWithKeys(fn ($r) => [(int) $r->c => ['loaded' => (int) $r->loaded, 'total' => (int) $r->total]])->all();
    }

    public function progress(): array
    {
        $containerId = $this->data['container_id'] ?? null;

        if (! $containerId) {
            return ['loaded' => 0, 'total' => 0];
        }

        $query = Invoice::where('container_id', $containerId);

        return [
            'loaded' => (clone $query)->where('is_verified', true)->count(),
            'total' => $query->count(),
            'last' => (clone $query)->max('verified_at'),
            'issues' => Invoiceissue::where('container_id', $containerId)->count(),
            'unmanifested' => Unmanifested::where('container_id', $containerId)->count(),
        ];
    }

    public function household(): array
    {
        return $this->householdRows($this->lastInvoice(), fn (Invoice $box) => [
            'trip' => $box->is_verified ? 'Verified' : 'Not scanned yet',
            'done' => (bool) $box->is_verified,
        ]);
    }

    public function reportIssueAction(): Action
    {
        return Action::make('reportIssue')
            ->label('Report a problem')
            ->icon(Heroicon::OutlinedExclamationTriangle)
            ->color('danger')
            ->outlined()
            ->visible(fn () => $this->lastInvoiceId !== null && $this->lastInvoice()?->container_id == ($this->data['container_id'] ?? null))
            ->modalHeading(fn () => 'Report a problem with '.$this->lastInvoice()?->invoice)
            ->modalWidth('lg')
            ->schema([
                Select::make('boxissue_id')
                    ->label('Problem')
                    ->options(fn () => Boxissue::query()->orderBy('issue_type')->pluck('issue_type', 'id'))
                    ->required(),
                MarkdownEditor::make('remarks')
                    ->label('Notes')
                    ->toolbarButtons(['bold', 'italic', 'bulletList']),
                FileUpload::make('attachment_pic')
                    ->label('Photo')
                    ->image()
                    ->disk('public')
                    ->directory('boxissue')
                    ->visibility('private')
                    ->required(),
            ])
            ->action(function (array $data): void {
                $invoice = $this->lastInvoice();

                if (! $invoice) {
                    return;
                }

                Invoiceissue::create([
                    'invoice' => $invoice->invoice,
                    'invoice_id' => $invoice->id,
                    'container_id' => $invoice->container_id,
                    'boxissue_id' => $data['boxissue_id'],
                    'remarks' => $data['remarks'] ?? null,
                    'attachment_pic' => $data['attachment_pic'] ?? null,
                    'user_id' => Auth::id(),
                ]);

                Notification::make()->title("Problem recorded for {$invoice->invoice}")->success()->send();
            });
    }

    public function unmanifestedAction(): Action
    {
        return Action::make('unmanifested')
            ->label('Record as unmanifested box')
            ->icon(Heroicon::OutlinedDocumentPlus)
            ->color('warning')
            ->visible(fn () => filled($this->missingCode))
            ->modalHeading(fn () => "Unmanifested box {$this->missingCode}")
            ->modalDescription('This box is in the container but not on its manifest. Take a photo and add a note.')
            ->modalWidth('lg')
            ->schema([
                FileUpload::make('attachment_pic')
                    ->label('Photo')
                    ->image()
                    ->disk('public')
                    ->directory('unmanifested')
                    ->visibility('private')
                    ->required(),
                Textarea::make('remarks')->label('Notes')->rows(3),
            ])
            ->action(function (array $data): void {
                Unmanifested::create([
                    'invoice' => $this->missingCode,
                    'container_id' => $this->data['container_id'],
                    'attachment_pic' => $data['attachment_pic'] ?? null,
                    'remarks' => $data['remarks'] ?? null,
                ]);

                Notification::make()->title("Unmanifested box {$this->missingCode} recorded")->success()->send();

                $this->missingCode = null;
            });
    }

    public function photoStep(): ?string
    {
        return 'unload';
    }

    public function photoContext(): array
    {
        $id = $this->data['container_id'] ?? null;

        return [
            'container_id' => $id,
            'warehouse_id' => ($id ? Container::whereKey($id)->value('warehouse_id') : null) ?? Auth::user()?->warehouse_id,
            'logistichub_id' => Auth::user()?->logistichub_id,
        ];
    }

    public function appChoices(): Collection
    {
        return $this->containerQuery()->with('consolidator:id,company_name')->latest('id')->limit(60)->get()
            ->map(fn (Container $c) => ['id' => $c->id, 'name' => $c->container_no, 'active' => (bool) ($c->is_active ?? true) && ! $c->is_unloaded,
                'sub' => collect([$c->batch_no ? 'Batch '.$c->batch_no : null, $c->consolidator?->company_name])->filter()->join(' · ') ?: null]);
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Http/Controllers/ScanPhotoController.php
mkdir -p 'app/Http/Controllers'
cat > 'app/Http/Controllers/ScanPhotoController.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Http\Controllers;

use App\Models\BoxPhoto;
use App\Models\Invoice;
use App\Models\PhotoSetting;
use App\Support\Photos\BoxPhotos;
use App\Support\ScanModes;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

/**
 * Scan app: a box photo sent in the back (board 51), so the crew scans the next box while it uploads.
 * Only for a box this person just scanned in the Scan app (kept in the session for 2 hours).
 */
class ScanPhotoController extends Controller
{
    public function store(Request $request): JsonResponse
    {
        $data = $request->validate([
            'photo' => 'required|image|max:12288',
            'invoice_id' => 'required|integer',
            'condition' => 'nullable|string|in:'.implode(',', array_keys(BoxPhoto::CONDITIONS)),
            'note' => 'nullable|string|max:250',
        ], ['photo.image' => 'That file is not a photo.']);

        $ok = session('scan-app.photo-ok', [])[(int) $data['invoice_id']] ?? null;
        $user = $request->user();
        $mode = $ok ? (ScanModes::for($user)[$ok['mode']] ?? null) : null;
        if (! $ok || ! $mode || ($ok['at'] ?? 0) < now()->subHours(2)->timestamp) {
            return response()->json(['message' => 'Scan the box again, then take the photo.'], 403);
        }
        $station = app($mode['class']);
        $station->data = [$mode['field'] => $ok['choice']];
        $step = $station->photoStep();
        if (! $step || ! PhotoSetting::current()->allows($step)) {
            return response()->json(['message' => 'Photos are off for this scan.'], 403);
        }
        $invoice = Invoice::findOrFail((int) $data['invoice_id']);
        $photo = BoxPhotos::store($request->file('photo'), $step, $invoice, $station->photoContext(), $user, $data['condition'] ?? null, $data['note'] ?? null);

        return response()->json(['id' => $photo->id]);
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Models/TripCrew.php
mkdir -p 'app/Models'
cat > 'app/Models/TripCrew.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** A person on one trip (copied from the truck team; can be changed for this trip only). */
class TripCrew extends Model
{
    protected $guarded = [];

    protected static function booted(): void
    {
        static::saved(fn () => \App\Support\TripFlow::forgetCrew());
        static::deleted(fn () => \App\Support\TripFlow::forgetCrew());
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function trip(): BelongsTo
    {
        return $this->belongsTo(Deliverylog::class, 'deliverylog_id');
    }

    public function replaces(): BelongsTo
    {
        return $this->belongsTo(User::class, 'replaces_user_id');
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Support/DriverTrip.php
mkdir -p 'app/Support'
cat > 'app/Support/DriverTrip.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\Invoiceissue;
use App\Models\Maps\TripStop;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Maps\TripSorter;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Everything the driver's dashboard shows about their current trip.
 * The trip is found the same way as on "My deliveries": the newest active
 * trip of the truck the driver is crew on.
 */
class DriverTrip
{
    public function __construct(
        public readonly User $driver,
        public readonly ?Deliverylog $trip,
    ) {}

    public static function for(User $driver): self
    {
        return new self($driver, static::currentTrip($driver));
    }

    /** The trip the person is on now: on its crew (trip steps), or the newest active trip of their truck. */
    public static function currentTrip(User $driver): ?Deliverylog
    {
        return \App\Support\TripFlow::tripFor($driver);
    }

    /** Every box on the trip, including ones a partner hub handed over to it. */
    public function boxes(): Builder
    {
        $tripId = $this->trip?->getKey() ?? 0;

        return Tripinvoice::query()->where(fn (Builder $query) => $query
            ->where('deliverylog_id', $tripId)
            ->orWhere('deliveryloghub_id', $tripId));
    }

    /** @return array{total: int, delivered: int, notDelivered: int, left: int, percent: int} */
    public function progress(): array
    {
        // one database question (the driver app asks this on every tap)
        $tried = \App\Models\DeliveryAttempt::query()->select('invoice_id')->whereColumn('delivery_attempts.invoice_id', 'tripinvoices.invoice_id')->limit(1)->toBase();
        $r = $this->boxes()->toBase()->selectRaw('count(*) as total, sum(case when is_delivered = 1 then 1 else 0 end) as delivered')
            ->selectRaw('sum(case when is_delivered = 0 and exists('.$tried->toSql().') then 1 else 0 end) as tried', $tried->getBindings())
            ->first();
        $total = (int) $r->total;
        $delivered = (int) $r->delivered;
        $notDelivered = (int) $r->tried;

        return [
            'total' => $total,
            'delivered' => $delivered,
            'notDelivered' => $notDelivered,
            'left' => $total - $delivered,
            'percent' => $total ? (int) floor($delivered / $total * 100) : 0,
        ];
    }

    public function isFinished(): bool
    {
        $progress = $this->progress();

        return $progress['total'] > 0 && $progress['left'] === 0;
    }

    /** The other people on the truck, e.g. "Jun Reyes · Helper". */
    public function crewmates(): Collection
    {
        if (! $this->trip?->truck_id) {
            return collect();
        }

        $crew = \App\Support\TripFlow::crew($this->trip)->pluck('user_id');

        return User::with('workposition')
            ->whereIn('id', $crew->isNotEmpty() ? $crew : Truckcrew::where('truck_id', $this->trip->truck_id)->pluck('crew'))
            ->whereKeyNot($this->driver->getKey())
            ->get()
            ->map(fn (User $user) => [
                'name' => $user->full_name,
                'role' => $user->workposition?->position_description,
            ]);
    }

    /** Undelivered priority boxes, shown first. */
    public function priority(): Collection
    {
        return $this->remaining()
            ->filter(fn (Tripinvoice $box) => $box->invdata?->is_priority)
            ->map(fn (Tripinvoice $box) => $this->stopCard($box))
            ->values();
    }

    /**
     * Remaining boxes grouped by city and barangay, then by receiver, so the
     * driver can finish one area at a time and hand a whole household over at once.
     */
    public function areas(): Collection
    {
        return $this->remaining()
            ->groupBy(fn (Tripinvoice $box) => Str::title((string) $box->invdata?->receiver_city).'|'.Str::title((string) \App\Support\Maps\Barangays::of($box->invdata)))
            ->map(function (Collection $boxes, string $key) {
                [$city, $barangay] = explode('|', $key);

                $stops = $boxes
                    ->groupBy(fn (Tripinvoice $box) => Str::lower(trim($box->invdata?->receiver_name.'|'.$box->invdata?->receiver_address)))
                    ->map(function (Collection $household) {
                        $card = $this->stopCard($household->first());
                        $card['count'] = $household->count();
                        $card['invoices'] = $household->pluck('invoice')->join(', ');

                        return $card;
                    })
                    ->values();

                return [
                    'key' => md5($key),
                    'city' => $city ?: 'No city',
                    'barangay' => $barangay,
                    'boxes' => $boxes->count(),
                    'stops' => $stops,
                ];
            })
            ->sortByDesc('boxes')
            ->values();
    }

    /**
     * Stops still to visit, in the order the office sorted them (Maps & routes).
     * Each has what Navigate needs: the pin, or the address when there is no pin.
     */
    public function stops(): Collection
    {
        if (! $this->trip || ! TripSorter::ensure($this->trip, 10)) {
            return collect();
        }
        $left = $this->remaining()->keyBy('id');

        return TripSorter::stops($this->trip)
            ->map(function (TripStop $s) use ($left) {
                $boxes = collect($s->box_ids)->map(fn ($id) => $left[$id] ?? null)->filter()->values();
                if ($boxes->isEmpty()) {
                    return null;
                }
                $first = $boxes->first();
                $phone = $first->invdata?->receiver_mobile_no;

                return [
                    'id' => $s->id, 'no' => $s->stop_no, 'name' => $s->name, 'address' => $s->address,
                    'place' => trim(($s->barangay ? $s->barangay.', ' : '').$s->city, ', '),
                    'count' => $boxes->count(), 'invoice' => $first->invoice, 'invoices' => $boxes->pluck('invoice')->join(', '),
                    'priority' => $s->priority, 'zone' => $s->zone,
                    'lat' => $s->lat, 'lng' => $s->lng, 'exact' => $s->exact,
                    'go' => $s->hasPin() ? $s->lat.','.$s->lng : $s->address.', Philippines',
                    'phone' => $phone, 'tel' => $phone ? 'tel:'.preg_replace('/[^0-9+]/', '', $phone) : null,
                ];
            })
            ->filter()
            ->values();
    }

    /** Undelivered boxes with a problem reported at unloading. */
    public function problems(): Collection
    {
        $remaining = $this->remaining()->keyBy('invoice_id');

        if ($remaining->isEmpty()) {
            return collect();
        }

        return Invoiceissue::with('boxissue')
            ->whereIn('invoice_id', $remaining->keys())
            ->latest('id')
            ->get()
            ->unique('invoice_id')
            ->map(fn (Invoiceissue $issue) => $this->stopCard($remaining[$issue->invoice_id]) + [
                'issue' => $issue->boxissue?->issue_type ?? 'Problem reported',
                'remarks' => Str::limit(strip_tags((string) $issue->remarks), 80),
            ])
            ->values();
    }

    /** The latest boxes delivered today, with their proof photo. */
    public function deliveredToday(int $limit = 5): Collection
    {
        return $this->boxes()
            ->with('invdata')
            ->where('is_delivered', true)
            ->where(fn (Builder $query) => $query
                ->whereDate('delivered_at', today())
                ->orWhere(fn (Builder $query) => $query->whereNull('delivered_at')->whereDate('updated_at', today())))
            ->orderByRaw('COALESCE(delivered_at, updated_at) DESC')
            ->limit($limit)
            ->get()
            ->map(fn (Tripinvoice $box) => $this->stopCard($box) + [
                'id' => $box->getKey(),
                'undoMinutesLeft' => app(TripAssignment::class)->driverUndoMinutesLeft($box, $this->driver),
                'time' => ($box->delivered_at ?? $box->updated_at)?->format('g:i A'),
                'photo' => ($photo = collect($box->delivery_picture)->first())
                    ? Storage::disk('public')->url($photo)
                    : null,
            ]);
    }

    protected function remaining(): Collection
    {
        return once(fn () => $this->boxes()
            ->with('invdata')
            ->where('is_delivered', false)
            ->orderBy('invoice')
            ->get());
    }

    /** @return array{invoice: string, name: string, address: string, phone: ?string, tel: ?string, count: int} */
    protected function stopCard(Tripinvoice $box): array
    {
        $invoice = $box->invdata;
        $phone = $invoice?->receiver_mobile_no;

        return [
            'invoice' => $box->invoice,
            'name' => Str::title((string) $invoice?->receiver_name),
            'address' => collect([$invoice?->receiver_address, \App\Support\Maps\Barangays::of($invoice), $invoice?->receiver_city])
                ->filter()->map(fn ($part) => Str::title($part))->join(', '),
            'phone' => $phone,
            'tel' => $phone ? 'tel:'.preg_replace('/[^0-9+]/', '', $phone) : null,
            'count' => 1,
        ];
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Support/ScanModes.php
mkdir -p 'app/Support'
cat > 'app/Support/ScanModes.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Support;

use App\Filament\Company\Pages\LoadTruck as HubLoadTruck;
use App\Filament\Company\Pages\ReturnBoxes as HubReturnBoxesCompany;
use App\Filament\Pages\ReturnBoxes as AdminReturnBoxes;
use App\Filament\Pages\Scaninvoice as AdminUnload;
use App\Filament\Pages\Scanload as AdminLoad;
use App\Filament\Warehouse\Pages\Hubloaded as WarehouseLoad;
use App\Filament\Warehouse\Pages\HubReturnBoxes as WarehouseReturn;
use App\Filament\Warehouse\Pages\Unloadedcontainer as WarehouseUnload;
use App\Filament\Warehouse\Pages\Whloaded;
use App\Filament\Warehouse\Pages\Whunloaded;
use App\Filament\Shared\Shipping\PortCheckStation;
use App\Filament\Shared\Shipping\ReceiveShipmentStation;
use App\Models\User;

/**
 * Which scans a person gets in the Scan app, from the account type set on the user.
 * Each scan reuses an existing scan page (its rules, limits and photo step) behind the scenes.
 */
class ScanModes
{
    /** @return array<string, array{label: string, sub: string, icon: string, class: class-string, field: string, kind: string, ok: string, done: string}> */
    public static function for(?User $user): array
    {
        $code = $user?->panelcategory?->code;

        $unload = ['label' => 'Unload container', 'sub' => 'Boxes off the ship container', 'icon' => 'container', 'field' => 'container_id', 'kind' => 'container', 'ok' => 'Verified · off the container', 'done' => 'Container unloaded'];
        $load = ['label' => 'Load truck', 'sub' => 'Onto a delivery trip', 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Loaded on the truck', 'done' => 'Truck loaded'];
        $return = ['label' => 'Return boxes', 'sub' => 'Not delivered, back in', 'icon' => 'return', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Returned to inventory', 'done' => 'Returns done'];
        $sea = \App\Support\Shipping\Shipments::ready();
        $port = ['label' => 'Port check', 'sub' => 'Boxes handed over at the port', 'icon' => 'out', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Handed over at the port', 'done' => 'Port check done', 'class' => PortCheckStation::class];
        $count = ['label' => 'Count a section', 'sub' => 'Check a section, move boxes into it', 'icon' => 'container', 'field' => 'wh_section_id', 'kind' => 'section', 'ok' => 'Counted', 'done' => 'Section counted', 'class' => \App\Filament\Shared\SectionCountStation::class];
        $retReceive = ['label' => 'Receive returns', 'sub' => 'Boxes coming back from a hub', 'icon' => 'in', 'field' => 'return_shipment_id', 'kind' => 'return shipment', 'ok' => 'Back at the warehouse', 'done' => 'Returns received', 'class' => \App\Filament\Shared\Shipping\ReturnReceiveStation::class];
        $pick = \App\Support\Trips\Picking::ready() ? ['pick' => ['label' => 'Pick boxes', 'sub' => 'From the sections, before Load truck', 'icon' => 'pick', 'field' => 'deliverylog_id', 'kind' => 'trip', 'ok' => 'Picked', 'done' => 'All boxes picked', 'class' => \App\Filament\Shared\PickStation::class]] : [];
        $receive = ['label' => 'Receive container', 'sub' => 'Sea shipment arriving at your hub', 'icon' => 'in', 'field' => 'sea_shipment_id', 'kind' => 'shipment', 'ok' => 'Received at your hub', 'done' => 'Container received', 'class' => ReceiveShipmentStation::class];

        return match ($code) {
            'whse' => [
                'unload' => $unload + ['class' => WarehouseUnload::class],
            ] + $pick + [
                'load' => $load + ['class' => WarehouseLoad::class],
                'wh_load' => ['label' => 'Warehouse load', 'sub' => 'To another warehouse', 'icon' => 'out', 'field' => 'deliverylog_id', 'kind' => 'transfer trip', 'ok' => 'Loaded for the transfer', 'done' => 'Transfer loaded', 'class' => Whloaded::class],
                'wh_unload' => ['label' => 'Warehouse unload', 'sub' => 'Arriving from another warehouse', 'icon' => 'in', 'field' => 'deliverylog_id', 'kind' => 'arriving transfer', 'ok' => 'Received · added to inventory', 'done' => 'Transfer received', 'class' => Whunloaded::class],
                'return' => $return + ['class' => WarehouseReturn::class],
            ] + ($sea ? ['port' => $port] : []) + (\App\Support\Shipping\Returns::ready() ? ['ret_receive' => $retReceive] : []) + (\App\Support\Boxes\SectionCount::ready() && \App\Support\Boxes\Sections::used($user?->warehouse_id) ? ['count' => $count] : []),
            'co' => $pick + [
                'hub_load' => ['label' => 'Hub load', 'sub' => "Onto your hub's own trucks", 'icon' => 'truck', 'field' => 'deliverylog_id', 'kind' => 'hub trip', 'ok' => 'Loaded on the hub truck', 'done' => 'Hub truck loaded', 'class' => HubLoadTruck::class],
                'return' => $return + ['class' => HubReturnBoxesCompany::class, 'ok' => 'Back at your hub'],
            ] + static::hubReceive($user, $sea, $receive),
            'adm' => [
                'unload' => $unload + ['class' => AdminUnload::class],
                'load' => $load + ['class' => AdminLoad::class],
                'return' => $return + ['class' => AdminReturnBoxes::class],
            ] + ($sea ? ['port' => $port] : []),
            default => [],
        };
    }

    /**
     * Camera settings of the Scan app and the Driver app (board 51): the box stickers and receipts are Code 39,
     * section and spot labels are QR. A number counts when it is read twice the same; no scan for 2 minutes turns
     * the camera off; after 3 s of unclear reads the crew can type the number.
     */
    public static function scanner(string $method = 'scan', int $cooldown = 2500): array
    {
        return ['method' => $method, 'formats' => ['code_39', 'qr_code'], 'autoStart' => true, 'continuous' => true, 'cooldown' => $cooldown, 'beep' => true,
            'confirm' => 2, 'idleOff' => 120000, 'hardAfter' => 3000, 'startDelay' => 0];
    }

    /**
     * Partner hub: Receive container for hubs reached by sea, Receive truck for hubs reached by truck
     * (Settings · Hubs · island & sea). The other one shows only while something is arriving that way.
     */
    protected static function hubReceive(?User $user, bool $sea, array $receive): array
    {
        $hubId = (int) $user?->logistichub_id;
        $bySea = \App\Support\Shipping\Islands::ready() && $hubId ? (bool) \App\Models\Logistichub::whereKey($hubId)->value('by_sea') : null;
        $out = [];
        if ($sea && ($bySea !== false || \App\Models\Shipping\SeaShipment::whereIn('status', ['sailed', 'arrived', 'picked_up'])->where(fn ($q) => $q->where('logistichub_id', $hubId)
            ->when(\App\Support\Shipping\Shipments::stopsReady(), fn ($q) => $q->orWhereIn('id', \App\Models\Shipping\SeaShipmentStop::where('logistichub_id', $hubId)->whereNull('received_at')->select('sea_shipment_id'))))->exists())) {
            $out['ship_receive'] = $receive;
        }
        if (\App\Support\Shipping\TruckReceive::ready() && ($bySea !== true || \App\Support\Shipping\TruckReceive::trips($hubId)->isNotEmpty())) {
            $out['truck_receive'] = ['label' => 'Receive truck', 'sub' => 'Boxes from Manila arriving by truck', 'icon' => 'in', 'field' => 'deliverylog_id', 'kind' => 'truck',
                'ok' => 'Received at your hub', 'done' => 'Truck received', 'class' => \App\Filament\Shared\Shipping\TruckReceiveStation::class];
        }

        return $out;
    }

    /** "Calgary Warehouse" or "Cebu Partner Hub" for the top of the app. */
    public static function place(?User $user): string
    {
        return match ($user?->panelcategory?->code) {
            'whse' => $user->warehouse?->name ?? 'Warehouse',
            'co' => $user->logistichub?->hub_name ?? 'Partner hub',
            'adm' => $user->logistichub?->hub_name ?? 'Main office',
            default => '',
        };
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Support/TripFlow.php
mkdir -p 'app/Support'
cat > 'app/Support/TripFlow.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\TripCrew;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * A trip from plan to closed: Planned → Loading → Ready → On the road → Back → Closed.
 * Each trip keeps its own crew (copied from the truck team). The trip closes and the truck is
 * released by itself when every box is delivered or returned.
 */
class TripFlow
{
    /** key => [label, who moves it on, colour] */
    public const STAGES = [
        'waiting' => ['Next trip · waits for the truck', 'Automatic', 'gray'],
        'planned' => ['Planned', 'Office', 'info'],
        'loading' => ['Loading', 'Warehouse', 'warning'],
        'ready' => ['Ready', 'Office locked it', 'primary'],
        'road' => ['On the road', 'Driver', 'success'],
        'back' => ['Back', 'Driver', 'warning'],
        'closed' => ['Closed', 'Automatic', 'gray'],
    ];

    public const RELEASE_REASONS = [
        'done' => 'Trip done',
        'hub' => 'Boxes handed to the partner hub',
        'broke_down' => 'Truck broke down',
        'cancelled' => 'Trip cancelled',
        'other' => 'Other',
    ];

    public const SWAP_REASONS = ['sick' => 'Sick', 'day_off' => 'Day off', 'other_truck' => 'On another truck', 'other' => 'Other'];

    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Schema::hasTable('trip_crews') && Schema::hasColumn('deliverylogs', 'taken_at');
    }

    public static function queueReady(): bool
    {
        static $ready;

        return $ready ??= Schema::hasColumn('deliverylogs', 'waits_for');
    }

    // ------------------------------------------------------------------ next trip waiting

    /** Trips not waiting for another trip that still runs (the trip they waited for may be closed by hand). */
    public static function notWaiting($q)
    {
        return $q->where(fn ($q) => $q->whereNull('waits_for')
            ->orWhereIn('waits_for', Deliverylog::query()->select('id')->where('is_active', false)));
    }

    /** The trip that still runs on this truck (another one than $except). */
    public static function runningOn(?int $truckId, ?int $except = null): ?Deliverylog
    {
        return $truckId ? Deliverylog::where('truck_id', $truckId)->where('is_active', true)
            ->when($except, fn ($q) => $q->whereKeyNot($except))
            ->when(static::queueReady(), fn ($q) => static::notWaiting($q))->oldest('id')->first() : null;
    }

    /** Trips loaded once for a whole list (speed): [app id, id => trip]. Set by known(). */
    protected static array $known = [null, [], []];

    /** Remember these trips' "waits for" trips for this request, so stage() needs no query per row. */
    public static function known(iterable $trips): void
    {
        $ids = collect($trips)->pluck('waits_for')->filter()->unique()->values()->all();
        $tripIds = collect($trips)->pluck('id')->all();
        static::$known = [spl_object_id(app()), $ids && static::queueReady() ? Deliverylog::whereIn('id', $ids)->get()->keyBy('id')->all() : [],
            // trip id => has a loaded box (for stage(): loading)
            array_fill_keys(Tripinvoice::whereIn('deliverylog_id', $tripIds)->where('is_loaded', true)->distinct()->pluck('deliverylog_id')->all(), true) + array_fill_keys($tripIds, false)];
    }

    /** This trip waits for the truck's current trip to close. */
    public static function waitsFor(Deliverylog $trip): ?Deliverylog
    {
        if (! static::queueReady() || ! $trip->waits_for) {
            return null;
        }
        $before = static::$known[0] === spl_object_id(app()) && isset(static::$known[1][$trip->waits_for])
            ? static::$known[1][$trip->waits_for] : Deliverylog::find($trip->waits_for);

        return $before && $before->is_active ? $before : null;
    }

    /** The next trip planned for the same truck, waiting for this one. */
    public static function nextAfter(Deliverylog $trip): ?Deliverylog
    {
        return static::queueReady() ? Deliverylog::where('waits_for', $trip->id)->where('is_active', true)->oldest('id')->first() : null;
    }

    /** Truck list for a trip: free trucks, and trucks still out (the trip then waits for them). */
    public static function truckOptions(?int $hubId, ?int $tripId = null): array
    {
        // Own trucks, and rental trucks booked today (own first).
        $trucks = Rentals::usable(Truck::query()->where('is_active', 1)->when($hubId, fn ($q) => $q->where('logistichub_id', $hubId)))
            ->get()->sortBy(fn ($t) => [$t->isRental() ? 1 : 0, $t->plate_no])->values();

        return $trucks->mapWithKeys(function ($t) use ($tripId) {
            $on = $t->is_assigned ? static::runningOn($t->id, $tripId) : null;
            if ($t->is_assigned && ! $on && ! static::queueReady()) {
                return [];
            }

            return [$t->id => $t->plate_no.($t->isRental() ? ' · rental, '.(Rentals::rateText($t) ?: 'booked today') : '').($on ? ' · on '.$on->trip_number.' (this trip waits for it)' : '')];
        })->all();
    }

    // ------------------------------------------------------------------ steps

    public static function stage(Deliverylog $trip): string
    {
        if (! $trip->is_active) {
            return 'closed';
        }
        if (static::waitsFor($trip)) {
            return 'waiting';
        }
        if (static::ready() && $trip->back_at) {
            return 'back';
        }
        if (static::ready() && $trip->taken_at) {
            return 'road';
        }
        if ($trip->is_lock) {
            return 'ready';
        }
        $known = static::$known[0] === spl_object_id(app()) && array_key_exists($trip->id, static::$known[2]) ? static::$known[2][$trip->id] : null;
        if ($trip->is_current || ($known ?? Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->exists())) {
            return 'loading';
        }

        return 'planned';
    }

    public static function label(Deliverylog $trip): string
    {
        return static::STAGES[static::stage($trip)][0];
    }

    /** The leadman (or anyone on the crew) takes the trip: it is on the road, with the box count confirmed. */
    public static function take(Deliverylog $trip, ?User $by = null): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        $by ??= Auth::user();
        $trip->forceFill(['taken_at' => now(), 'taken_by' => $by?->id, 'taken_boxes' => static::boxes($trip)->count(), 'is_current' => true])->save();
    }

    /** The driver is back at the hub; boxes not delivered are scanned back with Return boxes. */
    public static function back(Deliverylog $trip): void
    {
        if (! static::ready() || $trip->back_at) {
            return;
        }
        $trip->forceFill(['back_at' => now(), 'taken_at' => $trip->taken_at ?? now()])->save();
        static::maybeClose($trip->fresh());
    }

    /** Boxes the trip still carries (main trip or a partner hub's own trip). */
    public static function boxes(Deliverylog $trip)
    {
        return Tripinvoice::query()->where(fn ($q) => $q->where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id));
    }

    /** Boxes still to deliver or return. Boxes a partner hub received off this truck count as done. */
    public static function left(Deliverylog $trip): int
    {
        $handed = TruckReceiptReady::finishedHubs($trip->id);

        return static::boxes($trip)->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->when($handed, fn ($q) => $q->where(fn ($q) => $q->whereNull('logistichub_id')->orWhereNotIn('logistichub_id', $handed)->orWhere('deliveryloghub_id', $trip->id)))
            ->count();
    }

    /** Close the trip and free the truck when nothing is left: every box delivered, returned or received by the hub. */
    public static function maybeClose(?Deliverylog $trip): bool
    {
        if (! $trip || ! static::ready() || ! $trip->is_active || ! $trip->truck_id) {
            return false;
        }
        // Every box delivered, returned (taken off the trip) or received by the partner hub.
        $total = static::boxes($trip)->count();
        if ($total === 0 ? ! $trip->back_at : static::left($trip) > 0) {
            return false;
        }
        static::release($trip, 'done', auto: true);

        return true;
    }

    /** Free the truck and close the trip (by itself, or by the office with a reason). */
    public static function release(Deliverylog $trip, string $reason = 'done', bool $auto = false): void
    {
        app(TripAssignment::class)->releaseTruck($trip);
        if (static::ready()) {
            $trip->forceFill(['closed_at' => now(), 'release_reason' => $auto ? 'auto' : $reason]
                // done by itself: the Delivered date fills in (board 45c)
                + ($auto && ! $trip->delivery_date ? ['delivery_date' => now()->toDateString()] : []))->saveQuietly();
        }
        // The next trip waiting for this truck starts now: the crew sees it right away.
        if ($next = static::nextAfter($trip)) {
            $next->forceFill(['waits_for' => null])->saveQuietly();
            // More trips planned for this truck: they now wait for the one that just started, in order.
            Deliverylog::where('waits_for', $trip->id)->where('is_active', true)->whereKeyNot($next->id)->update(['waits_for' => $next->id]);
            $trip->truck?->update(['is_assigned' => true]);
        }
    }

    // ------------------------------------------------------------------ crew of the trip

    /** Copy the truck team onto the trip, when it has no crew yet. */
    public static function copyCrew(Deliverylog $trip): void
    {
        if (! static::ready() || ! $trip->truck_id || TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            return;
        }
        // Only active people: someone made inactive stays off new trips.
        $users = User::with('workposition')->where('is_active', true)->whereIn('id', Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew'))->get();
        foreach ($users as $u) {
            TripCrew::firstOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $u->id], ['role' => $u->workposition?->position_description]);
        }
    }

    /** The truck changed before the trip left: take the new truck's team. */
    public static function truckChanged(Deliverylog $trip, ?int $oldTruckId = null): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        // The old truck's team leaves the trip; people the office picked by hand stay.
        $oldTeam = $oldTruckId ? Truckcrew::where('truck_id', $oldTruckId)->pluck('crew') : collect();
        TripCrew::where('deliverylog_id', $trip->id)->whereNull('replaces_user_id')->whereIn('user_id', $oldTeam)->delete();
        static::forgetCrew();
        if (! TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            static::copyCrew($trip);
        }
    }

    /** Someone joined or left the truck team: update the trips of the truck that did not leave yet. */
    public static function teamChanged(int $truckId, int $userId, bool $joined): void
    {
        if (! static::ready() || ! $truckId || ! $userId || ($joined && ! User::whereKey($userId)->where('is_active', true)->exists())) {
            return;
        }
        $trips = Deliverylog::where('truck_id', $truckId)->where('is_active', true)->whereNull('taken_at')->pluck('id');
        foreach ($trips as $tripId) {
            if ($joined) {
                if (! TripCrew::where('deliverylog_id', $tripId)->where('replaces_user_id', $userId)->exists()) {
                    TripCrew::firstOrCreate(['deliverylog_id' => $tripId, 'user_id' => $userId], ['role' => User::find($userId)?->workposition?->position_description]);
                }
            } else {
                TripCrew::where('deliverylog_id', $tripId)->where('user_id', $userId)->whereNull('replaces_user_id')->delete();
                static::forgetCrew();
            }
        }
    }

    /** @return Collection<int, TripCrew> */
    /** @var array<string, Collection> crew per trip, once per request (cleared when the crew changes) */
    protected static array $crewMemo = [];

    public static function forgetCrew(): void
    {
        static::$crewMemo = [];
    }

    public static function crew(Deliverylog $trip): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $key = spl_object_id(app()).':'.$trip->id;
        if (isset(static::$crewMemo[$key])) {
            return static::$crewMemo[$key];
        }
        static::copyCrew($trip);

        return static::$crewMemo[$key] = TripCrew::with('user.workposition', 'replaces')->where('deliverylog_id', $trip->id)->orderBy('id')->get()
            ->sortBy(fn ($c) => static::isLead($c) ? 0 : 1)->values();
    }

    public static function isLead(TripCrew $c): bool
    {
        return Str::contains(Str::lower((string) ($c->role ?? $c->user?->workposition?->position_description)), 'lead');
    }

    /** Who may tap "I take the trip": the leadman; anyone on the crew when there is no leadman. */
    public static function canTake(Deliverylog $trip, User $user): bool
    {
        $crew = static::crew($trip);
        $leads = $crew->filter(fn ($c) => static::isLead($c));

        return ($leads->isNotEmpty() ? $leads : $crew)->contains(fn ($c) => (int) $c->user_id === (int) $user->id);
    }

    /**
     * Set the crew for this trip only. People not in the truck team are marked as replacing
     * the team members left out.
     *
     * @param  list<int>  $userIds
     */
    public static function setCrew(Deliverylog $trip, array $userIds, ?string $reason = null): void
    {
        $userIds = array_values(array_unique(array_map('intval', $userIds)));
        $team = Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew')->map(fn ($i) => (int) $i)->unique()->values()->all();
        $out = array_values(array_diff($team, $userIds));
        TripCrew::where('deliverylog_id', $trip->id)->whereNotIn('user_id', $userIds)->delete();
        static::forgetCrew();
        $users = User::with('workposition')->whereIn('id', $userIds)->get()->keyBy('id');
        foreach ($userIds as $i => $id) {
            $isNew = ! in_array($id, $team, true);
            TripCrew::updateOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $id], [
                'role' => $users[$id]?->workposition?->position_description,
                'replaces_user_id' => $isNew ? ($out[$i] ?? $out[0] ?? null) : null,
                'reason' => $isNew ? $reason : null,
            ]);
        }
    }

    /** The trip a crew member works on now: newest active trip with them on its crew (or their truck's). */
    public static function tripFor(User $user): ?Deliverylog
    {
        if (static::ready()) {
            $trip = Deliverylog::with('truck')->where('is_active', true)
                ->when(static::queueReady(), fn ($q) => static::notWaiting($q))
                ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('id')->first();
            if ($trip) {
                return $trip;
            }
        }
        $truckId = Truckcrew::where('crew', $user->getKey())->latest('id')->value('truck_id');
        if (! $truckId) {
            return null;
        }
        $trip = Deliverylog::with('truck')->where('truck_id', $truckId)->where('is_active', true)
            ->when(static::queueReady(), fn ($q) => static::notWaiting($q))->latest('id')->first();
        // Someone replaced this person on that trip: it is not theirs.
        if ($trip && static::ready() && TripCrew::where('deliverylog_id', $trip->id)->exists()
            && ! TripCrew::where('deliverylog_id', $trip->id)->where('user_id', $user->id)->exists()) {
            return null;
        }

        return $trip;
    }

    /** The trip that closed in the last 12 hours, for the "Trip done" screen. */
    public static function justClosedFor(User $user): ?Deliverylog
    {
        if (! static::ready()) {
            return null;
        }

        return Deliverylog::with('truck')->where('is_active', false)->where('closed_at', '>=', now()->subHours(12))
            ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('closed_at')->first();
    }

    // ------------------------------------------------------------------ warnings (crew board)

    /** Crew people of the hub (null = all hubs). */
    public static function crewPeople(int|false|null $hub): Collection
    {
        return User::with('workposition')->where('is_crew', true)->where('is_active', true)
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))
            ->when($hub === false, fn ($q) => $q->whereRaw('1 = 0'))
            ->orderBy('first_name')->get();
    }

    /**
     * What needs a look now: trips ready but not taken, trucks back with boxes not returned,
     * trucks out very long, crew without a truck, trucks on a trip without crew.
     *
     * @return list<array{tone: string, text: string}>
     */
    public static function warnings(int|false|null $hub): array
    {
        if (! static::ready() || $hub === false) {
            return [];
        }
        $out = [];
        $trips = Deliverylog::with('truck:id,plate_no')->where('is_active', true)->whereNotNull('truck_id')
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->get();
        foreach ($trips as $t) {
            $stage = static::stage($t);
            if ($stage === 'ready' && $t->ready_at && $t->ready_at->lt(now()->subMinutes(30))) {
                $out[] = ['kind' => 'ready', 'trip' => $t, 'tone' => 'warn', 'text' => 'Trip '.$t->trip_number.' is ready since '.$t->ready_at->format('g:i A').' · nobody took it yet.'];
            }
            if ($stage === 'back' && $t->back_at?->lt(now()->subHours(2)) && ($left = static::left($t)) > 0) {
                $out[] = ['kind' => 'back', 'trip' => $t, 'tone' => 'warn', 'text' => 'Truck '.$t->truck?->plate_no.' is back since '.$t->back_at->format('g:i A').' · '.$left.' '.str('box')->plural($left).' not returned yet (Return boxes).'];
            }
            if ($stage === 'road' && $t->taken_at?->lt(now()->subHours(14))) {
                $out[] = ['kind' => 'road', 'trip' => $t, 'tone' => 'warn', 'text' => 'Truck '.$t->truck?->plate_no.' is on trip '.$t->trip_number.' since '.$t->taken_at->format('M j g:i A').'. Still out?'];
            }
            if (in_array($stage, ['ready', 'road'], true) && ! TripCrew::where('deliverylog_id', $t->id)->exists()) {
                $out[] = ['kind' => 'nocrew', 'trip' => $t, 'tone' => 'bad', 'text' => 'Trip '.$t->trip_number.' has no crew.'];
            }
        }
        foreach (Truckcrew::with('member', 'truck')->whereHas('member', fn ($q) => $q->where('is_active', false))->get() as $c) {
            if ($hub === null || (int) $c->truck?->logistichub_id === $hub) {
                $out[] = ['kind' => 'inactive', 'truck_id' => $c->truck_id, 'user_id' => $c->crew, 'tone' => 'warn', 'text' => ($c->member?->full_name ?? 'Someone').' is inactive but still on the team of '.($c->truck?->plate_no ?? 'a truck').'.'];
            }
        }
        // On the team of an active truck (a truck made inactive does not count).
        $onTruck = Truckcrew::whereHas('truck', fn ($q) => $q->where('is_active', true))->pluck('crew')->map(fn ($i) => (int) $i)->all();
        foreach (static::crewPeople($hub)->reject(fn ($u) => in_array((int) $u->id, $onTruck, true)) as $u) {
            $out[] = ['kind' => 'notruck', 'tone' => 'info', 'text' => $u->full_name.' has no truck.'];
        }

        return $out;
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- public/js/app/barcode-scanner.js
mkdir -p 'public/js/app'
cat > 'public/js/app/barcode-scanner.js' <<'DISPATCH_FILE_END_9'
(function () {
    // ZXing (WebAssembly) barcode decoder — used when the phone has no built-in BarcodeDetector (e.g. iPhone)
    const PONYFILL_URL = 'https://fastly.jsdelivr.net/npm/barcode-detector@3/dist/iife/ponyfill.min.js';
    const CAMERA_KEY = 'bb-scanner-camera';

    const scripts = {};
    function loadScript(src) {
        if (!scripts[src]) {
            scripts[src] = new Promise((resolve, reject) => {
                const s = document.createElement('script');
                s.src = src;
                s.async = true;
                s.onload = () => resolve();
                s.onerror = () => {
                    delete scripts[src];
                    reject(new Error('Could not load the barcode decoder. Check your internet connection.'));
                };
                document.head.appendChild(s);
            });
        }
        return scripts[src];
    }

    const detectors = {};
    async function createDetector(formats) {
        const key = formats.join(',');
        if (detectors[key]) return detectors[key];

        let detector = null;

        // Android Chrome: use the fast built-in detector when it supports all formats
        if ('BarcodeDetector' in window) {
            try {
                const supported = await window.BarcodeDetector.getSupportedFormats();
                if (formats.every((f) => supported.includes(f))) {
                    detector = new window.BarcodeDetector({ formats });
                }
            } catch (e) {}
        }

        // iPhone / others: ZXing WebAssembly
        if (!detector) {
            await loadScript(PONYFILL_URL);
            detector = new window.BarcodeDetectionAPI.BarcodeDetector({ formats });
        }

        detectors[key] = detector;
        return detector;
    }

    let audioCtx = null;
    function beep() {
        try {
            audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
            const osc = audioCtx.createOscillator();
            const gain = audioCtx.createGain();
            osc.type = 'square';
            osc.frequency.value = 1200;
            gain.gain.value = 0.08;
            osc.connect(gain);
            gain.connect(audioCtx.destination);
            osc.start();
            osc.stop(audioCtx.currentTime + 0.12);
        } catch (e) {}
    }

    function describeError(e) {
        const name = (e && e.name) || '';
        const msg = String((e && (e.message || e)) || '');
        if (name === 'NotAllowedError' || /permission|notallowed/i.test(msg))
            return 'Camera permission was denied. Allow camera access for this site in your browser settings, then try again.';
        if (name === 'NotFoundError' || /requested device not found/i.test(msg))
            return 'No camera was found on this device.';
        if (name === 'NotReadableError' || /could not start|in use/i.test(msg))
            return 'The camera is being used by another app. Close it and try again.';
        return msg || 'Unable to start the camera.';
    }

    function waitForVideo(video, timeout = 4000) {
        return new Promise((resolve) => {
            if (video.videoWidth > 0) return resolve();
            const done = () => { clearTimeout(t); video.removeEventListener('loadedmetadata', done); resolve(); };
            const t = setTimeout(done, timeout);
            video.addEventListener('loadedmetadata', done);
        });
    }

    // A tiny copy of the picture, to notice when the camera only sends black frames
    const probe = document.createElement('canvas');
    probe.width = 32;
    probe.height = 18;
    const probeCtx = probe.getContext('2d', { willReadFrequently: true });

    function brightness(video) {
        try {
            probeCtx.drawImage(video, 0, 0, probe.width, probe.height);
            const px = probeCtx.getImageData(0, 0, probe.width, probe.height).data;
            let sum = 0;
            for (let i = 0; i < px.length; i += 4) sum += px[i] + px[i + 1] + px[i + 2];
            return sum / (px.length / 4) / 3;
        } catch (e) {
            return 255; // cannot read the picture: do not complain
        }
    }

    const ios = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    const homeScreenApp = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
    const BLACK_TIP = 'The camera picture is black. Close other apps that use the camera, check that this site may use the camera, '
        + (ios && homeScreenApp ? 'or close the app fully and open it again. ' : 'or reload the page. ')
        + 'You can always type the code above.';

    const TORCH_KEY = 'ds-torch-at';
    const TORCH_KEEP = 10 * 60 * 1000; // the flashlight comes back on by itself within 10 minutes
    const VIDEO = { width: { ideal: 1280 }, height: { ideal: 720 } }; // light and fast; the frame is read in full detail

    /*
     * Start the camera while the trip is still opening (tap on a trip), so the scan screen
     * finds it running. Not used within 10 s: let go of it.
     */
    let warm = null;
    window.dsWarmCamera = function (formats) {
        try {
            if (formats) createDetector(formats.map((f) => String(f).toLowerCase())).catch(() => {});
            if (warm || !navigator.mediaDevices || !window.isSecureContext) return;
            let saved = null;
            try { saved = localStorage.getItem(CAMERA_KEY); } catch (e) {}
            const w = { stream: null, timer: null };
            warm = w;
            navigator.mediaDevices.getUserMedia({ audio: false, video: saved ? { ...VIDEO, deviceId: { exact: saved } } : { ...VIDEO, facingMode: { ideal: 'environment' } } })
                .then((st) => { if (warm === w) { w.stream = st; w.timer = setTimeout(() => { if (warm === w) { st.getTracks().forEach((t) => t.stop()); warm = null; } }, 10000); } else st.getTracks().forEach((t) => t.stop()); })
                .catch(() => { if (warm === w) warm = null; });
        } catch (e) { warm = null; }
    };
    function takeWarm() {
        if (!warm || !warm.stream || !warm.stream.active) return null;
        clearTimeout(warm.timer);
        const st = warm.stream;
        warm = null;
        return st;
    }

    /*
     * Box photos sent in the back: the crew scans the next box while a photo uploads.
     * Each photo: shrunk on the phone, sent with its % shown, tried again 3 times.
     */
    let photoState = null;
    function photos() {
        if (!photoState) photoState = window.Alpine ? window.Alpine.reactive({ items: [] }) : { items: [] };
        return photoState;
    }
    function sendPhoto(item, tries = 0) {
        const fd = new FormData();
        fd.append('photo', item.file, 'photo.jpg');
        fd.append('invoice_id', item.invoiceId);
        if (item.condition) fd.append('condition', item.condition);
        if (item.note) fd.append('note', item.note);
        const xhr = new XMLHttpRequest();
        xhr.open('POST', item.url);
        const token = document.querySelector('meta[name="csrf-token"]');
        if (token) xhr.setRequestHeader('X-CSRF-TOKEN', token.content);
        xhr.setRequestHeader('Accept', 'application/json');
        xhr.upload.onprogress = (e) => { if (e.lengthComputable) item.p = Math.min(99, Math.round(e.loaded / e.total * 100)); };
        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                try { item.serverId = JSON.parse(xhr.responseText).id; } catch (e) {}
                item.p = 100; item.done = true; item.failed = false; item.file = null;
            } else if (xhr.status >= 500 && tries < 3) setTimeout(() => sendPhoto(item, tries + 1), 2000 * (tries + 1));
            else { item.failed = true; try { item.why = JSON.parse(xhr.responseText).message; } catch (e) {} }
        };
        xhr.onerror = () => { if (tries < 3) setTimeout(() => sendPhoto(item, tries + 1), 2000 * (tries + 1)); else item.failed = true; };
        xhr.send(fd);
    }
    window.dsPhotos = {
        state: photos,
        async add(file, info) {
            const small = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
            const item = { id: Date.now() + Math.random(), invoiceId: info.invoiceId, code: info.code || '', condition: info.condition || null, note: info.note || null,
                url: info.url, file: small, thumb: URL.createObjectURL(small), p: 2, done: false, failed: false, serverId: null, why: null };
            photos().items.push(item);
            sendPhoto(photos().items[photos().items.length - 1]);
        },
        retry(item) { if (item.file) { item.failed = false; item.p = 2; sendPhoto(item); } },
        going() { return photos().items.filter((i) => !i.done && !i.failed); },
        saved() { return photos().items.filter((i) => i.done).length; },
        failed() { return photos().items.filter((i) => i.failed); },
        of(invoiceId) { return photos().items.filter((i) => String(i.invoiceId) === String(invoiceId)); },
    };

    window.barcodeScanner = function (config) {
        const formats = (config.formats && config.formats.length ? config.formats : ['code_128', 'qr_code'])
            .map((f) => String(f).toLowerCase());

        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d', { willReadFrequently: true });

        let stream = null;
        let detector = null;
        let session = 0;
        let loopTimer = null;
        let startTimer = null;
        let watchTimer = null;
        let observer = null;
        let onVisibilityChange = null;
        let darkSince = 0;
        let frame = 0;
        let tried = new Set();
        let onCommand = null;
        let pending = { code: null, n: 0, at: 0 }; // a read waits for the same read once more
        let unsureSince = 0;
        let activity = 0;
        let dimSince = 0;
        const confirmReads = Math.max(1, config.confirm || 1);
        const idleOff = config.idleOff || 0;
        const hardAfter = config.hardAfter || 3000;

        return {
            scanning: false,
            loading: false,
            error: null,
            hint: null,
            lastCode: null,
            lastAt: 0,
            manualCode: '',
            cameras: [],
            cameraId: null,
            stoppedByUser: false,
            flash: false,
            torchSupported: false,
            torchOn: false,
            paused: false,
            hard: false,
            typing: false,
            typed: '',
            darkTip: false,
            offWhy: null,

            init() {
                try { this.cameraId = localStorage.getItem(CAMERA_KEY) || null; } catch (e) {}

                onVisibilityChange = () => {
                    if (document.hidden) {
                        this.stop();
                    } else if (config.autoStart && !this.stoppedByUser && this.$el.getClientRects().length) {
                        this.start();
                    }
                };
                document.addEventListener('visibilitychange', onVisibilityChange);

                // From the page: pause while a result is open, let go of the camera for the camera app
                onCommand = (e) => {
                    const d = (e && e.detail) || {};
                    if (d.release) { this.stop(); return; }
                    if ('paused' in d) this.setPaused(!!d.paused);
                };
                window.addEventListener('ds-scanner', onCommand);
                window.dsScanner = this;

                // Start when the scanner becomes visible (modal opened), stop when hidden (modal closed)
                if ('IntersectionObserver' in window) {
                    observer = new IntersectionObserver((entries) => {
                        const entry = entries[entries.length - 1];
                        entry.isIntersecting ? this.onShown() : this.onHidden();
                    }, { threshold: 0.01 });
                    observer.observe(this.$el);
                } else if (config.autoStart) {
                    setTimeout(() => this.start(), 300);
                }
            },

            destroy() {
                document.removeEventListener('visibilitychange', onVisibilityChange);
                window.removeEventListener('ds-scanner', onCommand);
                if (window.dsScanner === this) window.dsScanner = null;
                if (observer) observer.disconnect();
                clearTimeout(startTimer);
                this.stop();
            },

            onShown() {
                this.stoppedByUser = false;
                if (!config.autoStart) return;
                clearTimeout(startTimer);
                startTimer = setTimeout(() => this.start(), config.startDelay ?? 300); // let the modal finish opening
            },

            onHidden() {
                clearTimeout(startTimer);
                this.stop();
            },

            async start(afterBlack = false) {
                if (this.scanning || this.loading) return;
                this.error = null;
                this.stoppedByUser = false;
                if (!afterBlack) {
                    tried = new Set();
                    this.hint = null;
                }
                darkSince = 0;

                if (!window.isSecureContext) {
                    this.error = 'The camera only works over HTTPS (or on localhost). Open this page with https://';
                    return;
                }
                if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
                    this.error = 'This browser does not support camera access. Type the code instead.';
                    return;
                }

                const my = ++session;
                this.loading = true;

                try {
                    // Load the decoder at the same time as the camera starts
                    const detectorPromise = createDetector(formats);

                    const base = VIDEO;
                    let s = takeWarm();
                    if (!s) try {
                        s = await navigator.mediaDevices.getUserMedia({
                            audio: false,
                            video: this.cameraId
                                ? { ...base, deviceId: { exact: this.cameraId } }
                                : { ...base, facingMode: { ideal: 'environment' } },
                        });
                    } catch (e) {
                        if (!this.cameraId || e.name === 'NotAllowedError') throw e;
                        this.forgetCamera(); // saved camera no longer exists → use back camera
                        s = await navigator.mediaDevices.getUserMedia({
                            audio: false,
                            video: { ...base, facingMode: { ideal: 'environment' } },
                        });
                    }

                    if (my !== session) { s.getTracks().forEach((t) => t.stop()); return; }
                    stream = s;

                    // Attach the camera only once the preview box is on screen:
                    // iPhone home screen apps show a black picture otherwise.
                    await this.$nextTick();
                    await new Promise((resolve) => requestAnimationFrame(() => resolve()));

                    const video = this.$refs.video;
                    video.muted = true;
                    video.setAttribute('muted', '');
                    video.setAttribute('playsinline', '');
                    video.setAttribute('autoplay', '');
                    video.srcObject = stream;
                    try { await video.play(); } catch (e) {}
                    await waitForVideo(video);
                    if (video.paused) {
                        try { await video.play(); } catch (e) {}
                    }

                    const track = stream.getVideoTracks()[0];
                    try { await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }); } catch (e) {}
                    try {
                        const caps = track.getCapabilities ? track.getCapabilities() : {};
                        this.torchSupported = !!caps.torch;
                    } catch (e) { this.torchSupported = false; }
                    this.torchOn = false;
                    let torchAt = 0;
                    try { torchAt = Number(localStorage.getItem(TORCH_KEY) || 0); } catch (e) {}
                    if (this.torchSupported && torchAt && Date.now() - torchAt < TORCH_KEEP) {
                        try { await track.applyConstraints({ advanced: [{ torch: true }] }); this.torchOn = true; } catch (e) {}
                    }

                    detector = await detectorPromise;
                    if (my !== session) return;

                    this.scanning = true;
                    this.loading = false;
                    this.offWhy = null;
                    activity = Date.now();
                    pending = { code: null, n: 0, at: 0 };
                    unsureSince = 0;
                    this.hard = false;
                    this.watchHidden();
                    this.loop(my);
                    this.listCameras();
                } catch (e) {
                    if (my === session) {
                        this.error = describeError(e);
                        await this.stop();
                    }
                } finally {
                    if (my === session) this.loading = false;
                }
            },

            // Read frames ~10 times per second, cropped to the middle of the picture
            async loop(my) {
                if (my !== session) return;
                const video = this.$refs.video;

                if (idleOff && !this.typing && Date.now() - activity > idleOff) {
                    this.offWhy = 'No scan for ' + Math.round(idleOff / 60000) + ' minutes: camera and flashlight off to save battery.';
                    this.stop();
                    return;
                }
                if (unsureSince && Date.now() - pending.at > 1500) unsureSince = 0; // nothing read for a while: not a hard label
                if (unsureSince && !this.hard && Date.now() - unsureSince > hardAfter) this.hard = true;

                if (video.readyState >= 2 && video.videoWidth && ++frame % 3 === 0) {
                    const light = brightness(video);
                    if (light < 40 && light >= 8 && this.torchSupported && !this.torchOn) {
                        dimSince = dimSince || Date.now();
                        if (Date.now() - dimSince > 1500) this.darkTip = true;
                    } else {
                        dimSince = 0;
                        this.darkTip = false;
                    }
                    if (light < 8) {
                        darkSince = darkSince || Date.now();
                        if (Date.now() - darkSince > 2500) {
                            darkSince = 0;
                            this.onBlackPicture(my);
                            return;
                        }
                    } else {
                        darkSince = 0;
                        if (this.hint) this.hint = null;
                    }
                }

                try {
                    if (detector && !this.paused && !this.typing && video.readyState >= 2 && video.videoWidth) {
                        const vw = video.videoWidth;
                        const vh = video.videoHeight;
                        const cw = Math.floor(vw * 0.92);
                        const ch = Math.floor(vh * (config.confirm > 1 ? 0.5 : 0.6));
                        const scale = Math.min(1, 1280 / cw);

                        canvas.width = Math.floor(cw * scale);
                        canvas.height = Math.floor(ch * scale);
                        ctx.drawImage(video, (vw - cw) / 2, (vh - ch) / 2, cw, ch, 0, 0, canvas.width, canvas.height);

                        const results = await detector.detect(canvas);
                        if (my === session && !this.paused && results && results.length) {
                            this.onRead(results[0].rawValue);
                        }
                    }
                } catch (e) {}

                if (my === session && this.scanning) {
                    loopTimer = setTimeout(() => this.loop(my), 100);
                }
            },

            // The picture stayed black: try the other cameras once each, then explain.
            async onBlackPicture(my) {
                await this.listCameras();
                let current = this.cameraId;
                try { current = (stream && stream.getVideoTracks()[0].getSettings().deviceId) || current; } catch (e) {}
                tried.add(current || 'auto');
                const next = this.cameras.map((c) => c.id).find((id) => id && !tried.has(id));

                if (next && tried.size <= this.cameras.length) {
                    this.hint = 'The picture was black. Trying another camera…';
                    this.cameraId = next;
                    try { localStorage.setItem(CAMERA_KEY, next); } catch (e) {}
                    await this.stop();
                    await this.start(true);
                    return;
                }

                this.hint = BLACK_TIP;
                if (my === session && this.scanning) this.loop(my); // keep reading in case the picture comes back
            },

            async stop() {
                if (this.torchOn) { try { localStorage.setItem(TORCH_KEY, String(Date.now())); } catch (e) {} }
                this.darkTip = false;
                session++;
                clearTimeout(loopTimer);
                clearInterval(watchTimer);
                loopTimer = null;
                watchTimer = null;

                if (stream) {
                    stream.getTracks().forEach((t) => t.stop());
                    stream = null;
                }
                if (this.$refs.video) this.$refs.video.srcObject = null;

                this.scanning = false;
                this.loading = false;
                this.torchOn = false;
            },

            async toggle() {
                if (this.scanning || this.loading) {
                    this.stoppedByUser = true;
                    clearTimeout(startTimer);
                    await this.stop();
                } else {
                    await this.start();
                }
            },

            async toggleTorch() {
                const track = stream && stream.getVideoTracks()[0];
                if (!track) return;
                try {
                    await track.applyConstraints({ advanced: [{ torch: !this.torchOn }] });
                    this.torchOn = !this.torchOn;
                    this.darkTip = false;
                    try { this.torchOn ? localStorage.setItem(TORCH_KEY, String(Date.now())) : localStorage.removeItem(TORCH_KEY); } catch (e) {}
                } catch (e) {}
            },

            async listCameras() {
                if (this.cameras.length) return;
                try {
                    const devices = await navigator.mediaDevices.enumerateDevices(); // no permission popup
                    this.cameras = devices
                        .filter((d) => d.kind === 'videoinput')
                        .map((d, i) => ({ id: d.deviceId, label: d.label || `Camera ${i + 1}` }));
                } catch (e) {}
            },

            forgetCamera() {
                this.cameraId = null;
                try { localStorage.removeItem(CAMERA_KEY); } catch (e) {}
            },

            async useCamera(id) {
                this.cameraId = id || null;
                try { id ? localStorage.setItem(CAMERA_KEY, id) : localStorage.removeItem(CAMERA_KEY); } catch (e) {}
                if (this.scanning) { await this.stop(); await this.start(); }
            },

            // Backup: stop the camera if the modal closed and the observer missed it
            watchHidden() {
                clearInterval(watchTimer);
                watchTimer = setInterval(() => {
                    if (!this.$el.isConnected || this.$el.getClientRects().length === 0) this.stop();
                }, 1000);
            },

            // A read counts only when the same number is read again right after (blurry labels misread)
            onRead(text) {
                const code = String(text || '').trim();
                if (!code) return;
                const now = Date.now();
                if (code === this.lastCode && now - this.lastAt < (config.cooldown ?? 2500)) return;
                if (confirmReads <= 1) { this.onDetected(code); return; }
                if (pending.code === code && now - pending.at < 1500) {
                    pending.n++;
                    pending.at = now;
                    if (pending.n >= confirmReads) {
                        pending = { code: null, n: 0, at: 0 };
                        this.onDetected(code);
                    }
                    return;
                }
                pending = { code, n: 1, at: now };
                unsureSince = unsureSince || now;
            },

            setPaused(p) {
                this.paused = p;
                if (p) return;
                activity = Date.now();
                this.lastAt = Date.now(); // the box still in front of the camera is not read again at once
                pending = { code: null, n: 0, at: 0 };
                if (!this.scanning && !this.loading && config.autoStart && this.$el.getClientRects().length) this.start();
            },

            // Hard to read: type the number on a keypad
            openTyping() { this.typing = true; this.typed = ''; this.hard = false; unsureSince = 0; activity = Date.now(); },
            closeTyping() { this.typing = false; this.typed = ''; activity = Date.now(); },
            key(k) {
                activity = Date.now();
                if (k === '⌫') this.typed = this.typed.slice(0, -1);
                else this.typed = (this.typed + k).slice(0, 20);
            },
            findTyped() {
                const code = this.typed.trim();
                if (!code) return;
                this.typing = false;
                this.typed = '';
                this.lastCode = code;
                this.lastAt = Date.now();
                this.submit(code);
            },

            async turnTorchOn() { if (!this.torchOn) await this.toggleTorch(); },

            // 📷 Take photo here: a still from the camera that is already on (no camera app)
            async snapPhoto() {
                const track = stream && stream.getVideoTracks()[0];
                const video = this.$refs.video;
                this.flash = true;
                setTimeout(() => { this.flash = false; }, 160);
                if (track && 'ImageCapture' in window) {
                    try {
                        const blob = await new window.ImageCapture(track).takePhoto();
                        if (blob && blob.size) return new File([blob], 'photo.jpg', { type: blob.type || 'image/jpeg' });
                    } catch (e) {}
                }
                if (!video || !video.videoWidth) return null;
                const c = document.createElement('canvas');
                c.width = video.videoWidth;
                c.height = video.videoHeight;
                c.getContext('2d').drawImage(video, 0, 0);
                const blob = await new Promise((r) => c.toBlob(r, 'image/jpeg', 0.9));
                return blob ? new File([blob], 'photo.jpg', { type: 'image/jpeg' }) : null;
            },

            onDetected(text) {
                const code = String(text || '').trim();
                if (!code) return;
                activity = Date.now();
                unsureSince = 0;
                this.hard = false;
                const now = Date.now();
                if (code === this.lastCode && now - this.lastAt < (config.cooldown ?? 2500)) return;

                this.lastCode = code;
                this.lastAt = now;

                this.flash = true;
                setTimeout(() => { this.flash = false; }, 600);

                if (navigator.vibrate) navigator.vibrate(80);
                if (config.beep !== false) beep();
                if (!config.continuous) this.stop();
                this.submit(code);
            },

            submitManual() {
                const code = this.manualCode.trim();
                if (!code) return;
                activity = Date.now();
                this.lastCode = code;
                this.lastAt = Date.now();
                this.submit(code);
            },

            submit(code) {
                this.manualCode = config.statePath ? code : '';
                if (config.statePath) this.$wire.set(config.statePath, code);
                if (config.method) this.$wire.call(config.method, code);
                this.$dispatch('barcode-scanned', { code });
            },
        };
    };
})();
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- resources/css/filament/admin/theme.css
mkdir -p 'resources/css/filament/admin'
cat > 'resources/css/filament/admin/theme.css' <<'DISPATCH_FILE_END_10'
@import '../../../../vendor/filament/filament/resources/css/theme.css';

/* The Archivo font comes with the app (no internet needed): pages open fast even on a slow connection. */
@import '@fontsource/archivo/latin-400.css';
@import '@fontsource/archivo/latin-500.css';
@import '@fontsource/archivo/latin-600.css';
@import '@fontsource/archivo/latin-700.css';
@import '@fontsource/archivo/latin-800.css';
@import '@fontsource/archivo/latin-900.css';

@source '../../../../app/Filament/**/*';
@source '../../../../resources/views/filament/**/*';
@source '../../../../resources/views/components/**/*';

/*
 * Dispatch theme — "manifest & signal".
 * Harbour navy for the frame, signal yellow for action, colour only where it
 * carries meaning (scan outcomes, progress). Shared by all four panels.
 */
:root {
    --ds-navy: #0e2433;
    --ds-navy-2: #16334a;
    --ds-navy-3: #24465f;
    --ds-signal: #f6be00;
    --ds-steel: #5b6b78;
    --ds-deck: #f3f5f7;
    --ds-ok: #17895e;
    --ds-warn: #e08a00;
    --ds-bad: #cf3b3b;
    --ds-radius-lg: 0.875rem;
    --ds-radius: 0.625rem;
}

body {
    font-feature-settings: 'tnum' 1, 'ss01' 1;
}

/* ------------------------------------------------------------------ frame */

.fi-body {
    background: var(--ds-deck);
}

.dark .fi-body {
    background: #0a1a26;
}

.fi-sidebar {
    background: var(--ds-navy);
    border-inline-end: 0;
}

.fi-sidebar-header {
    background: var(--ds-navy);
    box-shadow: none;
    border-bottom: 1px solid rgb(255 255 255 / 0.06);
}

.fi-sidebar .fi-sidebar-group-label,
.fi-sidebar .fi-sidebar-group-btn {
    color: rgb(255 255 255 / 0.5);
}

.fi-sidebar .fi-sidebar-item-btn {
    color: rgb(255 255 255 / 0.78);
    border-radius: var(--ds-radius);
}

.fi-sidebar .fi-sidebar-item-icon {
    color: rgb(255 255 255 / 0.45);
}

.fi-sidebar .fi-sidebar-item-label {
    color: inherit;
}

.fi-sidebar .fi-sidebar-item-btn:hover,
.fi-sidebar .fi-sidebar-item-btn:focus-visible {
    background: var(--ds-navy-2);
    color: #fff;
}

/* Active item: a signal-yellow tab on the left edge, like a door stripe. */
.fi-sidebar .fi-sidebar-item.fi-active > .fi-sidebar-item-btn {
    background: var(--ds-navy-3);
    color: #fff;
    box-shadow: inset 3px 0 0 var(--ds-signal);
}

.fi-sidebar .fi-sidebar-item.fi-active .fi-sidebar-item-icon {
    color: var(--ds-signal);
}

.fi-sidebar .fi-sidebar-item-grouped-border-part {
    background: rgb(255 255 255 / 0.18);
}

.fi-sidebar-footer,
.ds-sidebar-footer {
    color: rgb(255 255 255 / 0.4);
    font-size: 0.75rem;
    padding: 0.75rem 1.25rem 1rem;
}

.fi-topbar > nav,
.fi-topbar {
    background: rgb(255 255 255 / 0.92);
    backdrop-filter: blur(8px);
    box-shadow: 0 1px 0 rgb(14 36 51 / 0.08);
}

.dark .fi-topbar > nav,
.dark .fi-topbar {
    background: rgb(14 36 51 / 0.92);
}

/* Brand mark */
.ds-brand {
    display: inline-flex;
    align-items: center;
    gap: 0.625rem;
    line-height: 1;
}

.ds-brand__mark {
    width: 2.1rem;
    height: 2.1rem;
    flex: none;
}

.ds-brand__text {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
}

.ds-brand__name {
    font-weight: 800;
    font-size: 1.05rem;
    letter-spacing: -0.01em;
    color: var(--ds-navy);
}

.ds-brand__area {
    font-size: 0.72rem;
    font-weight: 600;
    color: var(--ds-steel);
}

.fi-sidebar .ds-brand__name,
.dark .ds-brand__name {
    color: #fff;
}

.fi-sidebar .ds-brand__area,
.dark .ds-brand__area {
    color: var(--ds-signal);
}

.fi-sidebar .ds-brand__mark rect:first-child {
    fill: #23435b;
}

/* ---------------------------------------------------------------- content */

.fi-header-heading {
    letter-spacing: -0.02em;
    font-weight: 800;
}

.fi-section,
.fi-ta-ctn,
.fi-wi-stats-overview-stat {
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06);
}

.fi-ta-header-cell {
    font-weight: 600;
    color: var(--ds-steel);
}

.fi-wi-stats-overview-stat {
    position: relative;
    overflow: hidden;
}

.fi-wi-stats-overview-stat-value {
    font-weight: 800;
    letter-spacing: -0.02em;
}

/* --------------------------------------------------------------- sign-in */

.fi-simple-layout {
    background:
        repeating-linear-gradient(90deg, transparent 0 46px, rgb(255 255 255 / 0.035) 46px 48px),
        var(--ds-navy);
}

.fi-simple-main {
    border-radius: 1.25rem;
    box-shadow: 0 30px 60px -20px rgb(0 0 0 / 0.45);
    border-top: 6px solid var(--ds-signal);
}

/* ------------------------------------------------------------ scan station */

.ds-station {
    display: grid;
    gap: 1.25rem;
    align-items: start;
}

@media (min-width: 1100px) {
    .ds-station {
        grid-template-columns: minmax(22rem, 2fr) 3fr;
    }
}

.ds-station__panel,
.ds-station__result {
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
}

.ds-station__panel {
    background: #fff;
    border-radius: var(--ds-radius-lg);
    padding: 1.25rem;
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06), 0 0 0 1px rgb(14 36 51 / 0.05);
}

.dark .ds-station__panel {
    background: rgb(255 255 255 / 0.04);
    box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08);
}

.ds-station__title {
    display: flex;
    gap: 0.875rem;
    align-items: center;
}

.ds-station__title h2 {
    font-size: 1.125rem;
    font-weight: 750;
    color: var(--ds-navy);
}

.dark .ds-station__title h2 {
    color: #fff;
}

.ds-station__title p {
    font-size: 0.875rem;
    color: var(--ds-steel);
    max-width: 38ch;
}

.ds-station__badge {
    display: grid;
    place-items: center;
    width: 2.75rem;
    height: 2.75rem;
    border-radius: 0.75rem;
    background: var(--ds-navy);
    color: var(--ds-signal);
    flex: none;
}

/* Progress */
.ds-progress__head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 1rem;
    margin-bottom: 0.5rem;
    font-size: 0.875rem;
}

.ds-progress__label {
    color: var(--ds-steel);
    font-weight: 600;
}

.ds-progress__count strong {
    font-size: 1.5rem;
    font-weight: 800;
    color: var(--ds-navy);
}

.dark .ds-progress__count strong {
    color: #fff;
}

.ds-progress__pct {
    margin-inline-start: 0.5rem;
    color: var(--ds-steel);
}

.ds-progress__track {
    height: 0.75rem;
    border-radius: 999px;
    background: rgb(14 36 51 / 0.08);
    overflow: hidden;
}

.dark .ds-progress__track {
    background: rgb(255 255 255 / 0.1);
}

.ds-progress__bar {
    height: 100%;
    border-radius: inherit;
    background: var(--ds-signal);
    transition: width 0.35s ease;
}

.ds-progress.is-done .ds-progress__bar {
    background: var(--ds-ok);
}

.ds-progress__done {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    margin-top: 0.625rem;
    color: var(--ds-ok);
    font-weight: 600;
    font-size: 0.875rem;
}

/* Result card — the invoice number painted large, like on a container door. */
.ds-result {
    --ds-tone: var(--ds-ok);
    background: #fff;
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 1px 2px rgb(14 36 51 / 0.06), 0 0 0 1px rgb(14 36 51 / 0.05);
    border-inline-start: 0.6rem solid var(--ds-tone);
    padding: 1.25rem 1.5rem 1.5rem;
}

.dark .ds-result {
    background: rgb(255 255 255 / 0.04);
}

.ds-result--warning {
    --ds-tone: var(--ds-warn);
}

.ds-result--danger {
    --ds-tone: var(--ds-bad);
}

.ds-result__head {
    display: flex;
    align-items: center;
    gap: 1rem;
}

.ds-result__icon {
    color: var(--ds-tone);
    flex: none;
}

.ds-result__eyebrow {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--ds-tone);
}

.ds-result__invoice {
    font-size: clamp(2.25rem, 5vw, 3.5rem);
    line-height: 1;
    font-weight: 900;
    letter-spacing: 0.01em;
    color: var(--ds-navy);
    word-break: break-all;
}

.dark .ds-result__invoice {
    color: #fff;
}

.ds-result__message {
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-result__message {
    color: #fff;
}

.ds-result__chip {
    margin-inline-start: auto;
    align-self: flex-start;
    padding: 0.3rem 0.7rem;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-size: 0.8rem;
    font-weight: 700;
    white-space: nowrap;
}

.ds-result__grid {
    display: grid;
    gap: 0.875rem 1.5rem;
    margin-top: 1.25rem;
    padding-top: 1.25rem;
    border-top: 1px dashed rgb(14 36 51 / 0.15);
}

@media (min-width: 640px) {
    .ds-result__grid {
        grid-template-columns: 1fr 1fr;
    }
}

.ds-result__grid dt {
    font-size: 0.78rem;
    color: var(--ds-steel);
}

.ds-result__grid dd {
    font-size: 1rem;
    color: rgb(14 36 51 / 0.9);
}

.dark .ds-result__grid dd {
    color: rgb(255 255 255 / 0.88);
}

.ds-result__strong {
    font-size: 1.2rem !important;
    font-weight: 700;
}

.ds-result__actions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 1.25rem;
}

.ds-result__actions:empty {
    display: none;
}

/* Household list */
.ds-household {
    background: #fff;
    border-radius: var(--ds-radius-lg);
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    padding: 1rem 1.25rem;
}

.dark .ds-household {
    background: rgb(255 255 255 / 0.04);
}

.ds-household__head {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-household__head {
    color: #fff;
}

.ds-household__sub {
    margin-inline-start: auto;
    font-weight: 500;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-household__list {
    margin-top: 0.75rem;
    display: grid;
    gap: 0.25rem;
}

.ds-household__list li {
    display: grid;
    grid-template-columns: auto 1fr auto auto;
    gap: 0.75rem;
    align-items: center;
    padding: 0.5rem 0.25rem;
    border-top: 1px solid rgb(14 36 51 / 0.06);
    color: var(--ds-steel);
    font-size: 0.9rem;
}

.ds-household__list li.is-done {
    color: var(--ds-ok);
}

.ds-household__invoice {
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-household__invoice {
    color: #fff;
}

/* Empty state */
.ds-empty {
    display: grid;
    justify-items: center;
    text-align: center;
    gap: 0.5rem;
    padding: 3.5rem 1.5rem;
    border-radius: var(--ds-radius-lg);
    border: 2px dashed rgb(14 36 51 / 0.14);
    color: var(--ds-steel);
}

.ds-empty__title {
    font-size: 1.125rem;
    font-weight: 700;
    color: var(--ds-navy);
}

.dark .ds-empty__title {
    color: #fff;
}

.ds-empty__text {
    max-width: 36ch;
    font-size: 0.9rem;
}

/* Trip progress (dashboard table) */
.ds-trip-progress {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    min-width: 12rem;
    padding-inline: 0.75rem;
}

.ds-trip-progress__track {
    position: relative;
    flex: 1;
    height: 0.5rem;
    border-radius: 999px;
    background: rgb(14 36 51 / 0.08);
    overflow: hidden;
}

.ds-trip-progress__track > span {
    position: absolute;
    inset-block: 0;
    left: 0;
    border-radius: inherit;
}

.ds-trip-progress__loaded {
    background: var(--ds-signal);
}

.ds-trip-progress__delivered {
    background: var(--ds-ok);
}

.ds-trip-progress__nums {
    font-size: 0.85rem;
    font-weight: 700;
    white-space: nowrap;
}

.ds-trip-progress__nums span {
    font-weight: 400;
    color: var(--ds-steel);
}

@media (prefers-reduced-motion: reduce) {
    .ds-progress__bar {
        transition: none;
    }
}

/* Larger stat labels on the inventory widget (kept from the original theme). */
.fi-wi-stats-overview-stat-label {
    font-weight: 600;
}

/* The station's result card already shows the last scan (with the right colour). */
.ds-station .bb-scanner__last {
    display: none;
}

/* =================================================================
 * Sign-in pages — one design per panel (Admin, Partner hub,
 * Warehouse, Delivery). Filament's own form is placed inside.
 * ================================================================= */

.ds-auth-main {
    min-height: 100vh;
    min-height: 100dvh;
}

.ds-auth {
    --ds-input-h: 3.25rem;
    min-height: 100vh;
    min-height: 100dvh;
    color: var(--ds-navy);
    font-family: Archivo, ui-sans-serif, system-ui, sans-serif;
}

/* Company name + logo */
.ds-company {
    display: inline-flex;
    align-items: center;
    gap: 0.875rem;
}

.ds-company__logo {
    width: 3.25rem;
    height: 3.25rem;
    border-radius: 0.75rem;
    object-fit: contain;
    background: #fff;
    flex: none;
}

.ds-company__logo--initials {
    display: grid;
    place-items: center;
    background: var(--ds-signal);
    color: var(--ds-navy);
    font-weight: 900;
    font-size: 1.1rem;
}

.ds-company--sm .ds-company__logo {
    width: 2.5rem;
    height: 2.5rem;
    border-radius: 0.6rem;
    font-size: 0.9rem;
}

.ds-company--lg .ds-company__logo {
    width: 3.75rem;
    height: 3.75rem;
}

.ds-company__text {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
}

.ds-company__name {
    font-size: 1.2rem;
    font-weight: 800;
    letter-spacing: -0.01em;
    line-height: 1.15;
}

.ds-company--lg .ds-company__name {
    font-size: 1.75rem;
}

.ds-company--sm .ds-company__name {
    font-size: 1.05rem;
}

.ds-company__sub {
    font-size: 0.8rem;
    font-weight: 600;
    color: var(--ds-steel);
}

.ds-company--dark {
    color: #fff;
}

.ds-company--dark .ds-company__sub {
    color: #8fa3b3;
}

.ds-company__sub--accent,
.ds-company--dark .ds-company__sub--accent {
    color: var(--ds-signal);
}

/* Shared form styling */
.ds-auth__form {
    width: 100%;
    max-width: 26.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.ds-auth__chip {
    align-self: flex-start;
    font-size: 0.8rem;
    font-weight: 700;
    padding: 0.35rem 0.75rem;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
}

.ds-auth__title {
    margin: 0.5rem 0 0;
    font-size: 2.1rem;
    font-weight: 800;
    letter-spacing: -0.02em;
    line-height: 1.1;
}

.ds-auth__title--xl {
    font-size: clamp(2.2rem, 4vw, 2.75rem);
    letter-spacing: -0.03em;
}

.ds-auth__lead {
    margin: 0 0 1.25rem;
    font-size: 1rem;
    color: var(--ds-steel);
}

.ds-auth__help {
    margin: 1.25rem 0 0;
    font-size: 0.82rem;
    line-height: 1.5;
    color: var(--ds-steel);
    max-width: 26.5rem;
}

.ds-auth .fi-fo-field-label-content {
    font-weight: 600;
    color: var(--ds-navy);
}

.ds-auth .fi-input-wrp {
    min-height: var(--ds-input-h);
    border-radius: 0.65rem;
    align-items: center;
}

.ds-auth .fi-input {
    font-size: 1rem;
}

.ds-auth form .fi-btn {
    min-height: 3.4rem;
    border-radius: 0.65rem;
    font-size: 1.05rem;
    font-weight: 800;
}

.ds-auth--company form .fi-btn,
.ds-auth--warehouse form .fi-btn,
.ds-auth--delivery form .fi-btn {
    background: var(--ds-navy);
    color: #fff;
}

.ds-auth--company form .fi-btn:hover,
.ds-auth--warehouse form .fi-btn:hover,
.ds-auth--delivery form .fi-btn:hover {
    background: var(--ds-navy-3);
}

.ds-auth--company form .fi-btn,
.ds-auth--delivery form .fi-btn {
    border-radius: 999px;
}

/* ---------- Admin: navy story + form */
.ds-auth--admin {
    display: grid;
    background: var(--ds-deck);
}

@media (min-width: 1024px) {
    .ds-auth--admin {
        grid-template-columns: minmax(28rem, 44%) 1fr;
    }
}

.ds-auth-admin__story {
    position: relative;
    overflow: hidden;
    background: var(--ds-navy);
    color: #fff;
    padding: 2.5rem 1.75rem;
    display: flex;
    flex-direction: column;
    gap: 2rem;
}

@media (min-width: 1024px) {
    .ds-auth-admin__story {
        padding: 3.5rem 4rem;
        justify-content: space-between;
    }
}

.ds-auth-admin__pitch {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
}

.ds-auth-admin__pitch h1 {
    margin: 0;
    font-size: clamp(2.1rem, 4.2vw, 3.5rem);
    line-height: 1.03;
    font-weight: 800;
    letter-spacing: -0.03em;
    max-width: 14ch;
}

.ds-auth-admin__pitch p {
    margin: 0;
    font-size: 1.05rem;
    line-height: 1.55;
    color: #b7c4cf;
    max-width: 34ch;
}

.ds-auth-admin__foot {
    position: relative;
    z-index: 1;
    padding-top: 1.25rem;
    border-top: 1px solid rgb(255 255 255 / 0.12);
    font-size: 0.9rem;
    color: #8fa3b3;
}

.ds-auth-admin__ribs {
    position: absolute;
    right: -9rem;
    top: 7rem;
    width: 26rem;
    height: 35rem;
    border-radius: 1.75rem;
    background: repeating-linear-gradient(90deg, #12304a 0 34px, var(--ds-navy) 34px 46px);
    opacity: 0.7;
}

@media (max-width: 1023px) {
    .ds-auth-admin__foot,
    .ds-auth-admin__pitch p {
        display: none;
    }

    .ds-auth-admin__ribs {
        display: none;
    }
}

@media (max-width: 1023px) {
    /* On small screens the card already shows the company. */
    .ds-auth-warehouse__brand {
        display: none;
    }
}

.ds-auth__form-side {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2.5rem 1.75rem 3rem;
}

/* ---------- Partner hub: form + yellow steps */
.ds-auth--company {
    display: grid;
    background: var(--ds-signal);
}

@media (min-width: 1024px) {
    .ds-auth--company {
        grid-template-columns: minmax(30rem, 42%) 1fr;
    }
}

.ds-auth__form-side--white {
    background: #fff;
    flex-direction: column;
    align-items: stretch;
    justify-content: space-between;
    gap: 2.5rem;
}

@media (min-width: 1024px) {
    .ds-auth__form-side--white {
        padding: 4rem 5.5rem;
    }
}

.ds-auth-company__story {
    padding: 3rem 1.75rem;
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 2.5rem;
}

@media (min-width: 1024px) {
    .ds-auth-company__story {
        padding: 4.5rem 5rem;
    }
}

.ds-auth-company__story h1 {
    margin: 0;
    font-size: clamp(2.25rem, 4.5vw, 4rem);
    line-height: 0.98;
    font-weight: 900;
    letter-spacing: -0.035em;
    max-width: 14ch;
}

.ds-auth-company__steps {
    margin: 0;
    padding: 0;
    list-style: none;
    display: flex;
    flex-direction: column;
    max-width: 35rem;
}

.ds-auth-company__steps li {
    position: relative;
    display: grid;
    grid-template-columns: 2.75rem 1fr;
    gap: 1.25rem;
    padding-bottom: 1.6rem;
}

.ds-auth-company__steps li:not(:last-child)::before {
    content: '';
    position: absolute;
    left: calc(1.375rem - 1.5px);
    top: 2.9rem;
    bottom: 0.3rem;
    width: 3px;
    background: rgb(14 36 51 / 0.35);
}

.ds-auth-company__num {
    width: 2.75rem;
    height: 2.75rem;
    border-radius: 999px;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-weight: 800;
    font-size: 1.1rem;
}

.ds-auth-company__steps strong {
    display: block;
    padding-top: 0.45rem;
    font-size: 1.25rem;
    font-weight: 800;
}

.ds-auth-company__steps span:not(.ds-auth-company__num) {
    display: block;
    margin-top: 0.25rem;
    font-size: 0.95rem;
    color: #3b3000;
}

/* ---------- Warehouse: container side + card */
.ds-auth--warehouse {
    position: relative;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 2rem;
    padding: 2.5rem 1.25rem;
    background: repeating-linear-gradient(90deg, var(--ds-navy) 0 52px, #12304a 52px 60px, #0b1f2d 60px 64px);
}

.ds-auth-warehouse__stripe {
    position: absolute;
    inset-block: 0;
    left: 0;
    width: 1.125rem;
    background: var(--ds-signal);
}

@media (min-width: 1024px) {
    .ds-auth-warehouse__brand {
        position: absolute;
        left: 4.5rem;
        top: 4rem;
    }
}

.ds-auth-warehouse__card {
    position: relative;
    width: 100%;
    max-width: 30rem;
    background: #fff;
    border-radius: 1.4rem;
    padding: 2.75rem 2rem 2.25rem;
    box-shadow: 0 40px 80px -30px rgb(0 0 0 / 0.6);
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

@media (min-width: 640px) {
    .ds-auth-warehouse__card {
        padding: 2.75rem 3rem 2.5rem;
    }
}

.ds-auth-warehouse__tab {
    position: absolute;
    left: 3rem;
    right: 3rem;
    top: 0;
    height: 6px;
    border-radius: 0 0 6px 6px;
    background: var(--ds-signal);
}

.ds-auth-warehouse__card .ds-auth__title {
    margin-bottom: 0.75rem;
    font-size: 1.6rem;
}

/* ---------- Delivery: phone first */
.ds-auth--delivery {
    display: flex;
    flex-direction: column;
    background: #fff;
    max-width: 34rem;
    margin-inline: auto;
}

@media (min-width: 640px) {
    .ds-auth-main:has(.ds-auth--delivery) {
        background: var(--ds-navy);
        padding: 3rem 1rem;
    }

    .ds-auth--delivery {
        min-height: auto;
        border-radius: 1.5rem;
        overflow: hidden;
        box-shadow: 0 40px 80px -30px rgb(0 0 0 / 0.6);
    }
}

.ds-auth-delivery__top {
    background: var(--ds-signal);
    padding: 2.25rem 1.75rem 2rem;
    display: flex;
    flex-direction: column;
    gap: 1.4rem;
}

.ds-auth-delivery__top .ds-company__sub {
    color: var(--ds-navy);
    font-weight: 700;
}

.ds-auth-delivery__top h1 {
    margin: 0;
    font-size: 2.25rem;
    line-height: 1;
    font-weight: 900;
    letter-spacing: -0.035em;
    max-width: 12ch;
}

.ds-auth-delivery__form {
    flex: 1;
    padding: 1.75rem 1.75rem 2.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.ds-auth-delivery__form .ds-auth__title {
    margin-top: 0;
    font-size: 1.75rem;
}

.ds-auth--delivery {
    --ds-input-h: 3.5rem;
}

.dark .ds-auth--admin .ds-auth__form-side,
.dark .ds-auth__form-side--white,
.dark .ds-auth-warehouse__card,
.dark .ds-auth--delivery {
    color-scheme: light;
}

/* On yellow backgrounds the initials badge flips to navy. */
.ds-auth-delivery__top .ds-company__logo--initials {
    background: var(--ds-navy);
    color: var(--ds-signal);
}

/* Sign-in pages are always light: readable text even if dark mode slips through. */
.ds-auth {
    color-scheme: light;
}

.ds-auth .fi-input-wrp {
    background-color: #fff;
}

.ds-auth .fi-input,
.ds-auth .fi-input-wrp input {
    color: var(--ds-navy);
    -webkit-text-fill-color: var(--ds-navy);
    caret-color: var(--ds-navy);
}

.ds-auth .fi-input::placeholder {
    color: #8b98a3;
    -webkit-text-fill-color: #8b98a3;
}

/* Safari / Chrome autofill keeps a readable white box. */
.ds-auth input:-webkit-autofill {
    -webkit-box-shadow: 0 0 0 1000px #fff inset;
    -webkit-text-fill-color: var(--ds-navy);
}

/* Uploaded company logo in the panel header. */
.ds-brand__mark--image {
    object-fit: contain;
    border-radius: 0.5rem;
    background: #fff;
}

.ds-brand__name {
    max-width: 11rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

/* Delivery attempts history (dispatcher view). */
.ds-attempts {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

.ds-attempts__item {
    padding: 0.875rem 1rem;
    border-radius: var(--ds-radius);
    background: rgb(14 36 51 / 0.04);
}

.dark .ds-attempts__item {
    background: rgb(255 255 255 / 0.05);
}

.ds-attempts__head {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
}

.ds-attempts__when,
.ds-attempts__who {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-attempts__who {
    margin-top: 0.4rem;
}

.ds-attempts__note {
    margin-top: 0.4rem;
    font-size: 0.95rem;
}

.ds-attempts__photos {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    margin-top: 0.6rem;
}

.ds-attempts__photos img {
    width: 6rem;
    height: 6rem;
    object-fit: cover;
    border-radius: 0.5rem;
}

/* =================================================================
 * Driver dashboard (Delivery panel) — phone first.
 * ================================================================= */
.ds-driver {
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
    max-width: 40rem;
    color: var(--ds-navy);
}

.dark .ds-driver {
    color: #fff;
}

.ds-driver h2 {
    margin: 0;
    font-size: 1.15rem;
    font-weight: 800;
    display: flex;
    align-items: center;
    gap: 0.5rem;
}

.ds-driver__muted {
    display: block;
    font-size: 0.78rem;
    color: #8fa3b3;
}

.ds-driver__soft {
    display: block;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

/* Trip card */
.ds-driver__trip {
    background: var(--ds-navy);
    color: #fff;
    border-radius: 1.1rem;
    padding: 1.25rem;
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-driver__trip .ds-driver__soft {
    color: #b7c4cf;
}

.ds-driver__trip-head {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 0.75rem;
}

.ds-driver__trip-no {
    display: block;
    font-size: 1.9rem;
    font-weight: 900;
    letter-spacing: 0.01em;
    line-height: 1.1;
}

.ds-driver__pill {
    padding: 0.35rem 0.8rem;
    border-radius: 999px;
    background: var(--ds-signal);
    color: var(--ds-navy);
    font-size: 0.8rem;
    font-weight: 800;
    white-space: nowrap;
}

.ds-driver__trip-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.75rem;
    font-size: 0.9rem;
}

.ds-driver__trip-grid strong {
    display: block;
    font-weight: 700;
}

.ds-driver__progress-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 0.5rem;
    color: #b7c4cf;
}

.ds-driver__progress-head strong {
    font-size: 1.75rem;
    font-weight: 900;
    color: #fff;
}

.ds-driver__left {
    font-weight: 700;
    color: var(--ds-signal);
}

.ds-driver__bar {
    height: 0.75rem;
    border-radius: 999px;
    background: rgb(255 255 255 / 0.12);
    overflow: hidden;
}

.ds-driver__bar > span {
    display: block;
    height: 100%;
    border-radius: inherit;
    background: var(--ds-signal);
}

.ds-driver__warn {
    margin-top: 0.6rem;
    font-size: 0.85rem;
    color: #ffd7d7;
}

/* All delivered */
.ds-driver__trip--done {
    background: var(--ds-ok);
}

.ds-driver__trip--done .ds-driver__bar {
    background: rgb(255 255 255 / 0.25);
}

.ds-driver__trip--done .ds-driver__bar > span {
    background: #fff;
}

.ds-driver__done-title {
    font-size: 1.8rem;
    font-weight: 900;
    line-height: 1.05;
}

.ds-driver__done-sub {
    color: #d4f0e4;
}

.ds-driver__card {
    background: #fff;
    border-radius: 1rem;
    padding: 1.1rem;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
}

.dark .ds-driver__card {
    background: rgb(255 255 255 / 0.05);
}

/* Big buttons */
.ds-driver__actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.75rem;
}

.ds-driver__action {
    min-height: 4rem;
    border-radius: 0.9rem;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.6rem;
    font-weight: 800;
    font-size: 1rem;
    background: #fff;
    color: var(--ds-navy);
    box-shadow: inset 0 0 0 1.5px #d5dde3;
}

.ds-driver__action--primary {
    background: var(--ds-signal);
    box-shadow: none;
}

.ds-driver__action:focus-visible {
    outline: 3px solid var(--ds-navy);
    outline-offset: 2px;
}

/* Sections */
.ds-driver__section {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
}

.ds-driver__section-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 1rem;
}

.ds-driver__count {
    font-size: 0.8rem;
    padding: 0.1rem 0.55rem;
    border-radius: 999px;
    background: var(--ds-signal);
    color: var(--ds-navy);
}

/* Stop card */
.ds-stop {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.85rem 0.9rem;
    border-radius: 0.9rem;
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-stop {
    background: rgb(255 255 255 / 0.05);
}

.ds-stop--priority {
    background: #fff8db;
    box-shadow: inset 0 0 0 1.5px var(--ds-signal);
}

.ds-stop--problem {
    box-shadow: inset 0 0 0 1.5px #f2c4c4;
}

.ds-stop--soft {
    background: var(--ds-deck);
    box-shadow: none;
}

.dark .ds-stop--priority,
.dark .ds-stop--soft {
    background: rgb(255 255 255 / 0.06);
}

.ds-stop__text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
}

.ds-stop__label {
    font-size: 0.8rem;
    font-weight: 700;
    color: #b02e2e;
}

.ds-stop__invoice {
    font-weight: 900;
    font-size: 1.02rem;
    word-break: break-word;
}

.ds-stop__name {
    font-weight: 700;
}

.ds-stop__address,
.ds-stop__remark {
    font-size: 0.88rem;
    color: #4a5865;
}

.dark .ds-stop__address,
.dark .ds-stop__remark {
    color: #b7c4cf;
}

.ds-stop__count {
    font-size: 0.82rem;
    font-weight: 700;
    color: #2f6f9f;
}

.ds-stop__call {
    width: 3rem;
    height: 3rem;
    flex: none;
    border-radius: 999px;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: #fff;
}

/* Areas */
.ds-driver__areas {
    background: #fff;
    border-radius: 1rem;
    overflow: hidden;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-driver__areas {
    background: rgb(255 255 255 / 0.04);
}

.ds-driver__area + .ds-driver__area {
    border-top: 1px solid #e8edf1;
}

.ds-driver__area-btn {
    width: 100%;
    min-height: 4rem;
    padding: 0.75rem 1rem;
    display: flex;
    align-items: center;
    gap: 0.75rem;
    text-align: left;
}

.ds-driver__area-name {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.1rem;
}

.ds-driver__area-name span,
.ds-driver__area-count span {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-driver__area-count {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
}

.ds-driver__area-count strong {
    font-size: 1.15rem;
    font-weight: 900;
}

.ds-driver__chev {
    color: var(--ds-steel);
    transition: transform 0.2s;
}

.ds-driver__chev.is-open {
    transform: rotate(180deg);
}

.ds-driver__stops {
    padding: 0 1rem 0.9rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

/* Delivered today */
.ds-driver__list {
    background: #fff;
    border-radius: 1rem;
    padding: 0.25rem 1rem;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.dark .ds-driver__list {
    background: rgb(255 255 255 / 0.04);
}

.ds-driver__done-row {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.75rem 0;
}

.ds-driver__done-row + .ds-driver__done-row {
    border-top: 1px solid #e8edf1;
}

.ds-driver__done-row img,
.ds-driver__nophoto {
    width: 3.25rem;
    height: 3.25rem;
    border-radius: 0.6rem;
    object-fit: cover;
    flex: none;
}

.ds-driver__nophoto {
    display: grid;
    place-items: center;
    background: #e4e9ed;
    color: var(--ds-steel);
}

.ds-driver__done-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
}

.ds-driver__done-text span,
.ds-driver__done-when span:last-child {
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-driver__done-when {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
}

.ds-driver__ok {
    font-size: 0.82rem;
    font-weight: 700;
    color: var(--ds-ok);
}

/* Not on a trip */
.ds-driver__empty {
    border: 2px dashed #c9d3da;
    border-radius: 1.1rem;
    padding: 2.25rem 1.5rem;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.85rem;
}

.ds-driver__empty h2 {
    font-size: 1.35rem;
}

.ds-driver__empty p {
    max-width: 30ch;
    color: #4a5865;
}

.dark .ds-driver__empty p {
    color: #b7c4cf;
}

.ds-driver__empty-icon {
    width: 4.5rem;
    height: 4.5rem;
    border-radius: 1.25rem;
    display: grid;
    place-items: center;
    background: var(--ds-navy);
    color: var(--ds-signal);
}

@media (prefers-reduced-motion: reduce) {
    .ds-driver__chev {
        transition: none;
    }
}

/* Undo on "Delivered today" */
.ds-driver__done-when {
    gap: 0.3rem;
}

.ds-driver__undo {
    display: flex;
    align-items: center;
    gap: 0.4rem;
}

.ds-driver__undo > span {
    font-size: 0.75rem;
    color: var(--ds-steel);
}

.ds-driver__locked {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    font-size: 0.78rem;
    color: var(--ds-steel);
}

.ds-attempts__item--undo {
    border-left: 3px solid var(--ds-warn, #e08a00);
}

/* ------------------------------------------------------------------ trip board (Delivery Log widgets) */

.ds-board {
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-board__cards {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0.875rem;
}

@media (max-width: 1024px) {
    .ds-board__cards { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

.ds-board__card {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    padding: 1rem 1.1rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    color: var(--ds-navy);
    text-decoration: none;
    transition: box-shadow 0.15s;
}

.ds-board__card:hover { box-shadow: 0 0 0 1px rgb(14 36 51 / 0.2); }
.ds-board__card:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }
.ds-board__card.is-active { box-shadow: inset 0 0 0 2px var(--ds-navy); }

.ds-board__card-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 0.875rem;
    font-weight: 600;
    color: #4a5865;
}

.ds-board__card-value {
    font-size: 2.1rem;
    font-weight: 800;
    line-height: 1;
}

.ds-board__card-sub,
.ds-board__muted {
    font-size: 0.8rem;
    color: var(--ds-steel);
}

.ds-board__dot { width: 0.6rem; height: 0.6rem; border-radius: 999px; }
.ds-board__dot--navy { background: var(--ds-navy); }
.ds-board__dot--yellow { background: var(--ds-signal); }
.ds-board__dot--ok { background: var(--ds-ok); }
.ds-board__dot--bad { background: var(--ds-bad); }

.ds-board__bar {
    display: block;
    width: 100%;
    height: 0.4rem;
    border-radius: 999px;
    background: #e8edf1;
    overflow: hidden;
}

.ds-board__bar-fill { display: block; height: 100%; border-radius: 999px; background: var(--ds-navy); }
.ds-board__bar-fill--yellow { background: var(--ds-signal); }
.ds-board__bar-fill--ok { background: var(--ds-ok); }
.ds-board__bar-fill--warn { background: var(--ds-warn); }

.ds-board__panel {
    padding: 1.1rem 1.25rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
}

.ds-board__panel-head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
}

.ds-board__panel-head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-board__panel-head span { font-size: 0.8rem; color: var(--ds-steel); }

.ds-board__attention li {
    display: grid;
    grid-template-columns: 9.5rem minmax(0, 1fr) auto auto;
    gap: 1rem;
    align-items: center;
    padding: 0.7rem 0;
}

.ds-board__attention li + li { border-top: 1px solid #eef1f4; }

.ds-board__attention-text { font-size: 0.9rem; color: var(--ds-navy); }
.ds-board__detail { display: block; font-size: 0.8rem; color: #4a5865; }
.ds-board__truck { white-space: nowrap; }

@media (max-width: 768px) {
    .ds-board__attention li { grid-template-columns: 1fr auto; }
    .ds-board__attention-text { grid-column: 1 / -1; }
    .ds-board__truck { display: none; }
}

.ds-board__tag {
    padding: 0.2rem 0.6rem;
    border-radius: 999px;
    font-size: 0.75rem;
    font-weight: 700;
    text-align: center;
    background: #eef1f4;
    color: #4a5865;
}

.ds-board__tag--bad { background: #fdecea; color: var(--ds-bad); }
.ds-board__tag--warn { background: #fff1dc; color: #9a5b00; }

.ds-board__trends {
    display: grid;
    grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr);
    gap: 0.875rem;
}

@media (max-width: 1024px) {
    .ds-board__trends { grid-template-columns: 1fr; }
}

.ds-board__chart {
    display: flex;
    align-items: flex-end;
    gap: 0.4rem;
    height: 11rem;
}

.ds-board__col {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: flex-end;
    gap: 0.25rem;
    height: 100%;
}

.ds-board__col-n,
.ds-board__col-day { font-size: 0.7rem; color: var(--ds-steel); }

.ds-board__col-bar {
    width: 100%;
    max-width: 1.75rem;
    border-radius: 4px 4px 0 0;
    background: var(--ds-navy);
}

.ds-board__col-bar.is-today { background: var(--ds-signal); }
.ds-board__col-bar.is-zero { background: #d5dde3; }

.ds-board__reason { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-board__reason .ds-board__bar { height: 0.5rem; background: #eef1f4; }
.ds-board__reason-row { display: flex; justify-content: space-between; font-size: 0.875rem; color: var(--ds-navy); }

.dark .ds-board__card,
.dark .ds-board__panel { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); color: #e6edf3; }
.dark .ds-board__card.is-active { box-shadow: inset 0 0 0 2px var(--ds-signal); }
.dark .ds-board__card-head,
.dark .ds-board__detail { color: #b7c4cf; }
.dark .ds-board__panel-head h2,
.dark .ds-board__attention-text,
.dark .ds-board__reason-row { color: #e6edf3; }
.dark .ds-board__attention li + li { border-color: rgb(255 255 255 / 0.08); }
.dark .ds-board__col-bar { background: #7fa3bf; }
.dark .ds-board__col-bar.is-today { background: var(--ds-signal); }

/* ------------------------------------------------------------------ install as an app (PWA) */

.ds-pwa-install { display: none; }
html[data-pwa-installable] .ds-pwa-install { display: block; }

.ds-pwa-sheet:not([hidden]) {
    position: fixed;
    inset: 0;
    z-index: 60;
    display: flex;
    align-items: flex-end;
    justify-content: center;
}

.ds-pwa-sheet__backdrop { position: absolute; inset: 0; background: rgb(14 36 51 / 0.45); }

.ds-pwa-sheet__panel {
    position: relative;
    width: 100%;
    max-width: 30rem;
    padding: 1.4rem 1.4rem calc(1.9rem + env(safe-area-inset-bottom));
    border-radius: 1.4rem 1.4rem 0 0;
    background: #fff;
    color: var(--ds-navy);
    display: flex;
    flex-direction: column;
    gap: 1rem;
}

.ds-pwa-sheet__grip { align-self: center; width: 2.5rem; height: 0.3rem; border-radius: 999px; background: #d5dde3; }
.ds-pwa-sheet__head { display: flex; gap: 0.9rem; align-items: center; }
.ds-pwa-sheet__head img { width: 3.5rem; height: 3.5rem; border-radius: 0.9rem; flex: none; }
.ds-pwa-sheet__head > span { display: flex; flex-direction: column; gap: 0.15rem; }
.ds-pwa-sheet__head strong { font-size: 1.1rem; }
.ds-pwa-sheet__head span span { font-size: 0.875rem; color: #4a5865; }

.ds-pwa-sheet__steps { display: flex; flex-direction: column; gap: 0.6rem; }

.ds-pwa-sheet__steps li {
    display: flex;
    gap: 0.75rem;
    align-items: center;
    padding: 0.75rem 0.9rem;
    border-radius: 0.75rem;
    background: var(--ds-deck);
    font-size: 0.95rem;
}

.ds-pwa-sheet__steps li > span:first-child {
    width: 1.75rem;
    height: 1.75rem;
    flex: none;
    border-radius: 999px;
    background: var(--ds-navy);
    color: var(--ds-signal);
    font-weight: 800;
    display: flex;
    align-items: center;
    justify-content: center;
}

.ds-pwa-share { display: inline-block; padding: 0 0.35rem; border: 1.5px solid #0a84ff; border-radius: 0.35rem; color: #0a84ff; font-size: 0.8rem; }

.ds-pwa-sheet__close,
.ds-pwa-offline button {
    height: 3.1rem;
    border-radius: 0.75rem;
    font: inherit;
    font-weight: 700;
    font-size: 1rem;
    cursor: pointer;
}

.ds-pwa-sheet__close { border: 1.5px solid #d5dde3; background: #fff; color: var(--ds-navy); }

.ds-pwa-offline:not([hidden]) {
    position: fixed;
    inset: 0;
    z-index: 70;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1.75rem;
    background: var(--ds-deck);
    color: var(--ds-navy);
}

.ds-pwa-offline__body { width: 100%; max-width: 28rem; display: flex; flex-direction: column; gap: 1.1rem; }

.ds-pwa-offline__icon {
    width: 4.5rem;
    height: 4.5rem;
    border-radius: 1.4rem;
    background: #fff1dc;
    color: var(--ds-warn);
    display: flex;
    align-items: center;
    justify-content: center;
}

.ds-pwa-offline h2 { font-size: 1.75rem; font-weight: 800; line-height: 1.15; }
.ds-pwa-offline p { font-size: 1rem; line-height: 1.5; color: #4a5865; }

.ds-pwa-offline ul {
    padding: 0.9rem 1rem;
    border-radius: 0.9rem;
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    font-size: 0.95rem;
}

.ds-pwa-offline li { display: flex; gap: 0.6rem; }
.ds-pwa-offline .is-ok { color: var(--ds-ok); font-weight: 800; }
.ds-pwa-offline .is-warn { color: var(--ds-warn); font-weight: 800; }
.ds-pwa-offline button { border: 0; background: var(--ds-signal); color: var(--ds-navy); font-weight: 800; height: 3.5rem; }
.ds-pwa-offline button[disabled] { background: #d5dde3; color: #4a5865; }

.ds-pwa-sheet button:focus-visible,
.ds-pwa-offline button:focus-visible { outline: 3px solid var(--ds-navy); outline-offset: 3px; }

/* App icon & favicon page */
.ds-icons-preview {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 1.25rem 2rem;
    padding: 1rem 1.25rem;
    border-radius: var(--ds-radius-lg);
    background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}

.ds-icons-preview__tab {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    min-width: 12rem;
    padding: 0.5rem 0.9rem;
    border-radius: 0.6rem 0.6rem 0 0;
    background: var(--ds-deck);
    font-size: 0.85rem;
    color: var(--ds-navy);
}

.ds-icons-preview__phone {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.4rem;
    padding: 0.9rem 1.2rem;
    border-radius: 1rem;
    background: linear-gradient(160deg, #2b4d66, #0e2433);
    color: #fff;
    font-size: 0.75rem;
}

.ds-icons-preview__phone img { border-radius: 0.9rem; }

.ds-icons-preview p {
    flex: 1 1 18rem;
    font-size: 0.85rem;
    line-height: 1.5;
    color: var(--ds-steel);
}

.dark .ds-icons-preview { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-icons-preview__tab { background: #0e2433; color: #e6edf3; }
.dark .ds-icons-preview p { color: #b7c4cf; }

/* Scan progress: left, last scan, problems */
.ds-progress__meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem 1rem;
    margin-top: 0.6rem;
    font-size: 0.85rem;
    color: var(--ds-steel);
}

.ds-progress__left { font-weight: 700; color: var(--ds-navy); }
.dark .ds-progress__left { color: var(--ds-signal); }
.ds-progress__problems { color: var(--ds-bad); font-weight: 600; }

/* Module boards (Containers, Vehicles, Invoice Issue) — extend the trip board styles */
.ds-board__card--static:hover { box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); }
.ds-board__card-value.is-alert { color: var(--ds-bad); }
.ds-board__dot--steel { background: var(--ds-steel); }
.ds-board__dot--warn { background: var(--ds-warn); }
.ds-board__bar-fill--teal { background: #3fa7b9; }
.ds-board__bar-fill--bad { background: var(--ds-bad); }
.ds-board__trends--even { grid-template-columns: repeat(2, minmax(0, 1fr)); }

@media (max-width: 1024px) {
    .ds-board__trends--even { grid-template-columns: 1fr; }
}

.ds-board__photos {
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    gap: 0.75rem;
}

@media (max-width: 1024px) {
    .ds-board__photos { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

.ds-board__photos figure { position: relative; display: flex; flex-direction: column; gap: 0.4rem; margin: 0; }
.ds-board__photos img,
.ds-board__photo-none { width: 100%; height: 7rem; border-radius: 0.6rem; object-fit: cover; background: var(--ds-deck); }
.ds-board__photo-none { display: flex; align-items: center; justify-content: center; font-size: 0.8rem; color: var(--ds-steel); }
.ds-board__photos .ds-board__tag { position: absolute; left: 0.4rem; top: 0.4rem; }
.ds-board__photos figcaption { display: flex; flex-direction: column; font-size: 0.8rem; color: var(--ds-steel); }
.ds-board__photos figcaption strong { font-size: 0.9rem; color: var(--ds-navy); }
.dark .ds-board__photos figcaption strong { color: #e6edf3; }

/* Open issues slider (Invoice Issue widget) */
.ds-slider { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-slider__viewport { overflow: hidden; margin: 0 -0.4rem; }
.ds-slider__track { display: flex; transition: transform 0.5s ease; }
.ds-slider__slide { flex: 0 0 25%; margin: 0; padding: 0 0.4rem; box-sizing: border-box; }

.ds-slider__card {
    height: 100%;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    padding: 0.6rem;
    border-radius: 0.8rem;
    background: var(--ds-deck);
}

.ds-slider__photo { position: relative; }
.ds-slider__photo img,
.ds-slider__photo .ds-board__photo-none { width: 100%; height: 8.5rem; border-radius: 0.6rem; object-fit: cover; background: #e3e8ec; display: flex; }
.ds-slider__photo .ds-board__tag { position: absolute; left: 0.4rem; top: 0.4rem; }
.ds-slider__card figcaption { display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.8rem; color: var(--ds-steel); flex: 1; }
.ds-slider__card figcaption strong { font-size: 0.95rem; color: var(--ds-navy); }
.ds-slider__note { color: #4a5865; line-height: 1.35; }

.ds-slider__controls { display: flex; align-items: center; justify-content: center; gap: 0.75rem; }

.ds-slider__arrow {
    width: 2.25rem;
    height: 2.25rem;
    border-radius: 999px;
    border: 1.5px solid #d5dde3;
    background: #fff;
    color: var(--ds-navy);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
}

.ds-slider__dots { display: flex; gap: 0.4rem; }
.ds-slider__dot { width: 0.55rem; height: 0.55rem; border-radius: 999px; border: 0; padding: 0; background: #d5dde3; cursor: pointer; }
.ds-slider__dot.is-active { width: 1.4rem; background: var(--ds-navy); }
.ds-slider__arrow:focus-visible,
.ds-slider__dot:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }

.ds-slider__empty { display: flex; align-items: center; gap: 0.5rem; font-size: 0.9rem; color: var(--ds-ok); }

@media (prefers-reduced-motion: reduce) {
    .ds-slider__track { transition: none; }
}

.dark .ds-slider__card { background: #0e2433; }
.dark .ds-slider__card figcaption strong { color: #e6edf3; }
.dark .ds-slider__note { color: #b7c4cf; }
.dark .ds-slider__arrow { background: #10283a; border-color: rgb(255 255 255 / 0.15); color: #e6edf3; }
.dark .ds-slider__dot.is-active { background: var(--ds-signal); }
.ds-slider__counter { min-width: 4.5rem; text-align: center; font-size: 0.85rem; font-weight: 700; color: var(--ds-navy); font-variant-numeric: tabular-nums; }
.dark .ds-slider__counter { color: #e6edf3; }

/* Boxes by hub (Admin dashboard) */
.ds-board__dot--teal { background: #3fa7b9; }
.ds-hubs__head { display: flex; justify-content: space-between; align-items: flex-start; gap: 1rem; flex-wrap: wrap; }
.ds-hubs__head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-hubs__legend { display: flex; flex-wrap: wrap; gap: 0.35rem 1rem; margin-top: 0.35rem; font-size: 0.8rem; color: #4a5865; }
.ds-hubs__legend span { display: inline-flex; align-items: center; gap: 0.35rem; }
.ds-hubs__legend i { width: 0.75rem; height: 0.75rem; border-radius: 3px; }
.ds-hubs .is-wait { background: #3fa7b9; }
.ds-hubs .is-load { background: var(--ds-signal); }
.ds-hubs .is-out { background: var(--ds-navy); }
.ds-hubs .is-done { background: var(--ds-ok); }
.ds-hubs__sort { display: flex; gap: 0.35rem; }
.ds-hubs__sort button { height: 2rem; padding: 0 0.75rem; border-radius: 0.5rem; border: 0; background: #eef1f4; color: #4a5865; font-size: 0.8rem; font-weight: 700; cursor: pointer; }
.ds-hubs__sort button.is-active { background: var(--ds-navy); color: #fff; }
.ds-hubs__sort button:focus-visible, .ds-hubs__row:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }

.ds-hubs__table { display: flex; flex-direction: column; overflow-x: auto; }
.ds-hubs__row {
    display: grid;
    grid-template-columns: 13rem minmax(8rem, 1fr) 5rem 5rem 5.5rem 5.5rem 6.5rem 5rem;
    align-items: center;
    min-width: 54rem;
    padding: 0.7rem 0.25rem;
    border-top: 1px solid #f0f3f5;
    font-size: 0.9rem;
    color: var(--ds-navy);
    text-decoration: none;
    font-variant-numeric: tabular-nums;
}
.ds-hubs__row > span:nth-child(n + 3) { text-align: right; }
a.ds-hubs__row:hover { background: #f8fafb; }
.ds-hubs__row--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }
.ds-hubs__row--total { font-weight: 800; background: #f8fafb; border-top: 1px solid #e8edf1; }
.ds-hubs__name { display: flex; flex-direction: column; }
.ds-hubs__name small { font-size: 0.75rem; color: var(--ds-steel); }
.ds-hubs__bar { display: flex; align-items: center; gap: 0.6rem; padding-right: 1rem; }
.ds-hubs__bar b { min-width: 2.5rem; text-align: right; font-size: 0.85rem; }
.ds-hubs__track { flex: 1; display: flex; height: 0.85rem; border-radius: 4px; overflow: hidden; background: var(--ds-deck); }
.ds-hubs__track span { display: block; height: 100%; }
.ds-hubs .is-good { color: var(--ds-ok); font-weight: 700; background: none; }
.ds-hubs .is-muted { color: #4a5865; }
.ds-hubs .is-bad { color: var(--ds-bad); font-weight: 700; }

.dark .ds-hubs__row { color: #e6edf3; border-color: rgb(255 255 255 / 0.08); }
.dark a.ds-hubs__row:hover, .dark .ds-hubs__row--total { background: #0e2433; }
.dark .ds-hubs__head h2 { color: #e6edf3; }
.dark .ds-hubs .is-out { background: #7fa3bf; }
.dark .ds-hubs__track { background: #0e2433; }
.dark .ds-hubs__sort button { background: #0e2433; color: #b7c4cf; }
.dark .ds-hubs__sort button.is-active { background: var(--ds-signal); color: var(--ds-navy); }
.dark .ds-hubs .is-muted { color: #b7c4cf; }

/* Partner hub: your boxes as steps */
.ds-hubsteps { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-hubsteps h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-hubsteps__row { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.75rem; counter-reset: step; }
@media (max-width: 900px) { .ds-hubsteps__row { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
.ds-hubsteps__step {
    display: flex; flex-direction: column; gap: 0.35rem;
    padding: 1rem 1.1rem; border-radius: var(--ds-radius-lg); background: #fff;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); border-top: 4px solid var(--ds-navy);
}
.ds-hubsteps__step.is-wait { border-top-color: #3fa7b9; }
.ds-hubsteps__step.is-load { border-top-color: var(--ds-signal); }
.ds-hubsteps__step.is-done { border-top-color: var(--ds-ok); }
.ds-hubsteps__label { font-size: 0.85rem; font-weight: 600; color: #4a5865; }
.ds-hubsteps__value { font-size: 2rem; font-weight: 800; line-height: 1; color: var(--ds-navy); font-variant-numeric: tabular-nums; }
.ds-hubsteps__sub, .ds-hubsteps__note { font-size: 0.8rem; color: var(--ds-steel); }
.ds-hubsteps__alert {
    display: flex; align-items: center; gap: 1rem; padding: 1rem 1.1rem;
    border-radius: var(--ds-radius-lg); background: #fff8db; box-shadow: 0 0 0 1px #f3d77a; color: var(--ds-navy);
}
.ds-hubsteps__alert > span { flex: 1; display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.9rem; }
.ds-hubsteps__alert > span > span { color: #4a5865; }
@media (max-width: 640px) { .ds-hubsteps__alert { flex-wrap: wrap; } }
.dark .ds-hubsteps h2, .dark .ds-hubsteps__value { color: #e6edf3; }
.dark .ds-hubsteps__step { background: #10283a; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-hubsteps__label { color: #b7c4cf; }
.dark .ds-hubsteps__alert { background: rgb(120 90 0 / 0.25); box-shadow: 0 0 0 1px rgb(243 215 122 / 0.4); color: #e6edf3; }
.dark .ds-hubsteps__alert > span > span { color: #d8c690; }

/* ------------------------------------------------------------------ partner hub (Company) panel */
.ds-co { display: flex; flex-direction: column; gap: 1rem; }
.ds-co__h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); margin-bottom: 1rem; }
.ds-co__link { font-size: 0.85rem; font-weight: 700; color: #2f6f9f; white-space: nowrap; }
.ds-co__num { font-variant-numeric: tabular-nums; }

.ds-co__tabs { display: flex; gap: 0.35rem; }
.ds-co__tabs button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.5rem; border: 0; background: #eef1f4; color: #4a5865; font-size: 0.85rem; font-weight: 700; cursor: pointer; }
.ds-co__tabs button.is-active { background: var(--ds-navy); color: #fff; }

.ds-co__empty { display: flex; flex-direction: column; align-items: center; gap: 0.35rem; padding: 2.5rem 1rem; border-radius: var(--ds-radius-lg); background: #fff; color: var(--ds-steel); text-align: center; box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06); }
.ds-co__empty strong { color: var(--ds-navy); font-size: 1rem; }

/* incoming boxes */
.ds-co__areas { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-co__area {
    display: grid; grid-template-columns: 1.4rem minmax(0, 1fr) minmax(6rem, 12rem) 4rem 8.5rem; gap: 1rem; align-items: center;
    width: 100%; padding: 0.8rem 1rem; border: 0; border-radius: 0.8rem; background: #fff; color: var(--ds-navy); text-align: left; cursor: pointer;
    box-shadow: 0 0 0 1px rgb(14 36 51 / 0.06);
}
.ds-co__area.is-on { background: #fff8db; box-shadow: inset 0 0 0 2px var(--ds-signal); }
.ds-co__area:focus-visible { outline: 3px solid var(--ds-signal); outline-offset: 2px; }
.ds-co__check { width: 1.4rem; height: 1.4rem; border-radius: 0.4rem; display: flex; align-items: center; justify-content: center; font-weight: 900; color: transparent; box-shadow: inset 0 0 0 2px #b7c4cf; }
.ds-co__area.is-on .ds-co__check { background: var(--ds-navy); color: var(--ds-signal); box-shadow: none; }
.ds-co__area-name { display: flex; flex-direction: column; min-width: 0; }
.ds-co__area-name small { font-size: 0.75rem; color: var(--ds-steel); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-co__age { justify-self: end; padding: 0.2rem 0.6rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; white-space: nowrap; }
.ds-co__age.is-ok { background: #e3f5ed; color: var(--ds-ok); }
.ds-co__age.is-warn { background: #fff1dc; color: #9a5b00; }
.ds-co__age.is-bad { background: #fdecea; color: var(--ds-bad); }
@media (max-width: 768px) { .ds-co__area { grid-template-columns: 1.4rem 1fr 3rem; } .ds-co__area .ds-board__bar, .ds-co__area .ds-co__age { display: none; } }

.ds-co__oldest { display: grid; grid-template-columns: 8rem 1fr 1.2fr 7rem 6rem; gap: 0.75rem; align-items: center; padding: 0.6rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__oldest--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }

.ds-co__tripbar {
    position: sticky; bottom: 0.75rem; z-index: 5; display: flex; align-items: center; gap: 0.75rem;
    padding: 0.9rem 1.1rem; border-radius: var(--ds-radius-lg); background: var(--ds-navy); color: #fff;
}
.ds-co__tripbar > span { flex: 1; display: flex; flex-direction: column; }
.ds-co__tripbar strong { font-size: 1.05rem; }
.ds-co__tripbar small { color: #b7c4cf; font-size: 0.8rem; }

/* drivers */
.ds-co__driver { display: grid; grid-template-columns: 2rem 2.5rem minmax(0, 1fr) 5.5rem 9rem 6.5rem minmax(0, 1fr); gap: 0.85rem; align-items: center; padding: 0.7rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__driver--head { border-top: 0; font-size: 0.75rem; font-weight: 600; color: var(--ds-steel); }
.ds-co__rank { font-weight: 800; color: #8a97a2; text-align: center; }
.ds-co__avatar { width: 2.5rem; height: 2.5rem; border-radius: 999px; background: #24465f; color: #fff; display: flex; align-items: center; justify-content: center; font-weight: 800; font-size: 0.85rem; text-transform: uppercase; }
.ds-co__rate { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-co__rate b.is-ok { color: var(--ds-ok); }
.ds-co__rate b.is-warn { color: var(--ds-warn); }
@media (max-width: 900px) { .ds-co__driver { grid-template-columns: 2rem 2.5rem 1fr 4rem; } .ds-co__driver > :nth-child(n + 5) { display: none; } }

/* not delivered */
.ds-co__group { border-left: 4px solid var(--ds-warn); }
.ds-co__group.is-danger { border-left-color: var(--ds-bad); }
.ds-co__group.is-info, .ds-co__group.is-gray { border-left-color: #3fa7b9; }
.ds-co__group-head { display: flex; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-co__group-head h2 { font-size: 1.05rem; font-weight: 800; color: var(--ds-navy); }
.ds-co__group-head h2 span { font-weight: 600; font-size: 0.9rem; color: var(--ds-steel); }
.ds-co__tip { flex: 1; font-size: 0.85rem; color: #4a5865; }
.ds-co__retry { display: grid; grid-template-columns: 7.5rem minmax(0, 1fr) minmax(0, 1fr) 4.5rem 7.5rem auto; gap: 0.75rem; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__tries { font-size: 0.75rem; font-weight: 700; color: var(--ds-steel); }
.ds-co__tries.is-bad { color: var(--ds-bad); }
.ds-co__retry-actions { display: flex; gap: 0.4rem; justify-content: flex-end; }
@media (max-width: 900px) { .ds-co__retry { grid-template-columns: 1fr auto; } .ds-co__retry > :nth-child(n + 2):not(.ds-co__retry-actions) { display: none; } }

/* track a box */
.ds-co__search { display: flex; align-items: center; gap: 0.6rem; padding: 0.4rem 0.4rem 0.4rem 0.9rem; border-radius: 0.8rem; background: #fff; box-shadow: 0 0 0 2px var(--ds-signal); color: var(--ds-steel); }
.ds-co__search input { flex: 1; min-width: 0; border: 0; background: transparent; font-size: 1.05rem; font-weight: 600; color: var(--ds-navy); outline: none; box-shadow: none; }
.ds-co__search--small { box-shadow: 0 0 0 1px #d5dde3; padding: 0.15rem 0.75rem; width: 15rem; }
.ds-co__search--small input { font-size: 0.9rem; font-weight: 500; padding: 0.45rem 0; }
.ds-co__track { display: grid; grid-template-columns: minmax(0, 1fr) 20rem; gap: 1rem; align-items: start; }
@media (max-width: 1024px) { .ds-co__track { grid-template-columns: 1fr; } }
.ds-co__timeline { display: flex; flex-direction: column; }
.ds-co__timeline li { position: relative; display: grid; grid-template-columns: 1.6rem minmax(0, 1fr) auto; gap: 0.75rem; padding-bottom: 1.1rem; }
.ds-co__timeline li:not(:last-child)::before { content: ''; position: absolute; left: 0.5rem; top: 1.2rem; bottom: 0; width: 2px; background: #e3e8ec; }
.ds-co__dot { width: 1.1rem; height: 1.1rem; margin-top: 0.15rem; border-radius: 999px; background: #fff; box-shadow: inset 0 0 0 3px #b7c4cf; z-index: 1; }
.ds-co__timeline li.is-ok .ds-co__dot { background: var(--ds-ok); box-shadow: none; }
.ds-co__timeline li.is-warn .ds-co__dot { background: var(--ds-warn); box-shadow: none; }
.ds-co__event { display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.9rem; color: var(--ds-navy); }
.ds-co__event > span { color: #4a5865; font-size: 0.85rem; }
.ds-co__event img { margin-top: 0.4rem; width: 10rem; height: 6.5rem; object-fit: cover; border-radius: 0.6rem; }
.ds-co__timeline time { font-size: 0.8rem; white-space: nowrap; }
.ds-co__boxcard { gap: 0.4rem; }
.ds-co__boxno { font-size: 1.3rem; color: var(--ds-navy); }
.ds-co__boxcard dl { display: grid; gap: 0.2rem; margin-top: 0.5rem; padding-top: 0.75rem; border-top: 1px solid #eef1f4; font-size: 0.9rem; }
.ds-co__boxcard dt { color: var(--ds-steel); font-size: 0.8rem; margin-top: 0.4rem; }
.ds-co__boxcard dd { color: var(--ds-navy); }
.ds-co__boxcard dd a { font-weight: 700; color: #2f6f9f; margin-left: 0.4rem; }
.ds-co__status { align-self: flex-start; padding: 0.2rem 0.7rem; border-radius: 999px; font-size: 0.8rem; font-weight: 800; background: #e6edf3; color: var(--ds-navy); white-space: nowrap; }
.ds-co__status.is-ok, .ds-co__status.is-done { background: #e3f5ed; color: var(--ds-ok); }
.ds-co__status.is-loading { background: #fff6d6; color: #8a6a00; }

/* dashboard */
.ds-co__hello { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; margin-bottom: 0.5rem; }
.ds-co__hello > div { flex: 1; min-width: 14rem; }
.ds-co__hello-title { font-size: 1.6rem; font-weight: 800; color: var(--ds-navy); line-height: 1.2; }
.ds-co__today { display: grid; grid-template-columns: minmax(0, 1.5fr) minmax(0, 1fr); gap: 0.875rem; align-items: start; }
.ds-co__today--even { grid-template-columns: repeat(2, minmax(0, 1fr)); }
@media (max-width: 1024px) { .ds-co__today, .ds-co__today--even { grid-template-columns: 1fr; } }
.ds-co__trip { display: grid; grid-template-columns: 2.5rem minmax(0, 1fr) 10rem 6.5rem; gap: 0.85rem; align-items: center; padding: 0.65rem 0; border-top: 1px solid #eef1f4; }
.ds-co__trip .ds-co__status { justify-self: end; }
@media (max-width: 640px) { .ds-co__trip { grid-template-columns: 2.5rem 1fr; } .ds-co__trip > :nth-child(n + 3) { grid-column: 2; justify-self: start; } }
.ds-co__attn { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 0.75rem; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; font-size: 0.85rem; }

.dark .ds-co__area, .dark .ds-co__empty { background: #10283a; color: #e6edf3; box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-co__area.is-on { background: rgb(246 190 0 / 0.12); }
.dark .ds-co__hello-title, .dark .ds-co__h2, .dark .ds-co__group-head h2, .dark .ds-co__event, .dark .ds-co__boxno, .dark .ds-co__boxcard dd, .dark .ds-co__empty strong { color: #e6edf3; }
.dark .ds-co__search { background: #10283a; }
.dark .ds-co__search input { color: #e6edf3; }
.dark .ds-co__tabs button { background: #0e2433; color: #b7c4cf; }
.dark .ds-co__tabs button.is-active { background: var(--ds-signal); color: var(--ds-navy); }
.dark .ds-co__driver, .dark .ds-co__retry, .dark .ds-co__trip, .dark .ds-co__attn, .dark .ds-co__oldest { border-color: rgb(255 255 255 / 0.08); }
.ds-co__clear { height: 2.25rem; padding: 0 0.9rem; border-radius: 0.5rem; border: 1.5px solid rgb(255 255 255 / 0.35); background: transparent; color: #fff; font-weight: 700; font-size: 0.85rem; cursor: pointer; }
.ds-co__clear:hover { background: rgb(255 255 255 / 0.1); }

/* ------------------------------------------------------------------ box photos */
.ds-ph { display: flex; flex-direction: column; gap: 0.7rem; margin-top: 0.9rem; padding: 0.9rem 1rem; border-radius: var(--ds-radius); background: #fff; box-shadow: 0 0 0 1px rgb(14 36 51 / 0.08); }
.ds-ph__cond > span { display: block; font-size: 0.8rem; font-weight: 700; color: var(--ds-navy); margin-bottom: 0.4rem; }
.ds-ph__cond > div { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.4rem; }
.ds-ph__chip { min-height: 2.5rem; border-radius: 0.6rem; font-size: 0.85rem; font-weight: 700; background: #e3f5ed; color: #17895e; }
.ds-ph__chip.is-damaged { background: #fdecea; color: #cf3b3b; }
.ds-ph__chip.is-wet { background: #e3f0fb; color: #1f6fb2; }
.ds-ph__chip.is-open { background: #fff1dc; color: #9a5b00; }
.ds-ph__chip.is-on { color: #fff; background: #17895e; }
.ds-ph__chip.is-damaged.is-on { background: #cf3b3b; }
.ds-ph__chip.is-wet.is-on { background: #1f6fb2; }
.ds-ph__chip.is-open.is-on { background: #9a5b00; }
.ds-ph__tip { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fff8db; color: #6b4a00; font-size: 0.82rem; }
.ds-ph__note { width: 100%; border: 1px solid #d5dce2; border-radius: 0.6rem; padding: 0.5rem 0.7rem; font-size: 0.875rem; background: #fff; color: var(--ds-navy); }
.ds-ph__shots { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem; }
.ds-ph__shots img { width: 3.5rem; height: 3.5rem; object-fit: cover; border-radius: 0.5rem; }
.ds-ph__shots span { font-size: 0.78rem; color: var(--ds-steel); margin-left: 0.25rem; }
.ds-ph__add { display: flex; align-items: center; justify-content: center; gap: 0.5rem; min-height: 2.9rem; border-radius: 0.7rem; background: var(--ds-navy); color: #fff; font-weight: 700; }
.ds-ph__add:disabled { opacity: 0.7; }
.ds-ph__batch { display: flex; align-items: center; gap: 0.5rem; padding: 0.6rem 0.75rem; border-radius: 0.6rem; background: var(--ds-navy); color: #fff; font-size: 0.82rem; }
.ds-ph__batch span { flex: 1; }
.ds-ph__batch button { padding: 0.4rem 0.8rem; border-radius: 0.5rem; background: var(--ds-signal); color: var(--ds-navy); font-weight: 800; }
.ds-ph__batch button.is-skip { background: #24465f; color: #fff; }
.ds-ph__err { margin: 0; color: var(--ds-bad); font-size: 0.82rem; }
.ds-gm__status.is-good { color: var(--ds-ok); }
.ds-gm__status.is-damaged { color: var(--ds-bad); }
.ds-gm__status.is-wet { color: #1f6fb2; }
.ds-gm__status.is-open { color: var(--ds-warn); }
.ds-phs { display: flex; flex-direction: column; gap: 0.75rem; }
.ds-phs__big { width: 100%; max-height: 26rem; object-fit: contain; border-radius: var(--ds-radius); background: #000; }
.ds-phs__thumbs { display: flex; flex-wrap: wrap; gap: 0.5rem; }
.ds-phs__thumbs button { width: 6rem; border-radius: 0.5rem; overflow: hidden; opacity: 0.7; text-align: left; font-size: 0.7rem; background: var(--ds-deck); }
.ds-phs__thumbs button.is-on { opacity: 1; box-shadow: 0 0 0 3px var(--ds-signal); }
.ds-phs__thumbs img { width: 100%; height: 4.2rem; object-fit: cover; }
.ds-phs__thumbs span { display: block; padding: 0.15rem 0.35rem; color: var(--ds-navy); }
.ds-ps__row { display: grid; grid-template-columns: auto 1fr auto; align-items: center; padding: 0.55rem 0; border-top: 1px solid #eef1f4; }
/* layout helpers used by the photo pages */
.ds-tp { display: flex; flex-direction: column; gap: 1rem; }
.ds-tp__recent { display: flex; flex-direction: column; margin: 0; padding: 0; list-style: none; }
.ds-tp__recent li { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); gap: 0.75rem; padding: 0.45rem 0; border-top: 1px solid #eef1f4; font-size: 0.85rem; }
.ds-gm input[type=number] { border: 1px solid #d5dce2; border-radius: 0.5rem; padding: 0.4rem 0.6rem; background: #fff; color: var(--ds-navy); font-size: 0.875rem; }
.ds-gm__field { display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.8rem; color: var(--ds-steel); }
.ds-gm__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(14rem, 1fr)); gap: 0.9rem; }
.ds-gm__check { display: flex; align-items: center; gap: 0.6rem; font-size: 0.875rem; }
.ds-gm__save { display: flex; justify-content: flex-end; }
.ds-gm__status { font-size: 0.78rem; font-weight: 600; color: var(--ds-steel); }

/* ------------------------------------------------------------------ Box Photos (v2) */
.ds-bp {
    --bp-bg: #f3f5f7; --bp-surf: #ffffff; --bp-raised: #f6f8fa; --bp-line: rgb(14 36 51 / 0.09);
    --bp-text: #0e2433; --bp-muted: #5b6b78; --bp-pill-on: #0e2433; --bp-pill-on-text: #ffffff;
    --bp-ok: #17895e; --bp-bad: #d64236; --bp-wet: #2f7fc4; --bp-warn: #b97412; --bp-gold: #f6be00;
    --bp-shadow: 0 18px 40px rgb(14 36 51 / 0.08);
    display: flex; flex-direction: column; gap: 1.1rem; color: var(--bp-text); padding-bottom: 6rem;
}
.dark .ds-bp {
    --bp-surf: #122230; --bp-raised: #172b3a; --bp-line: rgb(255 255 255 / 0.08);
    --bp-text: #e9eff3; --bp-muted: #8ea2b0; --bp-pill-on: #e9eff3; --bp-pill-on-text: #0b1620;
    --bp-ok: #2fb37f; --bp-bad: #ef5a4f; --bp-wet: #4f9be0; --bp-warn: #e8a33a; --bp-shadow: 0 18px 40px rgb(0 0 0 / 0.35);
}
.ds-bp__head { display: flex; align-items: flex-end; justify-content: space-between; gap: 1.25rem; flex-wrap: wrap; }
.ds-bp__head h1 { margin: 0; font-size: 2.1rem; font-weight: 900; letter-spacing: -0.02em; line-height: 1.1; }
.ds-bp__head p { margin: 0.35rem 0 0; color: var(--bp-muted); }
.ds-bp__stats { display: flex; gap: 0.5rem; }
.ds-bp__stats span { display: flex; flex-direction: column; align-items: flex-end; padding: 0.5rem 0.9rem; border-radius: 0.9rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__stats strong { font-size: 1.25rem; font-variant-numeric: tabular-nums; line-height: 1.1; }
.ds-bp__stats small { font-size: 0.72rem; color: var(--bp-muted); }
.ds-bp__stats .is-bad strong { color: var(--bp-bad); }
.ds-bp__stats .is-wet strong { color: var(--bp-wet); }
.ds-bp__search { display: flex; align-items: center; gap: 0.85rem; height: 3.9rem; padding: 0 1.2rem; border-radius: 1.1rem; background: var(--bp-surf); color: var(--bp-muted);
    box-shadow: inset 0 0 0 1px var(--bp-line), 0 0 0 4px rgb(246 190 0 / 0.12); }
.ds-bp__search:focus-within { box-shadow: inset 0 0 0 2px var(--bp-gold), 0 0 0 5px rgb(246 190 0 / 0.18); }
.ds-bp__search input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--bp-text); font-size: 1.15rem; font-weight: 700; letter-spacing: 0.01em; }
.ds-bp__search input::placeholder { color: var(--bp-muted); font-weight: 500; }
.ds-bp__search input::-webkit-search-cancel-button { display: none; }
.ds-bp__clear { width: 1.9rem; height: 1.9rem; border-radius: 50%; background: var(--bp-raised); color: var(--bp-muted); font-size: 0.75rem; }
.ds-bp__hint { font-size: 0.75rem; padding: 0.3rem 0.6rem; border-radius: 0.5rem; background: var(--bp-raised); white-space: nowrap; }
.ds-bp__empty { display: flex; flex-direction: column; align-items: center; gap: 0.6rem; padding: 4.5rem 1.25rem; border-radius: 1.5rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); text-align: center; }
.ds-bp__empty.is-small { padding: 2.5rem 1.25rem; }
.ds-bp__empty-icon { display: grid; place-items: center; width: 4rem; height: 4rem; border-radius: 1.25rem; background: var(--bp-raised); color: var(--bp-gold); margin-bottom: 0.4rem; }
.ds-bp__empty h2 { margin: 0; font-size: 1.35rem; font-weight: 800; letter-spacing: -0.01em; }
.ds-bp__empty p { margin: 0; max-width: 30rem; color: var(--bp-muted); line-height: 1.5; }
.ds-bp__recent { display: flex; flex-wrap: wrap; justify-content: center; align-items: center; gap: 0.45rem; margin-top: 0.5rem; }
.ds-bp__recent span { font-size: 0.8rem; color: var(--bp-muted); }
.ds-bp__recent button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.65rem; background: var(--bp-raised); box-shadow: inset 0 0 0 1px var(--bp-line); font-weight: 700; font-size: 0.85rem; color: var(--bp-text); }
.ds-bp__pills { display: flex; flex-wrap: wrap; align-items: center; gap: 0.45rem; }
.ds-bp__pills button { display: inline-flex; align-items: center; gap: 0.4rem; height: 2.2rem; padding: 0 0.9rem; border-radius: 999px; font-size: 0.82rem; font-weight: 700;
    background: var(--bp-surf); color: var(--bp-text); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__pills button.is-on { background: var(--bp-pill-on); color: var(--bp-pill-on-text); box-shadow: none; }
.ds-bp__sep { width: 1px; height: 1.4rem; margin: 0 0.3rem; background: var(--bp-line); }
.ds-bp__dot { display: inline-block; width: 0.55rem; height: 0.55rem; border-radius: 50%; background: var(--bp-muted); flex: none; }
.ds-bp__dot.is-ok { background: var(--bp-ok); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-ok) 22%, transparent); }
.ds-bp__dot.is-bad { background: var(--bp-bad); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-bad) 22%, transparent); }
.ds-bp__dot.is-wet { background: var(--bp-wet); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-wet) 22%, transparent); }
.ds-bp__dot.is-warn { background: var(--bp-warn); box-shadow: 0 0 0 3px color-mix(in srgb, var(--bp-warn) 22%, transparent); }
.ds-bp__count { margin: 0; font-size: 0.82rem; color: var(--bp-muted); }
.ds-bp__layout { display: grid; grid-template-columns: minmax(0, 1fr) minmax(20rem, 29rem); gap: 1.25rem; align-items: start; }
.ds-bp__list { display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-bp__box { display: flex; flex-direction: column; gap: 0.9rem; padding: 1.1rem 1.25rem; border-radius: 1.15rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); transition: box-shadow 0.15s; }
.ds-bp__box.is-open { box-shadow: 0 0 0 2px var(--bp-gold), var(--bp-shadow); }
.ds-bp__boxhead { display: grid; grid-template-columns: auto auto auto 1fr; align-items: center; gap: 0.3rem 0.6rem; text-align: left; color: inherit; }
.ds-bp__inv { font-size: 1.3rem; font-weight: 800; letter-spacing: -0.01em; font-variant-numeric: tabular-nums; }
.ds-bp__n { justify-self: end; grid-column: 4; font-size: 0.78rem; color: var(--bp-muted); }
.ds-bp__who { grid-column: 1 / -1; font-size: 0.82rem; color: var(--bp-muted); }
.ds-bp__chip { display: inline-flex; align-items: center; padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.72rem; font-weight: 800; color: var(--bp-muted); background: var(--bp-raised); }
.ds-bp__chip.is-ok { color: var(--bp-ok); background: color-mix(in srgb, var(--bp-ok) 14%, transparent); }
.ds-bp__chip.is-bad { color: var(--bp-bad); background: color-mix(in srgb, var(--bp-bad) 14%, transparent); }
.ds-bp__chip.is-wet { color: var(--bp-wet); background: color-mix(in srgb, var(--bp-wet) 14%, transparent); }
.ds-bp__chip.is-warn { color: var(--bp-warn); background: color-mix(in srgb, var(--bp-warn) 14%, transparent); }
.ds-bp__journey { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem 0; margin: 0; padding: 0; list-style: none; }
.ds-bp__journey li { display: inline-flex; align-items: center; gap: 0.45rem; font-size: 0.76rem; font-weight: 600; color: var(--bp-muted); }
.ds-bp__journey li + li::before { content: ''; width: 1.4rem; height: 2px; margin: 0 0.45rem; background: var(--bp-line); border-radius: 2px; }
.ds-bp__thumbs { display: flex; flex-wrap: wrap; gap: 0.6rem; }
.ds-bp__thumb { position: relative; display: flex; flex-direction: column; gap: 0.3rem; width: 6.5rem; }
.ds-bp__img { position: relative; display: block; width: 6.5rem; height: 4.8rem; border-radius: 0.75rem; overflow: hidden; background: var(--bp-raised); }
.ds-bp__img img { width: 100%; height: 100%; object-fit: cover; }
.ds-bp__img .ds-bp__dot { position: absolute; left: 0.45rem; bottom: 0.45rem; }
.ds-bp__thumb.is-cur .ds-bp__img { outline: 2px solid var(--bp-gold); outline-offset: 2px; }
.ds-bp__thumb small { font-size: 0.68rem; color: var(--bp-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-bp__tick { position: absolute; right: 0.35rem; top: 0.35rem; display: grid; place-items: center; width: 1.4rem; height: 1.4rem; border-radius: 0.45rem; font-size: 0.75rem; font-weight: 900;
    background: rgb(11 22 32 / 0.5); color: transparent; box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / 0.85); }
.ds-bp__thumb.is-sel .ds-bp__tick { background: var(--bp-gold); color: #0e2433; box-shadow: none; }
.ds-bp__card { display: flex; flex-direction: column; gap: 0.75rem; padding: 0.85rem 0.95rem; border-radius: 0.95rem; }
.ds-bp__card.is-ok { --c: var(--bp-ok); }
.ds-bp__card.is-warn { --c: var(--bp-warn); }
.ds-bp__card { background: color-mix(in srgb, var(--c) 9%, transparent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--c) 35%, transparent); }
.ds-bp__cardhead { display: flex; align-items: center; gap: 0.7rem; }
.ds-bp__cardhead > span:nth-child(2) { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.ds-bp__cardhead strong { color: var(--c); font-size: 0.92rem; }
.ds-bp__cardhead small { font-size: 0.75rem; color: var(--bp-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-bp__cardhead em { font-style: normal; font-size: 0.75rem; color: var(--bp-muted); }
.ds-bp__badge { display: grid; place-items: center; width: 2rem; height: 2rem; border-radius: 0.65rem; background: var(--c); color: #0b1620; font-weight: 900; flex: none; }
.ds-bp__cardnote { margin: 0; font-size: 0.8rem; color: var(--bp-muted); font-style: italic; }
.ds-bp__viewer { position: sticky; top: 5rem; display: flex; flex-direction: column; gap: 0.85rem; padding: 0.9rem; border-radius: 1.35rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__big { position: relative; aspect-ratio: 4 / 3; border-radius: 0.9rem; overflow: hidden; background: #000; }
.ds-bp__big img { width: 100%; height: 100%; object-fit: contain; }
.ds-bp__pos { position: absolute; right: 0.6rem; top: 0.6rem; padding: 0.2rem 0.55rem; border-radius: 999px; background: rgb(14 36 51 / 0.72); color: #fff; font-size: 0.75rem; font-variant-numeric: tabular-nums; }
.ds-bp__nav { position: absolute; top: 50%; transform: translateY(-50%); width: 2.2rem; height: 2.2rem; border-radius: 50%; background: rgb(14 36 51 / 0.6); color: #fff; font-size: 1.3rem; line-height: 1; }
.ds-bp__nav.is-prev { left: 0.6rem; }
.ds-bp__nav.is-next { right: 0.6rem; }
.ds-bp__strip { display: flex; gap: 0.45rem; overflow-x: auto; }
.ds-bp__strip button { flex: none; width: 4.4rem; height: 3.3rem; border-radius: 0.6rem; overflow: hidden; opacity: 0.55; }
.ds-bp__strip button.is-on { opacity: 1; outline: 2px solid var(--bp-gold); outline-offset: 2px; }
.ds-bp__strip img { width: 100%; height: 100%; object-fit: cover; }
.ds-bp__vhead { display: flex; align-items: flex-start; justify-content: space-between; gap: 0.75rem; }
.ds-bp__vhead > span:first-child { display: flex; flex-direction: column; gap: 0.15rem; min-width: 0; }
.ds-bp__vhead strong { font-size: 1.05rem; }
.ds-bp__vhead small { font-size: 0.8rem; color: var(--bp-muted); }
.ds-bp__quote { margin: 0; padding: 0.6rem 0.85rem; border-radius: 0.7rem; background: var(--bp-raised); font-style: italic; font-size: 0.88rem; border-left: 3px solid var(--bp-gold); }
.ds-bp__meta { display: grid; grid-template-columns: 6rem 1fr; gap: 0.45rem 0.75rem; margin: 0; font-size: 0.85rem; }
.ds-bp__meta dt { color: var(--bp-muted); }
.ds-bp__meta dd { margin: 0; overflow-wrap: anywhere; }
.ds-bp__meta .is-mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.8rem; }
.ds-bp__vactions { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.ds-bp__vactions a, .ds-bp__vactions button { display: flex; align-items: center; justify-content: center; height: 2.6rem; border-radius: 0.75rem; font-size: 0.88rem; font-weight: 700;
    background: var(--bp-raised); color: var(--bp-text); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__del { align-self: flex-start; font-size: 0.8rem; color: var(--bp-bad); text-decoration: underline; }
.ds-bp__dock { position: fixed; left: 50%; bottom: 1.5rem; z-index: 40; transform: translateX(-50%); display: flex; align-items: center; gap: 0.6rem; padding: 0.55rem 0.55rem 0.55rem 0.85rem;
    border-radius: 1.25rem; background: #0e2433; color: #fff; box-shadow: 0 24px 60px rgb(0 0 0 / 0.4), inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-bp__dockn { display: grid; place-items: center; min-width: 1.9rem; height: 1.9rem; padding: 0 0.4rem; border-radius: 999px; background: var(--bp-gold); color: #0e2433; font-weight: 900; font-variant-numeric: tabular-nums; }
.ds-bp__docktext { display: flex; flex-direction: column; margin-right: 1rem; }
.ds-bp__docktext small { font-size: 0.72rem; color: #9fb3c1; }
.ds-bp__dock > button { height: 2.5rem; padding: 0 0.95rem; border-radius: 0.8rem; font-weight: 700; font-size: 0.88rem; }
.ds-bp__dock > .is-ghost { color: #9fb3c1; }
.ds-bp__dock > .is-dark { background: #24465f; color: #fff; }
.ds-bp__panel { padding: 1rem 1.2rem; border-radius: 1.15rem; background: var(--bp-surf); box-shadow: inset 0 0 0 1px var(--bp-line); }
.ds-bp__panel h3 { margin: 0 0 0.4rem; font-size: 0.95rem; font-weight: 800; }
.ds-bp__mails { margin: 0; padding: 0; list-style: none; }
.ds-bp__mails li { display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); gap: 0.75rem; padding: 0.5rem 0; border-top: 1px solid var(--bp-line); font-size: 0.85rem; }
.ds-bp__mails small { color: var(--bp-muted); text-align: right; }
@media (max-width: 64rem) { .ds-bp__layout { grid-template-columns: 1fr; } .ds-bp__viewer { position: static; order: -1; } }
@media (max-width: 40rem) { .ds-bp__hint, .ds-bp__stats { display: none; } .ds-bp__dock { left: 0.75rem; right: 0.75rem; transform: none; flex-wrap: wrap; } }
.ds-phs__link { font-size: 0.8rem; text-decoration: underline; }

/* ------------------------------------------------------------------ Scan app (/scan) */
.fi-panel-scan, .fi-panel-scan .fi-layout, .fi-panel-scan .fi-main-ctn { background: #0a1219; }
.fi-panel-scan .fi-main { padding: 0 !important; max-width: none !important; }
.fi-panel-scan .fi-page > .fi-header, .fi-panel-scan .fi-page-header-main-ctn > .fi-header { display: none; }
.fi-panel-scan .fi-page-content, .fi-panel-scan .fi-page-main { gap: 0 !important; }
.ds-sa {
    --sa-text: #eef3f6; --sa-muted: #7f93a1; --sa-line: rgb(255 255 255 / 0.07); --sa-glass: rgb(255 255 255 / 0.045);
    --sa-gold: #f6be00; --sa-ok: #34c38f; --sa-bad: #ff6b5e; --sa-wet: #5aa8ff; --sa-warn: #f0a93b;
    position: fixed; inset: 0; z-index: 20; overflow: hidden auto; color: var(--sa-text); font-feature-settings: 'tnum';
    background: radial-gradient(120% 70% at 0% 0%, #15293a 0%, #0a1219 55%);
    -webkit-tap-highlight-color: transparent;
}
.ds-sa button { cursor: pointer; }
.ds-sa__screen { min-height: 100%; box-sizing: border-box; display: flex; flex-direction: column; gap: 1.25rem; max-width: 34rem; margin: 0 auto;
    padding: calc(env(safe-area-inset-top) + 1.25rem) 1.35rem calc(env(safe-area-inset-bottom) + 1.5rem); animation: sa-in .35s ease-out; }
@keyframes sa-in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }
@keyframes sa-up { from { transform: translateY(100%); } to { transform: none; } }
@keyframes sa-pulse { from { box-shadow: 0 0 0 0 rgb(52 195 143 / 0.55); } to { box-shadow: 0 0 0 22px rgb(52 195 143 / 0); } }
@keyframes sa-shake { 0%,100% { transform: none; } 20% { transform: translateX(-8px); } 40% { transform: translateX(7px); } 60% { transform: translateX(-5px); } 80% { transform: translateX(3px); } }
@keyframes sa-sweep { 0% { top: 12%; opacity: 0; } 15%, 85% { opacity: 1; } 100% { top: 86%; opacity: 0; } }
@keyframes sa-ring { from { stroke-dashoffset: 302; } }
.ds-sa__hello { display: flex; align-items: center; justify-content: space-between; gap: 1rem; }
.ds-sa__hello > span:first-child { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-sa__hello small { font-size: 0.875rem; color: var(--sa-muted); }
.ds-sa__hello strong { font-size: 1.85rem; font-weight: 700; letter-spacing: -0.025em; line-height: 1.15; }
.ds-sa__avatar { display: grid; place-items: center; width: 2.75rem; height: 2.75rem; border-radius: 50%; flex: none; font-weight: 800; color: #0a1219; background: linear-gradient(135deg, #f6be00, #e08a00); }
.ds-sa__today { display: flex; align-items: center; gap: 1.1rem; padding: 1.1rem; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__today dl { flex: 1; display: grid; grid-template-columns: 1fr auto; gap: 0.6rem 0.75rem; margin: 0; font-size: 0.9rem; }
.ds-sa__today dt { color: var(--sa-muted); }
.ds-sa__today dd { margin: 0; font-weight: 700; }
.ds-sa .is-bad { color: #ff8a7e; }
.ds-sa__ring { position: relative; flex: none; width: 5.25rem; height: 5.25rem; }
.ds-sa__ring svg { width: 100%; height: 100%; transform: rotate(-90deg); }
.ds-sa__ring circle { fill: none; stroke-width: 9; }
.ds-sa__ring .is-track { stroke: rgb(255 255 255 / 0.08); }
.ds-sa__ring .is-fill { stroke: var(--sa-gold); stroke-linecap: round; stroke-dasharray: 289; transition: stroke-dashoffset .6s cubic-bezier(.2,.8,.2,1); }
.ds-sa__ring .is-fill.is-ok { stroke: var(--sa-ok); animation: sa-ring 1.1s cubic-bezier(.2,.8,.2,1); }
.ds-sa__ring > span { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; }
.ds-sa__ring > span strong { font-size: 1.35rem; letter-spacing: -0.02em; }
.ds-sa__ring > span small { font-size: 0.65rem; color: var(--sa-muted); }
.ds-sa__ring.is-small { width: 3.25rem; height: 3.25rem; }
.ds-sa__ring.is-small circle { stroke-width: 10; }
.ds-sa__ring.is-small b { font-size: 0.72rem; }
.ds-sa__ring.is-tiny { width: 3rem; height: 3rem; }
.ds-sa__ring.is-tiny circle { stroke-width: 11; }
.ds-sa__ring.is-big { width: 9.5rem; height: 9.5rem; align-self: center; margin-top: 1.5rem; }
.ds-sa__ring.is-big circle { stroke-width: 7; }
.ds-sa__ring.is-big i { display: grid; place-items: center; width: 4.75rem; height: 4.75rem; border-radius: 50%; background: rgb(52 195 143 / 0.14); color: var(--sa-ok); }
.ds-sa__ring.is-big i svg { width: 2.4rem; height: 2.4rem; transform: none; }
.ds-sa__label { margin: 0 0 -0.6rem; font-size: 0.8rem; font-weight: 600; color: var(--sa-muted); }
.ds-sa__list { display: flex; flex-direction: column; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); overflow: hidden; }
.ds-sa__row { display: flex; align-items: center; gap: 0.9rem; width: 100%; padding: 0.95rem 1rem; text-align: left; color: inherit; transition: background .2s, transform .12s; }
.ds-sa__row + .ds-sa__row { box-shadow: inset 0 1px 0 var(--sa-line); }
.ds-sa__row:active { background: rgb(255 255 255 / 0.05); transform: scale(.99); }
.ds-sa__chip { display: grid; place-items: center; width: 2.65rem; height: 2.65rem; border-radius: 0.9rem; flex: none; color: var(--sa-gold); background: rgb(246 190 0 / 0.1); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.18); }
.ds-sa__chip svg { width: 1.25rem; height: 1.25rem; }
.ds-sa__rowtext { flex: 1; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-sa__rowtext strong { font-size: 1rem; }
.ds-sa__rowtext small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__chev { font-size: 1.5rem; color: #4f6472; line-height: 1; }
.ds-sa__foot { margin-top: auto; display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__online { display: inline-flex; align-items: center; gap: 0.5rem; }
.ds-sa__online i { width: 0.45rem; height: 0.45rem; border-radius: 50%; background: var(--sa-ok); box-shadow: 0 0 0 4px rgb(52 195 143 / 0.18); }
.ds-sa__footlinks { display: flex; gap: 0.9rem; }
.ds-sa__footlinks button { color: var(--sa-muted); text-decoration: underline; }
.ds-sa__footlinks .ds-pwa-install { display: none; }
html[data-pwa-installable] .ds-sa__footlinks .ds-pwa-install { display: inline; }
.ds-sa__note { padding: 0.9rem 1rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.035); font-size: 0.875rem; color: #a9b8c2; line-height: 1.5; }
.ds-sa__pill { align-self: flex-start; display: inline-flex; align-items: center; gap: 0.4rem; height: 2.4rem; padding: 0 0.9rem 0 0.7rem; border-radius: 999px; background: rgb(255 255 255 / 0.06); color: inherit; font-weight: 600; font-size: 0.875rem; }
.ds-sa__title { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-sa__title small { font-size: 0.875rem; color: var(--sa-muted); }
.ds-sa__title strong { font-size: 1.75rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-sa__choice { display: flex; align-items: center; gap: 0.9rem; width: 100%; padding: 1.1rem; border-radius: 1.5rem; text-align: left; color: inherit; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); animation: sa-in .35s ease-out both; transition: transform .12s; }
.ds-sa__choice:active { transform: scale(.98); }
.ds-sa__choicetext { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.3rem; }
.ds-sa__choicetext strong { font-size: 1.1rem; letter-spacing: -0.01em; }
.ds-sa__choicetext small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__choicetext .is-num { color: #c9d5dc; }
.ds-sa__scan { padding: 0; max-width: none; gap: 0; position: relative; min-height: 100dvh; }
.ds-sa__cam { position: absolute; inset: 0; background: radial-gradient(90% 60% at 50% 38%, #2a3a45, #0b141b 75%); overflow: hidden; }
.ds-sa__cam video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.ds-sa__frame { position: absolute; left: 50%; top: 38%; width: min(72vw, 17rem); height: min(46vw, 11rem); transform: translate(-50%, -50%); }
.ds-sa__frame i { position: absolute; width: 2.1rem; height: 2.1rem; border: 3px solid #fff; transition: border-color .15s; }
.ds-sa__frame i:nth-child(1) { left: 0; top: 0; border-right: 0; border-bottom: 0; border-top-left-radius: 1.1rem; }
.ds-sa__frame i:nth-child(2) { right: 0; top: 0; border-left: 0; border-bottom: 0; border-top-right-radius: 1.1rem; }
.ds-sa__frame i:nth-child(3) { left: 0; bottom: 0; border-right: 0; border-top: 0; border-bottom-left-radius: 1.1rem; }
.ds-sa__frame i:nth-child(4) { right: 0; bottom: 0; border-left: 0; border-top: 0; border-bottom-right-radius: 1.1rem; }
.ds-sa__frame.is-hit i { border-color: var(--sa-ok); }
.ds-sa__sweep { position: absolute; left: 0.75rem; right: 0.75rem; height: 2px; border-radius: 2px; background: linear-gradient(90deg, transparent, var(--sa-gold), transparent); box-shadow: 0 0 14px var(--sa-gold); animation: sa-sweep 2.4s ease-in-out infinite; }
.ds-sa__camtext { position: absolute; left: 1.5rem; right: 1.5rem; top: 58%; margin: 0; text-align: center; font-size: 0.875rem; color: rgb(238 243 246 / 0.8); }
.ds-sa__camtext.is-error, .ds-sa__camtext.is-hint { top: 60%; padding: 0.6rem 0.8rem; border-radius: 0.8rem; background: rgb(10 18 25 / 0.75); color: #ffd8d3; }
.ds-sa__controls { position: absolute; left: 0; right: 0; bottom: 0; display: flex; flex-direction: column; gap: 1rem; padding: 1rem 1.25rem calc(env(safe-area-inset-bottom) + 1.6rem); background: linear-gradient(180deg, transparent, rgb(10 18 25 / 0.85) 40%); }
.ds-sa__type { display: flex; align-items: center; height: 3rem; padding: 0 0.35rem 0 1rem; border-radius: 1rem; background: rgb(10 18 25 / 0.6); backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.1); }
.ds-sa__type input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--sa-text); font-size: 1rem; font-weight: 600; }
.ds-sa__type input::placeholder { color: var(--sa-muted); font-weight: 500; }
.ds-sa__type button { width: 2.4rem; height: 2.4rem; border-radius: 0.75rem; background: rgb(255 255 255 / 0.1); color: var(--sa-text); font-size: 1.1rem; }
.ds-sa__buttons { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; justify-items: center; }
.ds-sa__round { grid-column: 1; display: grid; place-items: center; width: 3.25rem; height: 3.25rem; border-radius: 50%; background: rgb(255 255 255 / 0.1); backdrop-filter: blur(10px); color: var(--sa-text); }
.ds-sa__round svg { width: 1.35rem; height: 1.35rem; }
.ds-sa__round.is-on { background: var(--sa-gold); color: #0a1219; }
.ds-sa__round.is-text { grid-column: 3; font-size: 0.78rem; font-weight: 700; }
.ds-sa__shutter { grid-column: 2; display: grid; place-items: center; width: 5.4rem; height: 5.4rem; border-radius: 50%; box-shadow: 0 0 0 4px rgb(255 255 255 / 0.9); transition: transform .12s; }
.ds-sa__shutter:active { transform: scale(.94); }
.ds-sa__shutter > span { display: grid; place-items: center; width: 4.4rem; height: 4.4rem; border-radius: 50%; background: rgb(255 255 255 / 0.15); color: #fff; transition: background .25s; }
.ds-sa__shutter > span.is-live { background: var(--sa-gold); color: #0a1219; }
.ds-sa__shutter svg { width: 1.75rem; height: 1.75rem; }
.ds-sa__bar { position: absolute; top: calc(env(safe-area-inset-top) + 0.75rem); left: 1rem; right: 1rem; z-index: 2; display: flex; align-items: center; gap: 0.75rem; padding: 0.5rem; border-radius: 1.5rem;
    background: rgb(10 18 25 / 0.55); backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-sa__back { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; background: rgb(255 255 255 / 0.08); color: var(--sa-text); font-size: 1.3rem; }
.ds-sa__bartext { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.ds-sa__bartext small { font-size: 0.75rem; color: #9fb0bc; }
.ds-sa__bartext strong { font-size: 0.95rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-sa__count { display: flex; flex-direction: column; align-items: flex-end; padding-right: 0.5rem; }
.ds-sa__count strong { font-size: 1.05rem; }
.ds-sa__count small { font-size: 0.7rem; color: #9fb0bc; }
.ds-sa__sheet { position: fixed; left: 0; right: 0; bottom: 0; z-index: 25; max-width: 34rem; margin: 0 auto; display: flex; flex-direction: column; gap: 0.95rem; padding: 0.6rem 1.25rem calc(env(safe-area-inset-bottom) + 1.6rem);
    border-radius: 1.9rem 1.9rem 0 0; background: rgb(15 24 32 / 0.985); backdrop-filter: blur(24px); -webkit-backdrop-filter: blur(24px);
    box-shadow: 0 -20px 50px rgb(0 0 0 / 0.45), inset 0 1px 0 rgb(255 255 255 / 0.08); animation: sa-up .38s cubic-bezier(.2,.9,.2,1); }
.ds-sa__sheet.is-bad { background: rgb(32 16 18 / 0.985); box-shadow: 0 -20px 50px rgb(0 0 0 / 0.45), inset 0 1px 0 rgb(255 107 94 / 0.25); }
.ds-sa__sheet.is-warn { background: rgb(34 26 12 / 0.985); }
.ds-sa__grab { align-self: center; width: 2.5rem; height: 0.3rem; border-radius: 3px; background: rgb(255 255 255 / 0.2); }
.ds-sa__hit { display: flex; align-items: center; gap: 0.85rem; }
.ds-sa__hit > span:nth-child(2) { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-sa__hit strong { font-size: 1.7rem; letter-spacing: -0.02em; line-height: 1.05; overflow-wrap: anywhere; }
.ds-sa__hit small { font-size: 0.82rem; color: #6fd6ad; }
.ds-sa__sheet.is-bad .ds-sa__hit small { color: #ff9d93; }
.ds-sa__sheet.is-warn .ds-sa__hit small { color: #f3c98a; }
.ds-sa__hit em { font-style: normal; padding: 0.3rem 0.7rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); font-size: 0.75rem; font-weight: 600; color: #c9d5dc; }
.ds-sa__hit.is-shake { animation: sa-shake .45s ease-in-out .3s; }
.ds-sa__mark { display: grid; place-items: center; width: 3.1rem; height: 3.1rem; border-radius: 50%; flex: none; font-weight: 900; font-size: 1.4rem; }
.ds-sa__mark svg { width: 1.5rem; height: 1.5rem; }
.ds-sa__mark.is-ok { background: var(--sa-ok); color: #0a1219; animation: sa-pulse 1s ease-out; }
.ds-sa__mark.is-bad { background: var(--sa-bad); color: #fff; }
.ds-sa__mark.is-warn { background: var(--sa-warn); color: #0a1219; }
.ds-sa__msg { margin: 0; font-size: 0.95rem; line-height: 1.5; color: #e9cfcc; }
.ds-sa__who { display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 0.9rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.04); }
.ds-sa__who > span:first-child { display: grid; place-items: center; width: 2.25rem; height: 2.25rem; border-radius: 50%; flex: none; background: rgb(255 255 255 / 0.08); font-size: 0.8rem; font-weight: 700; }
.ds-sa__who > span:last-child { display: flex; flex-direction: column; min-width: 0; }
.ds-sa__who small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-sa__seg { position: relative; display: grid; grid-template-columns: repeat(4, 1fr); padding: 4px; border-radius: 1rem; background: rgb(255 255 255 / 0.05); }
.ds-sa__segthumb { position: absolute; top: 4px; bottom: 4px; width: calc((100% - 8px) / 4); border-radius: 0.75rem; transition: left .28s cubic-bezier(.2,.9,.2,1), background .28s; background: var(--sa-ok); }
.ds-sa__segthumb.is-damaged { background: var(--sa-bad); }
.ds-sa__segthumb.is-wet { background: var(--sa-wet); }
.ds-sa__segthumb.is-open { background: var(--sa-warn); }
.ds-sa__seg button { position: relative; z-index: 1; display: flex; align-items: center; justify-content: center; gap: 0.35rem; height: 2.65rem; font-size: 0.8rem; font-weight: 700; color: #c9d5dc; transition: color .2s; }
.ds-sa__seg button.is-on { color: #0a1219; }
.ds-sa__seg i { width: 0.45rem; height: 0.45rem; border-radius: 50%; }
.ds-sa__seg i.is-good { background: var(--sa-ok); }
.ds-sa__seg i.is-damaged { background: var(--sa-bad); }
.ds-sa__seg i.is-wet { background: var(--sa-wet); }
.ds-sa__seg i.is-open { background: var(--sa-warn); }
.ds-sa__seg button.is-on i { background: #0a1219; }
.ds-sa__note-in { height: 2.9rem; padding: 0 1rem; border: 0; border-radius: 0.9rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-size: 0.95rem; box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-sa__photos { display: flex; flex-wrap: wrap; align-items: center; gap: 0.6rem; }
.ds-sa__shot img { width: 3.5rem; height: 3.5rem; border-radius: 0.9rem; object-fit: cover; box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.15); animation: sa-in .25s ease-out; }
.ds-sa__addphoto { flex: 1; min-width: 10rem; display: flex; align-items: center; justify-content: center; gap: 0.5rem; height: 3.5rem; border-radius: 1rem; background: rgb(255 255 255 / 0.06); box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.1); color: var(--sa-text); font-weight: 600; }
.ds-sa__addphoto svg { width: 1.25rem; height: 1.25rem; }
.ds-sa__err { width: 100%; margin: 0; font-size: 0.8rem; color: #ff9d93; }
.ds-sa__primary { height: 3.6rem; border-radius: 1.15rem; background: var(--sa-gold); color: #0a1219; font-size: 1.05rem; font-weight: 700; transition: transform .12s; }
.ds-sa__secondary { height: 3rem; border-radius: 1rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-size: 0.95rem; font-weight: 600; }
.ds-sa__primary:active, .ds-sa__secondary:active { transform: scale(.98); }
.ds-sa__sheet .fi-btn { height: 3.4rem; border-radius: 1.1rem; }
.ds-sa__done { align-items: stretch; text-align: center; }
.ds-sa__done h2 { margin: 0.5rem 0 0; font-size: 1.75rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-sa__done > p { margin: 0; color: var(--sa-muted); }
.ds-sa__totals { display: grid; grid-template-columns: repeat(3, 1fr); margin-top: 0.75rem; border-radius: 1.4rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__totals span { display: flex; flex-direction: column; gap: 0.15rem; padding: 1rem 0.4rem; }
.ds-sa__totals span + span { box-shadow: inset 1px 0 0 var(--sa-line); }
.ds-sa__totals strong { font-size: 1.5rem; }
.ds-sa__totals small { font-size: 0.75rem; color: var(--sa-muted); }
.ds-sa__done .ds-sa__note { text-align: left; }
.ds-sa__done .ds-sa__primary { margin-top: auto; }
@media (prefers-reduced-motion: reduce) { .ds-sa *, .ds-sa *::before { animation: none !important; transition: none !important; } }
/* scan app sign-in */
.ds-auth--scan .ds-auth-delivery__top h1 { max-width: 14ch; }
.ds-sa__waiting { padding: 0.2rem 0.6rem; border-radius: 999px; font-size: 0.72rem; font-weight: 700; color: var(--sa-gold); background: rgb(246 190 0 / 0.12); white-space: nowrap; }
.ds-sa__waiting.is-none { color: var(--sa-muted); background: rgb(255 255 255 / 0.05); }
.ds-sa__choice.is-finished { opacity: 0.5; }
.ds-sa__choice.is-finished .ds-sa__ring .is-fill { stroke: var(--sa-ok); }
.ds-sa__more { align-self: center; padding: 0.5rem 1rem; border-radius: 999px; font-size: 0.85rem; font-weight: 600; color: var(--sa-muted); text-decoration: underline; }

/* ------------------------------------------------------------------ Driver app (delivery home) */
.fi-panel-delivery .fi-main:has(.ds-dr) { padding: 0 !important; max-width: none !important; }
.fi-panel-delivery .fi-page:has(.ds-dr) .fi-header { display: none; }
.ds-sa__avatar.is-green { background: linear-gradient(135deg, #34c38f, #1f9a6c); }
.ds-sa__ring.is-mid { width: 6rem; height: 6rem; }
.ds-sa__ring.is-mid > span strong { font-size: 1.5rem; }
.ds-sa__ring.is-mid > span small { font-size: 0.6rem; text-align: center; max-width: 4.5rem; line-height: 1.2; }
.ds-sa__ring .is-fill.is-green { stroke: var(--sa-ok); }
.ds-sa__today dd.is-ok { color: #6fd6ad; }
.ds-sa__today dd.is-warn { color: var(--sa-warn); }
.ds-dr__scanbtn { display: flex; align-items: center; justify-content: center; gap: 0.6rem; height: 4rem; border-radius: 1.4rem; font-size: 1.1rem; font-weight: 800; box-shadow: 0 14px 34px rgb(246 190 0 / 0.22); }
.ds-dr__scanbtn svg { width: 1.5rem; height: 1.5rem; }
.ds-dr__labelrow { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: -0.6rem; }
.ds-dr__labelrow .ds-sa__label { margin: 0; }
.ds-dr__labelrow button { color: var(--sa-gold); font-size: 0.82rem; font-weight: 700; }
.ds-sa__list.is-warn { box-shadow: inset 0 0 0 1px rgb(240 169 59 / 0.35); }
.ds-sa__list.is-warn .ds-sa__rowtext strong { color: #f3c98a; }
.ds-dr__done { cursor: default; }
.ds-dr__thumb { width: 2.6rem; height: 2.6rem; border-radius: 0.7rem; object-fit: cover; flex: none; }
.ds-dr__undo { padding: 0.45rem 0.7rem; border-radius: 0.7rem; background: rgb(255 255 255 / 0.08); color: var(--sa-text); font-size: 0.75rem; font-weight: 700; white-space: nowrap; }
.ds-dr__office { font-size: 0.72rem; color: var(--sa-muted); white-space: nowrap; }
.ds-dr__crew { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.75rem 0.9rem; border-radius: 1.1rem; background: rgb(255 255 255 / 0.035); font-size: 0.82rem; color: #a9b8c2; }
.ds-dr__crew span { display: flex; align-items: center; gap: 0.6rem; }
.ds-dr__crew i { display: grid; place-items: center; width: 1.9rem; height: 1.9rem; border-radius: 50%; background: rgb(255 255 255 / 0.08); font-style: normal; font-weight: 700; font-size: 0.7rem; color: var(--sa-text); }
.ds-dr__celebrate { display: flex; flex-direction: column; align-items: center; gap: 0.5rem; text-align: center; padding: 1rem 0; }
.ds-dr__celebrate strong { font-size: 1.5rem; letter-spacing: -0.02em; }
.ds-dr__celebrate p { margin: 0; color: var(--sa-muted); }
.ds-sa__empty { display: flex; flex-direction: column; align-items: center; gap: 0.6rem; padding: 3rem 1rem; text-align: center; border-radius: 1.6rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sa__empty-icon { display: grid; place-items: center; width: 3.5rem; height: 3.5rem; border-radius: 1.1rem; background: rgb(246 190 0 / 0.1); color: var(--sa-gold); }
.ds-sa__empty-icon svg { width: 1.6rem; height: 1.6rem; }
.ds-sa__empty strong { font-size: 1.2rem; }
.ds-sa__empty p { margin: 0; color: var(--sa-muted); font-size: 0.9rem; line-height: 1.5; }
.ds-dr__listhead { display: flex; align-items: center; gap: 0.7rem; }
.ds-dr__listhead strong { flex: 1; font-size: 1.6rem; font-weight: 700; letter-spacing: -0.025em; }
.ds-dr__scanmini { display: grid; place-items: center; width: 2.75rem; height: 2.75rem; border-radius: 0.9rem; background: var(--sa-gold); color: #0a1219; }
.ds-dr__scanmini svg { width: 1.25rem; height: 1.25rem; }
.ds-dr__search { display: flex; align-items: center; gap: 0.6rem; height: 3rem; padding: 0 0.9rem; border-radius: 1rem; background: rgb(255 255 255 / 0.05); box-shadow: inset 0 0 0 1px var(--sa-line); color: var(--sa-muted); }
.ds-dr__search svg { width: 1.1rem; height: 1.1rem; flex: none; }
.ds-dr__search input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: var(--sa-text); font-size: 1rem; }
.ds-dr__search input::-webkit-search-cancel-button { filter: invert(1); }
.ds-sa__seg.is-3 { grid-template-columns: repeat(3, 1fr); }
.ds-sa__seg.is-3 .ds-sa__segthumb { width: calc((100% - 8px) / 3); }
.ds-sa__segthumb.is-light { background: var(--sa-text); }
.ds-sa__seg.is-3 button { font-size: 0.74rem; }
.ds-dr__rows { display: flex; flex-direction: column; gap: 0.6rem; }
.ds-dr__card { display: flex; align-items: center; gap: 0.75rem; padding: 0.85rem 1rem; border-radius: 1.25rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); animation: sa-in .3s ease-out both; }
.ds-dr__cardmain { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; text-align: left; color: inherit; }
.ds-dr__cardtop { display: flex; align-items: baseline; gap: 0.5rem; }
.ds-dr__cardtop strong { font-size: 1rem; }
.ds-dr__cardtop em { font-style: normal; font-size: 0.7rem; font-weight: 700; padding: 0.1rem 0.5rem; border-radius: 999px; color: #c9d5dc; background: rgb(255 255 255 / 0.07); }
.ds-dr__cardtop em.is-ok { color: #6fd6ad; background: rgb(52 195 143 / 0.14); }
.ds-dr__cardtop em.is-warn { color: #f3c98a; background: rgb(240 169 59 / 0.14); }
.ds-dr__name { font-size: 0.9rem; }
.ds-dr__cardmain small { font-size: 0.75rem; color: var(--sa-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-dr__call { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; background: rgb(52 195 143 / 0.14); color: var(--sa-ok); }
.ds-dr__call svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__toast { position: fixed; top: calc(env(safe-area-inset-top) + 5.5rem); left: 1rem; right: 1rem; z-index: 26; max-width: 32rem; margin: 0 auto; display: flex; align-items: center; gap: 0.75rem; padding: 0.75rem 0.75rem 0.75rem 0.9rem; border-radius: 1.25rem;
    background: rgb(15 43 35 / 0.96); backdrop-filter: blur(18px); box-shadow: 0 16px 40px rgb(0 0 0 / 0.4), inset 0 0 0 1px rgb(52 195 143 / 0.4); animation: dr-toast .35s cubic-bezier(.2,.9,.2,1); }
@keyframes dr-toast { from { transform: translateY(-140%); } to { transform: none; } }
@keyframes dr-count { from { stroke-dashoffset: 0; } to { stroke-dashoffset: 113; } }
.ds-dr__toast .ds-sa__mark { width: 2.2rem; height: 2.2rem; }
.ds-dr__toast .ds-sa__mark svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__toast > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-dr__toast small { font-size: 0.75rem; color: #9fd8c0; }
.ds-dr__toast button { display: flex; align-items: center; gap: 0.45rem; height: 2.5rem; padding: 0 0.85rem 0 0.6rem; border-radius: 0.8rem; background: rgb(255 255 255 / 0.1); color: var(--sa-text); font-weight: 700; }
.ds-dr__toast button svg { width: 1.35rem; height: 1.35rem; transform: rotate(-90deg); }
.ds-dr__toast circle { fill: none; stroke-width: 4; }
.ds-dr__toast .is-track { stroke: rgb(255 255 255 / 0.15); }
.ds-dr__toast .is-fill { stroke: var(--sa-gold); stroke-dasharray: 113; animation: dr-count 15s linear forwards; }
.ds-dr__tags { display: flex; align-items: center; gap: 0.6rem; }
.ds-dr__ontruck { padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(52 195 143 / 0.14); color: #6fd6ad; font-size: 0.75rem; font-weight: 700; }
.ds-dr__tags strong { font-size: 0.95rem; color: #c9d5dc; }
.ds-dr__tags em { margin-left: auto; font-style: normal; padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); font-size: 0.75rem; font-weight: 600; color: #c9d5dc; }
.ds-dr__receiver { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-dr__receiver strong { font-size: 1.6rem; letter-spacing: -0.02em; line-height: 1.1; }
.ds-dr__receiver span { font-size: 0.9rem; color: #a9b8c2; line-height: 1.45; }
.ds-dr__two { display: grid; grid-template-columns: repeat(auto-fit, minmax(0, 1fr)); gap: 0.5rem; }
.ds-dr__two a { display: flex; align-items: center; justify-content: center; gap: 0.5rem; height: 3rem; border-radius: 0.9rem; background: rgb(255 255 255 / 0.06); color: var(--sa-text); font-weight: 600; font-size: 0.9rem; }
.ds-dr__two svg { width: 1.1rem; height: 1.1rem; }
.ds-dr__meta { font-size: 0.8rem; color: var(--sa-muted); }
.ds-dr__prev { font-size: 0.8rem; color: #f3c98a; }
.ds-sa__primary.is-green { background: var(--sa-ok); }
.ds-sa__primary.is-amber { background: var(--sa-warn); }
.ds-sa__primary.is-off { background: rgb(255 255 255 / 0.08); color: var(--sa-muted); }
.ds-dr__link { height: 2.6rem; color: var(--sa-muted); font-weight: 600; }
.ds-dr__sheethead { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-dr__sheethead small { font-size: 0.8rem; color: var(--sa-muted); }
.ds-dr__sheethead.is-warn small { color: #c9b08a; }
.ds-dr__sheethead strong { font-size: 1.45rem; letter-spacing: -0.02em; }
.ds-dr__sheethead > span { font-size: 0.88rem; color: #a9b8c2; }
.ds-dr__grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.6rem; }
.ds-dr__proof { position: relative; aspect-ratio: 1; border-radius: 1.1rem; overflow: hidden; animation: sa-in .25s ease-out; }
.ds-dr__proof img { width: 100%; height: 100%; object-fit: cover; }
.ds-dr__proof b { position: absolute; left: 0.45rem; bottom: 0.45rem; padding: 0.05rem 0.5rem; border-radius: 999px; background: rgb(10 18 25 / 0.75); font-size: 0.7rem; }
.ds-dr__proof button { position: absolute; right: 0.35rem; top: 0.35rem; width: 1.6rem; height: 1.6rem; border-radius: 50%; background: rgb(10 18 25 / 0.7); color: #fff; font-size: 0.7rem; }
.ds-dr__proof.is-small { width: 3.5rem; height: 3.5rem; aspect-ratio: auto; border-radius: 0.9rem; }
.ds-dr__add { aspect-ratio: 1; border-radius: 1.1rem; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 0.35rem; background: rgb(255 255 255 / 0.05); box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / 0.18); color: var(--sa-text); font-size: 0.8rem; font-weight: 600; }
.ds-dr__add svg { width: 1.6rem; height: 1.6rem; }
.ds-dr__chips { display: flex; flex-wrap: wrap; gap: 0.45rem; }
.ds-dr__chips button { height: 2.35rem; padding: 0 0.85rem; border-radius: 999px; background: rgb(255 255 255 / 0.07); color: var(--sa-text); font-size: 0.8rem; font-weight: 700; transition: background .2s, color .2s; }
.ds-dr__chips button.is-on { background: var(--sa-warn); color: #0a1219; }
.ds-sa__sheet.is-warn .ds-sa__note-in { background: rgb(255 255 255 / 0.06); }
.ds-sa.ds-dr { z-index: 32; }

/* ===================================================================== AI helpers */
.ds-ai {
    --ai-surf: #fff; --ai-raised: #f6f8fa; --ai-line: #e8edf1; --ai-text: #0e2433; --ai-muted: #5b6b78;
    --ai-violet: #6c55d9; --ai-violet-soft: #f2efff; --ai-violet-text: #3f3380;
    --ai-ok: #17895e; --ai-ok-soft: #e5f6ee; --ai-bad: #c2382f; --ai-bad-soft: #fde8e6; --ai-warn: #a76400; --ai-warn-soft: #fff2d9;
    --ai-blue: #1f6fa5; --ai-blue-soft: #e5f1fa; --ai-gold: #d4a72c;
    display: flex; flex-direction: column; gap: 1rem; color: var(--ai-text);
}
.dark .ds-ai {
    --ai-surf: #142430; --ai-raised: #1a2d3b; --ai-line: rgb(255 255 255 / 0.08); --ai-text: #e9eff3; --ai-muted: #93a6b4;
    --ai-violet-soft: rgb(108 85 217 / 0.18); --ai-violet-text: #cdc3ff;
    --ai-ok-soft: rgb(23 137 94 / 0.2); --ai-bad-soft: rgb(194 56 47 / 0.2); --ai-warn-soft: rgb(167 100 0 / 0.22); --ai-blue-soft: rgb(31 111 165 / 0.22);
    --ai-ok: #4fd09d; --ai-bad: #ff8a7e; --ai-warn: #f3c06b; --ai-blue: #8cc4ff;
}
.ds-ai__card { background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 1rem 1.1rem; display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-ai__card-head { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; flex-wrap: wrap; }
.ds-ai__card-head b { font-size: 1rem; }
.ds-ai__bar { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; flex-wrap: wrap; }
.ds-ai__seg { display: inline-flex; flex-wrap: wrap; gap: 0.3rem; align-items: center; }
.ds-ai__seg button { height: 2.1rem; padding: 0 0.85rem; border-radius: 0.65rem; font-size: 0.85rem; font-weight: 700; color: var(--ai-text); background: var(--ai-surf); box-shadow: inset 0 0 0 1px var(--ai-line); }
.ds-ai__seg.is-small button { height: 1.85rem; padding: 0 0.65rem; font-size: 0.78rem; background: var(--ai-raised); box-shadow: none; }
.ds-ai__seg button.is-on { background: var(--ds-navy); color: #fff; box-shadow: none; }
.dark .ds-ai__seg button.is-on { background: #e9eff3; color: #0b1620; }
.ds-ai__seg button i { font-style: normal; margin-left: 0.3rem; padding: 0 0.4rem; border-radius: 999px; background: #f0a93b; color: #fff; font-size: 0.72rem; }
.ds-ai__stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(10rem, 1fr)); gap: 0.75rem; }
.ds-ai__stats > div { background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 0.85rem 1rem; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-ai__stats.is-small > div { background: var(--ai-raised); box-shadow: none; }
.ds-ai__stats small { font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__stats b { font-size: 1.6rem; font-weight: 900; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
.ds-ai__stats b span { font-size: 0.9rem; font-weight: 600; color: var(--ai-muted); }
.ds-ai__stats em { font-style: normal; font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai .is-red { color: var(--ai-bad); } .ds-ai .is-amber { color: var(--ai-warn); } .ds-ai .is-green { color: var(--ai-ok); }
.ds-ai__split { display: grid; grid-template-columns: minmax(0, 1fr) 24rem; gap: 1rem; align-items: start; }
.ds-ai__split.is-even { grid-template-columns: repeat(auto-fit, minmax(22rem, 1fr)); }
@media (max-width: 1100px) { .ds-ai__split { grid-template-columns: 1fr; } }
.ds-ai__list { padding: 0; gap: 0; overflow: hidden; }
.ds-ai__list > .ds-ai__card-head { padding: 0.8rem 1rem; border-bottom: 1px solid var(--ai-line); }
.ds-ai__row { width: 100%; display: flex; align-items: center; gap: 0.8rem; padding: 0.7rem 1rem; text-align: left; border-top: 1px solid var(--ai-line); background: var(--ai-surf); color: inherit; }
.ds-ai__row:first-of-type { border-top: 0; }
.ds-ai__row:hover { background: var(--ai-raised); }
.ds-ai__row.is-sel { background: var(--ai-warn-soft); box-shadow: inset 3px 0 0 var(--ai-gold); }
.ds-ai__row img { width: 4.2rem; height: 3.2rem; border-radius: 0.55rem; object-fit: cover; flex: none; background: var(--ai-raised); }
.ds-ai__row-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.15rem; font-size: 0.85rem; }
.ds-ai__row-main b { font-size: 0.95rem; }
.ds-ai__row-main small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai__tag { display: inline-block; font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.72rem; font-weight: 800; background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__tag.is-damaged, .ds-ai__tag.is-no_box { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__tag.is-wet { background: var(--ai-blue-soft); color: var(--ai-blue); }
.ds-ai__tag.is-open { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__tag.is-blurry { background: var(--ai-violet-soft); color: var(--ai-violet-text); }
.ds-ai__tag.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__state { flex: none; padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__state.is-damaged, .ds-ai__state.is-removed { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__state.is-fine, .ds-ai__state.is-texted, .ds-ai__state.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__state.is-open { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__empty { padding: 1.5rem 1rem; color: var(--ai-muted); text-align: center; margin: 0; }
.ds-ai__detail { position: sticky; top: 5rem; }
.ds-ai__photo { position: relative; display: block; border-radius: 0.8rem; overflow: hidden; background: var(--ai-raised); }
.ds-ai__photo img { width: 100%; max-height: 18rem; object-fit: contain; display: block; }
.ds-ai__photo span { position: absolute; left: 0.6rem; top: 0.6rem; padding: 0.15rem 0.55rem; border-radius: 999px; background: rgb(14 36 51 / 0.75); color: #fff; font-size: 0.75rem; font-weight: 700; }
.ds-ai__detail-head { display: flex; align-items: baseline; justify-content: space-between; gap: 0.5rem; }
.ds-ai__detail-head b { font-size: 1.15rem; } .ds-ai__detail-head small { color: var(--ai-muted); font-size: 0.8rem; }
.ds-ai__said { display: flex; gap: 0.7rem; padding: 0.8rem 0.9rem; border-radius: 0.8rem; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.9rem; line-height: 1.5; }
.ds-ai__said > span:last-child { display: flex; flex-direction: column; gap: 0.35rem; flex: 1; min-width: 0; }
.ds-ai__said small { font-size: 0.85rem; opacity: 0.9; }
.ds-ai__badge { width: 1.7rem; height: 1.7rem; flex: none; border-radius: 0.5rem; background: var(--ai-violet); color: #fff; display: grid; place-items: center; font-size: 0.7rem; font-weight: 900; }
.ds-ai__two { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-ai__two > * { flex: 1 1 auto; }
.ds-ai__done { margin: 0; padding: 0.7rem 0.85rem; border-radius: 0.7rem; font-size: 0.85rem; font-weight: 600; }
.ds-ai__done.is-damaged { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__done.is-fine { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__link { color: var(--ai-violet); font-weight: 700; font-size: 0.8rem; margin-left: 0.4rem; text-decoration: none; }
.dark .ds-ai__link { color: #b9a8ff; }
.ds-ai__err { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: var(--ai-bad-soft, #fde8e6); color: var(--ai-bad, #b3261e); font-size: 0.85rem; }
.ds-ai__test { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; font-size: 0.9rem; font-weight: 600; }
.ds-ai__test.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ai__test.is-bad { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__paused { display: flex; gap: 0.6rem; align-items: center; padding: 0.7rem 0.9rem; border-radius: 0.8rem; background: var(--ai-warn-soft); color: var(--ai-warn); font-size: 0.9rem; }
.ds-ai__paused b { padding: 0.1rem 0.5rem; border-radius: 999px; background: #f0a93b; color: #fff; font-size: 0.75rem; }
.ds-ai__pill { padding: 0.15rem 0.6rem; border-radius: 999px; font-size: 0.75rem !important; font-weight: 700; }
.ds-ai__pill.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok) !important; }
.ds-ai__pill.is-off { background: var(--ai-warn-soft); color: var(--ai-warn) !important; }
/* settings */
.ds-ai-set { gap: 1rem; }
.ds-ai-set__steps { margin: 0; padding-left: 1.2rem; display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.9rem; }
.ds-ai-set__steps a, .ds-ai-set__notes a { color: var(--ai-violet); font-weight: 700; }
.ds-ai-set__key { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-ai-set__key input { flex: 1 1 18rem; min-width: 0; height: 2.6rem; padding: 0 0.8rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); font-family: ui-monospace, monospace; }
.ds-ai-set__feat { display: grid; grid-template-columns: auto 1fr auto; gap: 0.8rem; align-items: start; padding: 0.75rem 0; border-top: 1px solid var(--ai-line); cursor: pointer; }
.ds-ai-set__feat input { margin-top: 0.25rem; }
.ds-ai-set__feat > span:nth-child(2) { display: flex; flex-direction: column; gap: 0.15rem; }
.ds-ai-set__feat small { font-size: 0.85rem; color: var(--ai-muted); }
.ds-ai-set__feat em { font-style: normal; font-size: 0.75rem; font-weight: 700; color: var(--ai-violet); }
.ds-ai-set__use { display: flex; flex-direction: column; align-items: flex-end; font-variant-numeric: tabular-nums; }
.ds-ai-set__use small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ai-set__save { display: flex; justify-content: flex-end; }
.ds-ai-set__spend { display: flex; flex-direction: column; gap: 0.4rem; }
.ds-ai-set__spend i { display: block; height: 0.5rem; border-radius: 999px; background: var(--ai-raised); overflow: hidden; }
.ds-ai-set__spend s { display: block; height: 100%; background: var(--ai-ok); border-radius: 999px; text-decoration: none; }
.ds-ai-set__spend s.is-bad { background: var(--ai-bad); }
.ds-ai-set__notes { margin: 0; padding-left: 1.2rem; display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.9rem; }
.ds-ai-set code, .ds-ai-set__steps code { font-size: 0.85em; padding: 0.05rem 0.3rem; border-radius: 0.3rem; background: var(--ai-raised); }
/* ask */
.ds-ai__chat { padding: 0; gap: 0; min-height: 34rem; }
.ds-ai__msgs { flex: 1; max-height: 60vh; min-height: 22rem; overflow: auto; padding: 1.2rem 1.4rem; display: flex; flex-direction: column; gap: 0.8rem; }
.ds-ai__hello { margin: auto; text-align: center; display: flex; flex-direction: column; gap: 0.3rem; color: var(--ai-muted); }
.ds-ai__hello b { font-size: 1.1rem; color: var(--ai-text); }
.ds-ai__msg { align-self: flex-start; max-width: 46rem; padding: 0.7rem 0.95rem; border-radius: 1rem 1rem 1rem 0.25rem; background: var(--ai-raised); font-size: 0.95rem; line-height: 1.55; }
.ds-ai__msg.is-me { align-self: flex-end; background: var(--ds-navy); color: #fff; border-radius: 1rem 1rem 0.25rem 1rem; }
.ds-ai__typing { align-self: flex-start; align-items: center; gap: 0.3rem; padding: 0.6rem 0.9rem; border-radius: 1rem; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.85rem; }
.ds-ai__typing i { width: 0.4rem; height: 0.4rem; border-radius: 50%; background: var(--ai-violet); animation: ds-ai-dot 1s infinite; }
.ds-ai__typing i:nth-child(2) { animation-delay: 0.15s; } .ds-ai__typing i:nth-child(3) { animation-delay: 0.3s; }
.ds-ai__typing span { margin-left: 0.3rem; }
@keyframes ds-ai-dot { 0%, 80%, 100% { opacity: 0.25; } 40% { opacity: 1; } }
.ds-ai__ask { border-top: 1px solid var(--ai-line); padding: 0.8rem 1rem 1rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-ai__chips { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-ai__chips button { height: 1.9rem; padding: 0 0.75rem; border-radius: 999px; background: var(--ai-violet-soft); color: var(--ai-violet-text); font-size: 0.8rem; font-weight: 700; }
.ds-ai__chips button.is-plain { background: var(--ai-raised); color: var(--ai-muted); }
.ds-ai__askrow { display: flex; gap: 0.5rem; }
.ds-ai__askrow input, .ds-ai__text, .ds-ai__select { flex: 1; min-width: 0; height: 2.75rem; padding: 0 0.9rem; border-radius: 0.7rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); font-size: 0.95rem; }
.ds-ai__text { height: auto; padding: 0.7rem 0.9rem; line-height: 1.5; resize: vertical; }
.ds-ai__select { flex: 0 1 14rem; height: 2.2rem; }
/* manifest */
.ds-ai__upload { max-width: 44rem; }
.ds-ai__upload select { height: 2.6rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); padding: 0 0.7rem; }
.ds-ai__drop { display: flex; flex-direction: column; align-items: center; gap: 0.3rem; padding: 1.6rem 1rem; border-radius: 0.9rem; background: var(--ai-raised); box-shadow: inset 0 0 0 1.5px dashed var(--ai-line); border: 1.5px dashed #c9d3db; cursor: pointer; text-align: center; }
.ds-ai__drop input { max-width: 100%; font-size: 0.85rem; }
.ds-ai__drop small { color: var(--ai-muted); }
.ds-ai__table { overflow: auto; max-height: 62vh; border-radius: 0.7rem; box-shadow: 0 0 0 1px var(--ai-line); }
.ds-ai__tr { display: grid; grid-template-columns: 2rem 7rem minmax(10rem, 1.2fr) minmax(14rem, 2fr) 8rem 5rem minmax(12rem, 1.4fr); gap: 0.6rem; align-items: start; padding: 0.55rem 0.8rem; border-top: 1px solid var(--ai-line); font-size: 0.83rem; min-width: 64rem; }
.ds-ai__tr.is-head { position: sticky; top: 0; z-index: 1; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); border-top: 0; }
.ds-ai__tr small { display: block; color: var(--ai-muted); font-size: 0.73rem; }
.ds-ai__tr.is-off { opacity: 0.55; }
.ds-ai__tr.is-warn { background: var(--ai-warn-soft); }
.ds-ai__notes { display: flex; flex-direction: column; gap: 0.2rem; align-items: flex-start; }
.ds-ai__notes .ds-ai__tag { white-space: normal; }
.ds-ai__foot { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; }
.ds-ai__foot > span { flex: 1 1 20rem; font-size: 0.85rem; color: var(--ai-muted); }
/* risky */
.ds-ai__score { width: 3rem; height: 3rem; flex: none; border-radius: 0.8rem; display: grid; place-items: center; font-weight: 900; font-size: 0.9rem; background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ai__score.is-high { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__why { margin: 0; padding-left: 1.1rem; display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.88rem; }
.ds-ai__label { font-size: 0.85rem; }
.ds-ai__btn { display: inline-flex; align-items: center; justify-content: center; height: 2.25rem; padding: 0 0.9rem; border-radius: 0.55rem; font-weight: 700; font-size: 0.875rem; text-decoration: none; }
.ds-ai__btn.is-green { background: var(--ai-ok); color: #fff; }
/* alerts */
.ds-ai__alert { display: flex; gap: 0.85rem; align-items: flex-start; padding: 0.9rem 0.2rem; border-top: 1px solid var(--ai-line); }
.ds-ai__alert:first-child { border-top: 0; }
.ds-ai__alert-ic { width: 2.5rem; height: 2.5rem; flex: none; border-radius: 0.75rem; display: grid; place-items: center; font-size: 1.1rem; background: var(--ai-blue-soft); }
.ds-ai__alert.is-high .ds-ai__alert-ic { background: var(--ai-bad-soft); }
.ds-ai__alert.is-mid .ds-ai__alert-ic { background: var(--ai-warn-soft); }
.ds-ai__alert-act { display: flex; flex-direction: column; gap: 0.35rem; align-items: stretch; width: 9rem; flex: none; }
.ds-ai__alert-act small { color: var(--ai-muted); font-size: 0.75rem; text-align: center; }
/* insights */
.ds-ai__bars { display: flex; align-items: flex-end; gap: 0.35rem; height: 13rem; padding-top: 0.5rem; overflow-x: auto; }
.ds-ai__barcol { flex: 1 0 2.4rem; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; gap: 0.3rem; height: 100%; }
.ds-ai__barcol em { font-style: normal; font-size: 0.68rem; font-weight: 700; color: var(--ai-muted); font-variant-numeric: tabular-nums; }
.ds-ai__barcol i { position: relative; display: block; width: 1.3rem; border-radius: 0.3rem 0.3rem 0 0; min-height: 2px; }
.ds-ai__barcol i.is-past { background: #c9d3db; }
.dark .ds-ai__barcol i.is-past { background: #3a4f5f; }
.ds-ai__barcol i.is-next { background: #e9b730; }
.ds-ai__barcol i s { position: absolute; left: -0.25rem; right: -0.25rem; height: 2px; background: var(--ai-text); opacity: 0.55; }
.ds-ai__barcol small { font-size: 0.66rem; color: var(--ai-muted); white-space: nowrap; }
/* driver app + scan app */
.ds-dr__risk { display: flex; flex-direction: column; gap: 0.2rem; padding: 0.7rem 0.85rem; border-radius: 0.9rem; background: rgb(240 169 59 / 0.14); box-shadow: inset 0 0 0 1px rgb(240 169 59 / 0.4); color: #f3c98a; font-size: 0.82rem; line-height: 1.45; }
.ds-dr__risk b { color: #ffd28f; font-size: 0.85rem; }
.ds-dr__voice { display: flex; align-items: center; gap: 0.8rem; padding: 0.6rem 0.7rem; border-radius: 1rem; background: rgb(108 85 217 / 0.16); }
.ds-dr__voice button { width: 3.2rem; height: 3.2rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: #8b78ff; color: #fff; }
.ds-dr__voice button.is-on { background: #ff6b5e; animation: ds-ai-pulse 1s infinite; }
.ds-dr__voice button svg { width: 1.5rem; height: 1.5rem; }
.ds-dr__voice > span { display: flex; flex-direction: column; gap: 0.1rem; min-width: 0; }
.ds-dr__voice b { font-size: 0.9rem; } .ds-dr__voice small { font-size: 0.75rem; color: #c9c0ff; }
@keyframes ds-ai-pulse { 0% { box-shadow: 0 0 0 0 rgb(255 107 94 / 0.55); } 100% { box-shadow: 0 0 0 16px rgb(255 107 94 / 0); } }
.ds-sa__aiflag { position: relative; z-index: 6; display: flex; align-items: center; flex-wrap: wrap; gap: 0.6rem; margin: 0 0 0.6rem; padding: 0.7rem 0.8rem; border-radius: 1rem; background: rgb(108 85 217 / 0.2); box-shadow: inset 0 0 0 1px rgb(139 120 255 / 0.5); color: #eef3f6; }
.ds-sa__aiflag > span:nth-child(2) { flex: 1 1 10rem; display: flex; flex-direction: column; font-size: 0.85rem; }
.ds-sa__aiflag small { color: #c9c0ff; font-size: 0.75rem; }
.ds-sa__aiflag button { height: 2.3rem; padding: 0 0.8rem; border-radius: 0.7rem; background: #ff6b5e; color: #fff; font-weight: 800; font-size: 0.8rem; }
.ds-sa__aiflag button.is-plain { background: rgb(255 255 255 / 0.1); }
.ds-sa__aibadge { width: 1.8rem; height: 1.8rem; flex: none; border-radius: 0.55rem; display: grid; place-items: center; background: #8b78ff; color: #fff; font-size: 0.7rem; font-weight: 900; }
/* AI trip helper */
.ds-ai__plan { flex-direction: row; align-items: center; gap: 0.6rem; flex-wrap: wrap; padding: 0.6rem; }
.ds-ai__plan > input { flex: 1 1 18rem; min-width: 0; height: 2.5rem; padding: 0 0.8rem; border-radius: 0.6rem; border: 0; background: var(--ai-raised); color: var(--ai-text); }
.ds-ai__date { display: flex; align-items: center; gap: 0.4rem; font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__date input { height: 2.5rem; padding: 0 0.6rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); }
.ds-ai__split.is-trips { grid-template-columns: 20rem minmax(0, 1fr); }
@media (max-width: 1100px) { .ds-ai__split.is-trips { grid-template-columns: 1fr; } }
.ds-ai__tree { display: flex; flex-direction: column; gap: 0.7rem; max-height: 55vh; overflow: auto; }
.ds-ai__tree > div { display: flex; flex-direction: column; gap: 0.35rem; }
.ds-ai__tree > div > b { font-size: 0.85rem; }
.ds-ai__tree small { color: var(--ai-muted); font-weight: 600; }
.ds-ai__tree span { display: flex; flex-direction: column; gap: 0.1rem; padding-left: 0.6rem; border-left: 2px solid var(--ai-line); font-size: 0.82rem; }
.ds-ai__tree span small { font-weight: 400; line-height: 1.45; }
.ds-ai__two.is-left > * { flex: 0 0 auto; }
.ds-ai__tripcol { display: flex; flex-direction: column; gap: 0.8rem; min-width: 0; }
.ds-ai__trips { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 0.8rem; }
.ds-ai__trip { display: flex; flex-direction: column; gap: 0.6rem; padding: 0.9rem; border-radius: 1rem; background: var(--ai-surf); box-shadow: 0 0 0 1px var(--ai-line); }
.ds-ai__trip.is-over { box-shadow: 0 0 0 1.5px var(--ai-bad); }
.ds-ai__select.is-full { flex: none; width: 100%; }
.ds-ai__dest { display: flex; align-items: center; gap: 0.5rem; font-size: 0.8rem; color: var(--ai-muted); }
.ds-ai__dest .ds-ai__select { flex: 1; }
.ds-ai__fill { display: flex; justify-content: space-between; font-size: 0.85rem; font-variant-numeric: tabular-nums; }
.ds-ai__meter { display: block; height: 0.45rem; border-radius: 999px; background: var(--ai-raised); overflow: hidden; }
.ds-ai__meter s { display: block; height: 100%; border-radius: 999px; background: var(--ai-ok); text-decoration: none; }
.ds-ai__meter s.is-warn { background: #e0a400; } .ds-ai__meter s.is-bad { background: var(--ai-bad); }
.ds-ai__place { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; padding: 0.45rem 0.65rem; border-radius: 0.6rem; background: var(--ai-raised); text-align: left; font-size: 0.85rem; color: var(--ai-text); }
.ds-ai__place:hover { box-shadow: inset 0 0 0 1px var(--ai-violet); }
.ds-ai__place > span:first-child { display: flex; flex-direction: column; min-width: 0; }
.ds-ai__place small { color: var(--ai-muted); font-size: 0.72rem; }
.ds-ai__place > span:last-child { color: var(--ai-muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
.ds-ai__why1 { color: var(--ai-violet); font-size: 0.78rem; line-height: 1.4; }
.dark .ds-ai__why1 { color: #b9a8ff; }
.ds-ai__chipbtn { height: 1.9rem; padding: 0 0.7rem; border-radius: 999px; background: var(--ai-raised); font-size: 0.8rem; font-weight: 700; color: var(--ai-text); }
.ds-ai__chipbtn.is-prio { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ai__made { display: flex; align-items: center; gap: 0.8rem; }
.ds-ai__made > span:first-child { width: 2.6rem; height: 2.6rem; border-radius: 50%; background: var(--ai-ok); color: #fff; display: grid; place-items: center; font-size: 1.2rem; font-weight: 900; }
.ds-ai__made > span:last-child { display: flex; flex-direction: column; }
.ds-ai__made b { font-size: 1.15rem; } .ds-ai__made small { color: var(--ai-muted); }
.ds-ai__madeRow { display: grid; grid-template-columns: 8rem 9rem 1fr auto; gap: 0.8rem; align-items: center; padding: 0.6rem 0.8rem; border-radius: 0.7rem; background: var(--ai-raised); font-size: 0.9rem; }
.ds-ai__madeRow small { grid-column: 1 / -1; }
.ds-ai__card.ds-ai__foot { flex-direction: row; flex-wrap: wrap; align-items: center; }
.ds-ai__card.ds-ai__foot > span { flex: 1 1 20rem; }
/* Box aging */
.ds-ag .ds-ai__stats > button { text-align: left; background: var(--ai-surf); border-radius: 1rem; box-shadow: 0 0 0 1px var(--ai-line); padding: 0.85rem 1rem; display: flex; flex-direction: column; gap: 0.15rem; color: inherit; }
.ds-ag .ds-ai__stats > button:hover { box-shadow: 0 0 0 1.5px var(--ai-violet); }
.ds-ai__said > span:last-child > span { display: block; }
.ds-ag__table { padding: 0; gap: 0; overflow: auto; }
.ds-ag__tr { display: grid; grid-template-columns: minmax(15rem, 1.6fr) repeat(4, minmax(5rem, 1fr)) 6rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid var(--ai-line); min-width: 44rem; }
.ds-ag__tr.is-head { border-top: 0; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); }
.ds-ag__tr > span { display: flex; flex-direction: column; } .ds-ag__tr > span:not(:first-child) { align-items: center; }
.ds-ag__tr small { font-size: 0.75rem; color: var(--ai-muted); }
.ds-ag__cell { min-width: 3.4rem; height: 2rem; border-radius: 0.55rem; font-weight: 800; font-variant-numeric: tabular-nums; }
.ds-ag__cell.is-ok { background: var(--ai-ok-soft); color: var(--ai-ok); }
.ds-ag__cell.is-warn { background: var(--ai-warn-soft); color: var(--ai-warn); }
.ds-ag__cell.is-late { background: var(--ai-bad-soft); color: var(--ai-bad); }
.ds-ag__cell.is-zero { color: var(--ai-muted); opacity: 0.45; }
.ds-ag__cell.is-sel { box-shadow: 0 0 0 2px var(--ai-text); }
.ds-ag__late { text-align: right; font-size: 1.1rem; font-variant-numeric: tabular-nums; }
.ds-ag__box { display: grid; grid-template-columns: 6.5rem 1fr 4.5rem; gap: 0.6rem; align-items: center; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: var(--ai-raised); font-size: 0.85rem; }
.ds-ag__box > span:nth-child(2) { display: flex; flex-direction: column; min-width: 0; }
.ds-ag__box small { color: var(--ai-muted); font-size: 0.72rem; }
.ds-ag__age { display: flex; flex-direction: column; align-items: flex-end; font-weight: 800; font-variant-numeric: tabular-nums; }
.ds-ag__age.is-late { color: var(--ai-bad); } .ds-ag__age.is-warn { color: var(--ai-warn); } .ds-ag__age.is-ok { color: var(--ai-ok); }
.ds-ag__bar { display: grid; grid-template-columns: 1fr 10rem 4.5rem; gap: 0.6rem; align-items: center; font-size: 0.85rem; }
.ds-ag__bar small { color: var(--ai-muted); }
.ds-ag__bar i { display: flex; height: 0.6rem; border-radius: 999px; overflow: hidden; background: var(--ai-raised); }
.ds-ag__bar s { display: block; height: 100%; text-decoration: none; }
.ds-ag__bar s.is-ok { background: #34c38f; } .ds-ag__bar s.is-warn { background: #f0a93b; } .ds-ag__bar s.is-late { background: #d9534a; }
.ds-ag__bar b { text-align: right; font-size: 0.8rem; }
.ds-agl__tr { display: grid; grid-template-columns: minmax(14rem, 1.5fr) 6rem 9rem 9rem minmax(14rem, 2fr); gap: 0.7rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid var(--ai-line); min-width: 56rem; }
.ds-agl__tr.is-head { border-top: 0; background: var(--ai-raised); font-size: 0.75rem; font-weight: 700; color: var(--ai-muted); }
.ds-agl__tr.is-changed { background: var(--ai-warn-soft); }
.ds-agl__tr > span:first-child { display: flex; flex-direction: column; } .ds-agl__tr small { color: var(--ai-muted); font-size: 0.75rem; }
.ds-agl__num { display: flex; align-items: center; gap: 0.35rem; }
.ds-agl__num button { width: 1.7rem; height: 1.7rem; border-radius: 0.45rem; background: var(--ai-raised); font-weight: 800; }
.ds-agl__num b { min-width: 3.4rem; text-align: center; font-variant-numeric: tabular-nums; }
.ds-agl__why { font-size: 0.78rem; color: var(--ai-violet); line-height: 1.4; }
.dark .ds-agl__why { color: #b9a8ff; }
.ds-ai .ds-gm__field input { height: 2.4rem; padding: 0 0.7rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px var(--ai-line); background: var(--ai-surf); color: var(--ai-text); }
/* Install QR codes */
.ds-qr { display: flex; flex-direction: column; gap: 0.8rem; }
.ds-qr__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(24rem, 1fr)); gap: 1rem; }
.ds-qr.is-compact .ds-qr__grid { grid-template-columns: repeat(auto-fit, minmax(20rem, 1fr)); }
.ds-qr__card { display: flex; gap: 1rem; align-items: center; padding: 1rem; border-radius: 1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; }
.dark .ds-qr__card { background: rgb(255 255 255 / 0.04); box-shadow: 0 0 0 1px rgb(255 255 255 / 0.08); }
.ds-qr__code { flex: none; padding: 10px; border-radius: 0.8rem; background: #fff; box-shadow: inset 0 0 0 1px #e6ebef; line-height: 0; }
.ds-qr__code svg { display: block; }
.ds-qr.is-off .ds-qr__code { opacity: 0.25; filter: grayscale(1); }
.ds-qr__info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.5rem; }
.ds-qr__title { display: flex; align-items: center; gap: 0.6rem; }
.ds-qr__title img { width: 36px; height: 36px; border-radius: 9px; }
.ds-qr__title b { font-size: 1.1rem; }
.ds-qr__info small { color: #5b6b78; font-size: 0.82rem; line-height: 1.45; }
.dark .ds-qr__info small { color: #93a6b4; }
.ds-qr__link { display: flex; align-items: center; gap: 0.5rem; padding: 0.4rem 0.4rem 0.4rem 0.7rem; border-radius: 0.6rem; background: #f3f5f7; }
.dark .ds-qr__link { background: rgb(255 255 255 / 0.06); }
.ds-qr__link code { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.8rem; }
.ds-qr__link button { padding: 0.25rem 0.6rem; border-radius: 0.45rem; background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; font-size: 0.75rem; font-weight: 700; color: #0e2433; }
.ds-qr__info ol { margin: 0; padding-left: 1.1rem; font-size: 0.82rem; line-height: 1.6; }
.ds-qr__actions { display: flex; flex-wrap: wrap; gap: 0.4rem; }
.ds-qr__actions a { padding: 0.45rem 0.8rem; border-radius: 0.6rem; background: #eef1f4; color: #0e2433; font-size: 0.82rem; font-weight: 700; text-decoration: none; }
.ds-qr__actions a.is-main { background: #d4a72c; color: #1d1600; }
.dark .ds-qr__actions a:not(.is-main) { background: rgb(255 255 255 / 0.08); color: #e9eff3; }
.ds-qr__warn { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: #fde8e6; color: #8f2a22; font-size: 0.85rem; }
.ds-qr__warn.is-amber { background: #fff2d9; color: #7a5200; }
.ds-qr__ok { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.6rem; background: #e5f6ee; color: #0f5c3f; font-size: 0.85rem; }
.ds-qr__note { color: #8a99a5; font-size: 0.78rem; }
.ds-qr__hide { font-size: 0.8rem; font-weight: 700; color: #5b6b78; }
.ds-qr-set { display: flex; flex-direction: column; gap: 0.8rem; }
.ds-qr-set__base { display: flex; gap: 0.6rem; align-items: flex-end; flex-wrap: wrap; }
.ds-qr-set__base .ds-gm__field { flex: 1 1 24rem; }
.ds-qr-set__base input { height: 2.5rem; padding: 0 0.7rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; width: 100%; }
.ds-qr__info ol { list-style: decimal; }

/* ============================================================ Maps & routes */
.ds-mp { display: flex; flex-direction: column; gap: 1rem; }
.ds-mp__chain { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.6rem; }
.ds-mp__step { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.75rem; border-radius: 0.8rem; background: #f3f5f7; color: #5b6b78; }
.ds-mp__step.is-on { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__stephead { display: flex; align-items: center; gap: 0.5rem; font-size: 0.9rem; }
.ds-mp__stephead i { width: 1.5rem; height: 1.5rem; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font-style: normal; font-size: 0.75rem; font-weight: 900; color: #fff; background: #c9d1d8; }
.ds-mp__step.is-on .ds-mp__stephead i { background: #17895e; }
.ds-mp__step strong { font-size: 0.85rem; }
.ds-mp__step small { font-size: 0.78rem; line-height: 1.4; opacity: .85; }
.ds-mp__warn { margin: 0; padding: 0.5rem 0.75rem; border-radius: 0.6rem; background: #fff1d6; color: #7a5200; font-size: 0.85rem; }
.ds-mp__providers { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.75rem; }
.ds-mp__provider { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.9rem; border-radius: 0.9rem; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e6ebef; text-align: left; }
.ds-mp__provider.is-picked { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-mp__provhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
.ds-mp__provhead em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; background: #eef1f4; color: #6b7b88; }
.ds-mp__provhead em.is-on { background: #17895e; color: #fff; }
.ds-mp__provider small { font-size: 0.8rem; color: #5b6b78; line-height: 1.45; }
.ds-mp__provider code { font-size: 0.75rem; color: #33424e; }
.ds-mp__keyrow { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-mp__keyrow input, .ds-mp__testaddr input, .ds-mp__starts input, .ds-mp__fix input { flex: 1; min-width: 12rem; height: 2.5rem; padding: 0 0.75rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.9rem; }
.ds-mp__testaddr { display: flex; align-items: center; gap: 0.6rem; font-size: 0.85rem; color: #5b6b78; }
.ds-mp__result { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fde8e6; color: #8c1d18; font-size: 0.85rem; }
.ds-mp__result.is-ok { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__two { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
.ds-mp__two.is-one { grid-template-columns: minmax(0, 40rem); }
.ds-mp__toggle { align-self: flex-start; height: 2.3rem; padding: 0 0.9rem; border-radius: 0.6rem; font-weight: 800; font-size: 0.85rem; background: #eef1f4; color: #5b6b78; }
.ds-mp__toggle.is-on { background: #e5f6ee; color: #17895e; }
.ds-mp__starts { display: flex; flex-direction: column; gap: 0.45rem; }
.ds-mp__starts label { display: flex; align-items: center; gap: 0.6rem; font-size: 0.85rem; }
.ds-mp__starts label > span { width: 45%; font-weight: 700; }
.ds-mp__starts small { font-weight: 400; color: #8a99a5; }
.ds-mp__stats { display: flex; flex-wrap: wrap; gap: 0.5rem 1.5rem; font-size: 0.85rem; }
.ds-mp__stats small { color: #8a99a5; }
.ds-mp__fix { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-mp__fix > div { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; padding: 0.5rem 0.6rem; border-radius: 0.6rem; background: #f6f8fa; }
.ds-mp__fix > div > span { flex: 2; min-width: 14rem; display: flex; flex-direction: column; font-size: 0.85rem; }
.ds-mp__fix small { color: #6b7b88; }
.ds-mp__fix input { flex: 1; }

.ds-mp__badges { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-mp__badges > span:not(.ds-mp__badgeactions) { padding: 0.45rem 0.75rem; border-radius: 0.6rem; font-size: 0.82rem; font-weight: 700; background: #eef1f4; }
.ds-mp__badges .is-ok { background: #e5f6ee; color: #0f5c3f; }
.ds-mp__badges .is-ai { background: #f2efff; color: #4b3aa8; }
.ds-mp__badges .is-warn { background: #fff1d6; color: #7a5200; }
.ds-mp__badgeactions { margin-left: auto; display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-mp__truck { flex-direction: row; align-items: stretch; gap: 0; padding: 0.75rem; }
.ds-mp__cab { width: 4rem; border-radius: 1rem 0.3rem 0.3rem 1rem; background: #0e2433; color: #f6be00; font-size: 0.75rem; font-weight: 900; display: flex; align-items: center; justify-content: center; }
.ds-mp__zone { flex: 1; display: flex; flex-direction: column; justify-content: center; gap: 0.15rem; padding: 0.6rem 0.8rem; min-height: 4.5rem; box-shadow: inset -2px 0 0 #fff; }
.ds-mp__zone b { font-size: 0.9rem; }
.ds-mp__zone small { font-size: 0.75rem; opacity: .85; }
.ds-mp__zone.is-front { background: #e7f0fb; color: #1f5f9e; }
.ds-mp__zone.is-middle { background: #f2efff; color: #4b3aa8; }
.ds-mp__zone.is-back { background: #fff1d6; color: #8a5a00; }
.ds-mp__door { width: 3.5rem; display: flex; align-items: center; justify-content: center; font-size: 0.7rem; font-weight: 800; color: #6b7b88; border-left: 4px dashed #0e2433; }
.ds-mp__grid { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(0, 1fr); gap: 1rem; align-items: start; }
.ds-mp__map { height: 30rem; border-radius: 0.8rem; overflow: hidden; background: #e8eef2; z-index: 0; }
.ds-mp__legend { margin: 0; display: flex; flex-wrap: wrap; gap: 0.4rem 1rem; font-size: 0.75rem; color: #5b6b78; }
.ds-mp__legend .is-ok { color: #17895e; } .ds-mp__legend .is-area { color: #9a6400; } .ds-mp__legend .is-prio { color: #b3261e; }
.ds-mp__stops { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 0.4rem; }
.ds-mp__stops li { display: grid; grid-template-columns: 1rem 1.8rem minmax(0, 1fr) auto auto auto auto; gap: 0.5rem; align-items: center; padding: 0.5rem 0.6rem; border-radius: 0.6rem; background: #f6f8fa; }
.ds-mp__stops li.is-over { box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-mp__grab { color: #a8b3bb; cursor: grab; }
.ds-mp__no { width: 1.7rem; height: 1.7rem; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-weight: 900; font-size: 0.78rem; }
.ds-mp__who { font-size: 0.85rem; min-width: 0; }
.ds-mp__tags { display: flex; gap: 0.25rem; flex-wrap: wrap; margin-top: 0.15rem; }
.ds-mp__tags em { font-style: normal; padding: 0 0.45rem; border-radius: 999px; font-size: 0.68rem; font-weight: 800; }
.ds-mp__tags .is-prio { background: #fde8e6; color: #b3261e; }
.ds-mp__tags .is-warn, .ds-mp__tags .is-area { background: #fff1d6; color: #9a6400; }
.ds-mp__n { font-size: 0.8rem; white-space: nowrap; }
.ds-mp__spot { padding: 0.15rem 0.55rem; border-radius: 999px; font-size: 0.7rem; font-weight: 900; }
.ds-mp__spot.is-front { background: #e7f0fb; color: #1f5f9e; } .ds-mp__spot.is-middle { background: #f2efff; color: #4b3aa8; } .ds-mp__spot.is-back { background: #fff1d6; color: #8a5a00; }
.ds-mp__load { font-size: 0.75rem; font-weight: 800; color: #1f6fa5; white-space: nowrap; }
.ds-mp__updown { display: flex; flex-direction: column; }
.ds-mp__updown button { font-size: 0.6rem; line-height: 1; padding: 0.1rem 0.3rem; color: #6b7b88; }
.ds-mp__updown button:disabled { opacity: .25; }
.ds-map__pin { display: flex !important; align-items: center; justify-content: center; border-radius: 50%; color: #fff; font: 900 13px/1 Archivo, sans-serif; border: 3px solid #fff; box-shadow: 0 1px 4px rgb(0 0 0 / .35); background: #17895e; }
.ds-map__pin.is-area { background: #f0a93b; } .ds-map__pin.is-prio { background: #d9534a; }
.ds-map__pin.is-start { border-radius: 0.5rem; background: #0e2433; color: #f6be00; font-size: 11px; }
.dark .ds-mp__step, .dark .ds-mp__provider, .dark .ds-mp__stops li, .dark .ds-mp__fix > div { background: rgb(255 255 255 / 0.05); color: #e6edf3; box-shadow: none; }
.dark .ds-mp__step.is-on { background: rgb(23 137 94 / .2); color: #8ee0bd; }
.dark .ds-mp__provider.is-picked { box-shadow: inset 0 0 0 2px #d4a72c; }
.dark .ds-mp__keyrow input, .dark .ds-mp__testaddr input, .dark .ds-mp__starts input, .dark .ds-mp__fix input { background: rgb(255 255 255 / .06); color: #e6edf3; box-shadow: inset 0 0 0 1px rgb(255 255 255 / .15); }
@media (max-width: 1024px) { .ds-mp__grid, .ds-mp__two, .ds-mp__chain, .ds-mp__providers { grid-template-columns: 1fr; } }

/* Load truck: what to load next, and "too early" */
.ds-ld__next { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.8rem 0.9rem; border-radius: 0.9rem; background: #eef4fb; box-shadow: inset 0 0 0 1px #c8dcf2; color: #0e2433; }
.ds-ld__next small { font-size: 0.72rem; font-weight: 800; letter-spacing: .04em; color: #1f5f9e; }
.ds-ld__next small b { padding: 0 0.4rem; border-radius: 999px; background: #1f5f9e; color: #fff; }
.ds-ld__next small b.is-middle { background: #4b3aa8; } .ds-ld__next small b.is-back { background: #8a5a00; }
.ds-ld__next strong { font-size: 1.15rem; }
.ds-ld__next > span { font-size: 0.85rem; opacity: .85; }
.ds-ld__bar { display: flex; gap: 0.25rem; margin-top: 0.2rem; }
.ds-ld__bar i { flex: 1; height: 0.45rem; border-radius: 999px; background: rgb(14 36 51 / .12); }
.ds-ld__bar i.is-done { background: #34c38f; } .ds-ld__bar i.is-now { background: #3b8fe0; }
.ds-ld__ends { display: flex; justify-content: space-between; font-size: 0.68rem; opacity: .7; }
.ds-ld__next.is-dark { position: absolute; top: calc(env(safe-area-inset-top) + 5.2rem); left: 1rem; right: 1rem; z-index: 3; background: rgb(10 18 25 / .82); box-shadow: inset 0 0 0 1px rgb(140 196 255 / .35); color: #eef3f6; backdrop-filter: blur(8px); }
.ds-ld__next.is-dark small { color: #8cc4ff; }
.ds-ld__next.is-dark .ds-ld__bar i { background: rgb(255 255 255 / .14); }
.ds-ld__next.is-dark .ds-ld__bar i.is-done { background: #34c38f; } .ds-ld__next.is-dark .ds-ld__bar i.is-now { background: #8cc4ff; }
.ds-ld__early { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem 0.8rem; padding: 0.7rem 0.9rem; border-radius: 0.8rem; background: #fff1d6; color: #7a5200; font-size: 0.9rem; }
.ds-ld__kicker { display: block; font-size: 0.72rem; font-weight: 900; letter-spacing: .06em; color: #f3c98a; }
.ds-ld__spot { display: flex; align-items: baseline; gap: 0.6rem; padding: 0.55rem 0.8rem; border-radius: 0.8rem; background: rgb(140 196 255 / .14); color: #8cc4ff; }
.ds-ld__spot strong { font-size: 1.4rem; font-weight: 900; letter-spacing: .02em; }
.ds-ld__spot span { font-size: 0.85rem; color: #c9d5dc; }
.ds-ld__spot.is-middle { background: rgb(176 160 255 / .14); color: #c2b6ff; }
.ds-ld__spot.is-back { background: rgb(240 169 59 / .14); color: #f3c98a; }

/* Driver app: your stops and Navigate */
.ds-nav { display: contents; }
.ds-nav__next { display: flex; align-items: center; gap: 0.7rem; padding: 0.8rem 0.9rem; border-radius: 1rem; background: rgb(246 190 0 / .1); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .35); }
.ds-nav__next > span { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.ds-nav__next small { font-size: 0.75rem; color: #f6d36b; font-weight: 700; }
.ds-nav__next strong { font-size: 1rem; }
.ds-nav__next em { font-style: normal; font-size: 0.8rem; color: #a9b8c2; }
.ds-nav__next button { height: 2.5rem; padding: 0 1rem; border-radius: 0.7rem; background: var(--sa-gold, #f6be00); color: #0a1219; font-weight: 800; }
.ds-nav__row { gap: 0.7rem; }
.ds-nav__no { width: 2rem; height: 2rem; flex: none; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: 900; font-size: 0.85rem; background: rgb(255 255 255 / .1); }
.ds-nav__no.is-next { background: #f6be00; color: #0a1219; }
.ds-nav__no.is-prio { box-shadow: 0 0 0 2px #d9534a; }
.ds-nav__who { flex: 1; padding: 0; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; text-align: left; }
.ds-nav__go { height: 2.1rem; padding: 0 0.75rem; border-radius: 0.6rem; background: rgb(140 196 255 / .14); color: #8cc4ff; font-size: 0.8rem; font-weight: 800; }
.ds-nav__hint { margin: 0; font-size: 0.78rem; color: #7f93a1; text-align: center; }
.ds-nav__hint button { color: #8cc4ff; font-weight: 700; }
.ds-nav__veil { position: fixed; inset: 0; z-index: 60; background: rgb(0 0 0 / .55); display: flex; align-items: flex-end; }
.ds-nav__sheet { width: 100%; max-width: 32rem; margin: 0 auto; padding: 1rem 1.1rem 1.6rem; border-radius: 1.6rem 1.6rem 0 0; background: #101c25; color: #eef3f6; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-nav__sheet > small { font-size: 0.75rem; color: #7f93a1; }
.ds-nav__sheet > strong { font-size: 1.3rem; }
.ds-nav__addr { font-size: 0.9rem; color: #c9d5dc; line-height: 1.45; }
.ds-nav__chips { display: flex; gap: 0.4rem; flex-wrap: wrap; }
.ds-nav__chips em { font-style: normal; padding: 0.2rem 0.6rem; border-radius: 999px; background: rgb(255 255 255 / .08); font-size: 0.78rem; }
.ds-nav__ask { margin-top: 0.3rem; font-size: 0.85rem; }
.ds-nav__app { display: flex; align-items: center; gap: 0.75rem; height: 3.6rem; padding: 0 0.9rem; border-radius: 0.9rem; background: rgb(255 255 255 / .07); color: #fff; text-align: left; font-size: 1.2rem; }
.ds-nav__app > span { flex: 1; display: flex; flex-direction: column; font-size: 1rem; }
.ds-nav__app small { font-size: 0.75rem; color: #a9b8c2; }
.ds-nav__app i { width: 2.4rem; height: 2.4rem; flex: none; border-radius: 0.7rem; display: flex; align-items: center; justify-content: center; font-style: normal; font-weight: 900; font-size: 1.1rem; }
.ds-nav__app .is-waze { background: #33ccff; color: #0a1219; } .ds-nav__app .is-google { background: #fff; color: #1a73e8; } .ds-nav__app .is-apple { background: #e9eef2; color: #0e2433; }
.ds-nav__remember { display: flex; align-items: center; gap: 0.5rem; font-size: 0.82rem; color: #a9b8c2; }
.ds-nav__two { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.ds-nav__soft { height: 2.8rem; border-radius: 0.8rem; background: rgb(140 196 255 / .12); color: #8cc4ff; font-weight: 800; font-size: 0.88rem; display: flex; align-items: center; justify-content: center; }
.ds-nav__soft.is-warn { background: rgb(240 169 59 / .14); color: #f3c98a; }
.ds-nav__back { display: flex; flex-direction: column; gap: 0.5rem; padding: 1rem; border-radius: 1.2rem; background: rgb(52 195 143 / .1); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .4); }
.ds-nav__back small { font-size: 0.78rem; font-weight: 800; color: #6fe0b5; }
.ds-nav__back strong { font-size: 1.2rem; }
.ds-nav__back > span { font-size: 0.85rem; color: #c9d5dc; }
.ds-nav__link { font-size: 0.8rem; color: #7f93a1; }

/* ============================================================ Truck tracking */
.ds-tm { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-tm__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-tm__tabs { display: inline-flex; gap: 0.25rem; padding: 0.25rem; border-radius: 0.75rem; background: #e6ebef; }
.ds-tm__tabs button { height: 2rem; padding: 0 0.9rem; border-radius: 0.55rem; font-size: 0.82rem; font-weight: 800; color: #5b6b78; }
.ds-tm__tabs button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 2px rgb(0 0 0 / .12); }
.ds-mp__badges .is-bad { background: #fde8e6; color: #8c1d18; }
.ds-tm__grid { display: grid; grid-template-columns: minmax(0, 1fr) 22rem; gap: 0.9rem; align-items: start; }
.ds-tm__map { height: 36rem; border-radius: 0.8rem; overflow: hidden; background: #e8eef2; z-index: 0; }
.ds-tm__map.is-small { height: 30rem; }
.ds-tm__side { display: flex; flex-direction: column; gap: 0.75rem; min-width: 0; }
.ds-tm__list { padding: 0.5rem; gap: 0.3rem; max-height: 22rem; overflow: auto; }
.ds-tm__row { display: flex; flex-direction: column; align-items: flex-start; gap: 0.15rem; width: 100%; padding: 0.55rem 0.65rem; border-radius: 0.6rem; background: #f6f8fa; text-align: left; }
.ds-tm__row.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-tm__row > span { display: flex; justify-content: space-between; gap: 0.5rem; width: 100%; font-size: 0.85rem; }
.ds-tm__row small { font-size: 0.75rem; color: #5b6b78; }
.ds-tm em.is-ok, .ds-tm em.is-warn, .ds-tm em.is-bad { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; white-space: nowrap; }
.ds-tm em.is-ok { background: #e5f6ee; color: #17895e; } .ds-tm em.is-warn { background: #fff1d6; color: #9a6400; } .ds-tm em.is-bad { background: #fde8e6; color: #b3261e; }
.ds-tm__cardhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 0.95rem; }
.ds-tm__crew { font-size: 0.82rem; color: #33424e; }
.ds-tm__facts { display: grid; grid-template-columns: 1fr 1fr; gap: 0.4rem; }
.ds-tm__facts span { display: flex; flex-direction: column; padding: 0.5rem 0.6rem; border-radius: 0.55rem; background: #f6f8fa; font-size: 0.72rem; color: #6b7b88; }
.ds-tm__facts b { font-size: 0.82rem; color: #0e2433; }
.ds-tm__btns { display: flex; gap: 0.4rem; flex-wrap: wrap; }
.ds-tm__replay { display: flex; align-items: center; gap: 0.7rem; padding: 0.2rem 0.3rem; }
.ds-tm__replay button { width: 2.1rem; height: 2.1rem; border-radius: 50%; background: #0e2433; color: #fff; flex: none; }
.ds-tm__replay input { flex: 1; accent-color: #1f6fa5; }
.ds-tm__replay small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__who { display: flex; align-items: center; gap: 0.8rem; }
.ds-tm__who b { font-size: 1.15rem; }
.ds-tm__who small { color: #5b6b78; font-size: 0.82rem; }
.ds-tm__who small b { font-size: 0.82rem; color: #0e2433; }
.ds-tm__icon { width: 3rem; height: 3rem; border-radius: 0.9rem; background: #0e2433; display: grid; place-items: center; font-size: 1.4rem; flex: none; }
.ds-tm__stats { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 0.5rem; }
.ds-tm__stats.is-four { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.ds-tm__stats > span { padding: 0.65rem 0.8rem; gap: 0.1rem; }
.ds-tm__stats small { font-size: 0.72rem; color: #6b7b88; }
.ds-tm__stats b { font-size: 1.2rem; }
.ds-tm__stats b.is-ok { color: #17895e; }
.ds-tm__stats em { font-style: normal; font-size: 0.7rem; color: #8a99a5; }
.ds-tm__now { margin: 0; font-size: 0.85rem; line-height: 1.6; }
.ds-tm__events { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; }
.ds-tm__events li { display: grid; grid-template-columns: 2.6rem 0.8rem 1fr; gap: 0.5rem; align-items: start; min-height: 2rem; font-size: 0.8rem; line-height: 1.35; }
.ds-tm__events small { color: #6b7b88; font-size: 0.75rem; }
.ds-tm__events i { width: 0.7rem; height: 0.7rem; margin-top: 0.2rem; border-radius: 50%; background: #c9d1d8; box-shadow: 0 0 0 3px #fff; }
.ds-tm__events .is-start i { background: #0e2433; } .ds-tm__events .is-ok i { background: #17895e; } .ds-tm__events .is-warn i { background: #f0a93b; }
.ds-tm__events .is-bad i { background: #d9534a; } .ds-tm__events .is-now i { background: #1f6fa5; }
.ds-tm__table { display: flex; flex-direction: column; gap: 0.35rem; }
.ds-tm__table > div { display: grid; grid-template-columns: 6rem 6rem 9rem 4rem 5rem 5.5rem minmax(0, 1fr) 5.5rem; gap: 0.5rem; align-items: center; padding: 0.55rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; font-size: 0.82rem; }
.ds-tm__table > div.is-head { background: none; font-size: 0.72rem; font-weight: 800; color: #6b7b88; padding-top: 0; padding-bottom: 0; }
.ds-tm__table > div.is-sel { box-shadow: inset 0 0 0 2px #1f6fa5; }
.ds-tm__table .is-ok { color: #17895e; font-weight: 800; } .ds-tm__table .is-warn { color: #9a6400; font-weight: 800; }
.ds-tm__table small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__table button { color: #1f6fa5; font-weight: 800; font-size: 0.8rem; }
.ds-tm__alerts { display: flex; flex-direction: column; gap: 0.45rem; }
.ds-tm__alerts > div { display: flex; align-items: center; gap: 0.7rem; flex-wrap: wrap; padding: 0.65rem 0.75rem; border-radius: 0.7rem; background: #f6f8fa; }
.ds-tm__aicon { font-size: 1.1rem; }
.ds-tm__atext { flex: 1; min-width: 14rem; display: flex; flex-direction: column; gap: 0.1rem; font-size: 0.85rem; }
.ds-tm__atext small { color: #5b6b78; font-size: 0.75rem; }
.ds-tm__when { color: #6b7b88; font-size: 0.75rem; white-space: nowrap; }
.ds-tm__alerts input { height: 2.1rem; min-width: 12rem; padding: 0 0.6rem; border-radius: 0.5rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.8rem; }
.ds-tm__srcs { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.4rem; }
.ds-tm__srcs label, .ds-tm__form label { display: flex; justify-content: space-between; align-items: center; gap: 0.6rem; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; font-size: 0.85rem; }
.ds-tm__srcs small { color: #8a99a5; }
.ds-tm__srcs select, .ds-tm__form select, .ds-tm__form input { height: 2.1rem; padding: 0 0.5rem; border-radius: 0.5rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.82rem; }
.ds-tm__form .is-ok, .ds-tm__srcs .is-ok { color: #17895e; }
.ds-tm__link { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.75rem; border-radius: 0.7rem; background: #f3f5f7; font-size: 0.82rem; }
.ds-tm__link code { font-size: 0.75rem; word-break: break-all; }
.ds-tm__pin { display: flex !important; align-items: center; justify-content: center; border-radius: 999px; color: #fff; font: 900 12px/1 Archivo, sans-serif; border: 2px solid #fff; box-shadow: 0 1px 4px rgb(0 0 0 / .35); background: #0e2433; white-space: nowrap; }
.ds-tm__pin.is-done { background: #17895e; } .ds-tm__pin.is-mark { background: #f0a93b; }
.ds-tm__pin.is-start { border-radius: 0.5rem; color: #f6be00; font-size: 11px; }
.ds-tm__pin.is-truck { padding: 0 0.5rem; font-size: 12px; }
.ds-tm__pin.is-truck.is-warn { background: #9a6400; } .ds-tm__pin.is-truck.is-bad { background: #b3261e; }
.ds-tm__pin.is-truck.is-sel { box-shadow: 0 0 0 3px #f6be00, 0 2px 6px rgb(0 0 0 / .3); z-index: 1000 !important; }
.ds-tm__pin.is-ghost { background: #1f6fa5; font-size: 16px; }
.dark .ds-tm__row, .dark .ds-tm__facts span, .dark .ds-tm__table > div:not(.is-head), .dark .ds-tm__alerts > div, .dark .ds-tm__srcs label, .dark .ds-tm__form label, .dark .ds-tm__link { background: rgb(255 255 255 / .05); color: #e6edf3; }
.dark .ds-tm__facts b { color: #e6edf3; }
@media (max-width: 1100px) { .ds-tm__grid { grid-template-columns: 1fr; } .ds-tm__stats { grid-template-columns: repeat(3, 1fr); } .ds-tm__table > div { grid-template-columns: repeat(4, 1fr); } }

/* Driver app: tracking */
.ds-trk__ask { display: flex; flex-direction: column; gap: 0.7rem; margin: 0 0 1rem; padding: 1.2rem; border-radius: 1.5rem; background: rgb(140 196 255 / .07); box-shadow: inset 0 0 0 1px rgb(140 196 255 / .25); }
.ds-trk__pin { width: 3.2rem; height: 3.2rem; border-radius: 1rem; background: rgb(140 196 255 / .14); display: grid; place-items: center; font-size: 1.5rem; }
.ds-trk__ask strong { font-size: 1.35rem; letter-spacing: -0.02em; }
.ds-trk__ask p { margin: 0; font-size: 0.9rem; color: #c9d5dc; line-height: 1.5; }
.ds-trk__ask ul { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 0.4rem; }
.ds-trk__ask li { display: flex; gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 0.8rem; background: rgb(255 255 255 / .05); font-size: 0.85rem; }
.ds-trk__ask li b { color: #6fe0b5; } .ds-trk__ask li i { color: #8cc4ff; font-style: normal; font-weight: 900; }
.ds-trk__ask small { font-size: 0.75rem; color: #7f93a1; text-align: center; }
.ds-trk__bar { display: flex; align-items: center; gap: 0.6rem; width: 100%; margin: 0 0 0.8rem; padding: 0.55rem 0.8rem; border-radius: 0.9rem; background: rgb(52 195 143 / .1); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .35); text-align: left; color: inherit; }
.ds-trk__bar i { width: 0.6rem; height: 0.6rem; flex: none; border-radius: 50%; background: #34c38f; box-shadow: 0 0 0 4px rgb(52 195 143 / .2); }
.ds-trk__bar > span { display: flex; flex-direction: column; }
.ds-trk__bar b { font-size: 0.82rem; } .ds-trk__bar small { font-size: 0.72rem; color: #a9b8c2; }
.ds-trk__bar.is-off { background: rgb(240 169 59 / .1); box-shadow: inset 0 0 0 1px rgb(240 169 59 / .4); }
.ds-trk__bar.is-off i { background: #f0a93b; box-shadow: 0 0 0 4px rgb(240 169 59 / .2); }

/* ============================================================ SMS + AI helpers */
.ds-sms__providers { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.ds-sms__fields { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: 0.6rem; }
.ds-sms__fields label { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.8rem; font-weight: 700; }
.ds-sms__fields small { font-weight: 400; }
.ds-sms__fields small.is-ok { color: #17895e; font-weight: 700; }
.ds-sms__fields input, .ds-sms__fields select, .ds-sms__test input, .ds-sms__text { height: 2.5rem; padding: 0 0.75rem; border-radius: 0.6rem; border: 0; box-shadow: inset 0 0 0 1px #dfe5ea; background: #fff; font-size: 0.88rem; font-weight: 400; }
.ds-sms__test { display: inline-flex; gap: 0.4rem; margin-left: auto; }
.ds-sms__grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.15fr); gap: 1rem; align-items: start; }
.ds-sms__kind { display: flex; align-items: center; gap: 0.7rem; padding: 0.65rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; }
.ds-sms__kind.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-sms__kind > small { color: #6b7b88; font-size: 0.75rem; white-space: nowrap; }
.ds-sms__kindtext { flex: 1; display: flex; flex-direction: column; text-align: left; font-size: 0.88rem; }
.ds-sms__kindtext small { color: #5b6b78; font-size: 0.75rem; }
.ds-sms__switch { width: 2.5rem; height: 1.5rem; flex: none; padding: 0.15rem; border-radius: 999px; background: #c9d1d8; display: flex; justify-content: flex-start; }
.ds-sms__switch.is-on { background: #17895e; justify-content: flex-end; }
.ds-sms__switch i { width: 1.2rem; height: 1.2rem; border-radius: 50%; background: #fff; box-shadow: 0 1px 2px rgb(0 0 0 / .2); }
.ds-sms__text { height: auto; padding: 0.7rem 0.8rem; line-height: 1.5; font-family: ui-monospace, Menlo, monospace; resize: vertical; width: 100%; }
.ds-sms__blanks { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-sms__blanks em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; background: #f2efff; color: #4b3aa8; font-size: 0.7rem; font-weight: 800; }
.ds-sms__ai { display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: center; }
.ds-sms__ai button { height: 2.1rem; padding: 0 0.75rem; border-radius: 0.55rem; background: #f2efff; color: #4b3aa8; font-weight: 800; font-size: 0.8rem; }
.ds-sms__ai small { color: #6b7b88; font-size: 0.75rem; }
.ds-sms__ainote { display: flex; align-items: center; gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 0.65rem; background: #f2efff; color: #4b3aa8; font-size: 0.82rem; font-weight: 700; }
.ds-sms__ainote button { margin-left: auto; padding: 0.25rem 0.6rem; border-radius: 0.45rem; background: #fff; font-weight: 800; }
.ds-sms__checks { display: flex; flex-direction: column; gap: 0.3rem; }
.ds-sms__checks span { padding: 0.4rem 0.6rem; border-radius: 0.5rem; font-size: 0.8rem; }
.ds-sms__checks .is-ok { background: #e5f6ee; color: #0f5c3f; } .ds-sms__checks .is-warn { background: #fff1d6; color: #7a5200; }
.ds-sms__label { font-size: 0.82rem; margin-top: 0.3rem; }
.ds-sms__phone { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.8rem; border-radius: 1rem; background: #eef1f4; }
.ds-sms__phone small { text-align: center; font-size: 0.7rem; color: #6b7b88; }
.ds-sms__phone span { align-self: flex-start; max-width: 92%; padding: 0.6rem 0.75rem; border-radius: 1rem 1rem 1rem 0.3rem; background: #fff; font-size: 0.88rem; line-height: 1.45; color: #0e2433; }
.ds-sms__other { display: grid; grid-template-columns: 5rem 1fr; gap: 0.6rem; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; text-align: left; font-size: 0.8rem; }
.ds-sms__other span { color: #33424e; }
.ds-tm__stats.is-five { grid-template-columns: repeat(5, minmax(0, 1fr)); }
.ds-tm__stats b em { font-style: normal; font-size: 0.75rem; color: #6b7b88; font-weight: 400; }
.ds-tm__stats b.is-bad { color: #b3261e; }
.ds-tm__ainote { display: flex; flex-direction: column; gap: 0.1rem; margin-top: 0.3rem; padding: 0.5rem 0.65rem; border-radius: 0.55rem; background: #f2efff; color: #2c2470; font-size: 0.8rem; line-height: 1.45; }
.ds-tm__ainote small { color: #4b3aa8; font-weight: 800; font-size: 0.7rem; }
.ds-tm__aiacts { display: flex; flex-wrap: wrap; gap: 0.3rem; margin-top: 0.25rem; }
.ds-tm__aiacts i { font-style: normal; padding: 0.15rem 0.5rem; border-radius: 0.4rem; background: #eef1f4; font-size: 0.72rem; font-weight: 700; }
.ds-tm__daytext { background: #f2efff; }
.ds-tm__daytext small { color: #4b3aa8; font-weight: 800; font-size: 0.75rem; }
.ds-tm__daytext p { margin: 0; font-size: 0.98rem; line-height: 1.55; color: #2c2470; }
.ds-tm__daygrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 0.6rem; }
.ds-tm__daycard { display: flex; flex-direction: column; align-items: flex-start; gap: 0.25rem; padding: 0.8rem; border-radius: 0.9rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; text-align: left; }
.ds-tm__daycard.is-sel { background: #fff8e6; box-shadow: inset 0 0 0 2px #d4a72c; }
.ds-tm__daycard > span:first-child { display: flex; justify-content: space-between; width: 100%; }
.ds-tm__daycard small { color: #5b6b78; font-size: 0.78rem; }
.ds-tm__daycard em { font-style: normal; padding: 0.1rem 0.5rem; border-radius: 999px; font-size: 0.7rem; font-weight: 800; }
.ds-tm__daycard em.is-ok { background: #e5f6ee; color: #17895e; } .ds-tm__daycard em.is-mid { background: #eef4fb; color: #1f5f9e; } .ds-tm__daycard em.is-warn { background: #fff1d6; color: #9a6400; }
.ds-tm__daynums { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.25rem; width: 100%; margin-top: 0.2rem; }
.ds-tm__daynums i { font-style: normal; display: flex; flex-direction: column; padding: 0.35rem; border-radius: 0.45rem; background: #f6f8fa; font-size: 0.65rem; color: #6b7b88; }
.ds-tm__daynums b { font-size: 0.85rem; color: #0e2433; }
.ds-tm__aibox { margin: 0; display: flex; flex-direction: column; gap: 0.15rem; padding: 0.7rem 0.85rem; border-radius: 0.7rem; background: #f2efff; color: #2c2470; line-height: 1.55; }
.ds-tm__aibox small { color: #4b3aa8; font-weight: 800; font-size: 0.7rem; }
.ds-tm__goodbad { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-tm__goodbad span { display: flex; flex-direction: column; padding: 0.6rem 0.75rem; border-radius: 0.6rem; font-size: 0.82rem; line-height: 1.45; }
.ds-tm__goodbad .is-ok { background: #e5f6ee; color: #0f5c3f; } .ds-tm__goodbad .is-warn { background: #fff1d6; color: #7a5200; }
.dark .ds-sms__kind, .dark .ds-sms__other, .dark .ds-tm__daycard, .dark .ds-tm__daynums i { background: rgb(255 255 255 / .05); color: #e6edf3; box-shadow: none; }
.dark .ds-sms__fields input, .dark .ds-sms__fields select, .dark .ds-sms__test input, .dark .ds-sms__text { background: rgb(255 255 255 / .06); color: #e6edf3; }
@media (max-width: 1100px) { .ds-sms__grid, .ds-sms__providers { grid-template-columns: 1fr; } .ds-tm__stats.is-five { grid-template-columns: repeat(2, 1fr); } }

/* ============================== Help guide ============================== */
.ds-help { --h-ink: var(--ds-navy); --h-muted: #5b6b77; --h-card: #fff; --h-line: rgb(14 36 51 / 0.1); --h-soft: #f3f6f8; --h-accent: var(--ds-signal);
    display: flex; flex-direction: column; gap: 1rem; color: var(--h-ink); max-width: 60rem; }
.dark .ds-help { --h-ink: #e6edf3; --h-muted: #93a5b3; --h-card: #10283a; --h-line: rgb(255 255 255 / 0.09); --h-soft: rgb(255 255 255 / 0.04); }
.ds-help button { cursor: pointer; }
.ds-help__hero { display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.ds-help__hero h1 { font-size: 1.75rem; font-weight: 800; letter-spacing: -0.02em; line-height: 1.15; margin: 0; }
.ds-help__hero p { margin: 0.3rem 0 0; color: var(--h-muted); }
.ds-help__lang { display: inline-flex; padding: 0.2rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); flex: none; }
.ds-help__lang button { padding: 0.3rem 0.8rem; border-radius: 999px; font-size: 0.8rem; font-weight: 700; color: var(--h-muted); }
.ds-help__lang button.is-on { background: var(--ds-navy); color: #fff; }
.dark .ds-help__lang button.is-on { background: var(--ds-signal); color: #0e2433; }
.ds-help__search { display: flex; align-items: center; gap: 0.5rem; padding: 0.4rem 0.4rem 0.4rem 0.9rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line), 0 6px 20px -12px rgb(14 36 51 / 0.35); }
.ds-help__search:focus-within { box-shadow: 0 0 0 2px var(--ds-signal), 0 6px 20px -12px rgb(14 36 51 / 0.35); }
.ds-help__search-icon { color: var(--h-muted); display: flex; }
.ds-help__search input { flex: 1; min-width: 0; border: 0; background: transparent; font-size: 1rem; padding: 0.55rem 0; color: inherit; outline: none; box-shadow: none; }
.ds-help__search input::-webkit-search-cancel-button { display: none; }
.ds-help__clear { width: 2rem; height: 2rem; border-radius: 50%; color: var(--h-muted); font-size: 1.2rem; }
.ds-help__ask { padding: 0.6rem 1.1rem; border-radius: 0.75rem; font-weight: 800; background: var(--ds-navy); color: #fff; white-space: nowrap; }
.dark .ds-help__ask { background: var(--ds-signal); color: #0e2433; }
.ds-help__tries { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4rem; margin: -0.25rem 0 0; font-size: 0.85rem; color: var(--h-muted); }
.ds-help__tries button { padding: 0.3rem 0.7rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); color: var(--h-ink); }
.ds-help__tries button:hover { box-shadow: inset 0 0 0 1px var(--ds-signal); }
.ds-help__ai { display: flex; gap: 0.85rem; align-items: flex-start; padding: 1rem 1.1rem; border-radius: 1rem; background: linear-gradient(120deg, rgb(246 190 0 / 0.16), rgb(246 190 0 / 0.04)); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.45); }
.ds-help__ai.is-off { background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); }
.ds-help__ai-icon { font-size: 1.4rem; line-height: 1; }
.ds-help__ai strong { display: block; font-weight: 800; }
.ds-help__ai p { margin: 0.2rem 0 0; color: var(--h-muted); font-size: 0.9rem; }
.ds-help__answer { padding: 1rem 1.1rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); }
.ds-help__answer.is-ai { box-shadow: inset 4px 0 0 var(--ds-signal), 0 0 0 1px var(--h-line); }
.ds-help__answer small { font-size: 0.75rem; font-weight: 800; color: var(--h-muted); }
.ds-help__answer p { margin: 0.35rem 0 0.6rem; font-size: 1.02rem; line-height: 1.5; }
.ds-help__answer-open { font-weight: 800; color: var(--ds-navy); text-decoration: underline; text-underline-offset: 3px; text-align: left; }
.dark .ds-help__answer-open { color: var(--ds-signal); }
.ds-help__results, .ds-help__related { display: flex; flex-direction: column; gap: 0.4rem; }
.ds-help h3 { font-size: 0.85rem; font-weight: 800; color: var(--h-muted); margin: 0.25rem 0; }
.ds-help__muted { color: var(--h-muted); font-size: 0.9rem; margin: 0; }
.ds-help__row { display: flex; align-items: center; gap: 0.8rem; width: 100%; padding: 0.75rem 0.9rem; border-radius: 0.9rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); text-align: left; color: inherit; }
.ds-help__row:hover { box-shadow: 0 0 0 1px var(--ds-signal); }
.ds-help__row-icon { width: 2.25rem; height: 2.25rem; display: grid; place-items: center; border-radius: 0.7rem; background: var(--h-soft); flex: none; font-size: 1.1rem; }
.ds-help__row-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-help__row-text strong { font-weight: 750; }
.ds-help__row-text small { color: var(--h-muted); font-size: 0.82rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-help__row-n { font-size: 0.75rem; color: var(--h-muted); white-space: nowrap; }
.ds-help__chev { color: var(--h-muted); font-size: 1.2rem; }
.ds-help__topics { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.75rem; }
.ds-help__topic { padding: 1rem; border-radius: 1rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); }
.ds-help__topic h3 { display: flex; align-items: center; gap: 0.45rem; color: var(--h-ink); font-size: 0.95rem; margin: 0 0 0.5rem; }
.ds-help__topic h3 small { margin-left: auto; font-size: 0.75rem; color: var(--h-muted); font-weight: 700; }
.ds-help__topic ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; }
.ds-help__topic li button { width: 100%; text-align: left; padding: 0.35rem 0; font-size: 0.9rem; color: inherit; border-top: 1px solid var(--h-line); }
.ds-help__topic li:first-child button { border-top: 0; }
.ds-help__topic li button:hover { color: #b48800; }
.dark .ds-help__topic li button:hover { color: var(--ds-signal); }
.ds-help__bar { display: flex; align-items: center; gap: 0.6rem; }
.ds-help__bar > .ds-help__lang { margin-left: auto; }
.ds-help__bar-title { font-size: 1.15rem; font-weight: 800; }
.ds-help__back { font-weight: 800; color: var(--h-ink); padding: 0.35rem 0.2rem; }
.ds-help__x { width: 2.2rem; height: 2.2rem; border-radius: 50%; background: var(--h-soft); font-size: 1.3rem; line-height: 1; color: var(--h-ink); }
.ds-help__guide { display: flex; flex-direction: column; gap: 1rem; }
.ds-help__ghead { display: flex; align-items: flex-start; gap: 0.9rem; flex-wrap: wrap; }
.ds-help__ghead > div { flex: 1; min-width: 14rem; }
.ds-help__gicon { width: 3rem; height: 3rem; display: grid; place-items: center; border-radius: 0.9rem; font-size: 1.5rem; background: rgb(246 190 0 / 0.18); flex: none; }
.ds-help__ghead h2 { font-size: 1.45rem; font-weight: 800; letter-spacing: -0.015em; line-height: 1.2; margin: 0; }
.ds-help__ghead p { margin: 0.3rem 0 0; color: var(--h-muted); line-height: 1.5; }
.ds-help__doit { padding: 0.6rem 1rem; border-radius: 0.75rem; background: var(--ds-signal); color: #0e2433; font-weight: 800; white-space: nowrap; }
.ds-help__when, .ds-help__result { margin: 0; padding: 0.75rem 0.9rem; border-radius: 0.8rem; background: var(--h-soft); line-height: 1.5; }
.ds-help__when strong, .ds-help__result strong { display: block; font-size: 0.8rem; color: var(--h-muted); }
.ds-help__result { background: rgb(23 137 94 / 0.1); }
.ds-help__result strong { color: var(--ds-ok); }
.ds-help__steps { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 0; }
.ds-help__steps li { display: flex; gap: 0.9rem; padding-bottom: 1.1rem; position: relative; }
.ds-help__steps li:not(:last-child)::before { content: ''; position: absolute; left: 0.95rem; top: 2.1rem; bottom: 0.2rem; width: 2px; background: var(--h-line); }
.ds-help__n { width: 1.9rem; height: 1.9rem; flex: none; display: grid; place-items: center; border-radius: 50%; background: var(--ds-navy); color: #fff; font-weight: 800; font-size: 0.9rem; }
.dark .ds-help__n { background: var(--ds-signal); color: #0e2433; }
.ds-help__steps strong { display: block; font-weight: 800; margin-top: 0.2rem; }
.ds-help__steps p { margin: 0.2rem 0 0; line-height: 1.55; max-width: 40rem; }
.ds-help__shot { display: block; width: fit-content; margin-top: 0.6rem; max-width: min(100%, 26rem); border-radius: 0.8rem; overflow: hidden; box-shadow: 0 0 0 1px var(--h-line), 0 8px 24px -14px rgb(0 0 0 / 0.5); }
.ds-help__shot img { display: block; max-width: 100%; max-height: 30rem; width: auto; height: auto; }
.ds-help__problems details { border-radius: 0.8rem; background: var(--h-card); box-shadow: 0 0 0 1px var(--h-line); margin-bottom: 0.4rem; }
.ds-help__problems summary { padding: 0.7rem 0.9rem; font-weight: 700; cursor: pointer; }
.ds-help__problems details p { margin: 0; padding: 0 0.9rem 0.8rem; line-height: 1.5; color: var(--h-muted); }
.ds-help__vote { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; padding-top: 0.75rem; border-top: 1px solid var(--h-line); font-size: 0.9rem; color: var(--h-muted); }
.ds-help__vote button { padding: 0.35rem 0.8rem; border-radius: 999px; background: var(--h-soft); box-shadow: inset 0 0 0 1px var(--h-line); color: var(--h-ink); font-weight: 700; }
.ds-help__center-link { margin-top: auto; padding-top: 0.75rem; font-weight: 800; font-size: 0.9rem; color: var(--h-muted); }
/* "?" in the top bar */
.ds-help-q { width: 2.1rem; height: 2.1rem; border-radius: 50%; display: grid; place-items: center; font-weight: 900; font-size: 1rem; color: var(--ds-navy); background: rgb(246 190 0 / 0.25); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.7); margin-right: 0.35rem; }
.ds-help-q:hover { background: var(--ds-signal); }
.dark .ds-help-q { color: var(--ds-signal); background: rgb(246 190 0 / 0.12); }
/* the panel that "?" opens */
.ds-help-drawer { position: fixed; inset: 0; z-index: 60; display: flex; justify-content: flex-end; }
.ds-help-drawer__shade { position: absolute; inset: 0; background: rgb(6 16 24 / 0.45); border: 0; }
.ds-help-drawer__panel { position: relative; width: min(30rem, 100%); max-width: none; height: 100%; overflow-y: auto; box-sizing: border-box; padding: 1.1rem 1.2rem 1.5rem; background: #f7f9fa; box-shadow: -20px 0 50px -20px rgb(0 0 0 / 0.45); animation: help-in .22s ease-out; }
.dark .ds-help-drawer__panel { background: #0b1c28; }
@keyframes help-in { from { transform: translateX(24px); opacity: 0; } to { transform: none; opacity: 1; } }
.ds-help-drawer__panel .ds-help__topics { grid-template-columns: 1fr; }
.ds-help-drawer__panel .ds-help__shot { max-width: 100%; }
/* Scan app and Driver app: the whole phone screen, dark like the apps */
.ds-help-drawer.is-phone .ds-help-drawer__panel { width: 100%; max-width: 34rem; margin: 0 auto; box-shadow: none; animation: sa-up .25s ease-out;
    padding: calc(env(safe-area-inset-top) + 1rem) 1.2rem calc(env(safe-area-inset-bottom) + 1.5rem);
    --h-ink: #eef3f6; --h-muted: #8fa3b1; --h-card: rgb(255 255 255 / 0.05); --h-line: rgb(255 255 255 / 0.08); --h-soft: rgb(255 255 255 / 0.05); }
.ds-help-drawer.is-phone { background: radial-gradient(120% 70% at 0% 0%, #15293a 0%, #0a1219 55%); justify-content: center; }
.ds-help-drawer.is-phone .ds-help-drawer__panel { background: transparent; }
.ds-help-drawer.is-phone .ds-help__lang button.is-on, .ds-help-drawer.is-phone .ds-help__ask, .ds-help-drawer.is-phone .ds-help__n { background: var(--ds-signal); color: #0a1219; }
.ds-help-drawer.is-phone .ds-help__answer-open { color: var(--ds-signal); }
.ds-help-drawer.is-phone .ds-help__search { box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.12); }
.ds-help-drawer.is-phone .ds-help__row, .ds-help-drawer.is-phone .ds-help__topic li button { min-height: 2.75rem; }
.ds-help-drawer.is-phone .ds-help__topic li button:hover { color: var(--ds-signal); }
.ds-help-drawer.is-phone .ds-help__row-text small { white-space: normal; }
.ds-sa__help { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; flex: none; font-weight: 900; font-size: 1.05rem; color: var(--sa-gold); background: rgb(246 190 0 / 0.12); box-shadow: inset 0 0 0 1px rgb(246 190 0 / 0.35); }
.ds-sa__hello .ds-sa__help { margin-left: auto; margin-right: -0.4rem; }
.ds-sa__title--help { flex-direction: row; align-items: center; justify-content: space-between; }
.ds-sa__title--help > span { display: flex; flex-direction: column; gap: 0.25rem; }
@media (max-width: 40rem) { .ds-help__row-n { display: none; } .ds-help__hero h1 { font-size: 1.45rem; } }
@media (prefers-reduced-motion: reduce) { .ds-help-drawer__panel { animation: none !important; } }

/* ------------------------------------------------------------------ Fuel (office) */
.ds-fu { display: flex; flex-direction: column; gap: 1rem; }
.ds-fu__top { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 0.75rem; }
.ds-fu__month, .ds-fu__form select, .ds-fu__form input[type=text], .ds-fu__tr select, .ds-fu__tr input { height: 2.25rem; padding: 0 0.7rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; }
.dark .ds-fu__month, .dark .ds-fu__form select, .dark .ds-fu__form input[type=text], .dark .ds-fu__tr select, .dark .ds-fu__tr input { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-fu .ds-tm__stats em { display: block; }
.ds-fu .is-bad { color: #c8372d; }
.ds-fu .is-ok { color: #17895e; }
.dark .ds-fu .is-bad { color: #ff8a7e; }
.dark .ds-fu .is-ok { color: #4fd3a0; }
.ds-fu__alertbar { text-align: left; padding: 0.7rem 1rem; border-radius: 0.75rem; background: #fff4e0; color: #7a4a00; font-weight: 700; font-size: 0.88rem; }
.dark .ds-fu__alertbar { background: rgb(240 169 59 / .14); color: #f6c46b; }
.ds-fu__table { padding: 0.25rem 0; overflow-x: auto; }
.ds-fu__tr { display: grid; gap: 0.75rem; align-items: center; width: 100%; padding: 0.65rem 1rem; text-align: left; font-size: 0.88rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 40rem; }
.dark .ds-fu__tr { border-color: rgb(255 255 255 / .07); }
.ds-fu__tr.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
button.ds-fu__tr:hover { background: rgb(0 0 0 / .025); }
.dark button.ds-fu__tr:hover { background: rgb(255 255 255 / .03); }
.ds-fu__tr small { display: block; font-size: 0.74rem; color: #6b7b88; }
.ds-fu__tr.is-trucks { grid-template-columns: 2fr 1fr 1fr 1.2fr 1fr 1.6fr; }
.ds-fu__tr.is-weeks { grid-template-columns: 1fr 1fr 1fr; min-width: 0; }
.ds-fu__tr.is-vat { grid-template-columns: 0.7fr 2fr 1fr 1fr 1fr 1fr 1fr; }
.ds-fu__tr.is-set { grid-template-columns: 2fr 1fr 1fr 1fr; }
.ds-fu__chg { margin-left: 0.35rem; font-style: normal; font-size: 0.74rem; font-weight: 700; color: #6b7b88; }
.ds-fu__filter { margin: 0; font-size: 0.88rem; }
.ds-fu__filter button, .ds-fu__link { text-decoration: underline; color: #1d6fb8; }
.ds-fu__fills { display: flex; flex-direction: column; gap: 0.6rem; }
.ds-fu__fill { display: grid; grid-template-columns: 4.5rem 1fr auto; gap: 1rem; align-items: center; padding: 0.75rem 1rem; }
.ds-fu__photo { width: 4.5rem; height: 4.5rem; border-radius: 0.6rem; overflow: hidden; background: #eef2f5; display: grid; place-items: center; font-size: 0.7rem; color: #8a99a5; }
.dark .ds-fu__photo { background: rgb(255 255 255 / .05); }
.ds-fu__photo img { width: 100%; height: 100%; object-fit: cover; }
.ds-fu__fillmain { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
.ds-fu__fillmain small { color: #6b7b88; font-size: 0.78rem; }
.ds-fu__chips { display: flex; flex-wrap: wrap; gap: 0.3rem; margin-top: 0.2rem; }
.ds-fu__chips em, .ds-fu__line em { font-style: normal; font-size: 0.72rem; font-weight: 700; padding: 0.15rem 0.5rem; border-radius: 999px; background: #eef2f5; color: #3d4f5c; }
.dark .ds-fu__chips em, .dark .ds-fu__line em { background: rgb(255 255 255 / .06); color: #c9d5de; }
.ds-fu__chips em.is-bad, .ds-fu__line em.is-bad { background: #fde8e6; }
.ds-fu__chips em.is-ok, .ds-fu__line em.is-ok { background: #e2f5ec; }
.dark .ds-fu__chips em.is-bad, .dark .ds-fu__line em.is-bad { background: rgb(255 107 94 / .14); }
.dark .ds-fu__chips em.is-ok, .dark .ds-fu__line em.is-ok { background: rgb(52 195 143 / .14); }
.ds-fu__fillnums { display: flex; flex-direction: column; align-items: flex-end; gap: 0.1rem; font-size: 0.8rem; color: #6b7b88; }
.ds-fu__fillnums b { font-size: 1.05rem; color: inherit; }
.ds-fu__fillnums b { color: #0e2433; }
.dark .ds-fu__fillnums b { color: #e6edf3; }
.ds-fu__alerts { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-fu__alert { display: grid; grid-template-columns: 2.25rem 1fr auto; gap: 0.75rem; align-items: start; padding: 0.8rem 1rem; border-radius: 0.8rem; background: #fff8ec; box-shadow: inset 3px 0 0 #f0a93b; }
.ds-fu__alert.is-red { background: #fff1ef; box-shadow: inset 3px 0 0 #e0473b; }
.dark .ds-fu__alert { background: rgb(240 169 59 / .08); }
.dark .ds-fu__alert.is-red { background: rgb(255 107 94 / .09); }
.ds-fu__alert b { display: block; font-size: 0.9rem; }
.ds-fu__alert small { display: block; font-size: 0.8rem; color: #5b6b78; margin-top: 0.15rem; }
.dark .ds-fu__alert small { color: #a9b8c3; }
.ds-fu__alerticon { font-size: 1.25rem; line-height: 1.5rem; }
.ds-fu__when { white-space: nowrap; font-size: 0.74rem; color: #8a99a5; }
.ds-fu__two { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr); gap: 1rem; align-items: start; }
.ds-fu__two > section, .ds-fu__steps > section { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.7rem; }
.ds-fu h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-fu__where { margin: 0; padding-left: 1.1rem; font-size: 0.82rem; list-style: disc; display: flex; flex-direction: column; gap: 0.2rem; }
.ds-fu__form { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-fu__form input[type=file] { font-size: 0.8rem; max-width: 100%; }
.ds-fu__form.is-stack { flex-direction: column; align-items: stretch; }
.ds-fu__form.is-stack label { display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.78rem; color: #6b7b88; }
.ds-fu__err { margin: 0; color: #c8372d; font-size: 0.8rem; }
.ds-fu__counts { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-fu__counts button { padding: 0.25rem 0.65rem; border-radius: 999px; font-size: 0.75rem; font-weight: 700; background: #eef2f5; color: #3d4f5c; }
.ds-fu__counts button.is-on { background: #0e2433; color: #fff; }
.dark .ds-fu__counts button { background: rgb(255 255 255 / .06); color: #c9d5de; }
.dark .ds-fu__counts button.is-on { background: #e6edf3; color: #0e2433; }
.ds-fu__lines { display: flex; flex-direction: column; max-height: 32rem; overflow-y: auto; }
.ds-fu__line { display: grid; grid-template-columns: 1fr auto auto; gap: 0.75rem; align-items: center; padding: 0.5rem 0; border-top: 1px solid rgb(0 0 0 / .06); font-size: 0.84rem; }
.dark .ds-fu__line { border-color: rgb(255 255 255 / .07); }
.ds-fu__line small { color: #6b7b88; font-size: 0.75rem; }
.ds-fu__prices { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-fu__prices span { display: flex; flex-direction: column; padding: 0.75rem; border-radius: 0.7rem; background: #f3f6f8; }
.dark .ds-fu__prices span { background: rgb(255 255 255 / .04); }
.ds-fu__prices small, .ds-fu__prices em { font-size: 0.74rem; color: #6b7b88; font-style: normal; }
.ds-fu__prices b { font-size: 1.4rem; }
.ds-fu__vat { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)) auto; gap: 0.6rem; align-items: stretch; }
.ds-fu__vat > span { padding: 0.7rem 0.9rem; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-fu__vat small, .ds-fu__vat em { font-size: 0.74rem; color: #6b7b88; font-style: normal; }
.ds-fu__vat b { font-size: 1.2rem; }
.ds-fu__vat > span.is-ok b { color: #17895e; }
.ds-fu__vat > span.is-bad b { color: #c8372d; }
.ds-fu__export { display: grid; place-items: center; padding: 0 1.1rem; border-radius: 0.75rem; background: #17895e; color: #fff; font-weight: 800; font-size: 0.88rem; }
.ds-fu__steps { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.8rem; align-items: start; }
.ds-fu__num { display: inline-grid; place-items: center; width: 1.5rem; height: 1.5rem; margin-right: 0.35rem; border-radius: 50%; background: #0e2433; color: #fff; font-size: 0.75rem; }
.dark .ds-fu__num { background: #e6edf3; color: #0e2433; }
.ds-fu__calc { display: grid; grid-template-columns: auto 1fr; gap: 0.35rem 0.75rem; margin: 0; font-size: 0.84rem; }
.ds-fu__calc dt { color: #6b7b88; }
.ds-fu__calc dd { margin: 0; text-align: right; }
.ds-fu__calc small { display: block; font-size: 0.7rem; color: #8a99a5; }
.ds-fu__big { margin: 0; font-size: 1.9rem; font-weight: 800; letter-spacing: -0.02em; }
.ds-fu__hint { margin: 0; padding: 0.5rem 0.7rem; border-radius: 0.6rem; background: #eef5fb; font-size: 0.8rem; }
.dark .ds-fu__hint { background: rgb(90 168 255 / .1); }
@media (max-width: 1100px) { .ds-fu__two, .ds-fu__steps { grid-template-columns: 1fr; } .ds-fu__vat { grid-template-columns: 1fr 1fr; } }
@media (max-width: 640px) { .ds-fu__fill { grid-template-columns: 3.5rem 1fr; } .ds-fu__fillnums { grid-column: 2; align-items: flex-start; } .ds-fu__photo { width: 3.5rem; height: 3.5rem; } }

/* ------------------------------------------------------------------ Fuel (Driver app) */
.ds-fd__home { display: grid; grid-template-columns: 2.6rem 1fr auto; gap: 0.8rem; align-items: center; padding: 0.85rem 1rem; border-radius: 1.2rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); color: var(--sa-text); }
.ds-fd__home > span:first-child { display: grid; place-items: center; width: 2.6rem; height: 2.6rem; border-radius: 0.8rem; background: rgb(246 190 0 / .14); font-size: 1.3rem; }
.ds-fd__home b { display: block; font-size: 1rem; }
.ds-fd__home small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-fd__top { display: grid; grid-template-columns: 2.5rem 1fr auto; gap: 0.75rem; align-items: center; }
.ds-fd__top > span:nth-child(2) { display: flex; flex-direction: column; }
.ds-fd__top small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-fd__top strong { font-size: 1.5rem; font-weight: 700; letter-spacing: -0.02em; }
.ds-fd__back { display: grid; place-items: center; width: 2.5rem; height: 2.5rem; border-radius: 50%; background: rgb(255 255 255 / .06); color: var(--sa-text); font-size: 1.6rem; line-height: 1; }
.ds-fd__dots { display: flex; gap: 0.3rem; }
.ds-fd__dots i { width: 0.5rem; height: 0.5rem; border-radius: 50%; background: rgb(255 255 255 / .15); }
.ds-fd__dots i.is-done { background: var(--sa-ok); }
.ds-fd__dots i.is-on { background: var(--sa-gold); width: 1.3rem; border-radius: 999px; }
.ds-fd__cash { padding: 0.75rem 0.95rem; border-radius: 1rem; background: rgb(52 195 143 / .1); font-size: 0.9rem; }
.ds-fd__cash small { display: block; color: var(--sa-muted); font-size: 0.76rem; margin-top: 0.15rem; }
.ds-fd__intro { display: flex; flex-direction: column; align-items: center; text-align: center; gap: 0.5rem; margin-top: 1.5rem; }
.ds-fd__intro strong { font-size: 1.35rem; }
.ds-fd__intro p { margin: 0; color: var(--sa-muted); font-size: 0.92rem; max-width: 26rem; }
.ds-fd__big { display: grid; place-items: center; width: 5rem; height: 5rem; border-radius: 50%; background: rgb(255 255 255 / .06); font-size: 2.3rem; }
.ds-fd__big.is-ok { background: rgb(52 195 143 / .16); color: var(--sa-ok); font-weight: 800; }
.ds-fd__tin { padding: 0.6rem 0.8rem; border-radius: 0.8rem; background: rgb(246 190 0 / .1); color: var(--sa-text) !important; }
.ds-fd__actions { display: flex; flex-direction: column; gap: 0.6rem; margin-top: auto; }
.ds-fd__actions .ds-sa__primary, .ds-fd__actions .ds-sa__secondary { width: 100%; }
.ds-fd__thumb { display: grid; grid-template-columns: 4rem 1fr; gap: 0.8rem; align-items: center; padding: 0.5rem; border-radius: 1rem; background: var(--sa-glass); color: var(--sa-muted); font-size: 0.85rem; }
.ds-fd__thumb img { width: 4rem; height: 4rem; object-fit: cover; border-radius: 0.65rem; }
.ds-fd__odo { width: 100%; max-height: 14rem; object-fit: cover; border-radius: 1rem; }
.ds-fd__warn { padding: 0.7rem 0.9rem; border-radius: 0.9rem; background: rgb(240 169 59 / .14); color: #f6c46b; font-size: 0.88rem; }
.ds-fd__warn.is-bad { background: rgb(255 107 94 / .15); color: #ff9d93; }
.ds-fd__seg { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 0.3rem; padding: 0.3rem; border-radius: 1rem; background: rgb(255 255 255 / .05); }
.ds-fd__seg button { height: 2.9rem; border-radius: 0.75rem; color: var(--sa-muted); font-weight: 700; }
.ds-fd__seg button.is-on { background: var(--sa-gold); color: #0a1219; }
.ds-fd__seg.is-small button { height: 2.3rem; padding: 0 0.8rem; font-size: 0.85rem; }
.ds-fd__form { display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; }
.ds-fd__form label { display: flex; flex-direction: column; gap: 0.25rem; }
.ds-fd__form label.is-wide, .ds-fd__form .ds-sa__err { grid-column: 1 / -1; }
.ds-fd__form small { font-size: 0.76rem; color: var(--sa-muted); }
.ds-fd__form input { height: 3rem; padding: 0 0.85rem; border-radius: 0.85rem; border: 0; background: rgb(255 255 255 / .07); color: var(--sa-text); font-size: 1rem; color-scheme: dark; }
.ds-fd__form input:focus { outline: 2px solid var(--sa-gold); }
.ds-fd__form .is-total input { height: 3.4rem; font-size: 1.35rem; font-weight: 700; }
.ds-fd__ask { display: flex; align-items: center; justify-content: space-between; gap: 0.75rem; font-size: 0.9rem; }
.ds-fd__kml { display: grid; grid-template-columns: 1fr 1fr; border-radius: 1rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-fd__kml span { display: flex; flex-direction: column; padding: 0.8rem 1rem; }
.ds-fd__kml span + span { box-shadow: inset 1px 0 0 var(--sa-line); }
.ds-fd__kml small { color: var(--sa-muted); font-size: 0.76rem; }
.ds-fd__kml b { font-size: 1.4rem; }
.ds-fd__btn { display: grid; place-items: center; margin-top: auto; }

/* ------------------------------------------------------------------ Warehouse sections, sets, truck waiting (Scan app) */
.ds-sx__tile { display: flex; flex-direction: column; align-items: center; gap: 0.15rem; padding: 0.9rem 1rem; border-radius: 1.2rem; background: var(--sx, #1d6fb8); color: #fff; text-align: center; animation: ds-sx-in .2s ease-out; }
.ds-sx__tile small { font-size: 0.8rem; font-weight: 700; opacity: .85; }
.ds-sx__tile strong { font-size: 3.6rem; line-height: 1; font-weight: 900; letter-spacing: -0.02em; }
.ds-sx__tile span { font-size: 1.05rem; font-weight: 800; }
.ds-sx__tile em { font-style: normal; font-size: 0.8rem; opacity: .9; }
.ds-sx__tile.is-truck strong { font-size: 3.6rem; letter-spacing: 0.02em; }
.ds-sx__setrows { list-style: none; margin: 0.25rem 0 0; padding: 0; display: flex; flex-direction: column; gap: 0.3rem; font-size: 0.8rem; color: var(--sa-text); }
.ds-sx__setrows li { display: grid; grid-template-columns: 1.4rem 1fr; }
.ds-sx__setadd { margin-top: 0.35rem; min-height: 2.8rem; border-radius: 0.75rem; background: #f6be00; color: #0a1219; font-weight: 800; font-size: 0.9rem; padding: 0 0.8rem; }
.ds-sx__here { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; padding: 0.55rem 0.8rem; border-radius: 0.8rem; background: rgb(246 140 0 / .16); color: #ffd39a; font-size: 0.85rem; }
@keyframes ds-sx-in { from { transform: scale(.96); opacity: .4; } to { transform: none; opacity: 1; } }
@media (prefers-reduced-motion: reduce) { .ds-sx__tile { animation: none; } }
.ds-sx__set { display: flex; flex-direction: column; gap: 0.35rem; padding: 0.7rem 0.9rem; border-radius: 1rem; background: rgb(255 255 255 / .06); font-size: 0.92rem; }
.ds-sx__set small { color: var(--sa-muted); font-size: 0.8rem; }
.ds-sx__set.is-done { background: rgb(52 195 143 / .14); }
.ds-sx__set.is-split { background: rgb(240 169 59 / .14); }
.ds-sx__set.is-split small { color: #f6c46b; }
.ds-sx__dots { display: flex; gap: 0.25rem; }
.ds-sx__dots i { flex: 1; max-width: 2.2rem; height: 0.4rem; border-radius: 999px; background: rgb(255 255 255 / .15); }
.ds-sx__dots i.is-on { background: var(--sa-ok); }
.ds-sx__link { align-self: center; padding: 0.35rem 0.6rem; color: var(--sa-gold); font-size: 0.88rem; font-weight: 700; text-decoration: underline; text-underline-offset: 3px; }
.ds-sx__team { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-sx__team span { padding: 0.25rem 0.65rem; border-radius: 999px; background: rgb(255 255 255 / .06); font-size: 0.8rem; color: var(--sa-muted); }
.ds-sx__team span.is-me { color: var(--sa-gold); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .4); }
.ds-sx__team b { color: var(--sa-text); margin-left: 0.2rem; }
.ds-sx__truck { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.75rem 0.9rem; border-radius: 1rem; background: rgb(232 89 12 / .16); box-shadow: inset 0 0 0 1px rgb(232 89 12 / .5); }
.ds-sx__truck.is-paused { background: rgb(255 255 255 / .05); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sx__truckhead { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 0.9rem; }
.ds-sx__truckhead button { padding: 0.3rem 0.6rem; border-radius: 0.6rem; background: rgb(255 255 255 / .1); color: var(--sa-text); font-size: 0.78rem; font-weight: 700; margin-left: 0.25rem; }
.ds-sx__truckn { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.4rem; font-size: 0.74rem; color: var(--sa-muted); }
.ds-sx__truckn b { display: block; font-size: 1.15rem; color: var(--sa-text); }
.ds-sx__picker { display: flex; flex-direction: column; gap: 0.45rem; padding: 0.8rem; border-radius: 1rem; background: rgb(255 255 255 / .05); }
.ds-sx__picker > button:not(.ds-sx__link) { display: flex; flex-direction: column; align-items: flex-start; padding: 0.65rem 0.8rem; border-radius: 0.8rem; background: rgb(255 255 255 / .07); color: var(--sa-text); text-align: left; }
.ds-sx__picker small, .ds-sx__picker p { color: var(--sa-muted); font-size: 0.8rem; margin: 0; }
.ds-sx__open { display: flex; flex-direction: column; gap: 0.6rem; width: 100%; padding: 0.9rem; border-radius: 1rem; background: rgb(240 169 59 / .1); box-shadow: inset 0 0 0 1px rgb(240 169 59 / .4); text-align: left; }
.ds-sx__open > small { color: var(--sa-muted); font-size: 0.78rem; }
.ds-sx__openrow { display: flex; flex-direction: column; gap: 0.35rem; font-size: 0.9rem; }
.ds-sx__miss { display: flex; flex-direction: column; gap: 0.3rem; padding: 0.5rem 0.6rem; border-radius: 0.7rem; background: rgb(255 255 255 / .05); }
.ds-sx__miss small { color: var(--sa-muted); }
.ds-sx__why { display: flex; flex-wrap: wrap; gap: 0.3rem; }
.ds-sx__why button { padding: 0.3rem 0.55rem; border-radius: 999px; background: rgb(255 255 255 / .08); color: var(--sa-muted); font-size: 0.74rem; font-weight: 700; }
.ds-sx__why button.is-on { background: var(--sa-gold); color: #0a1219; }

/* ------------------------------------------------------------------ Settings · Warehouse sections */
.ds-ws { display: flex; flex-direction: column; gap: 1rem; }
.ds-ws__top { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end; gap: 0.75rem; }
.ds-ws__wh { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.8rem; color: #6b7b88; }
.ds-ws__acts { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-ws select, .ds-ws input[type=text], .ds-ws textarea { min-height: 2.25rem; padding: 0.35rem 0.6rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; width: 100%; box-sizing: border-box; }
.dark .ds-ws select, .dark .ds-ws input[type=text], .dark .ds-ws textarea { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-ws__list { padding: 0.25rem 0; overflow-x: auto; }
.ds-ws__row { display: grid; grid-template-columns: 7.5rem 1.2fr 0.9fr 1.3fr 2fr 4rem 2rem; gap: 0.6rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 62rem; }
.dark .ds-ws__row { border-color: rgb(255 255 255 / .07); }
.ds-ws__row.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
.ds-ws__code { display: grid; grid-template-columns: 2.6rem 1fr; gap: 0.3rem; align-items: center; }
.ds-ws__code input { text-align: center; font-weight: 900; font-size: 1.05rem !important; color: #fff !important; background: var(--c) !important; border-color: var(--c) !important; }
.ds-ws__code select { font-size: 0.7rem !important; padding: 0.2rem !important; }
.ds-ws__muted { color: #6b7b88; font-size: 0.8rem; margin: 0; }
.ds-ws__del { width: 2rem; height: 2rem; border-radius: 0.5rem; color: #c8372d; }
.ds-ws__del:hover { background: #fde8e6; }
.ds-ws__empty { padding: 1.25rem; display: flex; flex-direction: column; align-items: flex-start; gap: 0.75rem; }
.ds-ws__empty p { margin: 0; color: #6b7b88; }
.ds-ws__err { margin: 0.5rem 1rem; color: #c8372d; font-size: 0.85rem; }
.ds-ws__two { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; }
.ds-ws__box { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-ws__box h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-ws__toggle { display: flex; gap: 0.7rem; align-items: flex-start; cursor: pointer; }
.ds-ws__toggle input { margin-top: 0.25rem; width: 1.1rem; height: 1.1rem; }
.ds-ws__toggle small { display: block; color: #6b7b88; font-size: 0.8rem; margin-top: 0.15rem; }
@media (max-width: 900px) { .ds-ws__two { grid-template-columns: 1fr; } }
.ds-ws__result { display: flex; gap: 0.9rem; align-items: center; margin-top: 0.75rem; padding: 0.75rem 1rem; border-radius: 0.9rem; background: color-mix(in srgb, var(--c) 12%, transparent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--c) 40%, transparent); }
.ds-ws__result > strong { display: grid; place-items: center; min-width: 3rem; height: 3rem; padding: 0 0.4rem; border-radius: 0.7rem; background: var(--c); color: #fff; font-size: 1.6rem; font-weight: 900; }
.ds-ws__result small { display: block; color: #6b7b88; font-size: 0.8rem; }

/* ------------------------------------------------------------------ Sea shipments, wrong hub & returns */
.ds-sp { display: flex; flex-direction: column; gap: 1rem; }
.ds-sp h3 { margin: 0; font-size: 0.98rem; font-weight: 800; }
.ds-sp select, .ds-sp input[type=text], .ds-sp input[type=number], .ds-sp input[type=date] { min-height: 2.25rem; padding: 0.35rem 0.6rem; border-radius: 0.55rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.85rem; color: inherit; box-sizing: border-box; }
.dark .ds-sp select, .dark .ds-sp input[type=text], .dark .ds-sp input[type=number], .dark .ds-sp input[type=date] { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-sp__new { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.6rem; }
.ds-sp__newrow { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }
.ds-sp__newrow select, .ds-sp__newrow input { flex: 1 1 12rem; }
.ds-sp__err { margin: 0; color: #c8372d; font-size: 0.85rem; }
.ds-sp__filter { display: flex; gap: 0.35rem; }
.ds-sp__filter button { padding: 0.35rem 0.85rem; border-radius: 999px; font-size: 0.8rem; font-weight: 700; background: #eef2f5; color: #3d4f5c; }
.ds-sp__filter button.is-on { background: #0e2433; color: #fff; }
.dark .ds-sp__filter button { background: rgb(255 255 255 / .06); color: #c9d5de; }
.dark .ds-sp__filter button.is-on { background: #e6edf3; color: #0e2433; }
.ds-sp__list { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-sp__item { display: grid; grid-template-columns: 2.5rem 1fr auto auto; gap: 1rem; align-items: center; padding: 0.8rem 1rem; }
.ds-sp__icon { font-size: 1.5rem; }
.ds-sp__main { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
.ds-sp__main small, .ds-sp__nums small { color: #6b7b88; font-size: 0.78rem; }
.ds-sp__bar { display: flex; gap: 0.2rem; margin-top: 0.25rem; max-width: 20rem; }
.ds-sp__bar i { flex: 1; height: 0.35rem; border-radius: 999px; background: #dfe5ea; }
.ds-sp__bar i.is-done { background: #17895e; }
.ds-sp__bar i.is-now { background: #f6be00; }
.dark .ds-sp__bar i { background: rgb(255 255 255 / .1); }
.ds-sp__nums { display: flex; flex-direction: column; align-items: flex-end; }
.ds-sp__nums b { font-size: 1.2rem; }
.ds-sp__state { padding: 0.25rem 0.7rem; border-radius: 999px; font-size: 0.75rem; font-weight: 800; background: #eef5fb; color: #1d6fb8; white-space: nowrap; }
.ds-sp__state.is-received { background: #e2f5ec; color: #17895e; }
.ds-sp__state.is-preparing { background: #eef2f5; color: #3d4f5c; }
.ds-sp__steps { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 0.5rem; padding: 1rem; overflow-x: auto; }
.ds-sp__step { display: flex; flex-direction: column; gap: 0.3rem; min-width: 6rem; font-size: 0.85rem; color: #8a99a5; }
.ds-sp__step i { height: 0.4rem; border-radius: 999px; background: #dfe5ea; }
.ds-sp__step.is-done { color: inherit; }
.ds-sp__step.is-done i { background: #17895e; }
.ds-sp__step.is-now { color: inherit; }
.ds-sp__step.is-now i { background: #f6be00; }
.ds-sp__step small { font-size: 0.72rem; color: #8a99a5; }
.ds-sp__head { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 0.75rem; }
.ds-sp__track { display: flex; gap: 0.75rem; align-items: center; font-size: 1rem; }
.ds-sp__track > span:first-child { font-size: 1.6rem; }
.ds-sp__track small { display: block; color: #6b7b88; font-size: 0.78rem; }
.ds-sp__acts { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-sp__block { display: flex; flex-direction: column; gap: 0.25rem; padding: 0.7rem 1rem; border-radius: 0.75rem; background: #fff4e0; color: #7a4a00; font-size: 0.88rem; }
.dark .ds-sp__block { background: rgb(240 169 59 / .14); color: #f6c46b; }
.ds-sp__grid { display: grid; grid-template-columns: 1.4fr 1fr; gap: 1rem; align-items: start; }
.ds-sp__box { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.7rem; }
.ds-sp__nums4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0.5rem; }
.ds-sp__nums4 span { display: flex; flex-direction: column; padding: 0.7rem; border-radius: 0.7rem; background: #f3f6f8; }
.dark .ds-sp__nums4 span { background: rgb(255 255 255 / .04); }
.ds-sp__nums4 small { font-size: 0.72rem; color: #6b7b88; }
.ds-sp__nums4 b { font-size: 1.4rem; }
.ds-sp__nums4 .is-bad b { color: #c8372d; }
.ds-sp__warn { margin: 0; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #fde8e6; color: #a3281f; font-size: 0.85rem; }
.dark .ds-sp__warn { background: rgb(255 107 94 / .12); color: #ff9d93; }
.ds-sp__sets { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.85rem; padding: 0.6rem 0.75rem; border-radius: 0.6rem; background: #eef5fb; }
.dark .ds-sp__sets { background: rgb(90 168 255 / .08); }
.ds-sp__dl { display: grid; grid-template-columns: 1fr auto; gap: 0.35rem 0.75rem; margin: 0; font-size: 0.88rem; }
.ds-sp__dl dt { color: #6b7b88; }
.ds-sp__dl dd { margin: 0; text-align: right; font-variant-numeric: tabular-nums; }
.ds-sp__perbox { display: flex; justify-content: space-between; align-items: baseline; margin: 0; padding: 0.7rem 0.9rem; border-radius: 0.7rem; background: #eef5fb; font-weight: 800; }
.ds-sp__perbox b { font-size: 1.4rem; }
.dark .ds-sp__perbox { background: rgb(90 168 255 / .08); }
.ds-sp__pics { display: flex; gap: 0.5rem; }
.ds-sp__pics a { display: flex; flex-direction: column; gap: 0.2rem; font-size: 0.72rem; color: #6b7b88; }
.ds-sp__pics img { width: 5rem; height: 5rem; object-fit: cover; border-radius: 0.6rem; }
.ds-sp__form { padding: 1rem 1.15rem; display: flex; flex-direction: column; gap: 0.8rem; }
.ds-sp__fields { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.6rem; }
.ds-sp__fields label { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.75rem; color: #6b7b88; }
.ds-sp__fields .is-wide { grid-column: span 2; }
.ds-sp__fields input[type=file] { font-size: 0.78rem; }
.ds-sp__table { padding: 0.25rem 0; overflow-x: auto; }
.ds-sp__tr { display: grid; grid-template-columns: 1.4fr 1fr 1.6fr auto; gap: 0.8rem; align-items: center; padding: 0.7rem 1rem; border-top: 1px solid rgb(0 0 0 / .06); min-width: 46rem; font-size: 0.88rem; }
.dark .ds-sp__tr { border-color: rgb(255 255 255 / .07); }
.ds-sp__tr.is-head { border-top: 0; font-size: 0.72rem; font-weight: 700; color: #6b7b88; }
.ds-sp__tr > span { display: flex; flex-direction: column; gap: 0.2rem; }
.ds-sp__tr small { color: #6b7b88; font-size: 0.76rem; }
.ds-sp__tr select { font-size: 0.75rem; min-height: 1.9rem; }
.ds-sp__tag { align-self: flex-start; font-style: normal; font-size: 0.72rem; font-weight: 800; padding: 0.15rem 0.55rem; border-radius: 999px; background: #eef2f5; color: #3d4f5c; }
.ds-sp__tag.is-bad { background: #fde8e6; color: #a3281f; }
.ds-sp__ok { color: #17895e; }
.ds-sp__btns { flex-direction: row !important; gap: 0.35rem; flex-wrap: wrap; justify-content: flex-end; }
.ds-sp__pad { padding: 1rem; }
.ds-sp__barrow { display: grid; grid-template-columns: 11rem 1fr 2.5rem; gap: 0.6rem; align-items: center; font-size: 0.86rem; }
.ds-sp__barrow i { height: 0.7rem; border-radius: 999px; background: #eef2f5; overflow: hidden; }
.ds-sp__barrow i b { display: block; height: 100%; background: #1d6fb8; border-radius: 999px; }
@media (max-width: 1000px) { .ds-sp__grid { grid-template-columns: 1fr; } .ds-sp__fields { grid-template-columns: 1fr 1fr; } .ds-sp__nums4 { grid-template-columns: 1fr 1fr; } }
.ds-sx__stop { margin: 0; padding: 0.7rem 0.9rem; border-radius: 0.9rem; background: rgb(255 107 94 / .15); color: #ff9d93; font-weight: 700; font-size: 0.9rem; text-align: left; }
.ds-ws__row.is-view { grid-template-columns: 4rem 1.3fr 2fr 6rem 1.6fr; min-width: 48rem; }
.ds-ws__row.is-view > span { display: flex; flex-direction: column; }
.ds-ws__badge { display: grid !important; place-items: center; width: 2.6rem; height: 2.6rem; border-radius: 0.6rem; background: var(--c); color: #fff; font-weight: 900; font-size: 1.15rem; }
.ds-ws__pad { padding: 1rem; }
.ds-ws__box input[type=text] { max-width: 22rem; }
.ds-sp__tr.is-cost { grid-template-columns: 1.6fr 1fr 1.2fr 1.2fr 1fr; min-width: 40rem; }
.ds-sp__barrow.is-plain { grid-template-columns: 1fr auto auto; }
/* ============================== Box sizes ============================== */
.ds-bx { display: flex; flex-direction: column; gap: 1rem; }
.ds-bx__head { display: flex; align-items: center; justify-content: space-between; gap: 1rem; flex-wrap: wrap; }
.ds-bx__head p { margin: 0; max-width: 46rem; color: var(--ds-steel); }
.ds-bx__switch { display: inline-flex; align-items: center; gap: 0.6rem; padding: 0.5rem 0.9rem 0.5rem 0.5rem; border-radius: 0.8rem; font-weight: 800; background: #fff; color: var(--ds-steel); box-shadow: inset 0 0 0 1px rgb(14 36 51 / 0.12); cursor: pointer; }
.ds-bx__switch i { position: relative; width: 2.4rem; height: 1.4rem; border-radius: 999px; background: #c7d0d7; }
.ds-bx__switch i::after { content: ''; position: absolute; top: 0.2rem; left: 0.2rem; width: 1rem; height: 1rem; border-radius: 50%; background: #fff; transition: left .15s; }
.ds-bx__switch.is-on { background: #e7f5ee; color: #17694a; box-shadow: none; }
.ds-bx__switch.is-on i { background: var(--ds-ok); }
.ds-bx__switch.is-on i::after { left: 1.2rem; }
.ds-bx__two { display: grid; grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr); gap: 1rem; align-items: start; }
@media (max-width: 64rem) { .ds-bx__two { grid-template-columns: 1fr; } }
.ds-bx__types, .ds-bx__trucks, .ds-bx__same { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-bx__side { display: flex; flex-direction: column; gap: 1rem; }
.ds-bx__type { display: grid; grid-template-columns: minmax(0, 1fr) auto 4rem; align-items: center; gap: 0.75rem; padding: 0.7rem 0.8rem; border-radius: 0.8rem; box-shadow: inset 0 0 0 1px rgb(14 36 51 / 0.08); }
.ds-bx__type.is-new { background: #fff8e0; box-shadow: inset 0 0 0 1px #f2dc8c; }
.ds-bx__type.is-plain { background: rgb(14 36 51 / 0.03); box-shadow: none; }
.ds-bx__name { display: flex; flex-direction: column; gap: 0.2rem; min-width: 0; }
.ds-bx__name > span:first-child { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
.ds-bx__name small { color: var(--ds-steel); font-size: 0.78rem; }
.ds-bx__tag { font-style: normal; font-size: 0.65rem; font-weight: 800; padding: 0.1rem 0.45rem; border-radius: 999px; }
.ds-bx__tag.is-base { background: var(--ds-navy); color: #fff; }
.ds-bx__tag.is-new { background: #fff1c2; color: #7a5600; }
.ds-bx__links { display: flex; gap: 0.75rem; }
.ds-bx__links button { font-size: 0.75rem; font-weight: 700; color: var(--ds-steel); text-decoration: underline; text-underline-offset: 2px; }
.ds-bx__step { display: inline-flex; align-items: center; gap: 0.35rem; }
.ds-bx__step button { width: 2rem; height: 2rem; border-radius: 0.5rem; background: rgb(14 36 51 / 0.07); font-weight: 800; font-size: 1.05rem; }
.ds-bx__step b { min-width: 2.2rem; text-align: center; font-size: 1.05rem; font-variant-numeric: tabular-nums; }
.ds-bx__step input { width: 4rem; text-align: center; padding: 0.3rem; border-radius: 0.5rem; border: 1px solid rgb(14 36 51 / 0.15); font-weight: 800; background: transparent; }
.ds-bx__pic { display: flex; align-items: flex-end; justify-content: center; height: 2.6rem; }
.ds-bx__pic i { display: block; border-radius: 4px; background: var(--ds-navy-3); }
.ds-bx__same > div, .ds-bx__trucks > div { display: flex; align-items: center; gap: 0.6rem; padding: 0.55rem 0; border-top: 1px solid rgb(14 36 51 / 0.08); }
.ds-bx__same > div > span, .ds-bx__trucks > div > span:first-child { flex: 1; display: flex; flex-direction: column; gap: 0.15rem; min-width: 0; }
.ds-bx__same small, .ds-bx__trucks small { color: var(--ds-steel); font-size: 0.78rem; }
.ds-bx__trucks small.ds-bx__past { color: #5b46c2; }
.ds-bx__ai { align-self: flex-start; padding: 0.55rem 0.9rem; border-radius: 0.7rem; font-weight: 800; background: #f1eefc; color: #3b2f7a; box-shadow: inset 0 0 0 1px #d9d1f7; }
.dark .ds-bx__type { box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.08); }
.dark .ds-bx__type.is-new { background: rgb(246 190 0 / 0.08); }
.dark .ds-bx__switch { background: #10283a; }
.dark .ds-bx__step button { background: rgb(255 255 255 / 0.08); }
.dark .ds-bx__pic i { background: var(--ds-signal); }
.ds-sa__size { background: rgb(246 190 0 / 0.18) !important; color: #f6be00 !important; font-weight: 800; }
.ds-sa__count small.ds-sa__space { color: #f6be00; font-weight: 700; }
.ds-bx__note { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.7rem; background: #fff8e0; color: #7a5600; font-size: 0.9rem; }
.ds-bx__dims { display: flex; flex-wrap: wrap; align-items: center; gap: 0.25rem; font-size: 0.75rem; color: #6b7b88; margin-top: 0.25rem; }
.ds-bx__dims input { width: 3.6rem; height: 1.8rem; padding: 0 0.35rem; border-radius: 0.4rem; border: 1px solid #d5dde3; background: #fff; font-size: 0.78rem; color: inherit; }
.dark .ds-bx__dims input { background: #0b1d2a; border-color: rgb(255 255 255 / .12); }
.ds-bx__dims button { margin-left: 0.25rem; padding: 0.15rem 0.5rem; border-radius: 999px; background: #eef5fb; color: #1d6fb8; font-weight: 700; font-size: 0.72rem; }
.ds-sx__topup { display: flex; flex-direction: column; gap: 0.45rem; width: 100%; padding: 0.9rem; border-radius: 1rem; background: rgb(52 195 143 / .1); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .4); text-align: left; }
.ds-sx__topup > small { color: var(--sa-muted); font-size: 0.78rem; }
.ds-sx__toprow { display: grid; grid-template-columns: 1fr auto; gap: 0.5rem; align-items: center; padding: 0.5rem 0.6rem; border-radius: 0.7rem; background: rgb(255 255 255 / .05); font-size: 0.86rem; }
.ds-sx__toprow small { display: block; color: var(--sa-muted); font-size: 0.76rem; }
.ds-sx__toprow button { padding: 0.35rem 0.7rem; border-radius: 0.6rem; background: var(--sa-ok); color: #0a1219; font-weight: 800; font-size: 0.78rem; }
.ds-sp__lines { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-sp__line { display: inline-flex; align-items: center; gap: 0.35rem; padding: 0.3rem 0.4rem 0.3rem 0.7rem; border-radius: 999px; background: #eef2f5; font-size: 0.8rem; }
.dark .ds-sp__line { background: rgb(255 255 255 / .06); }
.ds-sp__x { width: 1.4rem; height: 1.4rem; border-radius: 50%; color: #c8372d; }
.ds-sp__search { display: flex; align-items: center; gap: 0.5rem; padding: 0 0.75rem; min-height: 2.6rem; border-radius: 0.7rem; box-shadow: inset 0 0 0 1.5px #0e2433; background: #fff; }
.dark .ds-sp__search { background: #0b1d2a; box-shadow: inset 0 0 0 1.5px rgb(255 255 255 / .3); }
.ds-sp__search input { flex: 1; border: 0 !important; box-shadow: none !important; background: transparent !important; outline: none; font-size: 0.92rem; padding: 0 !important; }
.ds-sp__search button { width: 1.5rem; height: 1.5rem; border-radius: 50%; background: #eef2f5; font-size: 0.7rem; }
.ds-sp__group { margin-top: 0.4rem; font-size: 0.72rem; color: #6b7b88; }
.ds-sp__pick { display: grid; grid-template-columns: 1.1rem 1fr auto; gap: 0.7rem; align-items: center; padding: 0.7rem 0.8rem; border-radius: 0.75rem; text-align: left; box-shadow: inset 0 0 0 1px #e6ebef; }
.dark .ds-sp__pick { box-shadow: inset 0 0 0 1px rgb(255 255 255 / .1); }
.ds-sp__pick i { width: 1.1rem; height: 1.1rem; border-radius: 50%; box-shadow: inset 0 0 0 2px #b7c4cf; }
.ds-sp__pick.is-on { box-shadow: inset 0 0 0 2px #0e2433; background: #f3f6f8; }
.dark .ds-sp__pick.is-on { box-shadow: inset 0 0 0 2px #e6edf3; background: rgb(255 255 255 / .04); }
.ds-sp__pick.is-on i { box-shadow: inset 0 0 0 6px #0e2433; }
.ds-sp__pick span { display: flex; flex-direction: column; }
.ds-sp__pick small { color: #6b7b88; font-size: 0.76rem; }
.ds-sp__pick em { font-style: normal; font-size: 0.78rem; font-weight: 800; color: #3d4f5c; }
.ds-sp__none { margin: 0; padding: 0.8rem; border-radius: 0.7rem; background: #f6f8fa; color: #5b6b78; font-size: 0.88rem; }
.dark .ds-sp__none { background: rgb(255 255 255 / .04); }
.ds-sp__lbl { display: flex; flex-direction: column; gap: 0.25rem; font-size: 0.75rem; color: #6b7b88; }
.ds-sp__tr.is-isl { grid-template-columns: 1.6fr 1fr 1.6fr 1.2fr; }
.ds-sp__way { justify-self: start; padding: 0.35rem 0.8rem; border-radius: 999px; font-size: 0.8rem; font-weight: 800; box-shadow: inset 0 0 0 1px #dfe5ea; color: #33424e; }
.ds-sp__way.is-sea { background: #0e2433; color: #fff; box-shadow: none; }
.dark .ds-sp__way.is-sea { background: #e6edf3; color: #0e2433; }
.ds-pt__q { font-size: 1.25rem; }
.ds-pt__count { display: grid; grid-template-columns: 3.5rem 1fr 3.5rem; gap: 0.8rem; align-items: center; padding: 1rem; border-radius: 1.3rem; background: rgb(255 255 255 / .05); }
.ds-pt__count button { height: 3.5rem; border-radius: 1rem; background: rgb(255 255 255 / .08); color: var(--sa-text); font-size: 1.6rem; }
.ds-pt__count input { width: 100%; text-align: center; border: 0; background: transparent; color: var(--sa-text); font-size: 3.2rem; font-weight: 800; font-variant-numeric: tabular-nums; outline: none; }
.ds-pt__hint { margin: 0; text-align: center; color: var(--sa-muted); font-size: 0.82rem; }

/* Sea shipment: one container, more hubs */
.ds-sp__stop { display: flex; align-items: center; gap: 0.6rem; padding: 0.55rem 0.7rem; border-radius: 0.75rem; background: rgb(127 147 161 / .1); }
.ds-sp__stop > span { flex: 1; display: flex; flex-direction: column; }
.ds-sp__stop small { color: rgb(107 123 136); font-size: 0.78rem; }
.ds-sp__stopn { width: 1.75rem; height: 1.75rem; flex: none; border-radius: 999px; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 0.85rem; }

/* Driver app · trip steps */
.ds-ts { display: flex; flex-direction: column; gap: 0.35rem; padding: 1rem 1.1rem; border-radius: 1.2rem; background: #1d3a52; color: #fff; margin-bottom: 0.75rem; }
.ds-ts small { opacity: .8; font-weight: 700; }
.ds-ts strong { font-size: 1.35rem; line-height: 1.2; }
.ds-ts span { font-size: 0.9rem; opacity: .92; }
.ds-ts .ds-sa__primary { margin-top: 0.5rem; }
.ds-ts--loading, .ds-ts--back { background: #8a5a00; }
.ds-ts--ready { background: #5b2f99; }
.ds-ts--closed { background: #0e2433; }
.ds-ts--next { background: #eef6ff; color: #1d5f99; }

/* Today's crew board (matches mockup boards 29 and 32) */
.ds-cb { display: flex; flex-direction: column; gap: 1.25rem; }
.ds-cb__groups { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: flex-start; }
.ds-cb__group { min-width: 18rem; flex: 0 1 auto; border-radius: 14px; background: #fff4d6; color: #6b4e00; }
.ds-cb__group.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-cb__group summary { display: flex; align-items: center; gap: 0.6rem; padding: 0.7rem 0.9rem; cursor: pointer; list-style: none; font-size: 0.9rem; }
.ds-cb__group summary::-webkit-details-marker { display: none; }
.ds-cb__gicon { font-size: 1rem; }
.ds-cb__gshow { margin-left: auto; font-size: 0.78rem; font-weight: 700; opacity: .75; }
.ds-cb__group[open] .ds-cb__gshow { visibility: hidden; }
.ds-cb__group ul { list-style: none; margin: 0; padding: 0 0.9rem 0.8rem; display: flex; flex-direction: column; gap: 0.35rem; max-height: 16rem; overflow: auto; }
.ds-cb__group li { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; padding: 0.45rem 0.6rem; border-radius: 10px; background: rgb(255 255 255 / .7); font-size: 0.85rem; }
.ds-cb__group li a, .ds-cb__group li button { flex: none; font-weight: 800; font-size: 0.8rem; color: #0e2433; }
.ds-cb__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(20rem, 1fr)); gap: 1.25rem; align-items: start; }
.ds-cb__card { display: flex; flex-direction: column; gap: 0.5rem; padding: 18px; border-radius: 20px; background: #fff; box-shadow: 0 1px 0 #e3e8ec, 0 12px 32px -18px rgb(14 36 51 / .25); color: #0e2433; }
.ds-cb__card header { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 17px; }
.ds-cb__label, .ds-cb__muted, .ds-cb__note { color: #6b7b88; font-size: 0.8rem; margin: 0; }
.ds-cb__pill { font-size: 11px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: #e6f4ff; color: #1d5f99; white-space: nowrap; }
.ds-cb__pill.is-free, .ds-cb__pill.is-waiting, .ds-cb__pill.is-closed { background: #eef1f4; color: #33424e; }
.ds-cb__pill.is-loading, .ds-cb__pill.is-back { background: #fff0d1; color: #8a5a00; }
.ds-cb__pill.is-ready { background: #efe6fb; color: #5b2f99; }
.ds-cb__pill.is-road { background: #e6f6ef; color: #17895e; }
.ds-cb__count { font-size: 11px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: #eef1f4; color: #33424e; }
.ds-cb__person { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; padding: 8px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-cb__person > span { display: flex; flex-direction: column; min-width: 0; }
.ds-cb__person b { font-size: 14px; }
.ds-cb__person small { color: #6b7b88; font-size: 12px; }
.ds-cb__person > button { color: #6b7b88; padding: 0 0.25rem; }
.ds-cb__person.is-inactive { background: #fff8ea; box-shadow: inset 0 0 0 1px #f39a1e; }
.ds-cb__none { color: #8a1f1f; font-size: 0.85rem; margin: 0; }
.ds-cb__add, .ds-cb__put { border: 0; border-radius: 10px; box-shadow: inset 0 0 0 1px #c3ccd4; background: transparent; color: #6b7b88; font-size: 13px; padding: 8px 12px; }
.ds-cb__put { padding: 6px 10px; flex: none; }
.ds-cb__same { align-self: flex-start; font-size: 13px; font-weight: 700; padding: 6px 12px; border-radius: 10px; background: #eef1f4; color: #33424e; }
.ds-cb__next { padding: 8px 12px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 13px; box-shadow: inset 0 0 0 1px #9cc7f0; }
.dark .ds-cb__card { background: rgb(255 255 255 / .05); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .08); color: inherit; }
.dark .ds-cb__person { background: rgb(255 255 255 / .06); }
.dark .ds-cb__person.is-inactive { background: rgb(243 154 30 / .12); }
.dark .ds-cb__group li { background: rgb(255 255 255 / .5); }

/* Trip page */
.ds-tp { display: flex; flex-direction: column; gap: 1rem; max-width: 60rem; }
.ds-tp__steps { display: flex; gap: 0.4rem; flex-wrap: wrap; }
.ds-tp__step { display: flex; flex-direction: column; min-width: 8.5rem; padding: 0.45rem 0.8rem; border-radius: 0.75rem; box-shadow: inset 0 0 0 1px rgb(127 147 161 / .35); }
.ds-tp__step small { font-size: 0.75rem; opacity: .75; }
.ds-tp__step.is-now { background: #0e2433; color: #fff; box-shadow: none; }
.ds-tp__step.is-done { background: #e6f6ef; color: #17895e; box-shadow: none; }
.ds-tp__card { display: flex; flex-direction: column; gap: 0.7rem; }
.ds-tp__head { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; font-size: 1.3rem; }
.ds-tp__tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr)); gap: 0.6rem; }
.ds-tp__tiles > span { display: flex; flex-direction: column; padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: rgb(127 147 161 / .1); }
.ds-tp__tiles small, .ds-tp__crewhead small, .ds-tp__person small, .ds-tp__next small { color: rgb(107 123 136); font-size: 0.78rem; }
.ds-tp__crewhead { display: flex; justify-content: space-between; align-items: baseline; gap: 0.5rem; flex-wrap: wrap; margin-top: 0.25rem; }
.ds-tp__person { display: flex; align-items: center; gap: 0.75rem; padding: 0.55rem 0.75rem; border-radius: 0.75rem; box-shadow: inset 0 0 0 1px rgb(127 147 161 / .3); }
.ds-tp__person.is-swap { box-shadow: inset 0 0 0 1px #f39a1e; background: #fff8ea; }
.ds-tp__person > span { display: flex; flex-direction: column; }
.ds-tp__person i { width: 2.25rem; height: 2.25rem; flex: none; border-radius: 999px; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-style: normal; font-weight: 800; font-size: 0.85rem; }
.ds-tp__warn { margin: 0; padding: 0.6rem 0.8rem; border-radius: 0.75rem; background: #fff4d6; color: #6b4e00; font-size: 0.875rem; }
.ds-tp__warn.is-ok { background: #e6f6ef; color: #17895e; }
.ds-tp__next { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; padding: 0.7rem 0.9rem; border-radius: 0.75rem; background: #eef6ff; box-shadow: inset 0 0 0 1px #9cc7f0; }
.ds-tp__next > span { display: flex; flex-direction: column; }
@media (max-width: 640px) { .ds-tp__tiles { grid-template-columns: 1fr; } }

/* Trucks (board 34) and rental trucks (board 33) */
.ds-fl { display: flex; flex-direction: column; gap: 1.1rem; }
.ds-fl__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-fl__summary { color: #6b7b88; }
.ds-fl__tools { display: flex; gap: 0.6rem; align-items: center; }
.ds-fl__search { width: 17.5rem; height: 42px; border: 0; border-radius: 12px; background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; padding: 0 14px; font-size: 14px; }
.ds-fl__add { height: 42px; padding: 0 18px; border-radius: 12px; background: #0e2433; color: #fff; font-weight: 800; display: inline-flex; align-items: center; }
.ds-fl__chips { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-fl__chip { height: 34px; padding: 0 14px; border-radius: 999px; font-weight: 700; font-size: 13px; background: #fff; color: #33424e; box-shadow: inset 0 0 0 1px #dfe5ea; }
.ds-fl__chip span { opacity: .6; margin-left: 4px; }
.ds-fl__chip.is-on { background: #0e2433; color: #fff; box-shadow: none; }
.ds-fl__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(19rem, 1fr)); gap: 1.1rem; }
.ds-fl__card { gap: 0.75rem; transition: transform .15s ease, box-shadow .15s ease; }
.ds-fl__card:hover { transform: translateY(-2px); box-shadow: 0 1px 0 #e3e8ec, 0 18px 36px -18px rgb(14 36 51 / .35); }
.ds-fl__card.is-dim { opacity: .72; }
.ds-fl__head { display: flex; justify-content: space-between; align-items: flex-start; gap: 0.5rem; }
.ds-fl__head > span:first-child { display: flex; flex-direction: column; }
.ds-fl__head small, .ds-tk__id small { color: #6b7b88; font-size: 12px; }
.ds-fl__plate { font-size: 22px; letter-spacing: .02em; }
.ds-fl__plate.is-big { font-size: 30px; }
.ds-fl__tags { display: flex; flex-direction: column; align-items: flex-end; gap: 6px; }
.ds-cb__pill.is-own { background: #e6f6ef; color: #17895e; }
.ds-cb__pill.is-rent, .ds-cb__pill.is-warn { background: #fff0d1; color: #8a5a00; }
.ds-cb__pill.is-info { background: #e6f4ff; color: #1d5f99; }
.ds-cb__pill.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-cb__pill.is-muted { background: #eef1f4; color: #6b7b88; }
.ds-fl__mid { display: flex; justify-content: space-between; align-items: flex-end; }
.ds-fl__truck { position: relative; width: 120px; height: 56px; flex: none; }
.ds-fl__truck i { position: absolute; display: block; }
.ds-fl__truck .b { left: 2px; top: 8px; width: 74px; height: 34px; border-radius: 5px; background: var(--tc); }
.ds-fl__truck .c { left: 78px; top: 18px; width: 34px; height: 24px; border-radius: 4px 12px 2px 2px; background: #0e2433; }
.ds-fl__truck .w { left: 84px; top: 22px; width: 13px; height: 9px; border-radius: 2px; background: #9cc7f0; }
.ds-fl__truck .r1, .ds-fl__truck .r2 { top: 39px; width: 14px; height: 14px; border-radius: 50%; background: #0e2433; box-shadow: inset 0 0 0 4px #0e2433, inset 0 0 0 7px #c3ccd4; }
.ds-fl__truck .r1 { left: 15px; } .ds-fl__truck .r2 { left: 87px; }
.ds-fl__truck.is-big { transform: scale(1.4); transform-origin: left center; margin-right: 50px; }
.ds-fl__crew { display: flex; align-items: center; }
.ds-fl__crew span { width: 30px; height: 30px; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 800; box-shadow: 0 0 0 2px #fff; }
.ds-fl__crew span + span { margin-left: -4px; }
.ds-fl__load { display: flex; justify-content: space-between; font-size: 12px; color: #6b7b88; }
.ds-fl__bar { height: 8px; border-radius: 999px; background: #eef1f4; overflow: hidden; }
.ds-fl__bar i { display: block; height: 100%; border-radius: 999px; background: #34c38f; }
.ds-fl__bar i.is-full { background: #f6be00; }
.ds-fl__note { font-size: 12px; padding: 6px 10px; border-radius: 10px; background: #f6f8fa; color: #33424e; }
.ds-fl__note.is-warn { background: #fff4d6; color: #6b4e00; }
.ds-fl__note.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-fl__note.is-muted { color: #6b7b88; }
.ds-fl__seg { display: inline-flex; gap: 6px; padding: 4px; border-radius: 12px; background: #e8ecef; align-self: flex-start; }
.ds-fl__seg button { height: 34px; padding: 0 14px; border-radius: 9px; font-weight: 800; color: #6b7b88; }
.ds-fl__seg button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 2px rgb(0 0 0 / .08); }
.ds-tk__back { align-self: flex-start; color: #6b7b88; font-size: 14px; }
.ds-tk__head { flex-direction: row; align-items: center; gap: 1.5rem; padding: 22px 24px; }
.ds-tk__id { flex: 1; display: flex; flex-direction: column; gap: 6px; }
.ds-tk__line { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.ds-tk__btn { height: 40px; padding: 0 16px; border-radius: 10px; box-shadow: inset 0 0 0 1px #c3ccd4; display: inline-flex; align-items: center; font-weight: 700; flex: none; }
.ds-tk__tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
.ds-tk__tiles .ds-cb__card { gap: 4px; padding: 16px 18px; }
.ds-tk__big { font-size: 20px; }
.ds-tk__two { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; align-items: start; }
.ds-tk__narrow { max-width: 45rem; }
.ds-tk__details { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; max-width: 70rem; }
.ds-tk__field { display: flex; flex-direction: column; gap: 4px; }
.ds-tk__field small { color: #6b7b88; font-size: 12px; }
.ds-tk__row { grid-column: 1 / -1; display: flex; justify-content: space-between; align-items: center; gap: 1rem; padding: 12px 14px; border-radius: 12px; background: #f6f8fa; }
.ds-tk__row > span { display: flex; flex-direction: column; }
.ds-tk__row small { color: #6b7b88; font-size: 12px; }
.ds-tk__switch { width: 46px; height: 26px; border-radius: 999px; background: #c3ccd4; position: relative; flex: none; }
.ds-tk__switch i { position: absolute; top: 3px; left: 3px; width: 20px; height: 20px; border-radius: 50%; background: #fff; transition: left .15s; }
.ds-tk__switch.is-on { background: #17895e; } .ds-tk__switch.is-on i { left: 23px; }
.ds-tk__table { padding: 8px 18px; gap: 0; max-width: 78rem; }
.ds-tk__tr { display: grid; grid-template-columns: 1fr 1.5fr 1.2fr .7fr 1.4fr; gap: 10px; padding: 11px 0; font-size: 14px; border-bottom: 1px solid #eef1f4; }
.ds-tk__table.is-rent .ds-tk__tr { grid-template-columns: .8fr 1.5fr 1.5fr 1fr .7fr .8fr; }
.ds-tk__tr.is-head { font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-tk__tr .is-ok { color: #17895e; font-weight: 700; }
.ds-tk__tr .is-bad { color: #8a1f1f; font-weight: 700; }
.ds-tk__month { display: inline-flex; align-items: center; gap: 0.5rem; font-weight: 700; color: #33424e; }
.ds-tk__month.is-big { font-size: 1.25rem; }
.ds-tk__month button { width: 28px; height: 28px; border-radius: 8px; background: #eef1f4; }
.ds-tk__cal { display: grid; grid-template-columns: repeat(7, 1fr); gap: 4px; text-align: center; }
.ds-tk__cal small { color: #6b7b88; font-size: 12px; }
.ds-tk__cal button { height: 34px; border-radius: 8px; background: #f6f8fa; font-size: 13px; font-weight: 700; color: #33424e; }
.ds-tk__cal button.is-today { background: #eef6ff; }
.ds-tk__cal button.is-on { background: #0e2433; color: #fff; }
.ds-tk__ai { max-width: 78rem; padding: 14px 16px; font-size: 14px; }
.ds-tk__addco { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-tk__addco input { height: 40px; border: 0; border-radius: 10px; box-shadow: inset 0 0 0 1px #c3ccd4; padding: 0 12px; font-size: 14px; flex: 1; min-width: 9rem; }
@media (max-width: 900px) { .ds-tk__tiles, .ds-tk__two, .ds-tk__details { grid-template-columns: 1fr; } }
.dark .ds-fl__search, .dark .ds-fl__chip { background: rgb(255 255 255 / .05); color: inherit; }

/* ───── Part 19b · Edit / Add truck (board 35) ───── */
.ds-te { display: flex; flex-direction: column; gap: 16px; color: #0e2433; }
.ds-te [x-cloak] { display: none; }
.ds-te__top { display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; flex-wrap: wrap; }
.ds-te__title { display: flex; flex-direction: column; gap: 4px; }
.ds-te__title small { color: #6b7b88; font-size: 13px; }
.ds-te__title h1 { margin: 0; font-size: 28px; font-weight: 900; letter-spacing: -0.02em; }
.ds-te__actions { display: flex; align-items: center; gap: 10px; }
.ds-te__dirty { color: #8a5a00; font-size: 13px; }
.ds-te__btn { height: 40px; padding: 0 16px; border-radius: 10px; font-weight: 800; background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; color: #33424e; display: inline-flex; align-items: center; flex: none; }
.ds-te__btn.is-main { background: #0e2433; color: #fff; box-shadow: none; }
.ds-te__btn:disabled { opacity: .6; }
.ds-te__errors { padding: 10px 14px; border-radius: 12px; background: #fde8e8; color: #8a1f1f; font-size: 14px; }
.ds-te__grid { display: grid; grid-template-columns: 340px 1fr; gap: 20px; align-items: start; }
.ds-te__side, .ds-te__form { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.ds-te__card { gap: 14px; padding: 20px; }
.ds-te__muted { color: #6b7b88; font-size: 12px; }
.ds-te__stage { height: 120px; border-radius: 16px; background: linear-gradient(180deg, #eef3f7, #f8fafb); display: flex; align-items: center; justify-content: center; }
.ds-te__truck { position: relative; width: calc(var(--bw) + 50px); height: 70px; display: block; transition: width .2s; }
.ds-te__truck i { position: absolute; display: block; transition: left .2s, width .2s, background .2s; }
.ds-te__truck .b { left: 0; top: 6px; width: var(--bw); height: 44px; border-radius: 7px; background: var(--tc); }
.ds-te__truck .c { left: calc(var(--bw) + 4px); top: 18px; width: 44px; height: 32px; border-radius: 5px 16px 3px 3px; background: #0e2433; }
.ds-te__truck .w { left: calc(var(--bw) + 12px); top: 24px; width: 16px; height: 11px; border-radius: 3px; background: #9cc7f0; }
.ds-te__truck .r1, .ds-te__truck .r2 { top: 44px; width: 20px; height: 20px; border-radius: 50%; background: #0e2433; box-shadow: inset 0 0 0 6px #0e2433, inset 0 0 0 10px #c3ccd4; }
.ds-te__truck .r1 { left: 14px; } .ds-te__truck .r2 { left: calc(var(--bw) + 16px); }
.ds-te__id { display: flex; justify-content: space-between; align-items: flex-start; gap: .5rem; }
.ds-te__id > span:first-child { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.ds-te__plate { font-size: 26px; letter-spacing: .02em; overflow-wrap: anywhere; }
.ds-te__plate.is-empty, .ds-te .is-empty { color: #9aa7b2; }
.ds-te__facts { display: flex; flex-direction: column; gap: 8px; }
.ds-te__facts > span { display: flex; justify-content: space-between; gap: .5rem; padding: 9px 12px; border-radius: 12px; background: #f6f8fa; color: #33424e; font-size: 13px; }
.ds-te__facts > span.is-rent { background: #fff8ea; color: #6b4e00; }
.ds-te__facts > span.is-warn { background: #fff4d6; color: #6b4e00; }
.ds-te__facts > span.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-te__facts > span.is-muted { color: #9aa7b2; }
.ds-te__drop { min-height: 130px; border-radius: 14px; border: 2px dashed #c9d3db; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; color: #6b7b88; font-size: 13px; cursor: pointer; overflow: hidden; text-align: center; padding: 8px; }
.ds-te__drop:hover { border-color: #0e2433; }
.ds-te__drop b { color: #0e2433; }
.ds-te__drop img { width: 100%; max-height: 180px; object-fit: cover; border-radius: 10px; }
.ds-te__drop-icon { font-size: 26px; }
.ds-te__photo-tools { display: flex; gap: 14px; }
.ds-te__link { border: 0; background: transparent; padding: 0; text-align: left; font-size: 13px; font-weight: 700; color: #1d5f99; cursor: pointer; }
.ds-te__link.is-bad { color: #8a1f1f; }
.ds-te__active { flex-direction: row; align-items: center; justify-content: space-between; gap: 12px; padding: 16px 18px; }
.ds-te__active > span { display: flex; flex-direction: column; gap: 2px; }
.ds-te__switch { flex: none; width: 50px; height: 28px; border-radius: 999px; background: #c3ccd4; position: relative; }
.ds-te__switch i { position: absolute; top: 4px; left: 4px; width: 20px; height: 20px; border-radius: 50%; background: #fff; transition: left .15s; }
.ds-te__switch.is-on { background: #17895e; }
.ds-te__switch.is-on i { left: 26px; }
.ds-te__sec { gap: 14px; padding: 20px 22px; }
.ds-te__head { display: flex; flex-direction: column; gap: 2px; }
.ds-te__head b { font-size: 17px; }
.ds-te__head small { color: #6b7b88; font-size: 12px; }
.ds-te__cols3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }
.ds-te__cols2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.ds-te__cols12 { display: grid; grid-template-columns: 1fr 2fr; gap: 14px; }
.ds-te__cols-r { display: grid; grid-template-columns: 1.3fr 1fr; gap: 14px; }
.ds-te__field { display: flex; flex-direction: column; gap: 6px; font-size: 13px; font-weight: 700; color: #33424e; min-width: 0; }
.ds-te__input { height: 42px; width: 100%; border: 0; border-radius: 12px; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; padding: 0 14px; font-size: 15px; font-weight: 400; color: #0e2433; }
.ds-te__input:focus { outline: none; background: #fff; box-shadow: inset 0 0 0 2px #0e2433; }
.ds-te__input::placeholder { color: #9aa7b2; }
.ds-te__input.is-fixed { display: flex; align-items: center; color: #33424e; }
.ds-te__text { height: auto; min-height: 76px; padding: 12px 14px; line-height: 1.5; resize: vertical; }
.ds-te__hint { font-size: 12px; font-weight: 400; color: #6b7b88; }
.ds-te__err { font-size: 12px; font-weight: 600; color: #b42318; }
.ds-te__kinds { display: grid; grid-template-columns: repeat(5, 1fr); gap: 10px; }
.ds-te__kind { display: flex; flex-direction: column; align-items: flex-start; gap: 4px; padding: 12px; border-radius: 14px; text-align: left; color: #0e2433; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-te__kind:hover { box-shadow: inset 0 0 0 1px #9aa7b2; }
.ds-te__kind.is-on { background: #fffaeb; box-shadow: inset 0 0 0 2px #f6be00; }
.ds-te__kind b { font-size: 13px; }
.ds-te__kind small { color: #6b7b88; font-weight: 400; font-size: 12px; }
.ds-te__mini { display: flex; align-items: flex-end; gap: 2px; height: 22px; }
.ds-te__mini i { display: block; height: 16px; border-radius: 3px; }
.ds-te__mini i + i { width: 10px; height: 11px; border-radius: 2px 5px 1px 1px; background: #0e2433; }
.ds-te__owners { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.ds-te__owner { display: flex; align-items: center; gap: 12px; padding: 14px 16px; border-radius: 14px; text-align: left; color: #0e2433; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-te__owner.is-on { background: #fff; box-shadow: inset 0 0 0 2px #0e2433; }
.ds-te__owner > span:nth-child(2) { display: flex; flex-direction: column; gap: 2px; }
.ds-te__owner b { font-size: 15px; }
.ds-te__owner small { color: #6b7b88; font-size: 12px; }
.ds-te__owner-icon { font-size: 22px; }
.ds-te__radio { margin-left: auto; flex: none; width: 20px; height: 20px; border-radius: 50%; box-shadow: inset 0 0 0 2px #c3ccd4; }
.ds-te__owner.is-on .ds-te__radio { box-shadow: inset 0 0 0 6px #0e2433; }
.ds-te__row { display: flex; gap: 8px; align-items: center; }
.ds-te__row.hidden { display: none; }
.ds-te__charge { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.ds-te__money { height: 42px; width: 200px; border-radius: 12px; background: #fff; box-shadow: inset 0 0 0 2px #0e2433; display: flex; align-items: center; gap: 8px; padding: 0 14px; }
.ds-te__money > span { color: #6b7b88; }
.ds-te__money input { flex: 1; min-width: 0; border: 0; padding: 0; background: transparent; font-size: 15px; font-weight: 800; color: #0e2433; }
.ds-te__money input:focus { outline: none; box-shadow: none; }
.ds-te__money small { color: #6b7b88; font-weight: 400; font-size: 12px; white-space: nowrap; }
.ds-te__booked { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; padding: 10px 14px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 13px; }
.ds-te__pair { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; align-items: stretch; }
.ds-te__note { padding: 9px 12px; border-radius: 12px; font-size: 13px; background: #f6f8fa; color: #6b7b88; }
.ds-te__note.is-ok { background: #e6f6ef; color: #17895e; }
.ds-te__note.is-warn { background: #fff4d6; color: #6b4e00; }
.ds-te__note.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-te__stepper { display: flex; align-items: center; gap: 12px; }
.ds-te__stepper button { width: 42px; height: 42px; flex: none; border-radius: 12px; background: #e8ecef; font-size: 20px; font-weight: 800; color: #0e2433; }
.ds-te__stepper button:hover { background: #dfe5ea; }
.ds-te__stepper > span { display: flex; flex-direction: column; align-items: center; min-width: 90px; }
.ds-te__stepper > span b { font-size: 30px; }
.ds-te__stepper > span small { color: #6b7b88; font-size: 12px; }
.ds-te__stepper .ds-te__hint { flex: 1; }
.ds-te__size { display: flex; align-items: center; gap: 8px; font-size: 13px; color: #6b7b88; }
.ds-te__size .ds-te__input { width: 76px; padding: 0 10px; }
.ds-te__size .ds-te__input.is-pct { width: 64px; }
.ds-te button:focus-visible, .ds-te a:focus-visible, .ds-te__drop:focus-within { outline: 3px solid #f6be00; outline-offset: 2px; }
@media (max-width: 1100px) {
  .ds-te__grid, .ds-te__pair { grid-template-columns: 1fr; }
  .ds-te__kinds { grid-template-columns: repeat(3, 1fr); }
}
@media (max-width: 640px) {
  .ds-te__cols3, .ds-te__cols12, .ds-te__cols-r, .ds-te__owners, .ds-te__cols2 { grid-template-columns: 1fr; }
  .ds-te__kinds { grid-template-columns: repeat(2, 1fr); }
}

/* ───── Part 19c · Duplicate trucks (board 36) ───── */
.ds-fl__dupes { display: flex; flex-direction: column; gap: 12px; padding: 18px 20px; box-shadow: inset 0 0 0 2px #f6be00, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-fl__dupes-head { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-fl__dupes-head > span { display: flex; flex-direction: column; gap: 2px; }
.ds-fl__dupes-head b { font-size: 17px; }
.ds-fl__dupes-head small { color: #6b7b88; font-size: 12px; }
.ds-fl__dupe { display: flex; align-items: center; gap: 14px; padding: 12px 14px; border-radius: 14px; background: #fffaeb; flex-wrap: wrap; }
.ds-fl__dupe > b { font-size: 18px; min-width: 110px; }
.ds-fl__dupe-copies { flex: 1; display: flex; gap: 8px; flex-wrap: wrap; }
.ds-fl__dupe-copies span { padding: 6px 10px; border-radius: 10px; background: #fff; box-shadow: inset 0 0 0 1px #f3d58a; font-size: 13px; }
.ds-fl__card.is-dupe { box-shadow: inset 0 0 0 2px #f6be00, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-dp__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(26rem, 1fr)); gap: 20px; }
.ds-dp__copy { display: flex; flex-direction: column; gap: 16px; padding: 22px; border-radius: 20px; background: #fff; color: #0e2433; text-align: left; box-shadow: inset 0 0 0 1px #e1e7ec, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-dp__copy.is-on { box-shadow: inset 0 0 0 3px #0e2433, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-dp__copy.is-on .ds-te__radio { box-shadow: inset 0 0 0 7px #0e2433; }
.ds-dp__copy .ds-te__radio { width: 24px; height: 24px; }
.ds-dp__top { display: flex; align-items: center; gap: 16px; }
.ds-dp__id { flex: 1; display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.ds-dp__id small { color: #6b7b88; font-size: 12px; }
.ds-dp__plate { font-size: 26px; letter-spacing: .02em; }
.ds-dp__stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.ds-dp__stats > span { padding: 10px 12px; border-radius: 12px; background: #f6f8fa; display: flex; flex-direction: column; min-width: 0; }
.ds-dp__stats small { color: #6b7b88; font-size: 12px; }
.ds-dp__stats b { font-size: 18px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-dp__foot { color: #6b7b88; font-size: 12px; }
.ds-dp__foot.is-ok { color: #17895e; }
.ds-dp__what { flex-direction: row; align-items: center; gap: 20px; padding: 18px 20px; flex-wrap: wrap; }
.ds-dp__what-text { flex: 1; display: flex; flex-direction: column; gap: 6px; min-width: 18rem; font-size: 14px; color: #33424e; }
.ds-dp__what-text > b { font-size: 16px; color: #0e2433; }
.ds-dp__what-text small { color: #6b7b88; font-size: 13px; }
.ds-dp__btns { display: flex; gap: 10px; flex-wrap: wrap; justify-content: center; }
.ds-dp__go { height: 48px; padding: 0 22px; font-size: 15px; }
.ds-dp__done { align-items: center; gap: 12px; max-width: 760px; align-self: center; margin-top: 40px; padding: 28px; text-align: center; color: #33424e; }
.ds-dp__tick { width: 64px; height: 64px; border-radius: 50%; background: #e6f6ef; color: #17895e; font-size: 30px; display: flex; align-items: center; justify-content: center; }
.ds-dp__done-title { font-size: 24px; color: #0e2433; }
.ds-dp__soft { padding: 10px 14px; border-radius: 12px; background: #f6f8fa; color: #6b7b88; font-size: 13px; }
.ds-te__exists { display: flex; align-items: center; gap: 14px; padding: 14px 16px; border-radius: 14px; background: #fff4d6; color: #6b4e00; flex-wrap: wrap; }
.ds-te__exists.is-info { background: #eef6ff; color: #1d5f99; }
.ds-te__exists > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 14rem; }
.ds-te__exists small { font-size: 12px; }
.ds-te__exists-icon { font-size: 22px; }
.ds-te__input.is-clash { box-shadow: inset 0 0 0 2px #f39a1e; }
.ds-te__input.is-free { box-shadow: inset 0 0 0 2px #17895e; }
.ds-te__okline { padding: 10px 14px; border-radius: 12px; background: #e6f6ef; color: #17895e; font-size: 13px; }

/* ───── Part 20a · Missing barangay (boards 37, 38) ───── */
.ds-ad { gap: 18px; }
.ds-ad__top { display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; flex-wrap: wrap; }
.ds-ad__pick { width: auto; min-width: 14rem; background: #fff; }
.ds-ad__tile { gap: 4px; padding: 16px 18px; }
.ds-ad__tile.is-ring { box-shadow: inset 0 0 0 2px #f6be00, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-ad__big { font-size: 26px; }
.ds-ad__pending { display: flex; justify-content: space-between; align-items: center; gap: 1rem; padding: 10px 14px; border-radius: 14px; background: #eef6ff; color: #1d5f99; font-size: 13px; flex-wrap: wrap; }
.ds-ad__table { padding: 6px 18px; gap: 0; }
.ds-ad__row { display: grid; grid-template-columns: 1.1fr 2.2fr 1.5fr 1.3fr 1.2fr; gap: 12px; padding: 12px 0; border-bottom: 1px solid #eef1f4; align-items: center; font-size: 14px; }
.ds-ad__row.is-head { padding: 10px 0; font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-ad__who { display: flex; flex-direction: column; min-width: 0; }
.ds-ad__who small, .ds-ad__as small, .ds-ad__how small { color: #6b7b88; font-size: 12px; }
.ds-ad__who b.is-empty { color: #9aa7b2; }
.ds-ad__as { color: #33424e; display: flex; flex-direction: column; min-width: 0; overflow-wrap: anywhere; }
.ds-ad__how { display: flex; flex-direction: column; gap: 4px; align-items: flex-start; }
.ds-ad__act { display: flex; gap: 6px; justify-content: flex-end; flex-wrap: wrap; }
.ds-ad__sm { height: 34px; }
.ds-ad__done { color: #17895e; font-weight: 700; font-size: 12px; text-align: right; }
.ds-ad__done.is-muted { color: #6b7b88; font-weight: 400; }
.ds-ad__empty { padding: 18px 0; }
.ds-ad__moreb { padding: 12px 0; }
.ds-cb__pill.is-warn { background: #fff4d6; color: #8a5a00; }
.ds-ad__one { display: grid; grid-template-columns: 1.15fr 1fr; gap: 20px; align-items: start; }
.ds-ad__col { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.ds-ad__card { gap: 12px; padding: 20px 22px; }
.ds-ad__h { font-size: 16px; }
.ds-ad__addr { padding: 14px 16px; border-radius: 14px; background: #f6f8fa; font-size: 17px; line-height: 1.7; }
.ds-ad__mark { background: #e6f6ef; border-radius: 4px; padding: 0 4px; color: inherit; }
.ds-ad__mark.is-subdivision { background: #fff0d1; }
.ds-ad__mark.is-landmark { background: #e6f4ff; }
.ds-ad__opt { display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 14px; color: #0e2433; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; text-align: left; }
.ds-ad__opt > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-ad__opt small { color: #6b7b88; font-size: 12px; }
.ds-ad__opt.is-on { background: #fff; box-shadow: inset 0 0 0 2px #0e2433; }
.ds-ad__opt.is-on .ds-te__radio { box-shadow: inset 0 0 0 6px #0e2433; }
.ds-ad__use { display: flex; gap: 12px; align-items: center; flex-wrap: wrap; margin-top: 4px; }
.ds-ad__go { height: 44px; }
.ds-ad__go:disabled { opacity: .5; }
.ds-ad__also { display: flex; gap: 8px; align-items: center; font-size: 13px; color: #33424e; }
.ds-ad__map { width: 100%; height: 380px; border: 0; border-radius: 14px; background: #e9efe6; }
.ds-ad__nomap { height: 380px; border-radius: 14px; background: linear-gradient(135deg, #e9efe6, #dfe9f0); display: flex; align-items: center; justify-content: center; text-align: center; padding: 20px; color: #33424e; }
.ds-ad__more { display: inline-block; margin-top: 4px; font-size: 12px; font-weight: 700; color: #1d5f99; }
.ds-ad__master { display: flex; align-items: center; gap: 12px; }
.ds-ad__model { font-size: 12px; padding: 5px 12px; }
.ds-ad__bigswitch { width: 54px; height: 30px; }
.ds-ad__bigswitch i { width: 22px; height: 22px; }
.ds-ad__bigswitch.is-on i { left: 28px; }
.ds-ad__set { display: grid; grid-template-columns: 1.4fr 1fr; gap: 20px; align-items: start; }
.ds-ad__set.is-off { opacity: .5; }
.ds-ad__optrow { display: flex; align-items: center; gap: 14px; padding: 13px 4px; border-top: 1px solid #eef1f4; color: #0e2433; text-align: left; }
.ds-ad__icon { font-size: 20px; width: 28px; flex: none; }
.ds-ad__optt { flex: 1; display: flex; flex-direction: column; gap: 2px; }
.ds-ad__optt > span { display: flex; gap: 8px; align-items: center; }
.ds-ad__optt small { color: #6b7b88; font-size: 12px; }
.ds-ad__smswitch { width: 44px; height: 24px; }
.ds-ad__smswitch i { top: 3px; left: 3px; width: 18px; height: 18px; }
.ds-ad__smswitch.is-on i { left: 23px; }
.ds-ad__level { display: flex; align-items: center; gap: 12px; padding: 14px 4px 4px; border-top: 1px solid #eef1f4; flex-wrap: wrap; }
.ds-ad__level > span:first-child { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 14rem; }
.ds-ad__level small { color: #6b7b88; font-size: 12px; }
.ds-ad__step { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-ad__step.is-ai { background: #fffaeb; }
.ds-ad__step > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-ad__step small { color: #6b7b88; font-size: 12px; }
.ds-ad__step .ds-cb__pill { background: #fff; }
.ds-ad__num { width: 26px; height: 26px; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 12px; flex: none; }
.ds-ad__month { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.ds-ad__month > span { padding: 10px 12px; border-radius: 12px; background: #f6f8fa; display: flex; flex-direction: column; }
.ds-ad__month small { color: #6b7b88; font-size: 12px; }
.ds-ad__month b { font-size: 20px; }
.ds-ad__try { display: grid; grid-template-columns: 1fr 1.2fr; gap: 20px; align-items: start; }
.ds-ad__sample { display: flex; flex-direction: column; gap: 2px; padding: 12px 14px; border-radius: 14px; color: #0e2433; text-align: left; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-ad__sample.is-on { background: #fff; box-shadow: inset 0 0 0 2px #0e2433; }
.ds-ad__sample small { color: #6b7b88; font-size: 12px; }
.ds-ad__rhead { display: flex; justify-content: space-between; align-items: center; gap: 1rem; }
.ds-ad__tag { font-size: 12px; padding: 5px 12px; }
.ds-ad__tag.is-used, .ds-ad__kv.is-used, .ds-ad__next.is-used { background: #e6f6ef; color: #17895e; }
.ds-ad__tag.is-check, .ds-ad__kv.is-check { background: #fff4d6; color: #8a5a00; }
.ds-ad__tag.is-none, .ds-ad__kv.is-none { background: #eef1f4; color: #6b7b88; }
.ds-ad__kv { display: flex; flex-direction: column; gap: 4px; }
.ds-ad__kv > span, .ds-ad__kv > b { padding: 12px 14px; border-radius: 12px; background: #f6f8fa; font-size: 15px; }
.ds-ad__kv.is-plain > span { background: transparent; padding: 0; font-size: 14px; color: #33424e; }
.ds-ad__kv small { color: #6b7b88; font-size: 12px; }
.ds-ad__two { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.ds-ad__two .ds-ad__kv { padding: 12px 14px; border-radius: 12px; background: #f6f8fa; }
.ds-ad__two .ds-ad__kv > b { padding: 0; background: transparent; font-size: 22px; color: #0e2433; }
.ds-ad__two .ds-ad__kv.is-used { background: #e6f6ef; } .ds-ad__two .ds-ad__kv.is-check { background: #fff4d6; } .ds-ad__two .ds-ad__kv.is-none { background: #eef1f4; }
.ds-ad__next { padding: 10px 14px; border-radius: 12px; font-size: 13px; background: #f6f8fa; color: #6b7b88; }
.ds-ad__next.is-check { background: #fff4d6; color: #6b4e00; }
.ds-ad__cmp { display: grid; grid-template-columns: 1.1fr 1.2fr 1.2fr; gap: 16px; padding: 13px 0; border-bottom: 1px solid #eef1f4; font-size: 14px; align-items: center; }
.ds-ad__cmp.is-head { padding: 12px 0; font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-ad__muted { color: #6b7b88; }
.ds-ad__tick { color: #17895e; font-weight: 800; margin-right: 8px; }
.ds-ad__info { padding: 12px 16px; border-radius: 14px; background: #eef6ff; color: #1d5f99; font-size: 14px; }
.ds-mp__brgy { font-style: normal; font-size: 11px; font-weight: 700; padding: 1px 6px; border-radius: 999px; background: #eef1f4; color: #6b7b88; }
.ds-mp__brgy.is-ai { background: #fff4d6; color: #8a5a00; }
.ds-mp__brgy.is-ok { background: #e6f6ef; color: #17895e; }
@media (max-width: 1100px) {
  .ds-ad__one, .ds-ad__set, .ds-ad__try { grid-template-columns: 1fr; }
  .ds-ad__row { grid-template-columns: 1fr 1fr; }
  .ds-ad__row.is-head { display: none; }
}

/* ───── Part 20b · Plan trips by city (board 30b) ───── */
.ds-pt { display: flex; flex-direction: column; gap: 18px; color: #0e2433; }
.ds-pt__top { display: flex; align-items: flex-end; justify-content: space-between; gap: 24px; flex-wrap: wrap; }
.ds-pt__title { display: flex; flex-direction: column; gap: 6px; flex: 1; min-width: 20rem; max-width: 64rem; }
.ds-pt__days { flex: none; }
.ds-pt__title small { color: #6b7b88; font-size: 15px; }
.ds-pt__h { display: flex; align-items: center; gap: 10px; }
.ds-pt__h h1 { margin: 0; font-size: 28px; font-weight: 900; letter-spacing: -0.02em; }
.ds-pt__logo { width: 34px; height: 34px; border-radius: 10px; background: #0e2433; color: #f6be00; display: flex; align-items: center; justify-content: center; font-weight: 900; }
.ds-pt__days { display: flex; gap: 8px; align-items: center; }
.ds-pt__date { width: auto; background: #fff; }
.ds-pt__ask { flex-direction: row; align-items: center; gap: 14px; padding: 14px 16px; flex-wrap: wrap; }
.ds-pt__spark { font-size: 20px; }
.ds-pt__asktext { flex: 1; display: flex; flex-direction: column; gap: 8px; min-width: 18rem; }
.ds-pt__asktext b { font-size: 14px; }
.ds-pt__chips { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-pt__chip { height: 34px; padding: 0 14px; border-radius: 999px; font-weight: 700; font-size: 13px; background: #eef1f4; color: #33424e; }
.ds-pt__chip.is-on { background: #0e2433; color: #fff; }
.ds-pt__type { width: 360px; max-width: 100%; }
.ds-pt__type .ds-te__input { background: #fff; box-shadow: inset 0 0 0 1px #e3e8ec; font-size: 14px; }
.ds-pt__grid { display: grid; grid-template-columns: 330px 1fr 340px; gap: 20px; align-items: start; }
.ds-pt__left { gap: 10px; }
.ds-pt__lhead { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
.ds-pt__lhead b { font-size: 17px; }
.ds-pt__lhead small, .ds-pt__muted { color: #6b7b88; font-size: 12px; }
.ds-pt__big { font-size: 18px !important; }
.ds-pt__prov { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; border-radius: 14px; background: #fff; box-shadow: inset 0 0 0 1px #eef1f4; }
.ds-pt__prov.is-planned { background: #f6f8fa; box-shadow: none; }
.ds-pt__provhead { display: flex; justify-content: space-between; align-items: baseline; color: #0e2433; text-align: left; }
.ds-pt__provhead b { font-size: 14px; }
.ds-pt__provhead span { font-size: 13px; color: #6b7b88; }
.ds-pt__bar { height: 6px; border-radius: 999px; background: #eef1f4; overflow: hidden; }
.ds-pt__bar i { display: block; height: 100%; border-radius: 999px; background: #1d9e75; }
.ds-pt__bar i.is-mid { background: #ef9f27; } .ds-pt__bar i.is-old { background: #e24b4a; }
.ds-pt__provfoot { display: flex; justify-content: space-between; font-size: 12px; color: #6b7b88; }
.ds-pt__provfoot b { color: #8a5a00; } .ds-pt__provfoot b.is-in { color: #17895e; }
.ds-pt__cities { display: flex; flex-direction: column; gap: 4px; padding-top: 4px; border-top: 1px dashed #dfe5ea; }
.ds-pt__cities > span { display: flex; justify-content: space-between; gap: 8px; font-size: 13px; }
.ds-pt__cities em { font-style: normal; color: #17895e; font-size: 12px; }
.ds-pt__unclear { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 9px 12px; border-radius: 12px; background: #fff4d6; color: #6b4e00; font-size: 12px; }
.ds-pt__mid { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.ds-pt__made { padding: 14px 16px; border-radius: 16px; background: #e6f6ef; color: #17895e; font-weight: 700; }
.ds-pt__trip { gap: 12px; }
.ds-pt__trip.is-off { opacity: .45; }
.ds-pt__trow { display: flex; align-items: center; gap: 12px; }
.ds-pt__tname { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.ds-pt__tname b { font-size: 18px; }
.ds-pt__tname b span { color: #6b7b88; font-weight: 700; }
.ds-pt__tname small { color: #6b7b88; font-size: 12px; }
.ds-pt__truck { display: flex; align-items: center; gap: 8px; height: 38px; padding: 0 12px; border-radius: 12px; background: #eef1f4; color: #33424e; font-weight: 800; flex: none; }
.ds-pt__truck span { opacity: .6; }
.ds-pt__truck.is-free { background: #e6f6ef; color: #17895e; }
.ds-pt__truck.is-busy { background: #fff0d1; color: #8a5a00; }
.ds-pt__stops { display: flex; align-items: flex-start; flex-wrap: wrap; padding: 4px 0 2px; row-gap: 8px; }
.ds-pt__stop { display: flex; flex-direction: column; align-items: center; gap: 4px; min-width: 96px; font-size: 12px; text-align: center; }
.ds-pt__dot { width: 12px; height: 12px; border-radius: 50%; background: #0e2433; box-shadow: 0 0 0 4px #e8ecef; }
.ds-pt__line { width: 48px; height: 2px; background: #c9d2d9; margin-top: 5px; }
.ds-pt__fillrow { display: flex; align-items: center; gap: 12px; }
.ds-pt__fill { flex: 1; height: 34px; border-radius: 10px; background: #eef1f4; position: relative; overflow: hidden; }
.ds-pt__fill i { position: absolute; inset: 0 auto 0 0; background: #bfe6d4; }
.ds-pt__fill i.is-full { background: #f6d77a; }
.ds-pt__fill span { position: absolute; inset: 0; display: flex; align-items: center; padding: 0 12px; font-size: 13px; font-weight: 800; }
.ds-pt__age { font-size: 12px; font-weight: 800; padding: 6px 10px; border-radius: 999px; background: #eef1f4; color: #33424e; white-space: nowrap; }
.ds-pt__age.is-mid { background: #fff0d1; color: #8a5a00; } .ds-pt__age.is-old { background: #fde8e8; color: #8a1f1f; }
.ds-pt__why { display: flex; gap: 8px; align-items: flex-start; font-size: 13px; color: #33424e; }
.ds-pt__why > span:first-child { color: #c99a00; }
.ds-pt__sum { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 14px 16px; border-radius: 16px; background: #0e2433; color: #fff; flex-wrap: wrap; }
.ds-pt__sum > span { display: flex; flex-direction: column; }
.ds-pt__sum small { opacity: .7; font-size: 12px; }
.ds-pt__sum button { height: 46px; padding: 0 22px; border-radius: 12px; background: #f6be00; color: #0a1219; font-weight: 900; font-size: 15px; }
.ds-pt__sum button:disabled { opacity: .5; }
.ds-pt__side { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.ds-pt__card { gap: 10px; }
.ds-pt__h3 { font-size: 17px; }
.ds-pt__trk { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 14px; background: #f6f8fa; }
.ds-pt__trk > i { width: 10px; height: 10px; border-radius: 50%; flex: none; }
.ds-pt__trk > span { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.ds-pt__trk > span b { font-size: 14px; }
.ds-pt__trk > span small { color: #6b7b88; font-size: 12px; }
.ds-pt__trk > small { font-weight: 800; font-size: 12px; }
.ds-pt__trk .is-free { background: #17895e; color: #17895e; } .ds-pt__trk .is-busy { background: #c97a00; color: #c97a00; }
.ds-pt__trk .is-kept { background: #6b7b88; color: #6b7b88; } .ds-pt__trk .is-off { background: #c3ccd4; color: #9aa7b2; }
.ds-pt__trk > small.is-free, .ds-pt__trk > small.is-busy, .ds-pt__trk > small.is-kept, .ds-pt__trk > small.is-off { background: transparent; }
.ds-pt__free { border-radius: 20px; padding: 18px; display: flex; flex-direction: column; gap: 10px; background: #fff8e1; box-shadow: inset 0 0 0 1px #f6d77a; font-size: 14px; color: #33424e; }
.ds-pt__free .ds-te__btn { align-self: flex-start; }
.ds-pt__fhead { display: flex; align-items: center; gap: 8px; color: #0e2433; }
.ds-pt__fhead span { color: #c99a00; }
.ds-pt__un { display: flex; justify-content: space-between; gap: 8px; font-size: 13px; padding: 6px 0; border-bottom: 1px solid #e3e8ec; }
.ds-pt__un b { color: #33424e; } .ds-pt__un b.is-here { color: #17895e; }
@media (max-width: 1280px) { .ds-pt__grid { grid-template-columns: 1fr 1fr; } .ds-pt__mid { grid-column: 1 / -1; order: -1; } }
@media (max-width: 800px) { .ds-pt__grid { grid-template-columns: 1fr; } }
.ds-tp__cities { margin: 0; padding: 10px 14px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 13px; display: flex; flex-direction: column; gap: 2px; }
.ds-tp__cities small { color: #33424e; }

/* ───── Two warehouses (board 40) ───── */
.ds-wc { gap: 16px; }
.ds-wc__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(22rem, 1fr)); gap: 18px; align-items: start; }
.ds-wc__card { gap: 12px; padding: 18px 20px; }
.ds-wc__head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.ds-wc__head > span:first-child { display: flex; flex-direction: column; }
.ds-wc__head b { font-size: 19px; }
.ds-wc__head small { color: #6b7b88; font-size: 12px; }
.ds-cb__pill.is-info { background: #e6f4ff; color: #1d5f99; }
.ds-wc__chips { display: flex; flex-wrap: wrap; gap: 8px; }
.ds-wc__chip { height: 32px; padding: 0 12px; border-radius: 999px; background: #eef1f4; color: #33424e; font-size: 13px; font-weight: 700; display: inline-flex; align-items: center; gap: 6px; }
.ds-wc__chip.is-own { background: #fff0d1; color: #8a5a00; }
.ds-wc__chip button { opacity: .5; font-size: 12px; } .ds-wc__chip button:hover { opacity: 1; }
.ds-wc__add { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.ds-wc__plus { height: 32px; padding: 0 12px; border-radius: 999px; box-shadow: inset 0 0 0 1px #c3ccd4; background: #fff; font-size: 13px; font-weight: 700; color: #33424e; }
.ds-wc__form { display: flex; gap: 8px; flex: 1; min-width: 14rem; }
.ds-wc__form .ds-te__input { height: 36px; font-size: 14px; }
.ds-wc__towns { display: flex; flex-direction: column; gap: 6px; padding: 12px; border-radius: 14px; background: #f6f8fa; font-size: 13px; }
.ds-wc__towns > span { display: flex; justify-content: space-between; gap: 8px; }
.ds-wc__towns .ds-te__input { background: #fff; }
.ds-wc__side { display: flex; flex-direction: column; gap: 14px; }
.ds-wc__conflict { border-radius: 20px; padding: 18px; display: flex; flex-direction: column; gap: 10px; background: #fff4d6; box-shadow: inset 0 0 0 1px #f6d77a; color: #6b4e00; font-size: 13px; }
.ds-wc__conflict b { color: #0e2433; font-size: 15px; }
.ds-wc__btns { display: flex; gap: 8px; }
.ds-wc__ghost { background: transparent; box-shadow: none; color: #6b4e00; }
.ds-wc__asked { padding: 12px 14px; border-radius: 14px; background: #eef6ff; color: #1d5f99; font-size: 13px; }
.ds-wc__req { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 10px 0; border-top: 1px solid #eef1f4; font-size: 13px; flex-wrap: wrap; }
.ds-wc__req > span:first-child { display: flex; flex-direction: column; }
.ds-wc__req small { color: #6b7b88; }
.ds-wc__ok { padding: 9px 12px; border-radius: 12px; background: #e6f6ef; color: #17895e; font-size: 13px; }
.ds-wc__info { padding: 9px 12px; border-radius: 12px; background: #f6f8fa; color: #33424e; font-size: 13px; }
.ds-wc__tgrid { display: grid; grid-template-columns: 1.3fr 1fr; gap: 20px; align-items: start; }
.ds-wc__prow { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; border-radius: 14px; background: #f6f8fa; }
.ds-wc__prow b { font-size: 14px; }
.ds-wc__pick { display: flex; gap: 8px; margin-top: 6px; }
.ds-wc__sel { height: 34px; border-radius: 10px; border: 0; background: rgb(255 255 255 / .12); color: #fff; padding: 0 10px; font-size: 13px; }
.ds-wc__sel option { color: #0e2433; }
.ds-wc__stop { border-radius: 20px; padding: 18px; display: flex; flex-direction: column; gap: 8px; background: #fde8e8; color: #8a1f1f; font-size: 13px; }
.ds-wc__stop b { font-size: 15px; }
.ds-wc__row { display: grid; grid-template-columns: 1.2fr .7fr 2fr 1.6fr 1.3fr; gap: 12px; padding: 14px 0; border-bottom: 1px solid #eef1f4; align-items: center; font-size: 14px; }
.ds-wc__row.is-head { padding: 12px 0; font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-wc__split { display: flex; flex-direction: column; gap: 6px; }
.ds-wc__bar { display: flex; height: 12px; border-radius: 999px; overflow: hidden; background: #eef1f4; }
.ds-wc__bar i { display: block; height: 100%; }
.ds-wc__tip { font-size: 13px; }
.ds-wc__row .ds-fl__seg button { height: 30px; font-size: 12px; }
.ds-pt__transfer { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 9px 12px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 12px; }
@media (max-width: 1100px) { .ds-wc__tgrid { grid-template-columns: 1fr; } .ds-wc__row { grid-template-columns: 1fr 1fr; } .ds-wc__row.is-head { display: none; } }

/* ───── Part 21 · top-up, truck full, bypass (board 39) ───── */
.ds-ld__early.is-full { background: #fde8e8; color: #8a1f1f; }
.ds-ld__bypass, .ds-ld__citytop { display: flex; flex-wrap: wrap; align-items: center; gap: .4rem .8rem; padding: .7rem .9rem; border-radius: .8rem; font-size: .9rem; }
.ds-ld__bypass { background: #eef6ff; color: #1d5f99; }
.ds-ld__citytop { background: #fff8e1; color: #6b4e00; box-shadow: inset 0 0 0 1px #f6d77a; }
.ds-ld__reasons { display: flex; gap: .4rem; flex-wrap: wrap; }
.ds-sx__citytop { margin: 10px 0; padding: 16px; border-radius: 18px; background: #2a2410; box-shadow: inset 0 0 0 1px #6b5a1c; display: flex; flex-direction: column; gap: 10px; color: #eef3f6; }
.ds-sx__citytop > b { color: #f6d77a; }
.ds-sx__reasons { display: flex; flex-direction: column; gap: 8px; }
.ds-sx__reasons button { height: 46px; border-radius: 12px; background: rgb(255 255 255 / .08); color: #eef3f6; font-weight: 700; text-align: left; padding: 0 14px; }
.ds-pt__top { display: flex; flex-direction: column; gap: 10px; padding: 14px; border-radius: 14px; background: #fff8e1; box-shadow: inset 0 0 0 1px #f6d77a; }
.ds-pt__top > b span { color: #c99a00; }
.ds-pt__topopt { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 12px; text-align: left; color: #0e2433; }
.ds-pt__topopt.is-on { background: #fff; }
.ds-pt__topopt .ds-te__radio { box-shadow: inset 0 0 0 2px #c9a64a; width: 18px; height: 18px; }
.ds-pt__topopt.is-on .ds-te__radio { box-shadow: inset 0 0 0 6px #0e2433; }
.ds-pt__topopt > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-pt__topopt small { color: #6b4e00; font-size: 12px; }
.ds-pt__topopt .ds-cb__pill { background: #fff; color: #6b4e00; }
.ds-pt__topbtns { display: flex; gap: 8px; }
.ds-pt__ok { color: #17895e; font-weight: 700; font-size: 13px; }
.ds-pt__sets { display: flex; flex-direction: column; gap: 6px; padding: 12px 14px; border-radius: 14px; background: #f6f8fa; }
.ds-pt__set { display: flex; justify-content: space-between; align-items: center; gap: 8px; font-size: 13px; padding: 6px 0; border-top: 1px solid #e3e8ec; }
.ds-pt__how { display: flex; gap: 10px; font-size: 13px; color: #33424e; }
.ds-pt__how b { width: 24px; height: 24px; border-radius: 50%; background: #0e2433; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 12px; flex: none; }
.ds-pt__sum .ds-wc__sel { max-width: 15rem; }
.ds-tr__grid { display: grid; grid-template-columns: 1.5fr 1fr; gap: 20px; align-items: start; }
.ds-tr__row { display: grid; grid-template-columns: 1.4fr 2fr; gap: 14px; padding: 14px 0; border-bottom: 1px solid #eef1f4; align-items: center; }
.ds-tr__row.is-head { padding: 12px 0; font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-tr__row .ds-fl__seg button { height: 32px; font-size: 12px; }
.ds-tr__note { padding: 12px 0; }
.ds-tr__reason { display: flex; justify-content: space-between; padding: 8px 12px; border-radius: 12px; background: #f6f8fa; font-size: 14px; }
.ds-ov__row { display: grid; grid-template-columns: .9fr 1.3fr .8fr 1.5fr 1.3fr; gap: 10px; padding: 11px 0; border-bottom: 1px solid #eef1f4; font-size: 13px; align-items: center; }
.ds-ov__row.is-head { font-size: 12px; color: #6b7b88; font-weight: 700; border-bottom-color: #e3e8ec; }
.ds-ov__row > span { display: flex; flex-direction: column; }
.ds-ov__row small { color: #6b7b88; font-size: 12px; }
.ds-ov__row .ds-ad__act { flex-direction: row; }
.ds-ov__bar { display: flex; flex-direction: column; gap: 4px; font-size: 13px; }
@media (max-width: 1100px) { .ds-tr__grid { grid-template-columns: 1fr; } .ds-ov__row { grid-template-columns: 1fr 1fr; } .ds-ov__row.is-head { display: none; } }
.ds-pt__top, .ds-pt__sets { align-self: stretch; align-items: stretch; text-align: left; width: 100%; }
.ds-pt__topopt { width: 100%; }
.ds-pt__topbtns { justify-content: flex-start; }
.ds-ov__row .ds-ad__act { flex-wrap: nowrap; gap: 6px; justify-content: flex-end; }
.ds-ov__row { grid-template-columns: .9fr 1.2fr .7fr 1.4fr 1.6fr; }
.ds-pt__provs { display: flex; flex-direction: column; gap: inherit; }
.ds-ha__grid { display: grid; grid-template-columns: 1fr 1fr 380px; gap: 18px; align-items: start; }
.ds-ha__name { display: flex; align-items: center; gap: 10px; }
.ds-ha__name i { width: 14px; height: 14px; border-radius: 4px; background: var(--hub, #1d6fb8); flex: none; }
.ds-ha__name > span { display: flex; flex-direction: column; }
.ds-ha__chip { background: color-mix(in srgb, var(--hub, #1d6fb8) 12%, #fff); color: color-mix(in srgb, var(--hub, #1d6fb8) 80%, #000); }
.ds-ha__add { display: grid; grid-template-columns: 1fr 1fr 1fr auto; gap: 6px; }
.ds-ha__split { display: flex; height: 14px; border-radius: 999px; overflow: hidden; background: #e8ecef; }
.ds-ha__split i { background: #1d6fb8; }
.ds-ha__split i.is-b { background: #c97a00; }
.ds-ha__req { display: flex; flex-direction: column; gap: 6px; padding: 12px; border-radius: 14px; background: #f6f8fa; }
.ds-ha__ok { padding: 9px 12px; border-radius: 12px; background: #e6f6ef; color: #17895e; font-size: 13px; }
.ds-ha__warn { padding: 9px 12px; border-radius: 12px; background: #fff4d6; color: #6b4e00; font-size: 13px; }
.ds-ha__off { display: flex; flex-direction: column; gap: 8px; padding: 14px 16px; border-radius: 16px; background: #fde8e8; color: #8a1f1f; font-size: 13px; }
.ds-ha__off b { font-size: 14px; }
.ds-ha__btnbad { background: #8a1f1f !important; color: #fff !important; }
@media (max-width: 1200px) { .ds-ha__grid { grid-template-columns: 1fr; } .ds-ha__add { grid-template-columns: 1fr; } }
.ds-hs__grid { display: grid; grid-template-columns: 380px 1fr 380px; gap: 18px; align-items: start; }
.ds-hs__form { display: flex; flex-direction: column; gap: 10px; }
.ds-hs__form label { display: flex; flex-direction: column; gap: 4px; }
.ds-hs__form small { color: #6b7b88; font-weight: 700; font-size: 12px; }
.ds-hs__sug { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 12px; background: #eef6ff; text-align: left; width: 100%; }
.ds-hs__sug.is-off { background: #f6f8fa; opacity: .6; }
.ds-hs__sug i { width: 20px; height: 20px; border-radius: 6px; background: #1d6fb8; color: #fff; display: flex; align-items: center; justify-content: center; font-style: normal; font-size: 13px; flex: none; }
.ds-hs__sug.is-off i { background: #c3ccd4; }
.ds-hs__sug > span { flex: 1; display: flex; flex-direction: column; }
.ds-hs__sug small { color: #6b7b88; font-size: 12px; }
.ds-hs__switch { display: flex; justify-content: space-between; align-items: center; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-hs__sw { width: 44px; height: 24px; border-radius: 999px; background: #c3ccd4; position: relative; }
.ds-hs__sw i { position: absolute; top: 3px; left: 3px; width: 18px; height: 18px; border-radius: 50%; background: #fff; transition: left .15s; }
.ds-hs__sw.is-on { background: #17895e; }
.ds-hs__sw.is-on i { left: 23px; }
@media (max-width: 1200px) { .ds-hs__grid { grid-template-columns: 1fr; } }
.ds-ma__grid { display: grid; grid-template-columns: 1fr 420px; gap: 20px; align-items: start; }
.ds-ma__row { display: flex; justify-content: space-between; padding: 12px 14px; border-radius: 14px; background: #f6f8fa; font-size: 14px; }
.ds-ma__row.is-prov { background: #fff0d1; color: #8a5a00; }
@media (max-width: 1100px) { .ds-ma__grid { grid-template-columns: 1fr; } }
.ds-pt__tabs { display: flex; gap: 8px; border-bottom: 1px solid #dfe5ea; }
.ds-pt__tabs button { height: 44px; padding: 0 16px; display: flex; align-items: center; gap: 8px; font-weight: 800; color: #6b7b88; }
.ds-pt__tabs button.is-on { color: #0e2433; box-shadow: inset 0 -3px 0 #f6be00; }
.ds-pt__tabs button span { padding: 2px 9px; border-radius: 999px; background: #e8ecef; color: #6b7b88; font-size: 12px; }
.ds-pt__tabs button.is-on span { background: #0e2433; color: #fff; }
.ds-pt__sms { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 700; color: #0e2433; text-align: left; }
.ds-pt__sms i { width: 18px; height: 18px; border-radius: 5px; background: #c3ccd4; color: #fff; display: flex; align-items: center; justify-content: center; font-style: normal; font-size: 12px; flex: none; }
.ds-pt__sms.is-on i { background: #1d6fb8; }
.ds-pt__sms small { font-weight: 400; color: #6b7b88; }
.ds-pt__sms:disabled { opacity: .5; }
.ds-pt__smslink { text-decoration: underline; color: inherit; }
.ds-ph__ai { display: flex; gap: 14px; padding: 14px 18px; border-radius: 18px; background: #fff8e1; box-shadow: inset 0 0 0 1px #f6d77a; }
.ds-ph__aitext { display: flex; flex-direction: column; gap: 4px; font-size: 14px; color: #4a3800; }
.ds-ph__why { display: flex; flex-direction: column; gap: 8px; padding: 12px 16px; border-radius: 14px; background: #fff4d6; }
.ds-ph__reasons { display: flex; gap: 6px; flex-wrap: wrap; }
.ds-ph__reasons button { height: 32px; padding: 0 12px; border-radius: 999px; background: #fff; box-shadow: inset 0 0 0 1px #e5c46a; font-size: 13px; font-weight: 700; color: #6b4e00; }
.ds-ph__reasons button.is-cancel { box-shadow: none; background: transparent; }
.ds-ph__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 14px; align-items: start; }
.ds-ph__card { display: flex; flex-direction: column; gap: 10px; padding: 16px 18px; box-shadow: inset 4px 0 0 var(--hub, #1d6fb8), 0 1px 0 #e3e8ec, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-ph__head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.ds-ph__head > span:first-child { display: flex; flex-direction: column; }
.ds-ph__head b { font-size: 17px; }
.ds-ph__head small { color: #6b7b88; font-size: 12px; }
.ds-ph__cities { display: flex; flex-direction: column; gap: 4px; }
.ds-ph__cities > span { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 6px 10px; border-radius: 10px; background: #f6f8fa; font-size: 13px; }
.ds-ph__cities button { font-size: 12px; font-weight: 700; color: #1d6fb8; white-space: nowrap; }
.ds-ph__when { align-self: flex-start; }
.ds-ph__when button { height: 30px; font-size: 12px; }
.ds-ph__part { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-ph__part .ds-ph__head b { font-size: 14px; }
.ds-ph__part small { font-size: 12px; color: #33424e; }
.ds-ph__bar { height: 24px; border-radius: 8px; background: #e3e8ec; overflow: hidden; display: flex; }
.ds-ph__bar i { background: #bfe6d4; display: flex; align-items: center; padding-left: 10px; font-size: 12px; font-weight: 700; font-style: normal; white-space: nowrap; }
.ds-ph__truck { align-self: flex-start; }
.ds-ph__tip { color: #33424e; font-size: 13px; }
.ds-ph__btns { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-ph__done { padding: 9px 12px; border-radius: 10px; background: #eef1f4; color: #33424e; font-size: 13px; font-weight: 700; }
.ds-ph__done.is-made { background: #e6f6ef; color: #17895e; }
.ds-pt__transfer.is-bad { background: #fde8e8; color: #8a1f1f; }
.ds-sms__follow { display: block; margin: -2px 0 6px; padding: 8px 12px; border-radius: 10px; background: #f6f8fa; color: #6b7b88; font-size: 12px; }
.ds-wc__head > span.ds-ha__name:first-child { flex-direction: row; align-items: center; }
.ds-ha__add { grid-template-columns: 1fr 1fr; }
.ds-ha__add .ds-te__btn { justify-self: start; }
.ds-wc__towns .ds-wc__chips { justify-content: flex-start; }
.ds-ph__truck.is-none { background: #eef1f4; color: #6b7b88; }
.ds-tp__lock { display: flex; flex-direction: column; gap: 8px; padding: 14px 16px; border-radius: 14px; background: #f6f8fa; }
.ds-tp__lock.is-ok { background: #eefaf4; box-shadow: inset 0 0 0 1px #bfe6d4; }
.ds-tp__lockhead { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }
.ds-tp__lockhead small, .ds-tp__lock > small { color: #6b7b88; font-size: 12px; }
.ds-tp__check { display: flex; gap: 10px; align-items: center; font-size: 14px; }
.ds-tp__check i { width: 22px; height: 22px; border-radius: 50%; background: #fde8e8; color: #8a1f1f; display: flex; align-items: center; justify-content: center; font-style: normal; font-size: 12px; font-weight: 900; flex: none; }
.ds-tp__check.is-ok i { background: #e6f6ef; color: #17895e; }
.ds-tp__check > span { display: flex; flex-direction: column; }
.ds-tp__check small { color: #6b7b88; font-size: 12px; }
.ds-tl__trip { display: flex; flex-direction: column; gap: 4px; align-items: flex-start; }
.ds-tl__trip b { font-size: 15px; color: #0e2433; }
.ds-tl__trip small, .ds-tl__goes small, .ds-tl__truck small, .ds-tl__boxes small, .ds-tl__status small { color: #6b7b88; font-size: 12px; }
.ds-tl__made { display: inline-flex; align-items: center; height: 22px; padding: 0 8px; border-radius: 999px; font-size: 11px; font-weight: 800; white-space: nowrap; }
.ds-tl__made.is-ai { background: #fff0d1; color: #8a5a00; }
.ds-tl__made.is-plan { background: #e6f4ff; color: #1d5f99; }
.ds-tl__made.is-changed { background: #efeafd; color: #5b3fc4; }
.ds-tl__made.is-manual { background: #eef1f4; color: #33424e; }
.ds-tl__goes { display: flex; flex-direction: column; gap: 2px; min-width: 180px; }
.ds-tl__goes > span { display: flex; align-items: center; gap: 6px; }
.ds-tl__goes i { width: 8px; height: 8px; border-radius: 50%; flex: none; }
.ds-tl__truck { display: flex; align-items: center; gap: 8px; }
.ds-tl__truck > i { width: 32px; height: 32px; border-radius: 50%; background: #eef1f4; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 800; font-style: normal; flex: none; }
.ds-tl__truck > span { display: flex; flex-direction: column; }
.ds-tl__boxes { display: flex; flex-direction: column; gap: 5px; min-width: 190px; }
.ds-tl__bar { height: 8px; border-radius: 999px; background: #e8ecef; display: flex; overflow: hidden; }
.ds-tl__bar i { background: #17895e; }
.ds-tl__bar i.is-l { background: #8fd3b4; }
.ds-tl__status { display: flex; flex-direction: column; gap: 3px; align-items: flex-start; }
.ds-tl__pill { display: inline-flex; align-items: center; height: 26px; padding: 0 10px; border-radius: 999px; font-size: 12px; font-weight: 800; white-space: nowrap; background: #eef1f4; color: #33424e; }
.ds-tl__pill.is-planned, .ds-tl__pill.is-ready { background: #eef6ff; color: #1d5f99; }
.ds-tl__pill.is-loading, .ds-tl__pill.is-back { background: #fff4d6; color: #8a5a00; }
.ds-tl__pill.is-road { background: #e6f4ff; color: #1d5f99; }
.ds-tl__pill.is-closed { background: #e6f6ef; color: #17895e; }
.ds-tl__det { display: flex; flex-direction: column; gap: 14px; }
.ds-tl__detpills { display: flex; gap: 6px; }
.ds-tl__how { display: flex; flex-direction: column; gap: 8px; padding: 14px; border-radius: 14px; background: #fff8e1; }
.ds-tl__how.is-manual { background: #f6f8fa; }
.ds-tl__how > span { display: flex; gap: 8px; font-size: 13px; color: #33424e; }
.ds-tl__how em { width: 18px; flex: none; font-style: normal; }
.ds-tl__facts { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.ds-tl__facts > span { display: flex; flex-direction: column; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-tl__facts small { color: #6b7b88; font-size: 12px; }
.ds-tl__facts b { font-size: 14px; }
.ds-tl__cities { display: flex; flex-direction: column; gap: 6px; }
.ds-tl__cities > span { display: flex; flex-wrap: wrap; gap: 6px; }
.ds-tl__cities > b small { float: right; font-weight: 600; color: #6b7b88; }
/* board 47b: 4 columns, top to bottom then the next column */
.ds-tl__cities ul { margin: 0; padding: 12px 14px 12px 30px; list-style: disc; columns: 4; column-gap: 20px; font-size: 13px; font-weight: 700; background: #f8fafb; border-radius: 14px; }
.ds-tl__cities li { break-inside: avoid; padding: 3px 0; line-height: 1.3; }
.dark .ds-tl__cities ul { background: rgb(255 255 255 / .04); }
@media (max-width: 640px) { .ds-tl__cities ul { columns: 2; } }
.ds-tl__cities li::marker { color: #6b7b88; }
.ds-tl__cities i { height: 28px; padding: 0 10px; border-radius: 999px; background: #eef6ff; color: #1d5f99; font-size: 13px; font-weight: 700; font-style: normal; display: flex; align-items: center; }
.ds-tl__btns { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-tl__hint { color: #6b7b88; font-size: 12px; }
.ds-tl__no { font-size: 15px; font-weight: 800; color: #0e2433; text-decoration: none; }
.ds-tl__no:hover { color: #1d6fb8; text-decoration: underline; }

/* ── Part 22e · New trip and Edit trip (boards 44, 44b) ─────────────────────────────── */
.ds-et__head { display: flex; flex-direction: column; gap: 6px; }
.ds-et__head .ds-te__link { font-size: 13px; font-weight: 700; text-decoration: none; }
.ds-et__line { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.ds-et__line .ds-tl__made { height: 26px; font-size: 12px; padding: 0 10px; }
.ds-et__tiles { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 12px; }
.ds-et__tile { gap: 2px; padding: 12px 16px; }
.ds-et__tile small { color: #6b7b88; font-size: 13px; }
.ds-et__tile b { font-size: 24px; font-weight: 900; letter-spacing: -0.01em; }
.ds-et__tile.is-ok b { color: #17895e; }
.ds-et__tile.is-bad b { color: #c0392b; }
.ds-et__tile.is-warn b { color: #8a5a00; }
@media (max-width: 900px) { .ds-et__tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
.dark .ds-et__tile small { color: #9aa7b2; }

.ds-nt { display: flex; flex-direction: column; gap: 18px; }
.ds-nt__top { display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; flex-wrap: wrap; }
.ds-nt__top .ds-te__link { text-decoration: none; }
.ds-nt__plan { height: 40px; padding: 0 16px; border-radius: 10px; font-weight: 800; background: #fff4d6; color: #8a5a00; display: inline-flex; align-items: center; text-decoration: none; }
.ds-nt__grid { display: grid; grid-template-columns: minmax(0, 1fr) 340px; gap: 20px; align-items: start; }
.ds-nt__steps { display: flex; flex-direction: column; gap: 16px; min-width: 0; }
.ds-nt__card { gap: 14px; padding: 20px; }
.ds-nt__h { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.ds-nt__h i { width: 26px; height: 26px; border-radius: 999px; background: #0e2433; color: #fff; font-style: normal; font-size: 13px; font-weight: 800; display: inline-flex; align-items: center; justify-content: center; }
.ds-nt__h b { font-size: 17px; }
.ds-nt__h small { color: #6b7b88; font-size: 13px; }
.ds-nt__two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.ds-nt__two label, .ds-nt__when label { display: flex; flex-direction: column; gap: 6px; font-weight: 700; }
.ds-nt__two label > small, .ds-nt__when label > small { color: #6b7b88; font-size: 13px; }
.ds-nt__opt { display: flex; gap: 12px; align-items: center; text-align: left; padding: 14px 16px; border: 0; border-radius: 14px; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; cursor: pointer; color: #0e2433; }
.ds-nt__opt em { font-style: normal; font-size: 22px; width: 40px; height: 40px; border-radius: 12px; background: #fff; display: flex; align-items: center; justify-content: center; flex: none; }
.ds-nt__opt span { display: flex; flex-direction: column; gap: 2px; }
.ds-nt__opt small { color: #6b7b88; font-size: 13px; }
.ds-nt__opt.is-on { background: #eef6ff; box-shadow: inset 0 0 0 2px #1d6fb8; }
.ds-nt__chips { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-nt__chip { height: 36px; padding: 0 14px; border: 0; border-radius: 999px; background: #f1f4f6; color: #33424e; font-weight: 700; font-size: 14px; cursor: pointer; display: inline-flex; align-items: center; gap: 8px; }
.ds-nt__chip i { width: 10px; height: 10px; border-radius: 3px; }
.ds-nt__chip.is-on { background: #0e2433; color: #fff; }
.ds-nt__trucks { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 10px; }
.ds-nt__truck { display: flex; flex-direction: column; gap: 4px; text-align: left; padding: 12px 14px; border: 0; border-radius: 14px; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; cursor: pointer; color: #0e2433; }
.ds-nt__truck small { color: #6b7b88; font-size: 12px; }
.ds-nt__truck.is-on { background: #eef6ff; box-shadow: inset 0 0 0 2px #1d6fb8; }
.ds-nt__truck.is-off { opacity: .5; cursor: not-allowed; }
.ds-nt__trow { display: flex; justify-content: space-between; align-items: center; gap: 6px; }
.ds-nt__trow em { font-style: normal; font-size: 11px; font-weight: 800; padding: 2px 8px; border-radius: 999px; background: #eef1f4; color: #33424e; white-space: nowrap; }
.ds-nt__trow em.is-free { background: #e6f6ef; color: #17895e; }
.ds-nt__trow em.is-busy { background: #fff4d6; color: #8a5a00; }
.ds-nt__crew { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-nt__when { display: grid; grid-template-columns: 1.3fr 1fr 1fr; gap: 14px; align-items: start; }
.ds-nt__field { display: flex; flex-direction: column; gap: 4px; }
.ds-nt__field em { font-style: normal; font-size: 12px; font-weight: 700; }
.ds-nt__field em.is-ok { color: #17895e; }
.ds-nt__field em.is-bad { color: #c0392b; }
.ds-nt__err { color: #c0392b; font-weight: 700; }
.ds-nt__sum { gap: 10px; padding: 20px; position: sticky; top: 84px; }
.ds-nt__sumh { font-size: 17px; }
.ds-nt__row { display: flex; justify-content: space-between; gap: 10px; font-size: 14px; padding: 4px 0; border-bottom: 1px solid #eef1f4; }
.ds-nt__row > span { color: #6b7b88; }
.ds-nt__row b { text-align: right; }
.ds-nt__space { display: flex; flex-direction: column; gap: 6px; padding: 6px 0; }
.ds-nt__space small { color: #6b7b88; font-size: 12px; }
.ds-nt__go, .ds-nt__only { height: 44px; border: 0; border-radius: 12px; font-weight: 800; font-size: 15px; cursor: pointer; }
.ds-nt__go { background: #e5b94a; color: #0e2433; }
.ds-nt__only { background: #fff; box-shadow: inset 0 0 0 1px #dfe5ea; color: #33424e; }
.ds-nt__go:disabled, .ds-nt__only:disabled { opacity: .6; }
.ds-nt__cancel { text-align: center; color: #6b7b88; font-weight: 700; text-decoration: none; font-size: 14px; }
@media (max-width: 1100px) { .ds-nt__grid { grid-template-columns: 1fr; } .ds-nt__sum { position: static; } .ds-nt__when, .ds-nt__two { grid-template-columns: 1fr; } }
.dark .ds-nt__opt, .dark .ds-nt__truck, .dark .ds-nt__chip { background: rgb(255 255 255 / .06); color: inherit; box-shadow: inset 0 0 0 1px rgb(255 255 255 / .1); }
.dark .ds-nt__opt.is-on, .dark .ds-nt__truck.is-on { box-shadow: inset 0 0 0 2px #5aa7e6; }
.dark .ds-nt__chip.is-on { background: #fff; color: #0e2433; }
.dark .ds-nt__row { border-color: rgb(255 255 255 / .08); }

/* ── New boxes since the trips were made (board 45b) ── */
.ds-nb { display: flex; flex-direction: column; gap: 14px; }
.ds-nb__empty { align-items: flex-start; }
.ds-nb__empty small { color: #6b7b88; }
.ds-nb__apply { flex-direction: row; align-items: center; gap: 14px; box-shadow: inset 0 0 0 2px #e5b94a, 0 12px 32px -18px rgb(14 36 51 / .25); }
.ds-nb__apply > span { flex: 1; display: flex; flex-direction: column; gap: 3px; }
.ds-nb__apply b { font-size: 17px; }
.ds-nb__apply small { color: #6b7b88; }
.ds-nb__apply .ds-nt__go { padding: 0 22px; }
.ds-nb__list { padding: 0; gap: 0; overflow: hidden; }
.ds-nb__row { display: grid; grid-template-columns: 1.3fr 90px 1.8fr 1.6fr; gap: 14px; align-items: center; padding: 14px 18px; border-top: 1px solid #f1f4f6; }
.ds-nb__head { border-top: 0; font-size: 12px; font-weight: 800; color: #6b7b88; padding: 12px 18px; }
.ds-nb__city { display: flex; flex-direction: column; }
.ds-nb__city small { color: #6b7b88; }
.ds-nb__n { font-size: 18px; }
.ds-nb__trip { display: flex; flex-direction: column; gap: 6px; }
.ds-nb__tline { display: flex; gap: 8px; align-items: center; }
.ds-nb__pill { font-size: 11px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: #eef1f4; color: #33424e; }
.ds-nb__pill.is-open { background: #e6f6ef; color: #17895e; }
.ds-nb__pill.is-full { background: #fff1c2; color: #8a5a00; }
.ds-nb__space { display: flex; align-items: center; gap: 8px; }
.ds-nb__space .ds-tl__bar { flex: 1; }
.ds-nb__space .ds-tl__bar i { background: #8fd3b4; }
.ds-nb__space small { font-weight: 700; color: #33424e; white-space: nowrap; }
.ds-nb__acts { display: flex; gap: 8px; justify-content: flex-end; flex-wrap: wrap; }
.ds-nb__btn { height: 36px; padding: 0 14px; font-size: 13px; }
.ds-nb__btn.is-anyway { color: #8a5a00; box-shadow: inset 0 0 0 1px #e8c873; }
.ds-nt__go.ds-nb__btn.is-anyway { background: #f2c46b; color: #0e2433; box-shadow: none; }
.ds-nb__modal { position: fixed; inset: 0; z-index: 50; background: rgb(14 36 51 / .35); display: flex; align-items: center; justify-content: center; padding: 20px; }
.ds-nb__pick { width: min(640px, 100%); max-height: calc(100vh - 40px); gap: 12px; }
.ds-nb__ph { display: flex; flex-direction: column; gap: 3px; }
.ds-nb__ph b { font-size: 19px; }
.ds-nb__ph small { color: #6b7b88; }
.ds-nb__meter { display: flex; flex-direction: column; gap: 6px; }
.ds-nb__meter .ds-tl__bar { height: 10px; }
.ds-nb__meter i.is-used { background: #b8c3cc; }
.ds-nb__meter i.is-new { background: #17895e; }
.ds-nb__meter i.is-over { background: #e2a23b; }
.ds-nb__meter small { font-weight: 800; color: #17895e; }
.ds-nb__meter small.is-over { color: #8a5a00; }
.ds-nb__items { display: flex; flex-direction: column; max-height: 340px; overflow: auto; border-radius: 12px; box-shadow: inset 0 0 0 1px #e3e8ec; }
.ds-nb__item { display: flex; align-items: center; gap: 12px; padding: 11px 14px; border: 0; border-bottom: 1px solid #f1f4f6; background: #fff; text-align: left; cursor: pointer; font: inherit; color: inherit; }
.ds-nb__item.is-on { background: #fffbea; }
.ds-nb__item > span { flex: 1; display: flex; flex-direction: column; }
.ds-nb__item small { color: #6b7b88; }
.ds-nb__check { width: 20px; height: 20px; border-radius: 6px; flex: none; display: flex; align-items: center; justify-content: center; font-style: normal; font-size: 12px; font-weight: 900; color: #fff; background: #fff; box-shadow: inset 0 0 0 1px #c3ccd4; }
.ds-nb__item.is-on .ds-nb__check { background: #c99a00; box-shadow: none; }
.ds-nb__tag { font-style: normal; font-size: 11px; font-weight: 800; padding: 3px 9px; border-radius: 999px; background: #eef1f4; color: #33424e; white-space: nowrap; }
.ds-nb__tag.is-combo { background: #f3e9ff; color: #6a2fb0; }
.ds-nb__warn { display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border-radius: 12px; background: #fff1c2; color: #7a5600; font-size: 13px; font-weight: 700; }
.ds-nb__foot { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.ds-nb__foot > span { display: flex; gap: 8px; align-items: center; }
.dark .ds-nb__item { background: transparent; }
.dark .ds-nb__item.is-on { background: rgb(201 154 0 / .12); }
@media (max-width: 900px) { .ds-nb__row { grid-template-columns: 1fr 60px; } .ds-nb__trip, .ds-nb__acts { grid-column: 1 / -1; } }

/* ── Scan app · Receive truck: the box goes on a hub trip (board 45d) ── */
.ds-ws__trip { display: flex; flex-direction: column; gap: 6px; padding: 14px; border-radius: 16px; background: #d9f2e6; color: #0e2433; }
.ds-ws__trip.is-new { background: #fff1c2; }
.ds-ws__trip.is-anyway { background: #ffe2b8; }
.ds-ws__trip b.ds-ws__to { font-size: 20px; }
.ds-ws__trip small { font-size: 13px; }
.ds-ws__trip button { height: 40px; border: 0; border-radius: 12px; background: #fff; font: inherit; font-weight: 800; color: #8a5a00; cursor: pointer; }

/* ── Plan trips: Create this trip (board 46) ── */
.ds-pt__one { display: flex; justify-content: flex-end; align-items: center; gap: 12px; border-top: 1px solid #eef1f4; padding-top: 12px; }
.ds-pt__one .ds-nt__go { height: 38px; padding: 0 18px; font-size: 13px; }
.ds-pt__one.is-made { justify-content: space-between; }
.ds-pt__madeone { font-size: 13px; font-weight: 800; padding: 7px 12px; border-radius: 999px; background: #e6f6ef; color: #17895e; }
.ds-pt__trip.is-made { box-shadow: inset 0 0 0 2px #8fd3b4, 0 12px 32px -18px rgb(14 36 51 / .25); }
.dark .ds-pt__one { border-color: rgb(255 255 255 / .08); }

/* ── AI settings · Who can use AI (board 48) ── */
.ds-aa__tabs { display: flex; gap: 6px; margin-bottom: 14px; }
.ds-aa__tabs button { height: 36px; padding: 0 14px; border: 0; border-radius: 10px; background: transparent; font: inherit; font-weight: 800; color: #33424e; cursor: pointer; }
.ds-aa__tabs button.is-on { background: #0e2433; color: #fff; }
.ds-aa { display: grid; grid-template-columns: minmax(0, 1fr) 420px; gap: 18px; align-items: start; }
.ds-aa__main, .ds-aa__side { display: flex; flex-direction: column; gap: 14px; }
.ds-aa__card { display: flex; flex-direction: column; gap: 12px; }
.ds-aa__h { display: flex; flex-direction: column; gap: 2px; }
.ds-aa__h b { font-size: 16px; }
.ds-aa__h small, .ds-aa__add > small, .ds-aa__f small { color: #6b7b88; }
.ds-aa__modes { display: flex; gap: 8px; flex-wrap: wrap; }
.ds-aa__modes button { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; padding: 10px 14px; border: 0; border-radius: 12px; background: #fff; box-shadow: inset 0 0 0 1px #d3dae0; font: inherit; text-align: left; cursor: pointer; color: inherit; }
.ds-aa__modes button small { opacity: .75; }
.ds-aa__modes button.is-on { background: #fff7dc; box-shadow: inset 0 0 0 2px #e5b94a; }
.ds-aa__chips { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.ds-aa__chip { height: 32px; padding: 0 6px 0 12px; border-radius: 999px; background: #fff7dc; box-shadow: inset 0 0 0 1px #ecd58a; display: inline-flex; align-items: center; gap: 6px; font-weight: 700; font-size: 13px; }
.ds-aa__chip small { color: #6b7b88; font-weight: 600; }
.ds-aa__chip button { width: 22px; height: 22px; border: 0; border-radius: 50%; background: #fff; cursor: pointer; font-weight: 900; color: #8a5a00; }
.ds-aa__chips.is-small .ds-aa__chip { height: 28px; font-size: 12px; }
.ds-aa__warn { color: #8a5a00; font-weight: 700; }
.ds-aa__add { display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border-radius: 12px; background: #f6f8fa; }
.ds-aa__sel { height: 34px; border-radius: 10px; border: 0; box-shadow: inset 0 0 0 1px #d3dae0; padding: 0 10px; font: inherit; font-size: 13px; font-weight: 700; background: #fff; max-width: 100%; }
.ds-aa__sel.is-all { background: #e6f6ef; box-shadow: inset 0 0 0 1px #8fd3b4; }
.ds-aa__sel.is-own { background: #fff1c2; box-shadow: inset 0 0 0 1px #e8c873; }
.ds-aa__sel.is-mini { height: 28px; font-size: 12px; }
.ds-aa__groups { display: flex; flex-wrap: wrap; gap: 6px; }
.ds-aa__groups button { height: 30px; padding: 0 12px; border: 0; border-radius: 10px; background: #fff; box-shadow: inset 0 0 0 1px #b9cfe6; color: #1d5f99; font: inherit; font-size: 12px; font-weight: 800; cursor: pointer; }
.ds-aa__list { padding: 0 !important; overflow: hidden; gap: 0; }
.ds-aa__row { display: grid; grid-template-columns: 1.5fr 1.1fr 1.8fr; gap: 12px; align-items: center; padding: 9px 18px; border-top: 1px solid #f3f5f7; }
.ds-aa__head { border-top: 0; font-size: 12px; font-weight: 800; color: #6b7b88; padding: 12px 18px; }
.ds-aa__f { display: flex; flex-direction: column; }
.ds-aa__where { color: #33424e; }
.ds-aa__who { display: flex; flex-direction: column; gap: 6px; align-items: flex-start; }
.ds-aa__fixed { font-size: 12px; font-weight: 700; color: #6b7b88; }
.ds-aa__verdict { padding: 10px 12px; border-radius: 12px; font-size: 13px; font-weight: 700; background: #fff1c2; color: #7a5600; }
.ds-aa__verdict.is-ok { background: #e6f6ef; color: #17895e; }
.ds-aa__prev { display: flex; flex-direction: column; gap: 6px; padding: 10px 12px; border-radius: 12px; background: #f3f5f7; color: #6b7b88; font-size: 13px; }
.ds-aa__prev.is-ai { background: #fff7dc; color: #0e2433; }
.ds-aa__prev em { font-style: normal; color: #6b7b88; padding: 6px 10px; border-radius: 10px; background: #fff; }
.ds-aa__spot { display: flex; justify-content: space-between; font-size: 13px; padding: 4px 0; border-bottom: 1px solid #f3f5f7; }
.ds-aa__spot b { color: #8a1f1f; }
.ds-aa__spot b.is-ok { color: #17895e; }
.dark .ds-aa__modes button, .dark .ds-aa__sel, .dark .ds-aa__groups button { background: transparent; }
@media (max-width: 1100px) { .ds-aa { grid-template-columns: 1fr; } }
.ds-pt__noai { color: #6b7b88; font-size: 14px; }

/* ── Warehouse sections: province or city, optional spots (boards 50, 50b) ── */
.ds-ws__row { grid-template-columns: 7.5rem 1.1fr 0.9fr 1.2fr 2.4fr 2rem; }
.ds-ws__row.has-spots { grid-template-columns: 7.5rem 1fr 0.9fr 1.1fr 2.2fr 1.6fr 2rem; min-width: 72rem; }
.ds-ws__row.is-view { grid-template-columns: 4rem 1.3fr 2fr 6rem 1.6fr; }
.ds-ws__row { align-items: start; }
.ds-ws__by { display: flex; justify-content: flex-end; margin-bottom: 0.5rem; }
.ds-ws__by > span { display: flex; flex-direction: column; gap: 4px; align-items: flex-end; }
.ds-ws__by small { font-weight: 800; color: #6b7b88; }
.ds-ws__seg { display: flex; padding: 4px; border-radius: 12px; background: #fff; box-shadow: inset 0 0 0 1px #d3dae0; }
.ds-ws__seg button { height: 34px; padding: 0 14px; border: 0; border-radius: 9px; font: inherit; font-size: 13px; font-weight: 800; cursor: pointer; background: transparent; color: #33424e; }
.ds-ws__seg button.is-on { background: #0e2433; color: #fff; }
.ds-ws__citynote { padding: 10px 14px; border-radius: 12px; background: #eef6ff; color: #1d5f99; font-size: 13px; font-weight: 700; margin-bottom: 0.75rem; }
.ds-ws__places { position: relative; display: block; }
.ds-ws__field { min-height: 40px; border-radius: 10px; box-shadow: inset 0 0 0 1px #d3dae0; background: #fff; display: flex; flex-wrap: wrap; align-items: center; gap: 6px; padding: 6px 8px; }
.ds-ws__field.is-open { box-shadow: inset 0 0 0 2px #1d6fb8; }
.ds-ws__chip { height: 28px; padding: 0 4px 0 10px; border-radius: 8px; background: #eef6ff; color: #1d5f99; font-size: 13px; font-weight: 800; display: inline-flex; align-items: center; gap: 4px; }
.ds-ws__chip.is-city { background: #eefaf3; color: #17895e; }
.ds-ws__chip button, .ds-ws__spot button { width: 22px; height: 22px; border: 0; border-radius: 6px; background: transparent; color: inherit; font: inherit; font-weight: 900; cursor: pointer; }
.ds-ws__add { flex: 1; min-width: 120px; height: 28px; border: 0; background: transparent; text-align: left; font: inherit; font-size: 13px; color: #6b7b88; cursor: pointer; }
.ds-ws__pop { position: absolute; top: calc(100% + 6px); left: 0; right: 0; z-index: 30; background: #fff; border-radius: 12px; box-shadow: 0 24px 48px -16px rgb(14 36 51 / .4), inset 0 0 0 1px #e3e8ec; display: flex; flex-direction: column; overflow: hidden; min-width: 18rem; }
.ds-ws__pop input { height: 40px; border: 0; border-bottom: 1px solid #eef1f4; padding: 0 12px; font: inherit; background: #fff; }
.ds-ws__opts { max-height: 300px; overflow: auto; display: flex; flex-direction: column; }
.ds-ws__opts button { display: flex; flex-direction: column; align-items: flex-start; gap: 1px; padding: 9px 12px; border: 0; border-bottom: 1px solid #f5f7f9; background: #fff; font: inherit; text-align: left; cursor: pointer; color: inherit; }
.ds-ws__opts button:hover { background: #f6f8fa; }
.ds-ws__opts small { color: #8a5a00; font-weight: 700; }
.ds-ws__none { padding: 12px; color: #6b7b88; }
.ds-ws__done { height: 38px; border: 0; border-top: 1px solid #eef1f4; background: #f6f8fa; font: inherit; font-weight: 800; cursor: pointer; }
.ds-ws__new { color: #1d5f99; }
.ds-ws__spots { display: flex; flex-direction: column; gap: 6px; }
.ds-ws__spotsw { display: flex; align-items: center; gap: 8px; }
.ds-ws__spotsw small { font-weight: 800; color: #33424e; }
.ds-ws__spotlist { display: flex; flex-wrap: wrap; gap: 4px; align-items: center; }
.ds-ws__spot { height: 26px; padding: 0 2px 0 8px; border-radius: 7px; background: #f3f5f7; box-shadow: inset 0 0 0 1px #d3dae0; font-size: 12px; font-weight: 800; display: inline-flex; align-items: center; }
.ds-ws__addspot { height: 26px; padding: 0 10px; border: 0; border-radius: 7px; background: #fff; box-shadow: inset 0 0 0 1px #b9cfe6; color: #1d5f99; font: inherit; font-size: 12px; font-weight: 800; cursor: pointer; }
.ds-ws__toggle.is-new { margin-top: 0.6rem; padding: 10px; border-radius: 12px; background: #f4f9ff; box-shadow: inset 0 0 0 1px #b9cfe6; }
.ds-ws__newpill { font-style: normal; font-size: 11px; font-weight: 800; padding: 2px 8px; border-radius: 999px; background: #e8f1fb; color: #1d5f99; margin-left: 4px; }
.ds-ws__spotnote { color: #1d5f99; }
.dark .ds-ws__field, .dark .ds-ws__pop, .dark .ds-ws__pop input, .dark .ds-ws__opts button, .dark .ds-ws__seg { background: rgb(255 255 255 / .04); }
/* Scan app · unload: optional spot (board 50) */
.ds-sx__spoth { display: block; font-size: 13px; color: #9fb0bc; font-weight: 800; margin-top: 10px; }
.ds-sx__spots { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 6px; }
.ds-sx__spots button { height: 54px; border: 0; border-radius: 14px; background: rgb(255 255 255 / .08); color: #fff; font: inherit; font-weight: 900; font-size: 18px; cursor: pointer; }
.ds-sx__skip { width: 100%; height: 46px; margin-top: 8px; border: 0; border-radius: 14px; background: rgb(255 255 255 / .06); color: #c8d3dc; font: inherit; font-weight: 800; cursor: pointer; }

/* Scan app · Pick boxes (board 49) */
.ds-pk__mine { display: flex; flex-direction: column; gap: 0.4rem; width: 100%; padding: 0.9rem; border-radius: 1.2rem; text-align: left; color: inherit; background: rgb(246 190 0 / .14); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .5); }
.ds-pk__mine small { color: #9fb0bc; font-size: 0.8rem; }
.ds-pk__row { display: flex; justify-content: space-between; align-items: center; }
.ds-pk__row b { font-size: 1.15rem; }
.ds-pk__row em { font-style: normal; font-size: 0.75rem; font-weight: 800; color: var(--sa-gold); }
.ds-pk__bar { height: 6px; border-radius: 99px; background: rgb(255 255 255 / .1); overflow: hidden; }
.ds-pk__bar i { display: block; height: 100%; background: var(--sa-ok); }
.ds-pk__open { display: flex; align-items: center; gap: 0.6rem; padding: 0.75rem 0.9rem; border-radius: 1.2rem; background: rgb(255 255 255 / .05); }
.ds-pk__open > span { flex: 1; display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.ds-pk__open small { color: #9fb0bc; font-size: 0.8rem; }
.ds-pk__open button { height: 2.5rem; padding: 0 0.9rem; border-radius: 0.75rem; background: var(--sa-gold); color: #0e2433; font-weight: 900; flex: none; }
.ds-pk__foot { display: block; color: #7f93a1; font-size: 0.78rem; line-height: 1.45; }
.ds-pk__list { display: flex; flex-direction: column; gap: 0.5rem; }
.ds-pk__group { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.65rem 0.75rem; border-radius: 0.9rem; background: rgb(255 255 255 / .05); }
.ds-pk__gh { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
.ds-pk__gh b { font-size: 0.9rem; }
.ds-pk__gh b i { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 6px; }
.ds-pk__gh small { font-weight: 800; color: #9fb0bc; }
.ds-pk__gh small.is-done { color: var(--sa-ok); }
.ds-pk__boxes { display: flex; flex-wrap: wrap; gap: 5px; }
.ds-pk__box { height: 28px; padding: 0 9px; border-radius: 8px; font-size: 0.78rem; font-weight: 800; display: inline-flex; align-items: center; gap: 5px; background: rgb(255 255 255 / .08); color: #fff; }
.ds-pk__box small { font-weight: 700; opacity: .75; font-size: 0.68rem; }
.ds-pk__box.is-combo { box-shadow: inset 0 0 0 1px rgb(90 168 255 / .7); }
.ds-pk__box.is-picked { background: rgb(52 195 143 / .16); color: #7fe0b8; }
.ds-pk__box.is-mine { background: rgb(52 195 143 / .3); color: #fff; }
.ds-pk__box.is-missing { background: rgb(240 169 59 / .2); color: #f3c98a; }
.ds-pk__hit { display: flex; justify-content: space-between; align-items: center; }
.ds-pk__hit small { font-weight: 800; color: #c8d3dc; }
.ds-pk__sheet strong { font-size: 1.2rem; }
.ds-pk__sheet.is-ok strong { color: #7fe0b8; }
.ds-pk__sheet.is-warn strong { color: #f3c98a; }
.ds-pk__sheet.is-bad strong { color: #ff9d93; }
.ds-pk__undo { height: 2.6rem; border-radius: 0.8rem; background: #fff; color: #8a1f1f; font-weight: 800; }
.ds-pk__ready { display: flex; flex-direction: column; gap: 0.45rem; padding: 0.9rem; border-radius: 1.1rem; background: rgb(52 195 143 / .14); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .45); }
.ds-pk__ready b { color: #7fe0b8; font-size: 1.05rem; }
.ds-pk__ready span { color: #c8d3dc; font-size: 0.88rem; }

/* Picking (office, board 49) */
.ds-pg { display: flex; flex-direction: column; gap: 1rem; }
.ds-pg__card { background: #fff; border-radius: 1rem; box-shadow: 0 1px 0 #e3e8ec, 0 12px 32px -20px rgb(14 36 51 / .25); overflow: hidden; }
.dark .ds-pg__card { background: rgb(255 255 255 / .04); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .08); }
.ds-pg__head, .ds-pg__row { display: grid; grid-template-columns: 150px 1.1fr 1.6fr 1.3fr 140px; gap: 12px; padding: 11px 16px; align-items: center; }
.ds-pg__head { font-size: 12px; font-weight: 800; color: #6b7b88; border-bottom: 1px solid #eef1f4; }
.ds-pg__row { border-bottom: 1px solid #f3f5f7; }
.dark .ds-pg__head, .dark .ds-pg__row { border-color: rgb(255 255 255 / .06); }
.ds-pg__trip { display: flex; flex-direction: column; }
.ds-pg__trip b { font-size: 15px; }
.ds-pg__trip small, .ds-pg__secs { color: #6b7b88; font-size: 12px; }
.ds-pg__pickers { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; position: relative; }
.ds-pg__chip { height: 28px; padding: 0 5px 0 10px; border-radius: 999px; background: #fff7dc; box-shadow: inset 0 0 0 1px #ecd58a; display: inline-flex; align-items: center; gap: 5px; font-size: 12px; font-weight: 800; color: #0e2433; }
.ds-pg__chip button { width: 20px; height: 20px; border-radius: 50%; background: #fff; font-weight: 900; color: #8a5a00; }
.ds-pg__add { height: 28px; padding: 0 10px; border-radius: 10px; font-size: 12px; font-weight: 800; box-shadow: inset 0 0 0 1px #b9cfe6; color: #1d5f99; background: #fff; }
.ds-pg__none { color: #8a5a00; font-weight: 700; font-size: 12px; }
.ds-pg__sug { width: 100%; display: flex; gap: 6px; align-items: center; padding: 6px 8px; border-radius: 10px; background: #fff7dc; color: #0e2433; }
.ds-pg__sug small { flex: 1; font-weight: 700; }
.ds-pg__sug small span { color: #6b7b88; font-weight: 600; }
.ds-pg__sug button { height: 26px; padding: 0 12px; border-radius: 10px; background: #e5b94a; font-size: 12px; font-weight: 800; color: #0e2433; }
.ds-pg__pop { position: absolute; z-index: 30; top: 32px; left: 0; width: 240px; max-height: 260px; overflow: auto; background: #fff; border-radius: 12px; box-shadow: 0 18px 40px -16px rgb(14 36 51 / .45), inset 0 0 0 1px #e3e8ec; padding: 6px; display: flex; flex-direction: column; }
.dark .ds-pg__pop { background: #1b2a36; }
.ds-pg__pop button { text-align: left; padding: 7px 10px; border-radius: 8px; font-size: 13px; display: flex; justify-content: space-between; gap: 8px; }
.ds-pg__pop button:hover { background: #f3f5f7; }
.dark .ds-pg__pop button:hover { background: rgb(255 255 255 / .06); }
.ds-pg__pop small { color: #6b7b88; }
.ds-pg__prog { display: flex; flex-direction: column; gap: 5px; }
.ds-pg__prog > span:first-child { height: 8px; border-radius: 99px; background: #eef1f4; overflow: hidden; }
.ds-pg__prog > span:first-child i { display: block; height: 100%; background: #17895e; }
.ds-pg__prog > small { font-weight: 700; color: #33424e; font-size: 12px; }
.dark .ds-pg__prog > small { color: #c8d3dc; }
.ds-pg__miss { color: #8a5a00; font-weight: 700; font-size: 12px; display: flex; flex-wrap: wrap; gap: 4px; align-items: center; }
.ds-pg__miss button { font-size: 11px; font-weight: 800; color: #1d5f99; text-decoration: underline; }
.ds-pg__st { justify-self: start; height: 26px; padding: 0 10px; border-radius: 999px; font-size: 12px; font-weight: 800; display: inline-flex; align-items: center; }
.ds-pg__st.is-ready { background: #e6f6ef; color: #17895e; }
.ds-pg__st.is-picking { background: #e8f1fb; color: #1d5f99; }
.ds-pg__st.is-wait { background: #fff1c2; color: #8a5a00; }
.ds-pg__log { padding: 14px 16px; display: flex; flex-direction: column; gap: 4px; }
.ds-pg__log > span { display: flex; gap: 10px; font-size: 13px; padding: 3px 0; border-bottom: 1px solid #f3f5f7; }
.dark .ds-pg__log > span { border-color: rgb(255 255 255 / .06); }
.ds-pg__log small { color: #6b7b88; width: 64px; flex: none; }
.ds-pg__empty { padding: 28px 16px; color: #6b7b88; text-align: center; }
@media (max-width: 900px) { .ds-pg__head { display: none; } .ds-pg__row { grid-template-columns: 1fr; } }

/* Pick boxes: a shorter camera, the pick list under it */
.ds-sa__scan.is-pick { display: flex; flex-direction: column; padding-bottom: 2rem; }
.ds-sa__scan.is-pick .ds-sa__cam { position: relative; inset: auto; height: 50dvh; min-height: 22rem; flex: none; }
.ds-sa__scan.is-pick .ds-sa__frame { top: 42%; height: min(30vw, 7rem); }
.ds-sa__scan.is-pick > :not(.ds-sa__cam):not(.ds-sa__bar):not(.ds-sa__sheet) { margin: 0.75rem 1rem 0; }
.ds-sa__scan.is-pick .ds-sa__camtext, .ds-sa__scan.is-pick .ds-sa__camtext.is-error, .ds-sa__scan.is-pick .ds-sa__camtext.is-hint { top: 5.6rem; }

/* Scan app and Driver app camera (board 51): wide frame for the stickers, camera off, dark, hard to read, photos */
.ds-sa__cam .ds-sa__frame { width: min(86vw, 21rem); height: min(30vw, 7.5rem); }
.ds-cx__off { position: absolute; inset: 0; z-index: 4; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 0.5rem; background: #05090c; color: #fff; text-align: center; padding: 1.5rem; }
.ds-cx__off span { display: grid; place-items: center; width: 4rem; height: 4rem; border-radius: 50%; background: rgb(255 255 255 / .1); font-size: 1.6rem; }
.ds-cx__off b { font-size: 1rem; }
.ds-cx__off small { max-width: 17rem; color: #9fb0bc; font-size: 0.8rem; line-height: 1.4; }
.ds-cx__dark { position: absolute; left: 1rem; right: 1rem; top: 52%; z-index: 3; display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem 0.65rem; border-radius: 0.8rem; background: rgb(10 18 25 / .88); box-shadow: inset 0 0 0 1px rgb(246 190 0 / .5); }
.ds-cx__dark span { flex: 1; font-size: 0.82rem; font-weight: 800; color: #ffe08a; }
.ds-cx__dark button { height: 2rem; padding: 0 0.8rem; border-radius: 0.6rem; background: var(--sa-gold); color: #0a1219; font-weight: 900; }
.ds-cx__hard { position: absolute; left: 1rem; right: 1rem; top: 60%; z-index: 3; height: 3.4rem; border-radius: 1rem; background: var(--sa-gold); color: #0a1219; font-size: 1rem; font-weight: 900; }
.ds-cx__type { position: absolute; left: 0; right: 0; bottom: 0; z-index: 5; display: flex; flex-direction: column; gap: 0.5rem; padding: 0.9rem 1rem calc(env(safe-area-inset-bottom) + 1rem); border-radius: 1.5rem 1.5rem 0 0; background: #0f1d27; box-shadow: 0 -16px 40px rgb(0 0 0 / .45); }
.ds-cx__type > small { color: #9fb0bc; font-size: 0.8rem; }
.ds-cx__field { display: flex; align-items: center; gap: 0.5rem; height: 3.2rem; padding-left: 0.9rem; border-radius: 0.9rem; box-shadow: inset 0 0 0 2px var(--sa-gold); }
.ds-cx__field b { font-size: 1.4rem; font-weight: 900; letter-spacing: .08em; }
.ds-cx__field i { width: 2px; height: 1.6rem; background: var(--sa-gold); margin-right: auto; animation: ds-blink 1s steps(2) infinite; }
.ds-cx__field button { height: 100%; padding: 0 1.2rem; border-radius: 0.9rem; background: var(--sa-gold); color: #0a1219; font-weight: 900; font-size: 1rem; }
@keyframes ds-blink { 50% { opacity: 0; } }
.ds-cx__keys { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.4rem; }
.ds-cx__keys button { height: 3rem; border-radius: 0.8rem; background: rgb(255 255 255 / .1); color: #fff; font-size: 1.3rem; font-weight: 800; }
.ds-cx__keys button:active { background: rgb(255 255 255 / .2); }
.ds-cx__back { height: 2.4rem; color: #9fb0bc; font-weight: 800; }
.ds-cx__chips { position: absolute; left: 1rem; right: 1rem; top: 50%; z-index: 2; display: flex; flex-wrap: wrap; gap: 0.35rem; pointer-events: none; }
.ds-cx__chips span { height: 1.7rem; padding: 0 0.7rem; border-radius: 999px; font-size: 0.78rem; font-weight: 800; display: inline-flex; align-items: center; pointer-events: auto; }
.ds-cx__chips .is-up { background: rgb(90 168 255 / .22); color: #a8d0ff; }
.ds-cx__chips .is-ok { background: rgb(52 195 143 / .2); color: #7fe0b8; }
.ds-cx__chips .is-bad { background: rgb(255 107 94 / .25); color: #ffb3ab; }
.ds-cx__chips .is-torch { background: rgb(246 190 0 / .2); color: #ffe08a; }
.ds-snap { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; }
.ds-snap .ds-sa__shot { position: relative; width: 3.6rem; height: 3.6rem; flex: none; border-radius: 0.75rem; overflow: hidden; }
.ds-snap .ds-sa__shot img { width: 100%; height: 100%; object-fit: cover; }
.ds-snap .ds-sa__shot b { position: absolute; left: 0; right: 0; bottom: 0; text-align: center; font-size: 0.65rem; font-weight: 900; padding: 1px 0; background: rgb(0 0 0 / .6); color: #a8d0ff; }
.ds-snap .ds-sa__shot b.is-done { color: #7fe0b8; }
.ds-snap .ds-sa__shot b.is-bad { color: #ffb3ab; }
.ds-snap__here { flex: 1; min-width: 9rem; height: 3.6rem; border-radius: 0.9rem; background: var(--sa-gold); color: #0a1219; font-size: 0.95rem; font-weight: 900; }
.ds-snap__app { width: 5.5rem; height: 3.6rem; flex: none; border-radius: 0.9rem; background: rgb(255 255 255 / .1); color: #fff; font-size: 0.78rem; font-weight: 800; line-height: 1.2; display: flex; flex-direction: column; align-items: center; justify-content: center; }
.ds-snap__app small { color: #9fb0bc; font-weight: 700; }
.ds-snap__note { width: 100%; margin: 0; color: #9fb0bc; font-size: 0.8rem; }
.ds-sa__primary.is-light { background: rgb(255 255 255 / .92); color: #0a1219; }
.ds-sx__skel { position: absolute; top: calc(env(safe-area-inset-top) + 5.2rem); left: 1rem; right: 1rem; z-index: 3; display: flex; flex-direction: column; gap: 0.45rem; padding: 0.8rem 0.9rem; border-radius: 0.9rem; background: rgb(10 18 25 / .82); backdrop-filter: blur(8px); }
.ds-sx__skel i { display: block; height: 0.7rem; border-radius: 0.35rem; background: rgb(255 255 255 / .1); animation: ds-skel 1.2s ease-in-out infinite; }
.ds-sx__skel i:nth-child(1) { width: 60%; } .ds-sx__skel i:nth-child(2) { width: 85%; } .ds-sx__skel i:nth-child(3) { width: 40%; }
.ds-sx__skel small { color: #7f93a1; font-size: 0.75rem; }
@keyframes ds-skel { 50% { opacity: .45; } }
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- resources/js/barcode-scanner.js
mkdir -p 'resources/js'
cat > 'resources/js/barcode-scanner.js' <<'DISPATCH_FILE_END_11'
(function () {
    // ZXing (WebAssembly) barcode decoder — used when the phone has no built-in BarcodeDetector (e.g. iPhone)
    const PONYFILL_URL = 'https://fastly.jsdelivr.net/npm/barcode-detector@3/dist/iife/ponyfill.min.js';
    const CAMERA_KEY = 'bb-scanner-camera';

    const scripts = {};
    function loadScript(src) {
        if (!scripts[src]) {
            scripts[src] = new Promise((resolve, reject) => {
                const s = document.createElement('script');
                s.src = src;
                s.async = true;
                s.onload = () => resolve();
                s.onerror = () => {
                    delete scripts[src];
                    reject(new Error('Could not load the barcode decoder. Check your internet connection.'));
                };
                document.head.appendChild(s);
            });
        }
        return scripts[src];
    }

    const detectors = {};
    async function createDetector(formats) {
        const key = formats.join(',');
        if (detectors[key]) return detectors[key];

        let detector = null;

        // Android Chrome: use the fast built-in detector when it supports all formats
        if ('BarcodeDetector' in window) {
            try {
                const supported = await window.BarcodeDetector.getSupportedFormats();
                if (formats.every((f) => supported.includes(f))) {
                    detector = new window.BarcodeDetector({ formats });
                }
            } catch (e) {}
        }

        // iPhone / others: ZXing WebAssembly
        if (!detector) {
            await loadScript(PONYFILL_URL);
            detector = new window.BarcodeDetectionAPI.BarcodeDetector({ formats });
        }

        detectors[key] = detector;
        return detector;
    }

    let audioCtx = null;
    function beep() {
        try {
            audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
            const osc = audioCtx.createOscillator();
            const gain = audioCtx.createGain();
            osc.type = 'square';
            osc.frequency.value = 1200;
            gain.gain.value = 0.08;
            osc.connect(gain);
            gain.connect(audioCtx.destination);
            osc.start();
            osc.stop(audioCtx.currentTime + 0.12);
        } catch (e) {}
    }

    function describeError(e) {
        const name = (e && e.name) || '';
        const msg = String((e && (e.message || e)) || '');
        if (name === 'NotAllowedError' || /permission|notallowed/i.test(msg))
            return 'Camera permission was denied. Allow camera access for this site in your browser settings, then try again.';
        if (name === 'NotFoundError' || /requested device not found/i.test(msg))
            return 'No camera was found on this device.';
        if (name === 'NotReadableError' || /could not start|in use/i.test(msg))
            return 'The camera is being used by another app. Close it and try again.';
        return msg || 'Unable to start the camera.';
    }

    function waitForVideo(video, timeout = 4000) {
        return new Promise((resolve) => {
            if (video.videoWidth > 0) return resolve();
            const done = () => { clearTimeout(t); video.removeEventListener('loadedmetadata', done); resolve(); };
            const t = setTimeout(done, timeout);
            video.addEventListener('loadedmetadata', done);
        });
    }

    // A tiny copy of the picture, to notice when the camera only sends black frames
    const probe = document.createElement('canvas');
    probe.width = 32;
    probe.height = 18;
    const probeCtx = probe.getContext('2d', { willReadFrequently: true });

    function brightness(video) {
        try {
            probeCtx.drawImage(video, 0, 0, probe.width, probe.height);
            const px = probeCtx.getImageData(0, 0, probe.width, probe.height).data;
            let sum = 0;
            for (let i = 0; i < px.length; i += 4) sum += px[i] + px[i + 1] + px[i + 2];
            return sum / (px.length / 4) / 3;
        } catch (e) {
            return 255; // cannot read the picture: do not complain
        }
    }

    const ios = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    const homeScreenApp = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
    const BLACK_TIP = 'The camera picture is black. Close other apps that use the camera, check that this site may use the camera, '
        + (ios && homeScreenApp ? 'or close the app fully and open it again. ' : 'or reload the page. ')
        + 'You can always type the code above.';

    const TORCH_KEY = 'ds-torch-at';
    const TORCH_KEEP = 10 * 60 * 1000; // the flashlight comes back on by itself within 10 minutes
    const VIDEO = { width: { ideal: 1280 }, height: { ideal: 720 } }; // light and fast; the frame is read in full detail

    /*
     * Start the camera while the trip is still opening (tap on a trip), so the scan screen
     * finds it running. Not used within 10 s: let go of it.
     */
    let warm = null;
    window.dsWarmCamera = function (formats) {
        try {
            if (formats) createDetector(formats.map((f) => String(f).toLowerCase())).catch(() => {});
            if (warm || !navigator.mediaDevices || !window.isSecureContext) return;
            let saved = null;
            try { saved = localStorage.getItem(CAMERA_KEY); } catch (e) {}
            const w = { stream: null, timer: null };
            warm = w;
            navigator.mediaDevices.getUserMedia({ audio: false, video: saved ? { ...VIDEO, deviceId: { exact: saved } } : { ...VIDEO, facingMode: { ideal: 'environment' } } })
                .then((st) => { if (warm === w) { w.stream = st; w.timer = setTimeout(() => { if (warm === w) { st.getTracks().forEach((t) => t.stop()); warm = null; } }, 10000); } else st.getTracks().forEach((t) => t.stop()); })
                .catch(() => { if (warm === w) warm = null; });
        } catch (e) { warm = null; }
    };
    function takeWarm() {
        if (!warm || !warm.stream || !warm.stream.active) return null;
        clearTimeout(warm.timer);
        const st = warm.stream;
        warm = null;
        return st;
    }

    /*
     * Box photos sent in the back: the crew scans the next box while a photo uploads.
     * Each photo: shrunk on the phone, sent with its % shown, tried again 3 times.
     */
    let photoState = null;
    function photos() {
        if (!photoState) photoState = window.Alpine ? window.Alpine.reactive({ items: [] }) : { items: [] };
        return photoState;
    }
    function sendPhoto(item, tries = 0) {
        const fd = new FormData();
        fd.append('photo', item.file, 'photo.jpg');
        fd.append('invoice_id', item.invoiceId);
        if (item.condition) fd.append('condition', item.condition);
        if (item.note) fd.append('note', item.note);
        const xhr = new XMLHttpRequest();
        xhr.open('POST', item.url);
        const token = document.querySelector('meta[name="csrf-token"]');
        if (token) xhr.setRequestHeader('X-CSRF-TOKEN', token.content);
        xhr.setRequestHeader('Accept', 'application/json');
        xhr.upload.onprogress = (e) => { if (e.lengthComputable) item.p = Math.min(99, Math.round(e.loaded / e.total * 100)); };
        xhr.onload = () => {
            if (xhr.status >= 200 && xhr.status < 300) {
                try { item.serverId = JSON.parse(xhr.responseText).id; } catch (e) {}
                item.p = 100; item.done = true; item.failed = false; item.file = null;
            } else if (xhr.status >= 500 && tries < 3) setTimeout(() => sendPhoto(item, tries + 1), 2000 * (tries + 1));
            else { item.failed = true; try { item.why = JSON.parse(xhr.responseText).message; } catch (e) {} }
        };
        xhr.onerror = () => { if (tries < 3) setTimeout(() => sendPhoto(item, tries + 1), 2000 * (tries + 1)); else item.failed = true; };
        xhr.send(fd);
    }
    window.dsPhotos = {
        state: photos,
        async add(file, info) {
            const small = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
            const item = { id: Date.now() + Math.random(), invoiceId: info.invoiceId, code: info.code || '', condition: info.condition || null, note: info.note || null,
                url: info.url, file: small, thumb: URL.createObjectURL(small), p: 2, done: false, failed: false, serverId: null, why: null };
            photos().items.push(item);
            sendPhoto(photos().items[photos().items.length - 1]);
        },
        retry(item) { if (item.file) { item.failed = false; item.p = 2; sendPhoto(item); } },
        going() { return photos().items.filter((i) => !i.done && !i.failed); },
        saved() { return photos().items.filter((i) => i.done).length; },
        failed() { return photos().items.filter((i) => i.failed); },
        of(invoiceId) { return photos().items.filter((i) => String(i.invoiceId) === String(invoiceId)); },
    };

    window.barcodeScanner = function (config) {
        const formats = (config.formats && config.formats.length ? config.formats : ['code_128', 'qr_code'])
            .map((f) => String(f).toLowerCase());

        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d', { willReadFrequently: true });

        let stream = null;
        let detector = null;
        let session = 0;
        let loopTimer = null;
        let startTimer = null;
        let watchTimer = null;
        let observer = null;
        let onVisibilityChange = null;
        let darkSince = 0;
        let frame = 0;
        let tried = new Set();
        let onCommand = null;
        let pending = { code: null, n: 0, at: 0 }; // a read waits for the same read once more
        let unsureSince = 0;
        let activity = 0;
        let dimSince = 0;
        const confirmReads = Math.max(1, config.confirm || 1);
        const idleOff = config.idleOff || 0;
        const hardAfter = config.hardAfter || 3000;

        return {
            scanning: false,
            loading: false,
            error: null,
            hint: null,
            lastCode: null,
            lastAt: 0,
            manualCode: '',
            cameras: [],
            cameraId: null,
            stoppedByUser: false,
            flash: false,
            torchSupported: false,
            torchOn: false,
            paused: false,
            hard: false,
            typing: false,
            typed: '',
            darkTip: false,
            offWhy: null,

            init() {
                try { this.cameraId = localStorage.getItem(CAMERA_KEY) || null; } catch (e) {}

                onVisibilityChange = () => {
                    if (document.hidden) {
                        this.stop();
                    } else if (config.autoStart && !this.stoppedByUser && this.$el.getClientRects().length) {
                        this.start();
                    }
                };
                document.addEventListener('visibilitychange', onVisibilityChange);

                // From the page: pause while a result is open, let go of the camera for the camera app
                onCommand = (e) => {
                    const d = (e && e.detail) || {};
                    if (d.release) { this.stop(); return; }
                    if ('paused' in d) this.setPaused(!!d.paused);
                };
                window.addEventListener('ds-scanner', onCommand);
                window.dsScanner = this;

                // Start when the scanner becomes visible (modal opened), stop when hidden (modal closed)
                if ('IntersectionObserver' in window) {
                    observer = new IntersectionObserver((entries) => {
                        const entry = entries[entries.length - 1];
                        entry.isIntersecting ? this.onShown() : this.onHidden();
                    }, { threshold: 0.01 });
                    observer.observe(this.$el);
                } else if (config.autoStart) {
                    setTimeout(() => this.start(), 300);
                }
            },

            destroy() {
                document.removeEventListener('visibilitychange', onVisibilityChange);
                window.removeEventListener('ds-scanner', onCommand);
                if (window.dsScanner === this) window.dsScanner = null;
                if (observer) observer.disconnect();
                clearTimeout(startTimer);
                this.stop();
            },

            onShown() {
                this.stoppedByUser = false;
                if (!config.autoStart) return;
                clearTimeout(startTimer);
                startTimer = setTimeout(() => this.start(), config.startDelay ?? 300); // let the modal finish opening
            },

            onHidden() {
                clearTimeout(startTimer);
                this.stop();
            },

            async start(afterBlack = false) {
                if (this.scanning || this.loading) return;
                this.error = null;
                this.stoppedByUser = false;
                if (!afterBlack) {
                    tried = new Set();
                    this.hint = null;
                }
                darkSince = 0;

                if (!window.isSecureContext) {
                    this.error = 'The camera only works over HTTPS (or on localhost). Open this page with https://';
                    return;
                }
                if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
                    this.error = 'This browser does not support camera access. Type the code instead.';
                    return;
                }

                const my = ++session;
                this.loading = true;

                try {
                    // Load the decoder at the same time as the camera starts
                    const detectorPromise = createDetector(formats);

                    const base = VIDEO;
                    let s = takeWarm();
                    if (!s) try {
                        s = await navigator.mediaDevices.getUserMedia({
                            audio: false,
                            video: this.cameraId
                                ? { ...base, deviceId: { exact: this.cameraId } }
                                : { ...base, facingMode: { ideal: 'environment' } },
                        });
                    } catch (e) {
                        if (!this.cameraId || e.name === 'NotAllowedError') throw e;
                        this.forgetCamera(); // saved camera no longer exists → use back camera
                        s = await navigator.mediaDevices.getUserMedia({
                            audio: false,
                            video: { ...base, facingMode: { ideal: 'environment' } },
                        });
                    }

                    if (my !== session) { s.getTracks().forEach((t) => t.stop()); return; }
                    stream = s;

                    // Attach the camera only once the preview box is on screen:
                    // iPhone home screen apps show a black picture otherwise.
                    await this.$nextTick();
                    await new Promise((resolve) => requestAnimationFrame(() => resolve()));

                    const video = this.$refs.video;
                    video.muted = true;
                    video.setAttribute('muted', '');
                    video.setAttribute('playsinline', '');
                    video.setAttribute('autoplay', '');
                    video.srcObject = stream;
                    try { await video.play(); } catch (e) {}
                    await waitForVideo(video);
                    if (video.paused) {
                        try { await video.play(); } catch (e) {}
                    }

                    const track = stream.getVideoTracks()[0];
                    try { await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }); } catch (e) {}
                    try {
                        const caps = track.getCapabilities ? track.getCapabilities() : {};
                        this.torchSupported = !!caps.torch;
                    } catch (e) { this.torchSupported = false; }
                    this.torchOn = false;
                    let torchAt = 0;
                    try { torchAt = Number(localStorage.getItem(TORCH_KEY) || 0); } catch (e) {}
                    if (this.torchSupported && torchAt && Date.now() - torchAt < TORCH_KEEP) {
                        try { await track.applyConstraints({ advanced: [{ torch: true }] }); this.torchOn = true; } catch (e) {}
                    }

                    detector = await detectorPromise;
                    if (my !== session) return;

                    this.scanning = true;
                    this.loading = false;
                    this.offWhy = null;
                    activity = Date.now();
                    pending = { code: null, n: 0, at: 0 };
                    unsureSince = 0;
                    this.hard = false;
                    this.watchHidden();
                    this.loop(my);
                    this.listCameras();
                } catch (e) {
                    if (my === session) {
                        this.error = describeError(e);
                        await this.stop();
                    }
                } finally {
                    if (my === session) this.loading = false;
                }
            },

            // Read frames ~10 times per second, cropped to the middle of the picture
            async loop(my) {
                if (my !== session) return;
                const video = this.$refs.video;

                if (idleOff && !this.typing && Date.now() - activity > idleOff) {
                    this.offWhy = 'No scan for ' + Math.round(idleOff / 60000) + ' minutes: camera and flashlight off to save battery.';
                    this.stop();
                    return;
                }
                if (unsureSince && Date.now() - pending.at > 1500) unsureSince = 0; // nothing read for a while: not a hard label
                if (unsureSince && !this.hard && Date.now() - unsureSince > hardAfter) this.hard = true;

                if (video.readyState >= 2 && video.videoWidth && ++frame % 3 === 0) {
                    const light = brightness(video);
                    if (light < 40 && light >= 8 && this.torchSupported && !this.torchOn) {
                        dimSince = dimSince || Date.now();
                        if (Date.now() - dimSince > 1500) this.darkTip = true;
                    } else {
                        dimSince = 0;
                        this.darkTip = false;
                    }
                    if (light < 8) {
                        darkSince = darkSince || Date.now();
                        if (Date.now() - darkSince > 2500) {
                            darkSince = 0;
                            this.onBlackPicture(my);
                            return;
                        }
                    } else {
                        darkSince = 0;
                        if (this.hint) this.hint = null;
                    }
                }

                try {
                    if (detector && !this.paused && !this.typing && video.readyState >= 2 && video.videoWidth) {
                        const vw = video.videoWidth;
                        const vh = video.videoHeight;
                        const cw = Math.floor(vw * 0.92);
                        const ch = Math.floor(vh * (config.confirm > 1 ? 0.5 : 0.6));
                        const scale = Math.min(1, 1280 / cw);

                        canvas.width = Math.floor(cw * scale);
                        canvas.height = Math.floor(ch * scale);
                        ctx.drawImage(video, (vw - cw) / 2, (vh - ch) / 2, cw, ch, 0, 0, canvas.width, canvas.height);

                        const results = await detector.detect(canvas);
                        if (my === session && !this.paused && results && results.length) {
                            this.onRead(results[0].rawValue);
                        }
                    }
                } catch (e) {}

                if (my === session && this.scanning) {
                    loopTimer = setTimeout(() => this.loop(my), 100);
                }
            },

            // The picture stayed black: try the other cameras once each, then explain.
            async onBlackPicture(my) {
                await this.listCameras();
                let current = this.cameraId;
                try { current = (stream && stream.getVideoTracks()[0].getSettings().deviceId) || current; } catch (e) {}
                tried.add(current || 'auto');
                const next = this.cameras.map((c) => c.id).find((id) => id && !tried.has(id));

                if (next && tried.size <= this.cameras.length) {
                    this.hint = 'The picture was black. Trying another camera…';
                    this.cameraId = next;
                    try { localStorage.setItem(CAMERA_KEY, next); } catch (e) {}
                    await this.stop();
                    await this.start(true);
                    return;
                }

                this.hint = BLACK_TIP;
                if (my === session && this.scanning) this.loop(my); // keep reading in case the picture comes back
            },

            async stop() {
                if (this.torchOn) { try { localStorage.setItem(TORCH_KEY, String(Date.now())); } catch (e) {} }
                this.darkTip = false;
                session++;
                clearTimeout(loopTimer);
                clearInterval(watchTimer);
                loopTimer = null;
                watchTimer = null;

                if (stream) {
                    stream.getTracks().forEach((t) => t.stop());
                    stream = null;
                }
                if (this.$refs.video) this.$refs.video.srcObject = null;

                this.scanning = false;
                this.loading = false;
                this.torchOn = false;
            },

            async toggle() {
                if (this.scanning || this.loading) {
                    this.stoppedByUser = true;
                    clearTimeout(startTimer);
                    await this.stop();
                } else {
                    await this.start();
                }
            },

            async toggleTorch() {
                const track = stream && stream.getVideoTracks()[0];
                if (!track) return;
                try {
                    await track.applyConstraints({ advanced: [{ torch: !this.torchOn }] });
                    this.torchOn = !this.torchOn;
                    this.darkTip = false;
                    try { this.torchOn ? localStorage.setItem(TORCH_KEY, String(Date.now())) : localStorage.removeItem(TORCH_KEY); } catch (e) {}
                } catch (e) {}
            },

            async listCameras() {
                if (this.cameras.length) return;
                try {
                    const devices = await navigator.mediaDevices.enumerateDevices(); // no permission popup
                    this.cameras = devices
                        .filter((d) => d.kind === 'videoinput')
                        .map((d, i) => ({ id: d.deviceId, label: d.label || `Camera ${i + 1}` }));
                } catch (e) {}
            },

            forgetCamera() {
                this.cameraId = null;
                try { localStorage.removeItem(CAMERA_KEY); } catch (e) {}
            },

            async useCamera(id) {
                this.cameraId = id || null;
                try { id ? localStorage.setItem(CAMERA_KEY, id) : localStorage.removeItem(CAMERA_KEY); } catch (e) {}
                if (this.scanning) { await this.stop(); await this.start(); }
            },

            // Backup: stop the camera if the modal closed and the observer missed it
            watchHidden() {
                clearInterval(watchTimer);
                watchTimer = setInterval(() => {
                    if (!this.$el.isConnected || this.$el.getClientRects().length === 0) this.stop();
                }, 1000);
            },

            // A read counts only when the same number is read again right after (blurry labels misread)
            onRead(text) {
                const code = String(text || '').trim();
                if (!code) return;
                const now = Date.now();
                if (code === this.lastCode && now - this.lastAt < (config.cooldown ?? 2500)) return;
                if (confirmReads <= 1) { this.onDetected(code); return; }
                if (pending.code === code && now - pending.at < 1500) {
                    pending.n++;
                    pending.at = now;
                    if (pending.n >= confirmReads) {
                        pending = { code: null, n: 0, at: 0 };
                        this.onDetected(code);
                    }
                    return;
                }
                pending = { code, n: 1, at: now };
                unsureSince = unsureSince || now;
            },

            setPaused(p) {
                this.paused = p;
                if (p) return;
                activity = Date.now();
                this.lastAt = Date.now(); // the box still in front of the camera is not read again at once
                pending = { code: null, n: 0, at: 0 };
                if (!this.scanning && !this.loading && config.autoStart && this.$el.getClientRects().length) this.start();
            },

            // Hard to read: type the number on a keypad
            openTyping() { this.typing = true; this.typed = ''; this.hard = false; unsureSince = 0; activity = Date.now(); },
            closeTyping() { this.typing = false; this.typed = ''; activity = Date.now(); },
            key(k) {
                activity = Date.now();
                if (k === '⌫') this.typed = this.typed.slice(0, -1);
                else this.typed = (this.typed + k).slice(0, 20);
            },
            findTyped() {
                const code = this.typed.trim();
                if (!code) return;
                this.typing = false;
                this.typed = '';
                this.lastCode = code;
                this.lastAt = Date.now();
                this.submit(code);
            },

            async turnTorchOn() { if (!this.torchOn) await this.toggleTorch(); },

            // 📷 Take photo here: a still from the camera that is already on (no camera app)
            async snapPhoto() {
                const track = stream && stream.getVideoTracks()[0];
                const video = this.$refs.video;
                this.flash = true;
                setTimeout(() => { this.flash = false; }, 160);
                if (track && 'ImageCapture' in window) {
                    try {
                        const blob = await new window.ImageCapture(track).takePhoto();
                        if (blob && blob.size) return new File([blob], 'photo.jpg', { type: blob.type || 'image/jpeg' });
                    } catch (e) {}
                }
                if (!video || !video.videoWidth) return null;
                const c = document.createElement('canvas');
                c.width = video.videoWidth;
                c.height = video.videoHeight;
                c.getContext('2d').drawImage(video, 0, 0);
                const blob = await new Promise((r) => c.toBlob(r, 'image/jpeg', 0.9));
                return blob ? new File([blob], 'photo.jpg', { type: 'image/jpeg' }) : null;
            },

            onDetected(text) {
                const code = String(text || '').trim();
                if (!code) return;
                activity = Date.now();
                unsureSince = 0;
                this.hard = false;
                const now = Date.now();
                if (code === this.lastCode && now - this.lastAt < (config.cooldown ?? 2500)) return;

                this.lastCode = code;
                this.lastAt = now;

                this.flash = true;
                setTimeout(() => { this.flash = false; }, 600);

                if (navigator.vibrate) navigator.vibrate(80);
                if (config.beep !== false) beep();
                if (!config.continuous) this.stop();
                this.submit(code);
            },

            submitManual() {
                const code = this.manualCode.trim();
                if (!code) return;
                activity = Date.now();
                this.lastCode = code;
                this.lastAt = Date.now();
                this.submit(code);
            },

            submit(code) {
                this.manualCode = config.statePath ? code : '';
                if (config.statePath) this.$wire.set(config.statePath, code);
                if (config.method) this.$wire.call(config.method, code);
                this.$dispatch('barcode-scanned', { code });
            },
        };
    };
})();
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- resources/views/filament/delivery/pages/driver-app.blade.php
mkdir -p 'resources/views/filament/delivery/pages'
cat > 'resources/views/filament/delivery/pages/driver-app.blade.php' <<'DISPATCH_FILE_END_12'
@php
    $ring = fn (int $done, int $total, int $len = 289) => $len - ($total > 0 ? round($len * min($done, $total) / $total) : 0);
    $p = $progress ?? ['total' => 0, 'delivered' => 0, 'notDelivered' => 0, 'left' => 0];
    $user = auth()->user();
    $initials = mb_strtoupper(mb_substr($user?->first_name ?? '', 0, 1).mb_substr($user?->last_name ?? '', 0, 1)) ?: '·';
    $photoJs = "{ busy: false, failed: false, pct: 0,
        take() { this.failed = false; window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { release: true } })); this.\$refs.file.value = ''; this.\$refs.file.click() },
        async send(e) {
            const files = [...e.target.files]; if (! files.length) return;
            for (const file of files) {
                this.busy = true; this.pct = 0; let out = file;
                out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
                await new Promise(done => \$wire.upload('upload', out, () => \$wire.savePhoto().then(done), () => { this.failed = true; done() }, (ev) => { this.pct = ev.detail.progress }));
            }
            this.busy = false;
        } }";
@endphp
<x-filament-panels::page>
<div class="ds-sa ds-dr" x-data x-on:driver-app-buzz.window="if (navigator.vibrate) navigator.vibrate($event.detail.ok ? 60 : [80, 60, 80])">
    {{-- Signal bar: drawn by driver-offline.js (shows "No signal", "waiting to send", "needs attention"). --}}
    <div id="ds-net" class="dso-net" wire:ignore aria-live="polite"></div>

    {{-- Truck tracking: location during trips, after the driver agrees once. --}}
    @include('filament.delivery.partials.tracking', ['tracking' => $tracking])

    {{-- ============================== today ============================== --}}
    @if ($screen === 'home')
        <section class="ds-sa__screen" wire:key="home">
            <header class="ds-sa__hello">
                <span>
                    <small>{{ $trip ? 'Trip '.$trip->trip_number.($trip->truck?->plate_no ? ' · Truck '.$trip->truck->plate_no : '') : now()->format('l, F j') }}</small>
                    <strong>{{ $greeting }}, {{ $user?->first_name }}</strong>
                </span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help')" aria-label="Help">?</button>
                <span class="ds-sa__avatar is-green">{{ $initials }}</span>
            </header>

            @if (\App\Support\Shipping\Shipments::ready() && ($portShip = \App\Support\Shipping\Shipments::forDriverPort($trip ?? null)))
                <a href="{{ \App\Filament\Delivery\Pages\AtPort::getUrl() }}" class="ds-fd__home"><span aria-hidden="true">🚢</span><span><b>At the port · {{ $portShip->code }}</b><small>{{ $portShip->port_count !== null ? 'Counted: '.$portShip->port_count.' boxes · tap to change' : 'Type the forwarder count and take a photo of the receipt' }}</small></span><span class="ds-sa__chev">›</span></a>
            @endif
            @if (\App\Support\Fuel\Fuel::ready())
                <a href="{{ \App\Filament\Delivery\Pages\Fuel::getUrl() }}" class="ds-fd__home"><span aria-hidden="true">⛽</span><span><b>Add fuel</b><small>Photo of the receipt and the odometer</small></span><span class="ds-sa__chev">›</span></a>
            @endif

            @if (! $trip && $closedTrip)
                <div class="ds-ts ds-ts--closed">
                    <small>Trip {{ $closedTrip->trip_number }} done · truck released</small>
                    <strong>{{ $closedDelivered ? 'All '.$closedDelivered.' boxes delivered' : 'Trip closed' }}</strong>
                    <span>Every box is delivered or returned. Thank you! Your next trip shows here when the office makes it.</span>
                </div>
            @elseif (! $trip)
                <div class="ds-sa__empty">
                    <span class="ds-sa__empty-icon">@include('filament.scan.icon', ['name' => 'truck'])</span>
                    <strong>You're not on a trip right now</strong>
                    <p>When the office puts you on a truck, today's boxes show up here. Pull down or reopen the app to refresh.</p>
                </div>
            @else
                @if ($stageCard)
                        <div class="ds-ts ds-ts--{{ $stage }}">
                            <small>{{ $stageCard[0] }}</small>
                            <strong>Trip {{ $trip->trip_number }}</strong>
                            <span>{{ $stageCard[1] }}</span>
                            @if ($canTake)
                                <button type="button" class="ds-sa__primary" wire:click="takeTrip" wire:confirm="Take trip {{ $trip->trip_number }} with {{ $p['total'] }} boxes?">I take the trip · {{ $p['total'] }} boxes</button>
                            @endif
                        </div>
                @endif
                @if ($nextTrip)
                    <div class="ds-ts ds-ts--next">
                        <small>Next trip waiting for this truck</small>
                        <strong>Trip {{ $nextTrip->trip_number }}</strong>
                        <span>It shows here as soon as trip {{ $trip->trip_number }} is closed.</span>
                    </div>
                @endif
                @if ($finished)
                    <div class="ds-dr__celebrate">
                        <span class="ds-sa__ring is-big"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="48" class="is-track"/><circle cx="55" cy="55" r="48" class="is-fill is-ok" style="stroke-dasharray: 302; stroke-dashoffset: 0"/></svg><span><i><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></i></span></span>
                        <strong>All {{ $p['total'] }} boxes delivered</strong>
                        <p>Great work. The office can see every delivery and photo.</p>
                    </div>
                @else
                    <div class="ds-sa__today">
                        <span class="ds-sa__ring is-mid">
                            <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill is-green" style="stroke-dashoffset: {{ $ring($p['delivered'], $p['total']) }}"/></svg>
                            <span><strong>{{ $p['delivered'] }}</strong><small>of {{ $p['total'] }} delivered</small></span>
                        </span>
                        <dl>
                            <dt>Delivered</dt><dd class="is-ok">{{ $p['delivered'] }}</dd>
                            <dt>Still on the truck</dt><dd>{{ $p['left'] }} left</dd>
                            <dt>Not delivered</dt><dd class="is-warn">{{ $p['notDelivered'] }}</dd>
                        </dl>
                    </div>

                    <button type="button" class="ds-sa__primary ds-dr__scanbtn" wire:click="go('scan')" x-on:click="window.dsWarmCamera && window.dsWarmCamera()">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg>
                        Scan a box to deliver
                    </button>
                    @if ($stage === 'road')
                        <button type="button" class="ds-sa__secondary" wire:click="backAtHub" wire:confirm="Back at the hub? Boxes not delivered ({{ $p['left'] }}) are given to the hub and scanned back.">Back at the hub</button>
                    @endif
                @endif

                @if ($priority->isNotEmpty())
                    <p class="ds-sa__label">Priority boxes</p>
                    <div class="ds-sa__list">
                        @foreach ($priority as $b)
                            <button type="button" class="ds-sa__row" wire:click="scan(@js($b['invoice']))"><span class="ds-sa__rowtext"><strong>{{ $b['invoice'] }} · {{ $b['name'] }}</strong><small>{{ $b['address'] }}</small></span><span class="ds-sa__chev">›</span></button>
                        @endforeach
                    </div>
                @endif

                @if ($problems->isNotEmpty())
                    <p class="ds-sa__label">Check before handing over</p>
                    <div class="ds-sa__list is-warn">
                        @foreach ($problems as $b)
                            <button type="button" class="ds-sa__row" wire:click="scan(@js($b['invoice']))"><span class="ds-sa__rowtext"><strong>{{ $b['invoice'] }} · {{ $b['issue'] }}</strong><small>{{ $b['name'] }}{{ $b['remarks'] ? ' · '.$b['remarks'] : '' }}</small></span><span class="ds-sa__chev">›</span></button>
                        @endforeach
                    </div>
                @endif

                @if ($stops->isNotEmpty())
                    @include('filament.delivery.partials.stops', ['stops' => $stops])
                @elseif ($areas->isNotEmpty())
                    <div class="ds-dr__labelrow"><p class="ds-sa__label">Where to go next</p><button type="button" wire:click="go('list')">All boxes ›</button></div>
                    <div class="ds-sa__list">
                        @foreach ($areas->take(6) as $a)
                            <button type="button" class="ds-sa__row" wire:click="area(@js($a['barangay'] ?: $a['city']))">
                                <span class="ds-sa__rowtext"><strong>{{ $a['barangay'] ? $a['barangay'].', ' : '' }}{{ $a['city'] }}</strong><small>{{ $a['boxes'] }} {{ str('box')->plural($a['boxes']) }} · {{ $a['stops']->count() }} {{ str('stop')->plural($a['stops']->count()) }}</small></span>
                                <span class="ds-sa__chev">›</span>
                            </button>
                        @endforeach
                    </div>
                @endif

                @if ($delivered->isNotEmpty())
                    <p class="ds-sa__label">Delivered today</p>
                    <div class="ds-sa__list">
                        @foreach ($delivered as $d)
                            <div class="ds-sa__row ds-dr__done">
                                @if ($d['photo'])<img src="{{ $d['photo'] }}" alt="" class="ds-dr__thumb">@endif
                                <span class="ds-sa__rowtext"><strong>{{ $d['invoice'] }} · {{ $d['name'] }}</strong><small>{{ $d['time'] }}</small></span>
                                @if ($d['undoMinutesLeft'])
                                    <button type="button" class="ds-dr__undo" wire:click="mountAction('undoDelivery', { tripinvoice: {{ $d['id'] }} })">Undo · {{ $d['undoMinutesLeft'] }} min left</button>
                                @else
                                    <span class="ds-dr__office">Office only</span>
                                @endif
                            </div>
                        @endforeach
                    </div>
                @endif

                @if ($crew->isNotEmpty())
                    <div class="ds-dr__crew">
                        @foreach ($crew as $c)
                            <span><i>{{ mb_strtoupper(mb_substr($c['name'], 0, 2)) }}</i>With {{ $c['name'] }}{{ $c['role'] ? ' ('.strtolower($c['role']).')' : '' }}</span>
                        @endforeach
                    </div>
                @endif
            @endif

            <footer class="ds-sa__foot">
                <span class="ds-sa__online"><i></i>Online · every delivery is saved</span>
                <span class="ds-sa__footlinks">
                    <button type="button" class="ds-pwa-install" onclick="window.dsInstallApp && window.dsInstallApp()">Install app</button>
                    <form method="POST" action="{{ filament()->getLogoutUrl() }}">@csrf<button type="submit">Sign out</button></form>
                </span>
            </footer>
        </section>
    @endif

    {{-- ============================== boxes ============================== --}}
    @if ($screen === 'list')
        <section class="ds-sa__screen" wire:key="list">
            <div class="ds-dr__listhead">
                <button type="button" class="ds-sa__back" wire:click="go('home')" aria-label="Back">‹</button>
                <strong>Boxes</strong>
                <button type="button" class="ds-dr__scanmini" wire:click="go('scan')" x-on:click="window.dsWarmCamera && window.dsWarmCamera()" aria-label="Scan a box"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></button>
            </div>
            <label class="ds-dr__search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
                <input type="search" wire:model.live.debounce.350ms="search" placeholder="Name, box number or barangay" aria-label="Search boxes">
            </label>
            @php($tabs = ['todo' => 'To deliver', 'delivered' => 'Delivered', 'missed' => 'Not delivered'])
            @php($ti = array_search($tab, array_keys($tabs), true) ?: 0)
            <div class="ds-sa__seg is-3">
                <span class="ds-sa__segthumb is-light" style="left: calc(4px + {{ $ti }} * (100% - 8px) / 3)"></span>
                @foreach ($tabs as $k => $l)
                    <button type="button" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k])>{{ $l }} · {{ $counts[$k] ?? 0 }}</button>
                @endforeach
            </div>
            <div class="ds-dr__rows">
                @forelse ($rows as $r)
                    @php($inv = $r->invdata)
                    <div class="ds-dr__card" wire:key="r-{{ $r->id }}">
                        <button type="button" class="ds-dr__cardmain" @if (! $r->is_delivered) wire:click="openBox({{ $r->id }})" @endif>
                            <span class="ds-dr__cardtop"><strong>{{ $r->invoice }}</strong>
                                @if ($r->is_delivered)
                                    <em class="is-ok">{{ ($r->delivered_at ?? $r->updated_at)?->format('g:i A') }}</em>
                                @elseif ($r->latestDeliveryAttempt)
                                    <em class="is-warn">{{ $r->latestDeliveryAttempt->reason->getLabel() }}</em>
                                @else
                                    <em>To deliver</em>
                                @endif
                            </span>
                            <span class="ds-dr__name">{{ \Illuminate\Support\Str::title($inv?->receiver_name) }}</span>
                            <small>{{ collect([$inv?->receiver_address, $inv?->receiver_barangay, $inv?->receiver_city])->filter()->map(fn ($x) => \Illuminate\Support\Str::title($x))->join(', ') }}</small>
                        </button>
                        @if ($inv?->receiver_mobile_no)
                            <a class="ds-dr__call" href="tel:{{ preg_replace('/[^0-9+]/', '', $inv->receiver_mobile_no) }}" aria-label="Call {{ $inv->receiver_name }}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2"/></svg></a>
                        @endif
                    </div>
                @empty
                    <div class="ds-sa__note">{{ $search !== '' ? 'No boxes match “'.$search.'”.' : 'Nothing here.' }}</div>
                @endforelse
            </div>
        </section>
    @endif

    {{-- ============================== scan ============================== --}}
    @if ($screen === 'scan')
        <section class="ds-sa__screen ds-sa__scan" wire:key="scan">
            <div class="ds-sa__cam" wire:ignore
                 x-data="barcodeScanner(@js(\App\Support\ScanModes::scanner('scan', 3000)))">
                <video x-ref="video" playsinline muted autoplay></video>
                <div class="ds-sa__frame" x-bind:class="{ 'is-hit': flash }"><i></i><i></i><i></i><i></i><span x-show="scanning" class="ds-sa__sweep"></span></div>
                <p class="ds-sa__camtext" x-show="loading" x-cloak>Starting camera…</p>
                <p class="ds-sa__camtext is-error" x-show="error" x-text="error" x-cloak></p>
                <p class="ds-sa__camtext is-hint" x-show="hint && ! error" x-text="hint" x-cloak></p>
                @include('filament.scan.cam-extras')
                <div class="ds-sa__controls">
                    <label class="ds-sa__type">
                        <input type="text" x-model="manualCode" x-on:keydown.enter.prevent="submitManual()" placeholder="Type a box number" autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="go" aria-label="Box number">
                        <button type="button" x-on:click="submitManual()" aria-label="Find">→</button>
                    </label>
                    <div class="ds-sa__buttons">
                        <button type="button" class="ds-sa__round" x-show="torchSupported && scanning" x-on:click="toggleTorch()" x-bind:class="{ 'is-on': torchOn }" aria-label="Flashlight" x-cloak><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h6l-1 6h-4zM10 8h4v12a2 2 0 0 1-4 0z"/></svg></button>
                        <button type="button" class="ds-sa__shutter" x-on:click="toggle()" x-bind:aria-label="scanning ? 'Stop camera' : 'Start camera'"><span x-bind:class="{ 'is-live': scanning }"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></span></button>
                        <button type="button" class="ds-sa__round is-text" wire:click="go('list')" aria-label="Boxes"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/></svg></button>
                    </div>
                </div>
            </div>

            <header class="ds-sa__bar">
                <button type="button" class="ds-sa__back" wire:click="go('home')" aria-label="Back">‹</button>
                <span class="ds-sa__bartext"><small>Deliver</small><strong>{{ $trip ? 'Trip '.$trip->trip_number : 'No trip' }}</strong></span>
                <span class="ds-sa__ring is-tiny"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill is-green" style="stroke-dashoffset: {{ $ring($p['delivered'], $p['total']) }}"/></svg></span>
                <span class="ds-sa__count"><strong>{{ $p['delivered'] }}</strong><small>of {{ $p['total'] }}</small></span>
            </header>

            <span class="hidden" wire:key="pz-{{ $sheet ?? 'none' }}-{{ $boxId ?? 0 }}" x-init="$dispatch('ds-scanner', { paused: @js((bool) $sheet) })"></span>

            @if ($just)
                <div class="ds-dr__toast" wire:key="toast-{{ $just->id }}" x-data="{ left: 15 }" x-init="const t = setInterval(() => { left--; if (left <= 0) { clearInterval(t); $wire.set('justDelivered', null) } }, 1000)">
                    <span class="ds-sa__mark is-ok"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></span>
                    <span><strong>{{ $just->invoice }} delivered</strong><small>{{ $justPhotos }} {{ str('photo')->plural($justPhotos) }} saved · undo for <span x-text="left"></span> s</small></span>
                    <button type="button" wire:click="undoJust"><svg viewBox="0 0 40 40"><circle cx="20" cy="20" r="18" class="is-track"/><circle cx="20" cy="20" r="18" class="is-fill"/></svg>Undo</button>
                </div>
            @endif

            @if ($sheet === 'found' && $box)
                @php($inv = $box->invdata)
                @php($addr = collect([$inv?->receiver_address, $inv?->receiver_barangay, $inv?->receiver_city, $inv?->receiver_province])->filter()->map(fn ($x) => \Illuminate\Support\Str::title($x))->join(', '))
                <div class="ds-sa__sheet" wire:key="found-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-dr__tags"><span class="ds-dr__ontruck">On your truck</span><strong>{{ $box->invoice }}</strong>@if ($inv?->boxtype)<em>{{ $inv->boxtype }}</em>@endif</div>
                    <div class="ds-dr__receiver"><strong>{{ \Illuminate\Support\Str::title($inv?->receiver_name) }}</strong><span>{{ $addr }}</span></div>
                    <div class="ds-dr__two">
                        @if ($inv?->receiver_mobile_no)
                            <a href="tel:{{ preg_replace('/[^0-9+]/', '', $inv->receiver_mobile_no) }}"><svg viewBox="0 0 24 24" fill="none" stroke="#34c38f" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2"/></svg>Call</a>
                        @endif
                        <a href="https://www.google.com/maps/search/?api=1&query={{ urlencode($addr.', Philippines') }}" target="_blank" rel="noopener"><svg viewBox="0 0 24 24" fill="none" stroke="#5aa8ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m3 11 18-8-8 18-2-8z"/></svg>Directions</a>
                    </div>
                    <span class="ds-dr__meta">From {{ \Illuminate\Support\Str::title($inv?->sender_name) ?: 'sender' }}@if ($household && $household['count'] > 1) · {{ $household['count'] }} boxes for this house, {{ $household['delivered'] }} delivered @endif</span>
                    @if ($box->latestDeliveryAttempt)
                        <span class="ds-dr__prev">Tried before: {{ $box->latestDeliveryAttempt->reason->getLabel() }} · {{ $box->latestDeliveryAttempt->created_at->diffForHumans() }}</span>
                    @endif
                    @if ($risk && $risk['score'] >= 50)
                        <span class="ds-dr__risk"><b>Heads up · may not be delivered</b>{{ implode(' · ', $risk['reasons']) }}. {{ $inv?->receiver_mobile_no ? 'Call before you go.' : '' }}</span>
                    @endif
                    <button type="button" class="ds-sa__primary is-green" wire:click="startDeliver">Deliver this box</button>
                    <button type="button" class="ds-sa__secondary" wire:click="startMiss">Can't deliver</button>
                </div>
            @endif

            @if ($sheet === 'deliver' && $box)
                <div class="ds-sa__sheet" wire:key="deliver-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <span class="ds-dr__sheethead"><small>{{ $box->invoice }} · {{ \Illuminate\Support\Str::title($box->invdata?->receiver_name) }}</small><strong>Proof of delivery</strong><span>Take as many photos as you need: the house, the box at the door, the receiver.</span></span>
                    <div class="ds-dr__grid" x-data="{{ $photoJs }}">
                        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                        @foreach ($photoUrls as $i => $url)
                            <span class="ds-dr__proof" wire:key="ph-{{ $i }}-{{ md5($url) }}"><img src="{{ $url }}" alt="Photo {{ $i + 1 }}"><b>{{ $i + 1 }}</b><button type="button" wire:click="removePhoto({{ $i }})" aria-label="Remove photo {{ $i + 1 }}">✕</button></span>
                        @endforeach
                        <button type="button" class="ds-dr__add" x-on:click="take()" x-bind:disabled="busy">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                            <span x-show="! busy">{{ $photoUrls ? 'Add another' : 'Take photo' }}</span>
                            <span x-show="busy" x-cloak>Saving… <span x-text="pct + '%'"></span></span>
                        </button>
                        <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                    </div>
                    <button type="button" @class(['ds-sa__primary', 'is-green' => $photoUrls, 'is-off' => ! $photoUrls]) wire:click="confirmDelivered" @disabled(! $photoUrls)>
                        {{ $photoUrls ? 'Delivered · '.count($photoUrls).' '.str('photo')->plural(count($photoUrls)) : 'Take at least 1 photo' }}
                    </button>
                    <button type="button" class="ds-dr__link" wire:click="backToBox">Back</button>
                </div>
            @endif

            @if ($sheet === 'miss' && $box)
                <div class="ds-sa__sheet is-warn" wire:key="miss-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <span class="ds-dr__sheethead is-warn"><small>{{ $box->invoice }} · {{ \Illuminate\Support\Str::title($box->invdata?->receiver_name) }}</small><strong>Why couldn't you deliver it?</strong></span>
                    <div class="ds-dr__chips" role="group" aria-label="Reason">
                        @foreach ($reasons as $r)
                            <button type="button" wire:click="$set('reason', '{{ $r->value }}')" @class(['is-on' => $reason === $r->value])>{{ $r->getLabel() }}</button>
                        @endforeach
                    </div>
                    @if ($voiceOn)
                        <div class="ds-dr__voice" x-data="{
                            ok: !! (window.SpeechRecognition || window.webkitSpeechRecognition), on: false, busy: false, heard: '',
                            start() {
                                const R = window.SpeechRecognition || window.webkitSpeechRecognition; if (! R) return;
                                const r = new R(); r.lang = 'fil-PH'; r.interimResults = true; r.continuous = false;
                                this.heard = ''; this.on = true;
                                r.onresult = (e) => { this.heard = Array.from(e.results).map(x => x[0].transcript).join(' ') };
                                r.onerror = () => { this.on = false };
                                r.onend = () => { this.on = false; if (this.heard.trim()) { this.busy = true; $wire.voiceFill(this.heard).then(() => this.busy = false) } };
                                r.start(); this.rec = r;
                            },
                            stop() { this.rec && this.rec.stop() }
                        }" x-show="ok" x-cloak>
                            <button type="button" x-on:click="on ? stop() : start()" x-bind:class="{ 'is-on': on }" x-bind:disabled="busy" aria-label="Say what happened">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>
                            </button>
                            <span>
                                <b x-text="on ? 'Listening… tap to stop' : (busy ? 'Filling in…' : 'Say what happened')"></b>
                                <small x-text="heard || 'Tagalog, Bisaya or English. The reason and note are filled in for you.'"></small>
                            </span>
                        </div>
                    @endif
                    <input type="text" class="ds-sa__note-in" wire:model.blur="note" maxlength="500" placeholder="{{ $reasonCase?->notePrompt() ?? 'Note' }}{{ $reasonCase?->requiresNote() ? '' : ' (optional)' }}" aria-label="Note">
                    <div class="ds-sa__photos" x-data="{{ $photoJs }}">
                        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                        @foreach ($photoUrls as $i => $url)
                            <span class="ds-sa__shot ds-dr__proof is-small"><img src="{{ $url }}" alt=""><button type="button" wire:click="removePhoto({{ $i }})" aria-label="Remove photo">✕</button></span>
                        @endforeach
                        @if (count($photoUrls) < 3)
                            <button type="button" class="ds-sa__addphoto" x-on:click="take()" x-bind:disabled="busy">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                                <span x-show="! busy">{{ $reasonCase?->requiresPhoto() ? 'Add photo (needed)' : 'Add photo' }}</span><span x-show="busy" x-cloak>Saving…</span>
                            </button>
                        @endif
                    </div>
                    <button type="button" class="ds-sa__primary is-amber" wire:click="saveMissed">Keep it on the truck</button>
                    <button type="button" class="ds-dr__link" wire:click="backToBox">Back</button>
                </div>
            @endif

            @if ($sheet === 'wrong')
                <div class="ds-sa__sheet is-bad" wire:key="wrong-{{ md5((string) $wrongText) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg></span>
                        <span><strong>Not this box</strong><small>Check the label</small></span>
                    </div>
                    <p class="ds-sa__msg">{{ $wrongText }}</p>
                    <button type="button" class="ds-sa__secondary" wire:click="closeSheet">Scan another box</button>
                </div>
            @endif
        </section>
    @endif
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- resources/views/filament/scan/app.blade.php
mkdir -p 'resources/views/filament/scan'
cat > 'resources/views/filament/scan/app.blade.php' <<'DISPATCH_FILE_END_13'
@php
    $ring = fn (int $done, int $total, int $len = 289) => $len - ($total > 0 ? round($len * min($done, $total) / $total) : 0);
    $condOrder = array_keys($conditions);
@endphp
<x-filament-panels::page>
<div class="ds-sa" x-data x-on:scan-app-result.window="if (navigator.vibrate) navigator.vibrate($event.detail.status === 'success' ? 60 : [80, 60, 80])">

    {{-- ============================== start ============================== --}}
    @if ($screen === 'home')
        <section class="ds-sa__screen ds-sa__home" wire:key="home">
            <header class="ds-sa__hello">
                <span><small>{{ $place }}</small><strong>{{ $greeting }}, {{ $firstName }}</strong></span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: 'scan-tips' })" aria-label="Help">?</button>
                <span class="ds-sa__avatar">{{ $initials }}</span>
            </header>

            <div class="ds-sa__today">
                <span class="ds-sa__ring">
                    <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring(min($today['scans'], 500), 500) }}"/></svg>
                    <span><strong>{{ $today['scans'] }}</strong><small>today</small></span>
                </span>
                <dl>
                    <dt>Boxes scanned</dt><dd>{{ number_format($today['scans']) }}</dd>
                    <dt>Photos</dt><dd>{{ number_format($today['photos']) }}</dd>
                    <dt>Problems</dt><dd class="is-bad">{{ $today['problems'] }}</dd>
                </dl>
            </div>

            @if ($modes)
                <p class="ds-sa__label">Start scanning</p>
                <div class="ds-sa__list">
                    @foreach ($modes as $key => $m)
                        <button type="button" class="ds-sa__row" wire:click="open('{{ $key }}')">
                            <span class="ds-sa__chip">@include('filament.scan.icon', ['name' => $m['icon']])</span>
                            <span class="ds-sa__rowtext"><strong>{{ $m['label'] }}</strong><small>{{ $m['sub'] }}</small></span>
                            @php($w = $waiting[$key] ?? 0)
                            <span @class(['ds-sa__waiting', 'is-none' => ! $w])>{{ $w ? $w.' waiting' : 'All done' }}</span>
                            <span class="ds-sa__chev" aria-hidden="true">›</span>
                        </button>
                    @endforeach
                </div>
            @else
                <div class="ds-sa__note">Your account can't scan here. Ask the office to set your account to Warehouse or Company.</div>
            @endif

            <footer class="ds-sa__foot">
                <span class="ds-sa__online"><i></i>Online · every scan is saved</span>
                <span class="ds-sa__footlinks">
                    <button type="button" class="ds-pwa-install" onclick="window.dsInstallApp && window.dsInstallApp()">Install app</button>
                    <form method="POST" action="{{ filament()->getLogoutUrl() }}">@csrf<button type="submit">Sign out</button></form>
                </span>
            </footer>
        </section>
    @endif

    {{-- ============================== pick ============================== --}}
    @if ($screen === 'pick' && $def)
        <section class="ds-sa__screen ds-sa__pick" wire:key="pick-{{ $this->mode }}">
            <button type="button" class="ds-sa__pill" wire:click="home"><span aria-hidden="true">‹</span> Back</button>
            <header class="ds-sa__title ds-sa__title--help"><span><small>{{ $def['label'] }}</small><strong>Choose the {{ $def['kind'] }}</strong></span><button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: '{{ \App\Support\Help\Help::forScanMode($this->mode) }}' })" aria-label="Help">?</button></header>

            @if ($this->mode === 'pick')
                @php($mineList = $choices->where('mine', true)->values())
                @php($openList = $choices->where('mine', false)->values())
                <p class="ds-sa__label">My trips</p>
                @forelse ($mineList as $i => $c)
                    <button type="button" class="ds-pk__mine" wire:click="pick({{ $c['id'] }})" x-on:click="window.dsWarmCamera && window.dsWarmCamera()" wire:key="pm-{{ $c['id'] }}">
                        <span class="ds-pk__row"><b>{{ $c['name'] }}</b><em>Open ›</em></span>
                        @if ($c['sub'])<small>{{ $c['sub'] }}</small>@endif
                        <span class="ds-pk__bar"><i style="width: {{ $c['total'] ? round($c['done'] / $c['total'] * 100) : 0 }}%"></i></span>
                        <small class="is-num">{{ $c['done'] }} of {{ $c['total'] }} picked</small>
                    </button>
                @empty
                    <div class="ds-sa__note">No trip given to you yet. Take one below, or ask the office.</div>
                @endforelse
                <p class="ds-sa__label">No picker yet · your hub</p>
                @forelse ($openList as $c)
                    <div class="ds-pk__open" wire:key="po-{{ $c['id'] }}">
                        <span><b>{{ $c['name'] }}</b><small>{{ $c['total'] }} {{ \Illuminate\Support\Str::plural('box', $c['total']) }}{{ $c['sub'] ? ' · '.$c['sub'] : '' }}</small></span>
                        <button type="button" wire:click="takeTrip({{ $c['id'] }})" x-on:click="window.dsWarmCamera && window.dsWarmCamera()" wire:loading.attr="disabled">Take this trip</button>
                    </div>
                @empty
                    <div class="ds-sa__note">Every trip has a picker.</div>
                @endforelse
                <small class="ds-pk__foot">Trips of other people and trips already picked are not shown here.</small>
            @else
            @forelse ($choices as $i => $c)
                <button type="button" @class(['ds-sa__choice', 'is-finished' => $c['finished']]) style="animation-delay: {{ $i * 50 }}ms" wire:click="pick({{ $c['id'] }})" x-on:click="window.dsWarmCamera && window.dsWarmCamera(@js(\App\Support\ScanModes::scanner()['formats']))" wire:key="c-{{ $c['id'] }}">
                    <span class="ds-sa__choicetext">
                        <strong>{{ $c['name'] }}</strong>
                        @if ($c['sub'])<small>{{ $c['sub'] }}</small>@endif
                        <small class="is-num">{{ $c['done'] }} of {{ $c['total'] }} scanned{{ $c['finished'] ? (($c['active'] ?? true) ? ' · finished' : ' · closed') : '' }}</small>
                    </span>
                    <span class="ds-sa__ring is-small">
                        <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring($c['done'], $c['total']) }}"/></svg>
                        <span><b>{{ $c['total'] ? round($c['done'] / $c['total'] * 100) : 0 }}%</b></span>
                    </span>
                </button>
            @empty
                <div class="ds-sa__note">Nothing left to scan for {{ strtolower($def['label']) }}. Everything open is 100% scanned.</div>
            @endforelse
            @endif

            @if ($finishedCount)
                <button type="button" class="ds-sa__more" wire:click="toggleFinished">
                    {{ $showFinished ? 'Hide finished' : 'Show finished ('.$finishedCount.')' }}
                </button>
            @endif
        </section>
    @endif

    {{-- ============================== scan ============================== --}}
    @if ($screen === 'scan' && $def)
        <section @class(['ds-sa__screen', 'ds-sa__scan', 'is-pick' => $this->mode === 'pick']) wire:key="scan-{{ $this->mode }}-{{ $choice }}">
            @if ($aiFlag)
                <div class="ds-sa__aiflag" wire:key="aiflag-{{ $aiFlag->id }}">
                    <span class="ds-sa__aibadge">AI</span>
                    <span><b>{{ $aiFlag->invoice }} looks {{ strtolower($aiFlag->label()) }}?</b><small>{{ $aiFlag->note }}</small></span>
                    <button type="button" wire:click="aiFlagAnswer({{ $aiFlag->id }}, true)">Yes, mark it</button>
                    <button type="button" class="is-plain" wire:click="aiFlagAnswer({{ $aiFlag->id }}, false)">It's fine</button>
                </div>
            @elseif ($aiPending)
                <span wire:poll.8s class="hidden"></span>
            @endif
            <div class="ds-sa__cam" wire:ignore
                 x-data="barcodeScanner(@js(\App\Support\ScanModes::scanner()))">
                <video x-ref="video" playsinline muted autoplay></video>
                <div class="ds-sa__frame" x-bind:class="{ 'is-hit': flash }"><i></i><i></i><i></i><i></i><span x-show="scanning" class="ds-sa__sweep"></span></div>
                <p class="ds-sa__camtext" x-show="loading" x-cloak>Starting camera…</p>
                <p class="ds-sa__camtext is-error" x-show="error" x-text="error" x-cloak></p>
                <p class="ds-sa__camtext is-hint" x-show="hint && ! error" x-text="hint" x-cloak></p>
                @include('filament.scan.cam-extras', ['uploads' => true])

                <div class="ds-sa__controls">
                    <label class="ds-sa__type">
                        <input type="text" x-model="manualCode" x-on:keydown.enter.prevent="submitManual()" placeholder="Type or use a handheld scanner" autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="go" aria-label="Box number">
                        <button type="button" x-on:click="submitManual()" aria-label="Find">→</button>
                    </label>
                    <div class="ds-sa__buttons">
                        <button type="button" class="ds-sa__round" x-show="torchSupported && scanning" x-on:click="toggleTorch()" x-bind:class="{ 'is-on': torchOn }" aria-label="Flashlight" x-cloak>
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h6l-1 6h-4zM10 8h4v12a2 2 0 0 1-4 0z"/></svg>
                        </button>
                        <button type="button" class="ds-sa__shutter" x-on:click="toggle()" x-bind:aria-label="scanning ? 'Stop camera' : 'Start camera'">
                            <span x-bind:class="{ 'is-live': scanning }"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></span>
                        </button>
                        <button type="button" class="ds-sa__round is-text" wire:click="finish">Done</button>
                    </div>
                </div>
            </div>

            <header class="ds-sa__bar">
                <button type="button" class="ds-sa__back" wire:click="back" aria-label="Back">‹</button>
                <span class="ds-sa__bartext"><small>{{ $def['label'] }}</small><strong>{{ $target['name'] ?? '' }}{{ ! empty($target['sub']) ? ' · '.$target['sub'] : '' }}</strong></span>
                <span class="ds-sa__ring is-tiny">
                    <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring($progress['loaded'] ?? 0, $progress['total'] ?? 0) }}"/></svg>
                </span>
                <span class="ds-sa__count"><strong>{{ $progress['loaded'] ?? 0 }}</strong><small>of {{ $progress['total'] ?? 0 }}</small>@if ($space)<small class="ds-sa__space">{{ \App\Support\BoxSizes::fmt($space['loaded']) }}{{ $space['cap'] ? ' / '.$space['cap'] : '' }} space</small>@endif</span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: '{{ \App\Support\Help\Help::forScanMode($this->mode) }}' })" aria-label="Help">?</button>
            </header>

            <span class="hidden" wire:key="pz-{{ $sessionScans }}-{{ $status ?? 'none' }}-{{ $paused ? 1 : 0 }}" x-init="$dispatch('ds-scanner', { paused: @js($paused) })"></span>
            @if (! $extrasReady)
                <div @class(['ds-sx__skel', 'hidden' => ! in_array($this->mode, ['load', 'hub_load'], true)]) wire:init="loadExtras"><i></i><i></i><i></i><small>Load next and space: coming… you can scan already</small></div>
            @endif

            @if (count($team) > 1)
                <div class="ds-sx__team" aria-label="Who scanned">
                    @foreach (array_slice($team, 0, 4) as $m)<span @class(['is-me' => $m['me']])>{{ $m['name'] }} <b>{{ $m['n'] }}</b></span>@endforeach
                </div>
            @endif

            @if ($this->mode === 'unload' && $trucks)
                @foreach ($trucks as $tk)
                    <div class="ds-sx__here"><b>🚚 Truck to {{ $tk['to'] }} is here</b><span>{{ $tk['onTruck'] }} on truck</span></div>
                @endforeach
            @endif

            @if (! $status && $loadNext && $loadNext['stop'])
                @include('filament.partials.load-next', ['next' => $loadNext, 'dark' => true])
            @endif

            @if (! $status && ! $bypass && $cityTopUp)
                <div class="ds-sx__citytop" wire:key="citytop-{{ $cityTopUp['key'] }}">
                    <b>✦ Room for {{ $cityTopUp['room'] }} more boxes</b>
                    <span>{{ $cityTopUp['same'] ? 'Same way' : 'Next province' }}: <b>{{ $cityTopUp['city'] }}, {{ $cityTopUp['province'] }}</b> · {{ $cityTopUp['boxes'] }} {{ Str::plural('box', $cityTopUp['boxes']) }}{{ $cityTopUp['days'] ? ', '.$cityTopUp['days'].' '.Str::plural('day', $cityTopUp['days']).' old' : '' }}.@if ($cityTopUp['section']) In section <b>{{ $cityTopUp['section'] }}</b>.@endif</span>
                    <button type="button" class="ds-sa__primary" wire:click="cityTopUpAdd(@js($cityTopUp['key']))">Scan them now</button>
                    <button type="button" class="ds-sa__secondary" wire:click="cityTopUpSkip">No thanks</button>
                </div>
            @endif

            @if ($this->mode === 'pick')
                @php($allPicked = ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total'])
                @if ($pickResult)
                    <div @class(['ds-sa__sheet', 'ds-pk__sheet', 'is-ok' => $pickResult['tone'] === 'ok', 'is-warn' => $pickResult['tone'] === 'warn', 'is-bad' => $pickResult['tone'] === 'bad']) wire:key="pk-{{ $sessionScans }}-{{ md5($pickResult['title'].$pickResult['code']) }}">
                        <span class="ds-sa__grab"></span>
                        <span class="ds-pk__hit"><b>{{ $pickResult['code'] ? 'Box '.$pickResult['code'] : '' }}</b><small>{{ ! empty($pickResult['spot']) ? 'Spot '.$pickResult['spot'] : (! empty($pickResult['section']) ? 'Section '.$pickResult['section'] : '') }}</small></span>
                        <strong>{{ $pickResult['title'] }}</strong>
                        <p class="ds-sa__msg">{{ $pickResult['why'] }}</p>
                        @if ($pickResult['undo'])
                            <button type="button" class="ds-pk__undo" wire:click="undoPick({{ $pickResult['undo'] }})">↶ Undo: I picked this by mistake</button>
                        @endif
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">Scan next box</button>
                    </div>
                @endif
                @if ($allPicked)
                    <div class="ds-pk__ready"><b>✓ All {{ $progress['total'] }} boxes picked</b><span>Ready to load. Bring them to the truck.</span>
                        <button type="button" class="ds-sa__primary" wire:click="goLoad">Go to Load truck</button></div>
                @endif
                <div class="ds-pk__list" wire:poll.6s.visible>
                    @foreach ($pickGroups as $g)
                        <div class="ds-pk__group" wire:key="pg-{{ md5($g['name']) }}">
                            <span class="ds-pk__gh"><b><i style="background: {{ $g['color'] }}"></i>{{ $g['name'] }}</b><small @class(['is-done' => $g['done'] >= $g['total']])>{{ $g['done'] }} of {{ $g['total'] }}</small></span>
                            <span class="ds-pk__boxes">
                                @foreach ($g['boxes'] as $b)
                                    @if ($b['picked'])
                                        <span @class(['ds-pk__box', 'is-picked', 'is-mine' => $b['byId'] === auth()->id()]) title="Picked by {{ $b['by'] }}">✓ {{ $b['code'] }}<small>{{ $b['byId'] === auth()->id() ? 'you' : $b['by'] }}</small></span>
                                    @elseif ($b['missing'])
                                        <span class="ds-pk__box is-missing" title="Not found by {{ $b['missBy'] }}">? {{ $b['code'] }}<small>not found</small></span>
                                    @else
                                        <button type="button" @class(['ds-pk__box', 'is-combo' => $b['combo']]) wire:click="notFound({{ $b['id'] }})" wire:confirm="Can't find {{ $b['code'] }} in its place? Mark it not found.">{{ $b['code'] }}@if ($b['combo'])<small>combo</small>@endif</button>
                                    @endif
                                @endforeach
                            </span>
                        </div>
                    @endforeach
                    <small class="ds-pk__foot">Scan each box you take. Tap a box you cannot find to mark it not found. Every phone on this trip sees the same list.</small>
                </div>
            @elseif ($bypass)
                <div class="ds-sa__sheet is-warn" wire:key="bypass-{{ $bypass['code'] }}">
                    <span class="ds-sa__grab"></span>
                    @if ($bypass['need'] === 'office')
                        <p class="ds-sa__msg"><b>{{ $bypass['title'] }}: office only.</b> Ask the office to allow {{ $bypass['code'] }}. Keep the box aside until they answer.</p>
                        <button type="button" class="ds-sa__primary" wire:click="askOffice">Ask the office</button>
                    @else
                        <span class="ds-sa__hit"><span><small class="ds-ld__kicker">{{ $bypass['title'] }} · load anyway</small><strong>{{ $bypass['code'] }}</strong></span></span>
                        <p class="ds-sa__msg"><b>Why? (the office sees this)</b></p>
                        <div class="ds-sx__reasons">@foreach ($bypassReasons as $r)<button type="button" wire:click="bypassWith(@js($r))">{{ $r }}</button>@endforeach</div>
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="cancelBypass">Cancel</button>
                </div>
            @elseif ($status === 'success' && $box)
                <div class="ds-sa__sheet is-ok" wire:key="ok-{{ $invoiceId }}-{{ $sessionScans }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-ok"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></span>
                        <span><strong>{{ $box->invoice }}</strong><small>{{ $def['ok'] }}</small></span>
                        @if ($boxSize && $boxSize['space'] != 1)<em class="ds-sa__size">{{ $boxSize['name'] }} · takes {{ \App\Support\BoxSizes::fmt($boxSize['space']) }} space</em>@elseif ($box->boxtype)<em>{{ $box->boxtype }}</em>@endif
                    </div>
                    @if ($this->mode === 'count')<p class="ds-sa__msg">{{ $message }}</p>@endif
                    @if ($route)
                        <div @class(['ds-sx__tile', 'is-truck' => ($route['kind'] ?? '') === 'truck']) style="--sx: {{ $route['color'] ?? '#1d6fb8' }}">
                            <small>{{ match ($route['kind'] ?? '') { 'truck' => 'Carry this box to', 'wrong' => 'Careful', default => 'Put this box in' } }}</small>
                            <strong>{{ ($route['kind'] ?? '') === 'truck' ? 'TRUCK' : $route['code'] }}</strong>
                            <span>{{ ($route['kind'] ?? '') === 'truck' ? $route['name'].(! empty($route['plate']) ? ' · '.$route['plate'] : '') : $route['name'] }}</span>
                            @if (($route['kind'] ?? '') === 'truck')<em>✓ Already loaded on trip {{ $route['trip'] }}. No need to scan it again.</em>@endif
                            @if (! empty($route['why']))<em>{{ $route['why'] }}</em>@endif
                            @if (! empty($route['pending']))<em>Then scan the QR on section {{ $route['code'] }}.</em>@endif
                            @if (! empty($route['spot']) && $route['spot'] !== 'skip')<em>✓ Spot {{ $route['spot'] }}</em>@elseif (($route['spot'] ?? null) === 'skip')<em>No spot · in section {{ $route['code'] }}</em>@endif
                        </div>
                        @if (! empty($route['spots']) && empty($route['spot']))
                            <span class="ds-sx__spoth">Spot? scan its QR, tap one, or skip</span>
                            <span class="ds-sx__spots">@foreach ($route['spots'] as $sp)<button type="button" wire:click="setSpot({{ $sp['id'] }})">{{ $sp['code'] }}</button>@endforeach</span>
                            <button type="button" class="ds-sx__skip" wire:click="setSpot">Skip · just section {{ $route['code'] }}</button>
                        @endif
                        @if (($route['kind'] ?? '') === 'truck')
                            <button type="button" class="ds-sx__link" wire:click="putInSection">Put in section instead</button>
                        @endif
                    @endif
                    @if ($hubTrip)
                        <div @class(['ds-ws__trip', 'is-new' => $hubTrip['kind'] === 'new', 'is-anyway' => $hubTrip['kind'] === 'anyway'])>
                            <small>{{ $hubTrip['kind'] === 'new' ? 'Trip full · goes on a new trip' : 'Goes on trip' }}</small>
                            <b class="ds-ws__to">→ {{ $hubTrip['trip'] }}</b>
                            <small>{{ $hubTrip['why'] }}</small>
                            @if ($hubTrip['kind'] === 'new' && ! empty($hubTrip['full']))
                                <button type="button" wire:click="hubAnyway" wire:loading.attr="disabled">Add anyway to {{ $hubTrip['full']['number'] }}</button>
                            @endif
                        </div>
                    @endif
                    @if ($setInfo)
                        <div @class(['ds-sx__set', 'is-'.$setInfo['kind']])>
                            <span><b>{{ $setInfo['name'] }}</b> · box {{ $setInfo['n'] }} of {{ $setInfo['of'] }}</span>
                            <span class="ds-sx__dots">@for ($i = 1; $i <= min(12, $setInfo['of']); $i++)<i @class(['is-on' => $i <= $setInfo['n']])></i>@endfor</span>
                            <small>{{ $setInfo['text'] }}</small>
                            @if (! empty($setInfo['rows']))
                                <ul class="ds-sx__setrows">@foreach ($setInfo['rows'] as $sr)<li><span>{{ $sr['i'] }}</span>{{ $sr['t'] }}</li>@endforeach</ul>
                            @endif
                            @foreach ($setInfo['add'] ?? [] as $sa)
                                <button type="button" class="ds-sx__setadd" wire:click="addSetBox({{ $sa['id'] }})">Bring {{ $sa['invoice'] }} from section {{ $sa['section'] ?? '?' }} · add to truck</button>
                            @endforeach
                        </div>
                    @endif
                    @if ($spot)
                        <div class="ds-ld__spot is-{{ $spot['zone'] }}"><strong>{{ \App\Models\Maps\TripStop::ZONES[$spot['zone']] ?? '' }}</strong><span>{{ ! empty($spot['hub']) ? $spot['hub'].' (stop '.$spot['stop'].')' : 'Stop '.$spot['stop'] }} · {{ ['front' => 'deep inside, next to the cab', 'middle' => 'in the middle', 'back' => 'near the door'][$spot['zone']] ?? '' }}</span></div>
                    @endif
                    <div class="ds-sa__who">
                        <span>{{ mb_strtoupper(mb_substr($box->receiver_name ?? '?', 0, 2)) }}</span>
                        <span><strong>{{ \Illuminate\Support\Str::title($box->receiver_name) }}</strong><small>{{ collect([$box->receiver_barangay, $box->receiver_city])->filter()->map(fn ($p) => \Illuminate\Support\Str::title($p))->join(', ') }}</small></span>
                    </div>

                    @if ($this->photosOn())
                        @php($ci = max(0, (int) array_search($condition ?? 'good', $condOrder, true)))
                        <div class="ds-sa__seg" role="group" aria-label="How does the box look?">
                            <span class="ds-sa__segthumb is-{{ $condition ?? 'good' }}" style="left: calc(4px + {{ $ci }} * (100% - 8px) / 4)"></span>
                            @foreach ($conditions as $key => $label)
                                <button type="button" wire:click="setCondition('{{ $key }}')" @class(['is-on' => ($condition ?? 'good') === $key]) aria-pressed="{{ ($condition ?? 'good') === $key ? 'true' : 'false' }}"><i class="is-{{ $key }}"></i>{{ $label }}</button>
                            @endforeach
                        </div>
                        @if (in_array($condition, ['damaged', 'wet', 'open'], true))
                            <input type="text" class="ds-sa__note-in" wire:model.blur="note" maxlength="250" placeholder="What is wrong? (optional)" aria-label="What is wrong?">
                        @endif

                        <div class="ds-sa__photos ds-snap" wire:ignore
                             x-data="{ rendered: @js($shots->pluck('id')->all()), inv: {{ (int) $box->id }}, code: @js($box->invoice), busy: false, msg: null,
                                mine() { return window.dsPhotos ? window.dsPhotos.of(this.inv).filter((i) => ! this.rendered.includes(i.serverId)) : [] },
                                info() { return { invoiceId: this.inv, code: this.code, condition: $wire.condition, note: $wire.note, url: @js(route('scan.box-photo')) } },
                                async here() {
                                    if (this.busy || ! window.dsScanner) return; this.busy = true; this.msg = null;
                                    const f = await window.dsScanner.snapPhoto();
                                    this.busy = false;
                                    if (! f) { this.msg = 'The camera is off. Use Camera app.'; return; }
                                    window.dsPhotos.add(f, this.info());
                                },
                                app() { window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { release: true } })); this.$refs.file.value = ''; this.$refs.file.click() },
                                picked(e) { const f = e.target.files[0]; if (f) window.dsPhotos.add(f, this.info()) } }">
                            <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="picked($event)">
                            @foreach ($shots as $shot)
                                <a href="{{ $shot->url() }}" target="_blank" class="ds-sa__shot"><img src="{{ $shot->url() }}" alt="Photo {{ $loop->iteration }}"><b class="is-done">✓</b></a>
                            @endforeach
                            <template x-for="it in mine()" :key="it.id">
                                <span class="ds-sa__shot" x-on:click="it.failed && window.dsPhotos.retry(it)"><img :src="it.thumb" alt="Photo"><b :class="{ 'is-done': it.done, 'is-bad': it.failed }" x-text="it.failed ? 'Retry' : (it.done ? '✓' : it.p + '%')"></b></span>
                            </template>
                            <button type="button" class="ds-snap__here" x-on:click="here()" x-bind:disabled="busy">📷 Take photo here</button>
                            <button type="button" class="ds-snap__app" x-on:click="app()">Camera app<small>close-up</small></button>
                            <p class="ds-snap__note" x-text="msg || (mine().length ? 'Uploads in the back. You can scan the next box now.' : (['damaged', 'wet', 'open'].includes($wire.condition) ? 'Damaged: take a photo. Camera app for a close-up with flash.' : 'Photo optional · Take photo here uses the camera that is already on.'))"></p>
                        </div>
                    @endif
                    <button type="button" @class(['ds-sa__primary', 'is-light' => $this->photosOn()]) wire:click="dismiss">Scan next box</button>
                </div>
            @elseif ($status === 'success' && $route)
                <div class="ds-sa__sheet is-ok" wire:key="placed-{{ $sessionScans }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sx__tile" style="--sx: {{ $route['color'] ?? '#1d6fb8' }}"><small>Saved in</small><strong>{{ $route['code'] }}</strong><span>{{ $route['name'] }}</span></div>
                    <p class="ds-sa__msg">{{ $message }}</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">Scan next box</button>
                </div>
            @elseif ($status === 'warning' && $wrongHub)
                <div class="ds-sa__sheet is-bad" wire:key="wronghub-{{ $sessionScans }}-{{ $wrongHub['code'] }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad">⛔</span>
                        <span><small class="ds-ld__kicker">{{ ['city' => 'Other city', 'wh' => 'Not for '.($wrongHub['trip'] ?? ''), 'full' => 'Truck full', 'hub' => 'Not for this trip'][$wrongHub['kind'] ?? ''] ?? 'Wrong hub' }}</small><strong>{{ ($wrongHub['kind'] ?? null) === 'full' ? $wrongHub['code'].' does not fit' : $wrongHub['code'].' is for '.$wrongHub['for'] }}</strong></span>
                    </div>
                    @if (($wrongHub['kind'] ?? null) === 'full')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }}. This box takes {{ $wrongHub['space'] }} space: it waits for the next {{ $wrongHub['province'] }} trip. Put it back{{ $wrongHub['section'] !== '—' ? ' in section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">It still fits · load anyway</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'wh')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }} is delivered from {{ $wrongHub['home'] }}. Not loaded: it stays here{{ $wrongHub['section'] !== '—' ? ', section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">The office says load it</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'hub')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }} goes {{ str_contains($wrongHub['home'], 'own trucks') ? 'with '.$wrongHub['home'] : 'to '.$wrongHub['home'] }}. Not loaded on {{ $wrongHub['trip'] }}: put it back{{ $wrongHub['section'] !== '—' ? ' in section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Deliver it on this trip anyway</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'city')
                        <p class="ds-sa__msg">This trip goes to {{ $wrongHub['trip'] }}. Not loaded. Put it back in section {{ $wrongHub['section'] }}; it goes on a trip to its own city.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Add it to this trip anyway</button>
                    @else
                    <p class="ds-sa__msg">This trip goes to {{ $wrongHub['trip'] }}. Not loaded. Put it back in section {{ $wrongHub['section'] }} and tell the office.</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                    <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">The office says load it</button>
                    @endif
                </div>
            @elseif ($status === 'warning' && $early)
                <div class="ds-sa__sheet is-warn" wire:key="early-{{ $sessionScans }}-{{ $early['code'] }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-warn">!</span>
                        <span><small class="ds-ld__kicker">Too early</small><strong>{{ $early['code'] }} is for stop {{ $early['stop'] }}{{ $early['place'] ? ' ('.$early['place'].')' : '' }}</strong></span>
                    </div>
                    <p class="ds-sa__msg">It's delivered earlier, so it goes in later, {{ $early['zone'] === 'back' ? 'at the door' : 'in the middle' }}. Put it aside and load stop {{ $early['nextStop'] }} now.</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put aside</button>
                    <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Load it anyway</button>
                </div>
            @elseif ($status === 'warning')
                <div class="ds-sa__sheet is-warn" wire:key="warn-{{ $sessionScans }}-{{ md5($message) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-warn">!</span>
                        <span><strong>{{ $box?->invoice ?? 'Check this box' }}</strong><small>{{ $message }}</small></span>
                    </div>
                    <button type="button" class="ds-sa__secondary" wire:click="dismiss">OK, scan next</button>
                </div>
            @elseif ($status === 'danger')
                <div class="ds-sa__sheet is-bad" wire:key="bad-{{ $sessionScans }}-{{ md5($message) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg></span>
                        <span><strong>{{ $missing ?? $box?->invoice ?? 'Wrong box' }}</strong><small>Not on this {{ $def['kind'] }}</small></span>
                    </div>
                    <p class="ds-sa__msg">{{ $message }}</p>
                    @if ($missing && $this->mode === 'unload')
                        {{ $this->unmanifestedAction }}
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="dismiss">Keep it aside, scan next</button>
                </div>
            @endif
        </section>
    @endif

    {{-- ============================== done ============================== --}}
    @if ($screen === 'done' && $def)
        <section class="ds-sa__screen ds-sa__done" wire:key="done">
            <span class="ds-sa__ring is-big">
                <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="48" class="is-track"/><circle cx="55" cy="55" r="48" class="is-fill is-ok" style="stroke-dasharray: 302; stroke-dashoffset: {{ $ring($progress['loaded'] ?? 0, $progress['total'] ?? 0, 302) }}"/></svg>
                <span><i><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></i></span>
            </span>
            @php($complete = ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total'])
            <h2>{{ $complete ? $def['done'] : ($progress['loaded'] ?? 0).' of '.($progress['total'] ?? 0).' scanned' }}</h2>
            <p>{{ $target['name'] ?? '' }}{{ ! empty($target['sub']) ? ' · '.$target['sub'] : '' }}</p>
            <div class="ds-sa__totals">
                <span><strong>{{ $sessionScans }}</strong><small>scanned now</small></span>
                <span><strong>{{ $today['photos'] }}</strong><small>photos today</small></span>
                <span><strong class="is-bad">{{ $today['problems'] }}</strong><small>problems today</small></span>
            </div>
            <p class="ds-sa__note">{{ $complete ? 'Everything on this '.$def['kind'].' is scanned. The office sees it right away.' : 'You can come back and finish later; every scan is already saved.' }}</p>
            @if ($topUp && $topUp['room'] >= 1)
                <div class="ds-sx__topup">
                    <strong>Room for about {{ \App\Support\BoxSizes::fmt($topUp['room']) }} more on the truck</strong>
                    @forelse ($topUp['boxes'] as $tb)
                        <div class="ds-sx__toprow" wire:key="tu-{{ $tb['id'] }}">
                            <span><b>{{ $tb['invoice'] }} · {{ $tb['name'] }}</b><small>{{ $tb['place'] }}{{ $tb['section'] ? ' · section '.$tb['section'] : '' }}{{ $tb['space'] != 1 ? ' · takes '.\App\Support\BoxSizes::fmt($tb['space']) : '' }}</small></span>
                            <button type="button" wire:click="topUpAdd({{ $tb['id'] }})">Add</button>
                        </div>
                    @empty
                        <small>No waiting boxes for these provinces.</small>
                    @endforelse
                    <small>Waiting boxes for the same provinces, oldest and priority first. Add one, then scan it onto the truck.</small>
                </div>
            @endif
            @if ($receiveResult)
                <div class="ds-sx__open">
                    <strong>{{ $receiveResult['got'] }} of {{ $receiveResult['of'] }} boxes received</strong>
                    @if (count($receiveResult['missing']))
                        <span>{{ $receiveResult['of'] - $receiveResult['got'] }} not scanned:</span>
                        @foreach ($receiveResult['missing'] as $rm)
                            <span class="ds-sx__miss"><span>{{ $rm['code'] }} <small>{{ $rm['sub'] }}</small></span></span>
                        @endforeach
                        <small>Look in the truck once more. Found it? Keep scanning.</small>
                    @else
                        <span>✓ Every box arrived.</span>
                    @endif
                    @if ($receiveResult['finished'])
                        <span>✓ Receiving finished.</span>
                    @else
                        <button type="button" class="ds-sa__secondary" wire:click="finishReceiving" wire:confirm="Finish receiving? Boxes not scanned get a Missing box issue each.">Finish receiving{{ ! empty($receiveResult['next']) ? ' · pass on to '.$receiveResult['next'] : '' }}</button>
                    @endif
                </div>
            @endif
            @if ($countResult)
                <div class="ds-sx__open">
                    <strong>Section {{ $countResult['code'] }}: {{ $countResult['found'] }} found{{ $countResult['moved'] ? ' · '.$countResult['moved'].' moved in' : '' }}</strong>
                    @if (count($countResult['missing']))
                        <span>{{ count($countResult['missing']) }} missing: {{ implode(', ', array_slice($countResult['missing'], 0, 12)) }}{{ count($countResult['missing']) > 12 ? '…' : '' }}</span>
                    @else
                        <span>✓ Nothing missing.</span>
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="closeCount" wire:confirm="Close the count of section {{ $countResult['code'] }}?">Close the count</button>
                </div>
            @endif
            @if (count($openSets))
                @if ($noReason)<p class="ds-sx__stop">⛔ Not ready to leave: {{ $noReason }} {{ $noReason === 1 ? 'customer has' : 'customers have' }} boxes left behind with no reason.</p>@endif
                <div class="ds-sx__open">
                    <strong>{{ count($openSets) }} {{ count($openSets) === 1 ? 'customer is' : 'customers are' }} missing boxes</strong>
                    @foreach ($openSets as $os)
                        <div class="ds-sx__openrow" wire:key="os-{{ $os['key'] }}">
                            <span><b>{{ $os['name'] }}</b> · {{ $os['have'] }} of {{ $os['of'] }} on the truck</span>
                            @foreach ($os['missing'] as $mb)
                                <span class="ds-sx__miss"><span>{{ $mb['invoice'] }} <small>{{ $mb['where'] }}</small></span>
                                    <span class="ds-sx__why">@foreach ($splitReasons as $rk => $rl)<button type="button" wire:click="splitReason({{ $mb['id'] }}, '{{ $rk }}')" @class(['is-on' => $mb['reason'] === $rk])>{{ $rl }}</button>@endforeach</span>
                                </span>
                            @endforeach
                        </div>
                    @endforeach
                    <small>Find the boxes, or pick why each one stays behind. The office sees it on the trip.</small>
                </div>
            @endif
            <button type="button" class="ds-sa__primary" wire:click="pick({{ $choice }})">Keep scanning</button>
            <button type="button" class="ds-sa__secondary" wire:click="home">Back to start</button>
        </section>
    @endif
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- resources/views/filament/scan/cam-extras.blade.php
mkdir -p 'resources/views/filament/scan'
cat > 'resources/views/filament/scan/cam-extras.blade.php' <<'DISPATCH_FILE_END_14'
{{-- Inside a barcodeScanner() camera (Scan app, Driver app): camera off, dark, hard to read, photos uploading (board 51). --}}
<button type="button" class="ds-cx__off" x-show="! scanning && ! loading && ! error" x-on:click="start()" x-cloak>
    <span>📷</span><b>Camera off · tap to scan</b><small x-show="offWhy" x-text="offWhy"></small>
</button>
<div class="ds-cx__dark" x-show="darkTip && scanning && ! typing" x-cloak>
    <span>🌙 Dark here · turn on the flashlight?</span><button type="button" x-on:click="turnTorchOn()">Turn on</button>
</div>
<button type="button" class="ds-cx__hard" x-show="hard && scanning && ! typing && ! paused" x-on:click="openTyping()" x-cloak>⌨ Hard to read? Type the number</button>
<div class="ds-cx__type" x-show="typing" x-cloak>
    <small>Type the number on the sticker, exactly (with the zeros if it has them)</small>
    <span class="ds-cx__field"><b x-text="typed"></b><i></i><button type="button" x-on:click="findTyped()">Find</button></span>
    <span class="ds-cx__keys">
        <template x-for="k in ['1','2','3','4','5','6','7','8','9','⌫','0','00']" :key="k"><button type="button" x-on:click="key(k)" x-text="k"></button></template>
    </span>
    <button type="button" class="ds-cx__back" x-on:click="closeTyping()">Back to camera</button>
</div>
@if ($uploads ?? false)
    <div class="ds-cx__chips" x-data="{ p() { return window.dsPhotos ? window.dsPhotos : null } }" x-show="p() && (p().going().length || p().saved() || p().failed().length || torchOn)" x-cloak>
        <template x-if="p() && p().going().length"><span class="is-up" x-text="'⇡ ' + p().going().length + (p().going().length > 1 ? ' photos' : ' photo') + ' uploading · ' + ((p().going()[0] || {}).p || 0) + '%'"></span></template>
        <template x-if="p() && p().failed().length"><span class="is-bad" x-on:click="p().failed().forEach((i) => p().retry(i))" x-text="'⚠ ' + p().failed().length + ' not saved · tap to retry'"></span></template>
        <template x-if="p() && p().saved()"><span class="is-ok" x-text="'✓ ' + p().saved() + (p().saved() > 1 ? ' photos' : ' photo') + ' saved'"></span></template>
        <template x-if="torchOn"><span class="is-torch">🔦 Flashlight on</span></template>
    </div>
@endif
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- routes/web.php
mkdir -p 'routes'
cat > 'routes/web.php' <<'DISPATCH_FILE_END_15'
<?php

use App\Http\Controllers\AiChatController;
use App\Http\Controllers\BoxPhotoController;
use App\Http\Controllers\DriverOfflineController;
use App\Http\Controllers\FuelController;
use App\Http\Controllers\InstallQrController;
use App\Http\Controllers\InvoiceController;
use App\Http\Controllers\LoadingListController;
use App\Http\Controllers\PwaController;
use App\Http\Controllers\TrackController;
use Illuminate\Foundation\Http\Middleware\ValidateCsrfToken;
use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken;
use Illuminate\Support\Facades\Route;

// Printable delivery receipt. Only signed-in users (any panel) may print.
Route::get('/tripinv/{invoice}/printpdf', [InvoiceController::class, 'tripinvoice'])
    ->middleware('auth')
    ->whereNumber('invoice')
    ->name('invoicepdf');

// Several receipts at once (at most 15), one per page: /tripinv/print?ids=1,2,3
Route::get('/tripinv/print', [InvoiceController::class, 'bulk'])
    ->middleware('auth')
    ->name('invoicepdf.bulk');

// Install the Delivery panel as an app (PWA): manifest, icons, service worker and offline page.
Route::controller(PwaController::class)->group(function () {
    Route::get('/sw.js', 'serviceWorker')->name('pwa.sw');
    Route::get('/pwa/offline', 'offline')->name('pwa.offline');
    Route::get('/pwa/{panel}/manifest.webmanifest', 'manifest')->whereIn('panel', ['delivery', 'scan'])->name('pwa.manifest');
    Route::get('/pwa/{panel}/icon-{size}.png', 'icon')->whereIn('panel', ['delivery', 'scan'])->whereNumber('size')->name('pwa.icon');
    // Same files without a file ending: Plesk's nginx serves .js / .png / .webmanifest from disk
    // and never asks Laravel, so phones get a 404 and Android does not offer to install.
    Route::get('/pwa/sw', 'serviceWorker')->name('pwa.sw.plain');
    Route::get('/pwa/{panel}/manifest', 'manifest')->whereIn('panel', ['delivery', 'scan'])->name('pwa.manifest.plain');
    Route::get('/pwa/{panel}/icon/{size}', 'icon')->whereIn('panel', ['delivery', 'scan'])->whereNumber('size')->name('pwa.icon.plain');
});

Route::middleware('web')->group(function () {
    Route::get('/box-photos/{photo}.jpg', [BoxPhotoController::class, 'show'])->whereNumber('photo')->name('box-photos.show');
    Route::get('/box-photos/{photo}/download', [BoxPhotoController::class, 'download'])->whereNumber('photo')->name('box-photos.download');
});

// Driver app without signal: today's boxes for the phone, sending what was saved offline, and the offline page.
Route::middleware('web')->group(function () {
    Route::get('/delivery-offline/trip', [DriverOfflineController::class, 'trip'])->name('driver-offline.trip');
    Route::post('/delivery-offline/sync', [DriverOfflineController::class, 'sync'])->name('driver-offline.sync');
    Route::get('/delivery-offline', [DriverOfflineController::class, 'shell'])->name('driver-offline.shell');
});

// Customer chat: receivers ask about their own box (only while "Customer chat" is on in Admin → Settings → AI).
Route::middleware(['web', 'throttle:30,60'])->controller(AiChatController::class)->group(function () {
    Route::get('/ask-box', 'show')->name('ai-chat.show');
    Route::post('/ask-box', 'start')->name('ai-chat.start');
    Route::get('/ask-box/{token}', 'chat')->name('ai-chat.chat');
    Route::post('/ask-box/{token}', 'ask')->name('ai-chat.ask');
});

// Install QR codes for the phone apps (signed-in staff only): download, poster, stickers.
Route::middleware(['web', 'auth'])->controller(InstallQrController::class)->group(function () {
    Route::get('/install-qr/{app}.png', 'png')->whereIn('app', ['scan', 'driver'])->name('install-qr.png');
    Route::get('/install-qr/{app}/poster', 'poster')->whereIn('app', ['scan', 'driver'])->name('install-qr.poster');
    Route::get('/install-qr/{app}/stickers', 'stickers')->whereIn('app', ['scan', 'driver'])->name('install-qr.stickers');
});

// Maps & routes: printed loading list of a trip (FRONT → MIDDLE → BACK).
Route::middleware(['web', 'auth'])->get('/trip-loading/{trip}', [LoadingListController::class, 'show'])
    ->whereNumber('trip')->name('trip.loading-list');

// Truck tracking: the Driver app sends locations during a trip; GPS trackers send to a secret link.
Route::middleware(['web', 'auth', 'throttle:240,1'])->post('/scan/box-photo', [App\Http\Controllers\ScanPhotoController::class, 'store'])->name('scan.box-photo');
Route::middleware(['web', 'auth', 'throttle:120,1'])->post('/delivery-track', [TrackController::class, 'driver'])->name('track.driver');
Route::middleware(['throttle:600,1'])->match(['get', 'post'], '/track/in/{token}', [TrackController::class, 'tracker'])
    ->withoutMiddleware([ValidateCsrfToken::class, VerifyCsrfToken::class, 'Illuminate\Foundation\Http\Middleware\PreventRequestForgery'])
    ->name('track.tracker');

// Fuel › VAT: the month's fuel receipts for the accountant (signed-in staff, their own hub).
Route::get('/fuel/vat-export', [FuelController::class, 'vatExport'])->middleware(['web', 'auth'])->name('fuel.vat-export');

// Printable QR labels for the warehouse sections.
Route::get('/sections/labels', App\Http\Controllers\SectionLabelsController::class)->middleware(['web', 'auth'])->name('sections.labels');
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- tests/Feature/BoxSizesTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/BoxSizesTest.php' <<'DISPATCH_FILE_END_16'
<?php

use App\Filament\Pages\Ai\AiTrips as AdminTrips;
use App\Filament\Pages\BoxSizeSettings;
use App\Filament\Scan\Pages\ScanApp;
use App\Models\Ai\AiSetting;
use App\Models\AppSetting;
use App\Models\Boxes\BoxSize;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Truck;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Http;
use Livewire\Livewire;

uses(RefreshDatabase::class);

function sizeBox(string $no, string $type, string $name = 'Maria Santos', string $brgy = 'Basak', string $phone = '09171112222'): Invoice
{
    return Invoice::create([
        'container_id' => Container::value('id'), 'invoice' => $no, 'sender_name' => 'Sender', 'receiver_name' => $name,
        'receiver_address' => '1 Street', 'receiver_province' => 'Cebu', 'receiver_city' => 'Mandaue City', 'receiver_barangay' => $brgy,
        'receiver_mobile_no' => $phone, 'boxtype' => $type, 'location_code' => 'X', 'is_verified' => true, 'warehouse_id' => 1,
    ]);
}

function sizeOfName(string $name): BoxSize
{
    return BoxSize::where('name', $name)->firstOrFail();
}

beforeEach(function () {
    (fn () => static::$memo = null)->call(new AppSetting); // kept in memory between tests
    BoxSizes::forget();
    $this->seed(DemoSeeder::class);
    Invoice::query()->update(['boxtype' => 'Medium', 'is_verified' => false]);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
});

it('reads the box types from the manifests, joins spellings, and makes the most common one the normal box', function () {
    foreach (['LARGE', 'Large Box', 'large'] as $i => $t) {
        sizeBox("L{$i}", $t);
    }
    sizeBox('X1', 'X-LARGE');
    sizeBox('X2', 'XL');
    sizeBox('B1', 'Bulilit');

    expect(BoxSizes::key('Large Box'))->toBe('large')
        ->and(BoxSizes::key(' X-LARGE '))->toBe('xlarge')
        ->and(BoxSizes::key('Med. Box'))->toBe('med');

    BoxSizes::sync();
    expect(BoxSize::pluck('name')->sort()->values()->all())->toBe(['Bulilit', 'Large', 'Medium', 'X-Large', 'XL'])
        ->and(sizeOfName('Medium')->is_base)->toBeTrue()
        ->and(sizeOfName('Large')->is_set)->toBeFalse();

    // a second sync adds nothing new
    expect(BoxSizes::sync())->toBe(0);

    // "X-LARGE" and "XL" look like the same box
    $pairs = collect(BoxSizes::lookAlike());
    expect($pairs)->toHaveCount(1)
        ->and($pairs[0]['into']->name)->toBe('XL');
    BoxSizes::join($pairs[0]['from'], $pairs[0]['into']);
    expect(sizeOfName('XL')->spellings)->toContain('xl', 'xlarge')
        ->and(BoxSizes::lookAlike())->toBe([]);
});

it('counts space only once a size is set, and a missing or unknown type is 1', function () {
    sizeBox('L1', 'Large');
    BoxSizes::sync();
    expect(BoxSizes::on())->toBeFalse()           // everything still 1: count boxes as before
        ->and(BoxSizes::spaceOf('Large'))->toBe(1.0);

    BoxSizes::setSpace(sizeOfName('Large'), 1.5);
    expect(BoxSizes::on())->toBeTrue()
        ->and(BoxSizes::spaceOf('LARGE box'))->toBe(1.5)
        ->and(BoxSizes::spaceOf(''))->toBe(1.0)
        ->and(BoxSizes::spaceOf('Never seen'))->toBe(1.0)
        ->and(BoxSizes::fmt(1.5))->toBe('1½')
        ->and(BoxSizes::fmt(0.5))->toBe('½');

    AppSetting::put(BoxSizes::SETTING, '0');
    BoxSizes::forget();
    expect(BoxSizes::on())->toBeFalse()->and(BoxSizes::spaceOf('Large'))->toBe(1.0);
});

it('keeps the real sizes when the normal box changes', function () {
    sizeBox('L1', 'Large');
    sizeBox('X1', 'XL');
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('Large'), 2);
    BoxSizes::setSpace(sizeOfName('XL'), 4);

    BoxSizes::setBase(sizeOfName('Large'));
    expect(sizeOfName('Large')->space)->toBe(1.0)
        ->and(sizeOfName('XL')->space)->toBe(2.0)
        ->and(sizeOfName('Medium')->space)->toBe(0.5)
        ->and(sizeOfName('Medium')->is_base)->toBeFalse();
});

it('fills trucks by space in the AI trip helper', function () {
    Truck::query()->update(['is_assigned' => true]);
    $hub = $this->admin->logistichub_id;
    $truck = Truck::create(['plate_no' => 'SPC 101', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => false, 'capacity' => 10, 'category' => 'Truck', 'description' => 'Elf', 'registration_no' => 'R1', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    // Maria: 4 XL (2 each = 8 space); Jose: 4 Medium (4 space). 8 boxes would fit 10 by count, not by space.
    foreach (range(1, 4) as $i) {
        sizeBox("MX{$i}", 'XL');
        sizeBox("JM{$i}", 'Medium', 'Jose Ramos', 'Basak', '09173334444');
    }
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('XL'), 2);

    $units = (new TripPlanner($this->admin, 'delivery'))->units();
    expect($units->firstWhere('name', 'Maria Santos')['space'])->toBe(8.0)
        ->and($units->firstWhere('name', 'Maria Santos')['n'])->toBe(4);

    AiSetting::query()->delete();
    AiSetting::create(['api_key' => null, 'features' => ['trips']]); // made without AI: same rules
    (fn () => static::$memo = null)->call(new AiSetting);
    $page = Livewire::test(AdminTrips::class)->call('suggest');
    $trips = $page->get('trips');
    $keys = collect($trips)->flatMap(fn ($t) => collect($t['places'])->flatMap(fn ($p) => $p['units']));
    expect($keys)->toHaveCount(1); // only one receiver fits by space
    $page->assertSee('/ 10')->assertSee('space')->assertSee('Left for later');

    // forcing both on the truck is blocked
    $page->call('addPlace', 'Cebu › Mandaue City › Basak', 0)->assertSee('too much');
    $page->call('create')->assertSee('needs more space than truck SPC 101');
});

it('shows Settings → Box sizes, sets sizes, joins, sets the base and truck space', function () {
    sizeBox('L1', 'LG');
    sizeBox('L2', 'Large');
    $truck = Truck::first();

    $page = Livewire::test(BoxSizeSettings::class)
        ->assertSee('Box types from your manifests')
        ->assertSee('Normal box = 1')
        ->assertSee('New · not set')
        ->assertSee('These look like the same box')
        ->assertSee('Every box type is still 1');

    $lg = sizeOfName('LG');
    $large = sizeOfName('Large');
    $page->call('join', $lg->id, $large->id)->assertDontSee('These look like the same box');
    $page->call('step', $large->id, 1)->call('step', $large->id, 1)->assertSee('2')->assertDontSee('Every box type is still 1');
    expect($large->fresh()->space)->toBe(2.0)->and($large->fresh()->is_set)->toBeTrue()
        ->and(BoxSizes::spaceOf('LG'))->toBe(2.0);

    $page->call('setTruck', $truck->id, 64);
    expect($truck->fresh()->capacity)->toBe(64);
    $page->call('truckStep', $truck->id, 1);
    expect($truck->fresh()->capacity)->toBe(65);

    $page->call('toggle');
    expect(BoxSizes::on())->toBeFalse();

    $this->get('/box-sizes')->assertOk();
    $this->flushSession();
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    $this->get('/box-sizes')->assertForbidden();
});

it('shows the size and the space used while loading in the Scan app', function () {
    $hub = $this->admin->logistichub_id;
    Deliverylog::query()->update(['is_active' => false]);
    $truck = Truck::create(['plate_no' => 'SPC 202', 'logistichub_id' => $hub, 'is_active' => true, 'is_assigned' => true, 'capacity' => 20, 'category' => 'Truck', 'description' => 'Elf', 'registration_no' => 'R2', 'user_id' => $this->admin->id, 'date_registered' => now(), 'date_expired' => now()->addYear()]);
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $a = sizeBox('SX1', 'XL');
    $b = sizeBox('SM1', 'Medium', 'Jose Ramos', 'Basak', '09173334444');
    app(TripAssignment::class)->addToDeliveryTrip($trip, collect([$a, $b]));
    BoxSizes::sync();
    BoxSizes::setSpace(sizeOfName('XL'), 2);

    $space = BoxSizes::tripSpace($trip->fresh());
    expect($space)->toBe(['loaded' => 0.0, 'total' => 3.0, 'cap' => 20, 'reserve' => 0]);

    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Livewire::test(ScanApp::class)
        ->call('open', 'load')->call('pick', $trip->id)->assertDontSee('0 / 20 space')->call('loadExtras')
        ->assertSee('0 / 20 space')
        ->call('scan', 'SX1')
        ->assertSee('XL · takes 2 space')
        ->assertSee('2 / 20 space');
});

it('lets the AI find look-alikes the simple check misses, using only real box types', function () {
    sizeBox('B1', 'Bulilit');
    sizeBox('S1', 'Small');
    sizeBox('S2', 'Small');
    BoxSizes::sync();
    expect(BoxSizes::lookAlike())->toBe([]);

    AiSetting::query()->delete();
    AiSetting::create(['api_key' => 'sk-ant-test', 'features' => ['box_sizes']]);
    (fn () => static::$memo = null)->call(new AiSetting);
    $bulilit = sizeOfName('Bulilit');
    $small = sizeOfName('Small');
    Http::fake(fn () => Http::response(['content' => [['type' => 'text', 'text' => json_encode(['same' => [
        ['from_id' => $bulilit->id, 'into_id' => $small->id, 'why' => 'Bulilit means small'],
        ['from_id' => 999, 'into_id' => $small->id, 'why' => 'made up'],
    ]])]], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 5, 'output_tokens' => 5]]));

    Livewire::test(BoxSizeSettings::class)
        ->call('askAi')
        ->assertSee('“Bulilit” (1) looks like')
        ->assertSee('Bulilit means small')
        ->call('join', $bulilit->id, $small->id);
    expect(BoxSizes::spaceOf('Bulilit'))->toBe(1.0)
        ->and(sizeOfName('Small')->spellings)->toContain('bulilit');
});
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- tests/Feature/FastScanTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/FastScanTest.php' <<'DISPATCH_FILE_END_17'
<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Filament\Warehouse\Pages\Hubloaded;
use App\Filament\Warehouse\Pages\Unloadedcontainer;
use App\Models\BoxPhoto;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\User;
use App\Support\DriverTrip;
use App\Support\ScanModes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('public');
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    $base = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->user = $base->replicate()->fill(['email' => 'fast@example.com']);
    $this->user->save();
    $this->actingAs($this->user);
});

it('reads only Code 39 and QR, twice the same, with the camera off after 2 minutes', function () {
    $c = ScanModes::scanner();
    expect($c['formats'])->toBe(['code_39', 'qr_code'])
        ->and($c['confirm'])->toBe(2)->and($c['idleOff'])->toBe(120000)->and($c['hardAfter'])->toBe(3000);
    expect(file_get_contents(resource_path('js/barcode-scanner.js')))->toBe(file_get_contents(public_path('js/app/barcode-scanner.js')));
});

it('counts every trip and container of the list in one question, the same as one by one', function () {
    $hub = (int) $this->user->logistichub_id;
    $load = app(Hubloaded::class);
    $ids = $load->appChoices()->pluck('id')->all();
    $many = $load->progressMany($ids);
    foreach ($ids as $id) {
        $one = app(Hubloaded::class);
        $one->data = ['deliverylog_id' => $id];
        $p = $one->progress();
        expect($many[$id] ?? ['loaded' => 0, 'total' => 0])->toMatchArray(['loaded' => $p['loaded'], 'total' => $p['total']]);
    }
    $un = app(Unloadedcontainer::class);
    $cids = $un->appChoices()->pluck('id')->all();
    expect($cids)->not->toBeEmpty();
    $many = $un->progressMany($cids);
    foreach ($cids as $id) {
        $one = app(Unloadedcontainer::class);
        $one->data = ['container_id' => $id];
        expect($many[$id])->toMatchArray(['loaded' => $one->progress()['loaded'], 'total' => $one->progress()['total']]);
    }
});

it('opens the trip first, then Load next and space; pauses the scanner while a photo is taken', function () {
    $container = Container::where('warehouse_id', $this->user->warehouse_id)->firstOrFail();
    $box = Invoice::where('container_id', $container->id)->where('is_verified', false)->firstOrFail();

    $lw = Livewire::test(ScanApp::class)->call('open', 'unload')->call('pick', $container->id)
        ->assertSet('extrasReady', false)->assertSet('targetInfo.id', $container->id)
        ->call('loadExtras')->assertSet('extrasReady', true)
        ->call('scan', $box->invoice)->assertSet('status', 'success');
    expect($lw->viewData('paused'))->toBeTrue(); // photos are on: wait for Scan next box
    $lw->call('dismiss');
    expect($lw->viewData('paused'))->toBeFalse();
});

it('saves a photo sent in the back, only for a box just scanned', function () {
    $container = Container::where('warehouse_id', $this->user->warehouse_id)->firstOrFail();
    [$box, $other] = Invoice::where('container_id', $container->id)->where('is_verified', false)->take(2)->get();

    Livewire::test(ScanApp::class)->call('open', 'unload')->call('pick', $container->id)->call('scan', $box->invoice)->assertSet('status', 'success');

    $this->postJson(route('scan.box-photo'), ['invoice_id' => $box->id, 'condition' => 'damaged', 'photo' => UploadedFile::fake()->image('p.jpg', 1280, 720)])
        ->assertOk()->assertJsonStructure(['id']);
    $photo = BoxPhoto::latest('id')->first();
    expect($photo->invoice_id)->toBe($box->id)->and($photo->condition)->toBe('damaged')->and($photo->step)->toBe('unload')
        ->and($photo->user_id)->toBe($this->user->id);

    // a box not scanned by this person: refused
    $this->postJson(route('scan.box-photo'), ['invoice_id' => $other->id, 'photo' => UploadedFile::fake()->image('p.jpg')])->assertForbidden();
});

it('counts the driver trip in one question, the same as before', function () {
    $driver = User::whereHas('panelcategory', fn ($q) => $q->where('code', 'drv'))->get()->first(fn ($u) => DriverTrip::for($u)->trip);
    if (! $driver) {
        $this->markTestSkipped('No driver with a trip in the demo data.');
    }
    $t = DriverTrip::for($driver);
    $t->boxes()->limit(1)->update(['is_delivered' => true]);
    $b = $t->boxes()->where('is_delivered', false)->first();
    \App\Models\DeliveryAttempt::create(['tripinvoice_id' => $b->id, 'invoice_id' => $b->invoice_id, 'deliverylog_id' => $t->trip->id, 'user_id' => $driver->id, 'reason' => 'no_one_home']);
    $p = $t->progress();
    expect($p['total'])->toBe($t->boxes()->count())
        ->and($p['delivered'])->toBe($t->boxes()->where('is_delivered', true)->count())
        ->and($p['notDelivered'])->toBe($t->boxes()->where('is_delivered', false)->has('deliveryAttempts')->count())
        ->and($p['notDelivered'])->toBe(1);
});

it('has no property named like an action, so every button works in the browser', function () {
    foreach ([ScanApp::class, \App\Filament\Delivery\Pages\Dashboard::class, \App\Filament\Shared\Trips\PickingPage::class] as $class) {
        $r = new ReflectionClass($class);
        $props = collect($r->getProperties(ReflectionProperty::IS_PUBLIC))->reject->isStatic()->map->getName();
        $methods = collect($r->getMethods(ReflectionMethod::IS_PUBLIC))->reject->isStatic()->map->getName();
        expect($props->intersect($methods)->values()->all())->toBe([], $class);
    }
});
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- tests/Feature/PickingTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/PickingTest.php' <<'DISPATCH_FILE_END_18'
<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Filament\Warehouse\Pages\Picking as WarehousePicking;
use App\Models\Boxes\WhSection;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Support\ScanModes;
use App\Support\Trips\Picking;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->wh = User::with('panelcategory')->where('email', 'warehouse@example.com')->firstOrFail();
    $this->ben = $this->wh->replicate()->forceFill(['email' => 'ben@pick.test', 'first_name' => 'Ben']);
    $this->ben->save();
    $this->carla = $this->wh->replicate()->forceFill(['email' => 'carla@pick.test', 'first_name' => 'Carla']);
    $this->carla->save();
    $hub = (int) $this->wh->logistichub_id;
    $this->sec = WhSection::create(['warehouse_id' => $this->wh->warehouse_id, 'code' => 'C', 'name' => 'Nueva Ecija', 'color' => '#1d6fb8', 'sort' => 1, 'is_active' => true]);
    $this->trip = Deliverylog::create(['trip_number' => 'PK1', 'logistichub_id' => $hub, 'assigned_to' => $hub, 'truck_id' => Truck::where('logistichub_id', $hub)->value('id'),
        'is_active' => true, 'departure_date' => today(), 'trip_day' => today(), 'eta' => today(), 'user_id' => $this->wh->id]);
    $base = Invoice::firstOrFail();
    $this->rows = collect(['PK01' => '09170000001', 'PK02' => '09170000001', 'PK03' => '09170000003', 'PK04' => '09170000004'])->map(function ($phone, $no) use ($base) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => $no, 'receiver_mobile_no' => $phone, 'receiver_name' => 'R '.$phone, 'wh_section_id' => $this->sec->id, 'set_key' => null, 'is_delivered' => false])->save();

        return Tripinvoice::create(['invoice' => $no, 'invoice_id' => $i->id, 'deliverylog_id' => $this->trip->id, 'logistichub_id' => $this->trip->logistichub_id, 'is_loaded' => false, 'is_delivered' => false]);
    });
    $this->other = Deliverylog::create(['trip_number' => 'PK2', 'logistichub_id' => $hub, 'assigned_to' => $hub, 'is_active' => true, 'departure_date' => today(), 'trip_day' => today(), 'eta' => today(), 'user_id' => $this->wh->id]);
    $i = $base->replicate();
    $i->forceFill(['invoice' => 'PK99', 'wh_section_id' => $this->sec->id])->save();
    Tripinvoice::create(['invoice' => 'PK99', 'invoice_id' => $i->id, 'deliverylog_id' => $this->other->id, 'logistichub_id' => $hub, 'is_loaded' => false]);
});

it('adds Pick boxes to the Scan app for the warehouse and partner hubs', function () {
    expect(ScanModes::for($this->wh))->toHaveKey('pick')
        ->and(ScanModes::for(tap($this->wh->replicate()->forceFill(['email' => 'hub@pick.test', 'panelcategory_id' => \App\Models\Panelcategory::where('code', 'co')->value('id')]))->save()->load('panelcategory')))->toHaveKey('pick');
});

it('suggests free pickers, about one for 40 boxes, the truck crew first', function () {
    DB::table('truckcrews')->insert(['truck_id' => $this->trip->truck_id, 'crew' => $this->carla->id, 'user_id' => $this->wh->id]);
    $s = Picking::suggest($this->trip);
    expect($s['ids'])->toBe([$this->carla->id])->and($s['why'])->toContain('4 boxes: 1 picker');

    Picking::assign($this->other, [$this->carla->id], $this->wh);
    expect(Picking::suggest($this->trip)['ids'])->not->toContain($this->carla->id); // busy on PK2
});

it('picks on many phones: combo n of m, already picked, not for this trip, undo, not found', function () {
    Picking::assign($this->trip, [$this->ben->id, $this->carla->id], $this->wh);

    $r = Picking::scan($this->trip, $this->ben, 'PK01');
    expect($r['title'])->toBe('Picked · combo 1 of 2')->and($r['why'])->toContain('PK02 in section C');
    expect(Picking::scan($this->trip, $this->carla, 'PK02')['title'])->toBe('Picked · combo complete (2)');
    expect(Picking::scan($this->trip, $this->carla, 'PK01')['title'])->toBe('Already picked by Ben');
    expect(Picking::scan($this->trip, $this->ben, 'PK01')['title'])->toBe('You already picked this');
    $bad = Picking::scan($this->trip, $this->ben, 'PK99');
    expect($bad['tone'])->toBe('bad')->and($bad['why'])->toContain('PK2')->and($bad['why'])->toContain('section C');

    $row = $this->rows['PK03'];
    Picking::scan($this->trip, $this->ben, 'PK03');
    expect(Picking::undo($this->trip, $row->id, $this->ben))->toBeTrue()
        ->and($row->fresh()->picked_at)->toBeNull();
    Picking::notFound($this->trip, $this->rows['PK04']->id, $this->carla);
    expect(Picking::progress($this->trip))->toBe(['total' => 4, 'picked' => 2, 'missing' => 1])
        ->and(DB::table('pick_logs')->where('deliverylog_id', $this->trip->id)->pluck('what')->all())
        ->toContain('picked', 'undone', 'not_found', 'wrong', 'assigned');
});

it('lets a picker take a trip with no picker in the Scan app, and scan there', function () {
    $this->actingAs($this->ben);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Picking::assign($this->other, [$this->carla->id], $this->wh); // PK2 is Carla's: not shown to Ben

    $lw = Livewire::test(ScanApp::class)->call('open', 'pick')->assertSet('screen', 'pick')
        ->assertSee('Take this trip')->assertSee('PK1')->assertDontSee('PK2');
    $lw->call('takeTrip', $this->trip->id)->assertSet('screen', 'scan')->assertSee('Section C');
    expect(Picking::isPicker($this->trip, $this->ben))->toBeTrue()
        ->and(Picking::take($this->trip, $this->carla))->toBeFalse(); // already taken

    $lw->call('scan', 'PK03')->assertSet('pickResult.title', 'Picked ✓')->assertSee('↶ Undo');
    $lw->call('undoPick', $this->rows['PK03']->id)->assertSet('pickResult.title', '↶ Undone · back on the list');

    // next time: his one trip opens by itself
    Livewire::test(ScanApp::class)->call('open', 'pick')->assertSet('screen', 'scan')->assertSet('choice', $this->trip->id);
});

it('shows the office Picking page with Use suggestion, pickers and status', function () {
    $this->actingAs($this->wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    Livewire::test(WarehousePicking::class)->assertSee('PK1')->assertSee('Give it a picker')->assertSee('✦ Suggested')
        ->call('useSuggestion', $this->trip->id)->assertSee('Waiting for pickers');
    expect(Picking::pickers($this->trip))->toHaveCount(1);

    $p = Picking::pickers($this->trip)->first();
    Picking::scan($this->trip, $p, 'PK01');
    Livewire::test(WarehousePicking::class)->assertSee('Picking')->assertSee('PK01 picked')
        ->call('undo', $this->rows['PK01']->id);
    expect($this->rows['PK01']->fresh()->picked_at)->toBeNull();
});
DISPATCH_FILE_END_18

# ---------------------------------------------------------------- tests/Feature/ScanAppTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/ScanAppTest.php' <<'DISPATCH_FILE_END_19'
<?php

use App\Filament\Scan\Pages\ScanApp;
use App\Models\BoxPhoto;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Unmanifested;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Support\ScanModes;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('local');
    Storage::fake('public');
    Filament::setCurrentPanel(Filament::getPanel('scan'));
});

/** A copy of a demo user without the super_admin role, so we test the account type alone. */
function scanUser(string $email): User
{
    $base = User::where('email', $email)->firstOrFail();
    $u = $base->replicate()->fill(['email' => 'scan-'.$email]);
    $u->save();

    return $u;
}

it('lets warehouse, partner hub and office accounts in, but not drivers', function () {
    $this->actingAs(scanUser('warehouse@example.com'))->get('/scan')->assertOk()->assertSee('Unload container')->assertSee('Warehouse unload');
    $this->flushSession();
    $this->actingAs(scanUser('company@example.com'))->get('/scan')->assertOk()->assertSee('Hub load')->assertDontSee('Unload container');
    $this->flushSession();
    $this->actingAs(scanUser('admin@example.com'))->get('/scan')->assertOk()->assertSee('Load truck');
    $this->flushSession();
    $this->actingAs(scanUser('driver@example.com'))->get('/scan')->assertForbidden();
});

it('gives each account type its own scans', function () {
    expect(array_keys(ScanModes::for(scanUser('warehouse@example.com'))))->toBe(['unload', 'pick', 'load', 'wh_load', 'wh_unload', 'return', 'port', 'ret_receive'])
        ->and(array_keys(ScanModes::for(scanUser('company@example.com'))))->toBe(['pick', 'hub_load', 'return', 'truck_receive'])
        ->and(array_keys(ScanModes::for(scanUser('admin@example.com'))))->toBe(['unload', 'load', 'return', 'port'])
        ->and(ScanModes::for(scanUser('driver@example.com')))->toBe([]);
});

it('unloads a container box by box, with an optional photo, using the same rules as Unload Container', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $container = Container::where('warehouse_id', $user->warehouse_id)->firstOrFail();
    $box = Invoice::where('container_id', $container->id)->where('is_verified', false)->firstOrFail();

    $page = Livewire::test(ScanApp::class)
        ->call('open', 'unload')->assertSet('screen', 'pick')->assertSee($container->container_no)
        ->call('pick', $container->id)->assertSet('screen', 'scan')
        ->call('scan', $box->invoice)
        ->assertSet('status', 'success')->assertSee('Verified · off the container')->assertSee('📷 Take photo here')->assertSee('Camera app')
        ->call('setCondition', 'damaged')->assertSee('What is wrong?')
        ->set('note', 'Corner crushed')
        ->set('boxPhoto', UploadedFile::fake()->image('p.jpg', 2000, 1500))
        ->call('saveBoxPhoto')->assertHasNoErrors();

    expect($box->fresh()->is_verified)->toBeTrue();
    $photo = BoxPhoto::sole();
    expect($photo->step)->toBe('unload')->and($photo->condition)->toBe('damaged')->and($photo->note)->toBe('Corner crushed')
        ->and($photo->container_id)->toBe($container->id)->and($photo->user_id)->toBe($user->id);

    // a box that is not on the manifest
    $page->call('scan', 'NOTONMANIFEST1')->assertSet('status', 'danger')->assertSet('missing', 'NOTONMANIFEST1')
        ->assertSee('Not on this container')
        ->callAction('unmanifested', data: ['attachment_pic' => [UploadedFile::fake()->image('u.jpg')], 'remarks' => 'Found inside'])
        ->assertHasNoActionErrors()->assertSet('missing', null);
    expect(Unmanifested::where('invoice', 'NOTONMANIFEST1')->where('container_id', $container->id)->exists())->toBeTrue();

    $page->call('finish')->assertSet('screen', 'done')->assertSee('Keep scanning')->call('home')->assertSet('screen', 'home');
});

it('loads a delivery truck and refuses a box from another trip', function () {
    $user = scanUser('admin@example.com');
    $this->actingAs($user);
    $trip = Deliverylog::where('logistichub_id', $user->logistichub_id)->whereNotNull('truck_id')->where('is_active', true)->firstOrFail();
    $row = Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', false)->first();
    if (! $row) {
        $row = Tripinvoice::where('deliverylog_id', $trip->id)->firstOrFail();
        $row->update(['is_loaded' => false]);
    }

    Livewire::test(ScanApp::class)
        ->call('open', 'load')->call('pick', $trip->id)
        ->call('scan', $row->invoice)->assertSet('status', 'success')->assertSee('Loaded on the truck')
        ->call('scan', 'NOPE-123')->assertSet('status', 'danger')->assertSee('Keep it aside, scan next');

    expect($row->fresh()->is_loaded)->toBeTruthy();
});

it('does not open a container or trip that is not yours, or a scan your account does not have', function () {
    $user = scanUser('company@example.com');
    $this->actingAs($user);
    $otherTrip = Deliverylog::where('logistichub_id', '!=', $user->logistichub_id)->firstOrFail();

    Livewire::test(ScanApp::class)
        ->call('open', 'unload')->assertSet('screen', 'home')
        ->call('open', 'hub_load')->assertSet('screen', 'pick')
        ->call('pick', $otherTrip->id)->assertSet('screen', 'pick')->assertNotified('That one is not open for you any more.');
});

it('installs as its own app', function () {
    $this->get('/pwa/scan/manifest.webmanifest')->assertOk()->assertJsonPath('short_name', 'Scan')->assertJsonPath('scope', '/scan');
    $this->get('/scan/login')->assertOk()->assertSee('Load and unload, box by box.')->assertSee('/pwa/scan/manifest"', false);
});

it('receives a warehouse transfer and adds the box to this warehouse', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $row = Whtripinvoice::firstOrFail();
    $row->update(['is_loaded' => true, 'is_unloaded' => false]);
    $trip = Whdeliverylog::findOrFail($row->whdeliverylog_id);
    $trip->update(['warehouse_id' => $user->warehouse_id]);
    $invoice = Invoice::findOrFail($row->invoice_id);
    $invoice->update(['warehouse_id' => null]);

    Livewire::test(ScanApp::class)
        ->call('open', 'wh_unload')->call('pick', $trip->id)
        ->call('scan', $invoice->invoice)->assertSet('status', 'success')->assertSee('Received · added to inventory');

    expect($row->fresh()->is_unloaded)->toBeTruthy()
        ->and($invoice->fresh()->warehouse_id)->toBe($user->warehouse_id);
});

it('hides finished and closed containers, with a link to show them', function () {
    $user = scanUser('warehouse@example.com');
    $this->actingAs($user);
    $base = Container::where('warehouse_id', $user->warehouse_id)->firstOrFail();
    $open = $base->replicate()->fill(['container_no' => 'OPEN0000001', 'is_unloaded' => false, 'is_active' => true]);
    $open->save();
    $full = $base->replicate()->fill(['container_no' => 'FULL0000001', 'is_unloaded' => false, 'is_active' => true]);
    $full->save();
    $closed = $base->replicate()->fill(['container_no' => 'SHUT0000001', 'is_unloaded' => false, 'is_active' => false]);
    $closed->save();
    $box = Invoice::where('container_id', $base->id)->firstOrFail();
    $box->replicate()->fill(['invoice' => 'OPENBOX1', 'container_id' => $open->id, 'is_verified' => false])->save();
    $box->replicate()->fill(['invoice' => 'FULLBOX1', 'container_id' => $full->id, 'is_verified' => true])->save();
    $box->replicate()->fill(['invoice' => 'SHUTBOX1', 'container_id' => $closed->id, 'is_verified' => false])->save();

    Livewire::test(ScanApp::class)
        ->assertSee('waiting')
        ->call('open', 'unload')
        ->assertSee('OPEN0000001')->assertDontSee('FULL0000001')->assertDontSee('SHUT0000001')
        ->assertSee('Show finished')
        ->call('toggleFinished')
        ->assertSee('FULL0000001')->assertSee('SHUT0000001')->assertSee('· closed')->assertSee('Hide finished')
        ->call('pick', $full->id)->assertSet('screen', 'scan'); // still openable to re-check
});
DISPATCH_FILE_END_19

# ---------------------------------------------------------------- tests/Feature/WarehouseSectionsTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/WarehouseSectionsTest.php' <<'DISPATCH_FILE_END_20'
<?php

use App\Filament\Pages\WarehouseSections;
use App\Filament\Scan\Pages\ScanApp;
use App\Filament\Warehouse\Resources\Whdeliverylogs\Pages\ListWhdeliverylogs;
use App\Models\Boxes\SetSplit;
use App\Models\Boxes\WhSection;
use App\Models\Boxes\WhSpot;
use App\Models\Container;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\TripOverride;
use App\Models\Truck;
use App\Models\User;
use App\Models\Warehouse;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Services\TripAssignment;
use App\Support\Boxes\Crossdock;
use App\Support\Boxes\Sections;
use App\Support\Boxes\TruckSets;
use App\Support\Trips\TripRules;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Sections::forget();
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    $base = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->user = $base->replicate()->fill(['email' => 'sec-wh@example.com']);
    $this->user->save();
    $this->wade = $base->replicate()->fill(['email' => 'wade2@example.com', 'first_name' => 'Wade']);
    $this->wade->save();
    $this->wh = $this->user->warehouse_id;
    $this->tarlac = Warehouse::create(['name' => 'Tarlac Warehouse', 'address' => 'MacArthur Hwy', 'city' => 'Tarlac City', 'province' => 'Tarlac', 'zip_code' => '2300', 'mobile_number' => '0917', 'email' => 't@example.com', 'user_id' => $this->user->id]);
    $this->main = Logistichub::where('is_company', false)->firstOrFail();
    $this->cebu = Logistichub::where('is_company', true)->firstOrFail();

    $mk = fn ($code, $name, $kind, $prov, $extra = []) => WhSection::create(['warehouse_id' => $this->wh, 'code' => $code, 'name' => $name, 'kind' => $kind, 'provinces' => $prov, 'color' => '#1d6fb8'] + $extra);
    $this->A = $mk('A', 'Manila trucks', 'area', ['Metro Manila', 'Cavite'], ['logistichub_id' => $this->main->id]);
    $this->C = $mk('C', 'Cebu hub', 'area', ['Cebu', 'Bohol'], ['logistichub_id' => $this->cebu->id]);
    $this->T = $mk('T', 'Tarlac', 'area', ['Tarlac', 'Nueva Ecija'], ['to_warehouse_id' => $this->tarlac->id]);
    $this->X = $mk('X', 'Check address', 'check', null);

    $demo = Container::where('warehouse_id', $this->wh)->firstOrFail();
    $this->container = $demo->replicate()->fill(['container_no' => 'MSKU7712040', 'is_unloaded' => false, 'is_active' => true]);
    $this->container->save();
    $other = $demo->replicate()->fill(['container_no' => 'OTHR0000001', 'is_unloaded' => false, 'is_active' => true]);
    $other->save();
    $tpl = Invoice::where('container_id', $demo->id)->firstOrFail();
    $box = function (string $no, string $name, string $province, ?int $container = null) use ($tpl) {
        $b = $tpl->replicate()->fill(['invoice' => $no, 'container_id' => $container ?? $this->container->id, 'receiver_name' => $name, 'receiver_mobile_no' => '0917'.crc32($name),
            'receiver_province' => $province, 'receiver_city' => 'Mandaue City', 'is_verified' => false, 'is_assigned' => false, 'wh_is_assigned' => false, 'is_delivered' => false, 'warehouse_id' => $this->wh, 'verified_by' => null, 'wh_section_id' => null, 'set_key' => null]);
        $b->save();

        return $b;
    };
    $this->maria1 = $box('S-101', 'Maria Santos', 'Province of Cebu');
    $this->maria2 = $box('S-102', 'Maria Santos', 'Cebu');
    $this->liza1 = $box('S-201', 'Liza Gomez', 'Cebu');
    $this->liza2 = $box('S-202', 'Liza Gomez', 'Cebu', $other->id);
    $this->rosa = $box('S-301', 'Rosa Lim', 'Tarlac');
    $this->ben = $box('S-302', 'Ben Uy', 'Nueva Ecija');
    $this->nop = $box('S-401', 'Joy Tan', '');
    $this->otherContainer = $other;
    $this->box = $box;
});

function unload($test)
{
    return Livewire::test(ScanApp::class)->call('open', 'unload')->call('pick', $test->container->id)->call('loadExtras');
}

it('finds the section from the province, and sends unclear addresses to Check address', function () {
    expect(Sections::forInvoice($this->maria1)->code)->toBe('C')
        ->and(Sections::forInvoice($this->rosa)->code)->toBe('T')
        ->and(Sections::forInvoice($this->nop)->code)->toBe('X')
        ->and(Sections::forInvoice($this->nop->replicate()->fill(['receiver_province' => 'Leyte']))->code)->toBe('X')
        ->and(Sections::clean('NCR'))->toBe('metro manila');
});

it('shows the section and the set at unload, and does not count a box twice', function () {
    $this->actingAs($this->user);
    unload($this)->call('scan', 'S-101')
        ->assertSet('status', 'success')->assertSet('route.code', 'C')->assertSee('Cebu hub')
        ->assertSee('box 1 of 2')->assertSee('1 more still in this container')
        ->call('dismiss')->call('scan', 'S-201')->assertSee('in another container')
        ->call('dismiss')->call('scan', 'S-401')->assertSet('route.code', 'X')->assertSee('No province in the address.');

    expect($this->maria1->fresh())->wh_section_id->toBe($this->C->id)->sectioned_at->not->toBeNull()->verified_by->toBe($this->user->id);

    $this->flushSession();
    $this->actingAs($this->wade);
    unload($this)->call('scan', 'S-101')->assertSet('status', 'warning')->assertSee('already verified by '.$this->user->first_name);
    unload($this)->call('scan', 'S-102')->assertSee('All 2 boxes are off the container')->assertSee($this->user->first_name)->assertSee('You');
});

it('loads boxes straight onto the truck the office switched on, and the crew can keep one in its section', function () {
    $this->actingAs($this->user);
    $trip = Whdeliverylog::create(['truck_id' => Truck::value('id'), 'warehouse_id' => $this->tarlac->id, 'user_whid' => $this->wh, 'departure_date' => today(), 'delivery_date' => today(), 'is_active' => true, 'user_id' => $this->user->id]);

    // Not switched on: the Tarlac box goes to its section, as always.
    unload($this)->assertDontSee('is here');

    Crossdock::switchOn($trip);
    unload($this)->assertSee('Truck to Tarlac Warehouse is here')
        ->call('scan', 'S-301')->assertSet('route.kind', 'truck')->assertSee('TRUCK')->assertSee('Already loaded')->assertSee('Put in section instead')
        ->call('dismiss')->call('scan', 'S-302')->assertSet('route.kind', 'truck')
        ->call('putInSection')->assertSet('route.code', 'T')
        ->call('dismiss')->call('scan', 'S-101')->assertSet('route.code', 'C')
        ->call('dismiss')->assertSee('1 on truck');

    expect(Whtripinvoice::where('whdeliverylog_id', $trip->id)->pluck('invoice_id')->all())->toBe([$this->rosa->id])
        ->and(Whtripinvoice::where('invoice_id', $this->rosa->id)->value('is_loaded'))->toBeTruthy()
        ->and($this->ben->fresh()->sectioned_at)->not->toBeNull()
        ->and($this->ben->fresh()->wh_is_assigned)->toBeFalse();

    // Locking the trip switches it off by itself.
    $trip->update(['is_lock' => true]);
    expect($trip->fresh()->truck_here)->toBeFalse()
        ->and(Crossdock::here($this->wh))->toBeEmpty();
});

it('lets the office switch the truck on in the transfer trip, only when a section goes there', function () {
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    $trip = Whdeliverylog::create(['truck_id' => Truck::value('id'), 'warehouse_id' => $this->tarlac->id, 'user_whid' => $this->wh, 'departure_date' => today(), 'delivery_date' => today(), 'is_active' => true, 'user_id' => $this->user->id]);

    Livewire::test(ListWhdeliverylogs::class)
        ->callTableAction('truckHere', $trip);
    expect($trip->fresh()->truck_here)->toBeTrue();

    Livewire::test(ListWhdeliverylogs::class)
        ->assertSee('Here, loading')->callTableAction('truckHere', $trip);
    expect($trip->fresh()->truck_here)->toBeFalse();

    $this->T->update(['to_warehouse_id' => null]);
    Sections::forget();
    Livewire::test(ListWhdeliverylogs::class)
        ->callTableAction('truckHere', $trip)->assertNotified('No section goes to Tarlac Warehouse yet');
    expect($trip->fresh()->truck_here)->toBeFalse();
});

it('on the TRUCK screen shows where the customer\'s other boxes are, and brings one from the section', function () {
    $this->actingAs($this->user);
    $trip = Whdeliverylog::create(['truck_id' => Truck::value('id'), 'warehouse_id' => $this->tarlac->id, 'user_whid' => $this->wh, 'departure_date' => today(), 'delivery_date' => today(), 'is_active' => true, 'user_id' => $this->user->id]);
    $ana1 = ($this->box)('S-501', 'Ana Cruz', 'Tarlac');
    $ana1->forceFill(['is_verified' => true, 'wh_section_id' => $this->T->id, 'sectioned_at' => now()])->save();
    $ana2 = ($this->box)('S-502', 'Ana Cruz', 'Tarlac');
    $ana3 = ($this->box)('S-503', 'Ana Cruz', 'Tarlac', $this->otherContainer->id);
    Crossdock::switchOn($trip);

    unload($this)->call('scan', 'S-502')->assertSet('route.kind', 'truck')
        ->assertSee('Box 1 · S-501: in section T. Bring it to the truck too.')
        ->assertSee('in another container')
        ->assertSee('Bring S-501 from section T')
        ->call('addSetBox', $ana1->id)->assertNotified()
        ->assertSee('added, scan it at the truck door')->assertDontSee('Bring S-501 from section T');

    $row = Whtripinvoice::where('whdeliverylog_id', $trip->id)->where('invoice_id', $ana1->id)->first();
    expect($row)->not->toBeNull()->and((bool) $row->is_loaded)->toBeFalse();

    $open = TruckSets::open($trip);
    expect($open)->toHaveCount(1)
        ->and($open[0]['have'])->toBe(1)->and($open[0]['of'])->toBe(3)
        ->and(collect($open[0]['missing'])->pluck('invoice')->all())->toBe(['S-501', 'S-503'])
        ->and($open[0]['missing'][1]['where'])->toContain('not unloaded yet');

    // Truck left: a reason is needed for each box left behind.
    $this->actingAs(User::where('email', 'warehouse@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    Livewire::test(ListWhdeliverylogs::class)
        ->callTableAction('truckHere', $trip, data: ['why' => [$ana1->id => 'not_found']])
        ->assertHasTableActionErrors();
    expect($trip->fresh()->truck_here)->toBeTrue();

    Livewire::test(ListWhdeliverylogs::class)
        ->callTableAction('truckHere', $trip, data: ['why' => [$ana1->id => 'not_found', $ana3->id => 'not_arrived']])
        ->assertHasNoTableActionErrors();
    expect($trip->fresh()->truck_here)->toBeFalse()
        ->and(SetSplit::where('whdeliverylog_id', $trip->id)->pluck('reason', 'invoice_id')->all())->toBe([$ana1->id => 'not_found', $ana3->id => 'not_arrived']);
});

it('with the label scan on, saves boxes in a section only when its QR is scanned', function () {
    Sections::setLabelScan($this->wh, true);
    $this->actingAs($this->user);
    unload($this)->call('scan', 'S-101')->assertSee('Then scan the QR on section C')
        ->call('dismiss')->call('scan', 'S-102')
        ->call('dismiss')->call('scan', $this->T->qrText())->assertSet('status', 'warning')->assertSee('are for C, not T')
        ->call('dismiss')->call('scan', $this->C->qrText())->assertSet('status', 'success')->assertSee('2 boxes saved in section C');
    expect($this->maria1->fresh()->sectioned_at)->not->toBeNull();

    Sections::setLabelScan($this->wh, false);
    unload($this)->call('scan', $this->C->qrText())->assertSee('label scan is off');
});

it('stops a box for another hub when loading, and lists customers missing boxes at the end', function () {
    $this->actingAs($this->user);
    unload($this)->call('scan', 'S-101')->call('dismiss')->call('scan', 'S-102')->call('dismiss')->call('scan', 'S-301');

    $truck = Truck::firstOrFail();
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $this->main->id, 'user_id' => $this->user->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    app(TripAssignment::class)->addToDeliveryTrip($trip, Invoice::whereIn('id', [$this->maria1->id, $this->rosa->id])->get());

    $page = Livewire::test(ScanApp::class)->call('open', 'load')->call('pick', $trip->id)
        ->call('scan', 'S-101')->assertSet('status', 'warning')->assertSee('Wrong hub')->assertSee('is for Cebu hub')
        // wrong hub is office only: the crew asks, the office approves, the next scan loads it
        ->call('loadAnyway')->assertSee('office only')->call('askOffice')->assertSet('status', 'warning');
    $ask = TripOverride::where('rule', 'wrong_hub')->sole();
    expect($ask->status)->toBe('pending');
    TripRules::decide($ask, true, null);
    $page->call('dismiss')->call('scan', 'S-101')->assertSee('Too early')->call('loadAnyway')->assertSet('status', 'success')->assertSee('box 1 of 2')->assertSee('not on this trip');
    expect(Tripinvoice::where('invoice_id', $this->maria1->id)->value('loaded_by'))->toBe($this->user->id);

    // splitting a customer is office only too: asked, then approved = the reason is saved
    $page->call('finish')->assertSee('missing boxes')->assertSee('Maria Santos')->assertSee('S-102')
        ->call('splitReason', $this->maria2->id, 'not_found');
    expect(SetSplit::count())->toBe(0);
    TripRules::decide(TripOverride::where('rule', 'split_set')->sole(), true, null);
    expect(SetSplit::sole())->reason->toBe('not_found')->deliverylog_id->toBe($trip->id);
});

it('lets the admin set up the sections and print the labels', function () {
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->get(WarehouseSections::getUrl())->assertOk()->assertSee('Cebu hub')->assertSee('Print QR labels');

    Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)
        ->call('addRow')->set('rows.4.name', 'Davao hub')->set('rows.4.provinces', ['Davao del Sur', 'cebu'])
        ->call('save')->assertHasErrors('rows')
        ->set('rows.4.provinces', ['Davao del Sur', 'Cotabato'])->set('labelScan', true)->call('save')->assertHasNoErrors();
    expect(WhSection::where('warehouse_id', $this->wh)->count())->toBe(5)
        ->and(WhSection::where('name', 'Davao hub')->value('provinces'))->toBe(['Davao del Sur', 'Cotabato'])
        ->and(Sections::labelScan($this->wh))->toBeTrue();

    $this->get(route('sections.labels', ['warehouse' => $this->wh]))->assertOk()->assertSee('Davao hub')->assertSee('<svg', false);
    $this->flushSession();
    $driver = User::where('email', 'driver@example.com')->firstOrFail()->replicate()->fill(['email' => 'nobody@example.com', 'warehouse_id' => null]);
    $driver->save();
    $this->actingAs($driver)->get(route('sections.labels', ['warehouse' => $this->wh]))->assertForbidden();
});

it('picks provinces from a list: chips with ✕, a province moves from another section, no box counts (board 50b)', function () {
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $page = Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)
        ->assertSee('Receiver provinces')->assertSee('Province · default')->assertDontSee('>Boxes<', false)
        ->call('openPick', 0)->assertSee('Nueva Ecija')->assertSee('In Section T · pick to move it here')
        ->set('pickQ', 'nueva')->assertSee('Nueva Vizcaya')->assertDontSee('Bulacan')
        ->call('addPlace', 'Nueva Ecija')
        ->call('removePlace', 0, 'Cavite')->call('save')->assertHasNoErrors();

    expect($this->A->fresh()->provinces)->toBe(['Metro Manila', 'Nueva Ecija'])
        ->and($this->T->fresh()->provinces)->toBe(['Tarlac']);
});

it('chooses sections by city when switched to City: each city with its province (board 50b)', function () {
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->rosa->update(['receiver_city' => 'San Jose', 'receiver_province' => 'Nueva Ecija']);
    Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)
        ->call('setBy', 'city')->assertSee('Receiver cities and municipalities')->assertSee('City mode')
        ->call('openPick', 2)->set('pickQ', 'san jose')->assertSee('San Jose · Nueva Ecija')
        ->call('addPlace', 'San Jose · Nueva Ecija')->call('save')->assertHasNoErrors();

    Sections::forget();
    expect(Sections::by($this->wh))->toBe('city')
        ->and($this->T->fresh()->cities)->toBe(['San Jose · Nueva Ecija'])
        ->and($this->T->fresh()->provinces)->toBe(['Tarlac', 'Nueva Ecija'])            // kept for Province mode
        ->and(Sections::forInvoice($this->rosa->fresh())->code)->toBe('T')
        ->and(Sections::forInvoice($this->rosa->fresh()->replicate()->fill(['receiver_province' => 'Batangas']))->code)->toBe('X') // San Jose, Batangas
        ->and(Sections::forInvoice($this->maria1)->code)->toBe('X');                  // Cebu has no city set
});

it('uses spots only when switched on, and the crew can tap a spot, scan its QR, or skip (board 50)', function () {
    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(WarehouseSections::class)->set('warehouseId', $this->wh)->assertDontSee('Spots (optional)')
        ->set('spotsOn', true)->assertSee('Spots (optional)')
        ->call('toggleSpots', 1)->call('addSpot', 1)->call('save')->assertHasNoErrors();
    $spots = WhSpot::where('wh_section_id', $this->C->id)->orderBy('sort')->pluck('code', 'id');
    expect($spots->values()->all())->toBe(['C1', 'C2', 'C3', 'C4'])->and($this->A->fresh()->use_spots)->toBeFalse();

    $this->actingAs($this->user);
    Filament::setCurrentPanel(Filament::getPanel('scan'));
    Sections::forget();
    $c2 = $spots->search('C2');
    $scan = unload($this)->call('scan', 'S-101')->assertSee('Spot? scan its QR, tap one, or skip')->assertSee('C3')
        ->call('setSpot', $c2)->assertSee('✓ Spot C2');
    expect((int) $this->maria1->fresh()->wh_spot_id)->toBe($c2);

    $scan->call('scan', 'S-102')->call('setSpot')->assertSee('No spot');
    expect($this->maria2->fresh()->wh_spot_id)->toBeNull();

    $scan->call('scan', 'SPOT-'.$spots->search('C4')); // the spot's QR: the last box scanned for section C
    expect($this->maria2->fresh()->wh_spot_id)->toBe($spots->search('C4'));

    $scan->call('scan', 'S-301')->assertDontSee('Spot?'); // section T has no spots

    $this->actingAs(User::where('email', 'admin@example.com')->firstOrFail());
    $this->get(route('sections.labels', ['warehouse' => $this->wh]))->assertOk()->assertSee('Spot C2 · section C');
});
DISPATCH_FILE_END_20

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
