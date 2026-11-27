#!/usr/bin/env bash
#
# Dispatch System — Part 42 · Check photos + accidental-scan protection
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part42-photo-review.sh

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

    /** Two boxes with one number on the trip (board 57): the tripinvoice ids to pick from by receiver. */
    public array $whichIds = [];

    /** The scanned number while asking Which one? */
    public ?string $whichCode = null;

    /** Board 68: another box was read while a delivery was open; the open sheet stays. */
    public ?string $otherCode = null;

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
        $this->reset('boxId', 'sheet', 'wrongText', 'photos', 'upload', 'reason', 'note', 'whichIds', 'whichCode', 'otherCode');
    }

    /** Board 68: the driver chose to leave the open delivery and open the other box that was read. */
    public function openOther(): void
    {
        $code = $this->otherCode;
        $this->otherCode = null;
        if ($code) {
            $this->closeSheet();
            $this->scan($code);
        }
    }

    /** Board 62: the RoRo driver pressed the next step (Leaving for the port, On the ship, Off the ship, Arrived at a hub). */
    public function roroStep(string $key): void
    {
        $trip = $this->driverTrip()->trip;
        $s = \App\Support\Shipping\SeaTrucks::roroFor($trip);
        if ($s && \App\Support\Shipping\SeaTrucks::roroStep($s, (int) $trip->id, $key)) {
            \Filament\Notifications\Notification::make()->title('Saved: '.(\App\Support\Shipping\SeaTrucks::roroNext($s->fresh(), (int) $trip->id)[1] ?? 'all hubs reached').' is next')->success()->send();
        }
    }

    /** Which one? The driver picked the receiver's name. */
    public function pickBox(int $id): void
    {
        $box = in_array($id, $this->whichIds, true) ? $this->driverTrip()->boxes()->whereKey($id)->first() : null;
        if (! $box || $box->is_delivered) {
            return;
        }
        $this->reset('whichIds', 'whichCode');
        $this->boxId = $box->id;
        $this->sheet = 'found';
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

        // Board 68: a box read by accident never closes a delivery that is being done.
        if (in_array($this->sheet, ['deliver', 'miss'], true) && ($open = $this->box())) {
            $same = strcasecmp($code, (string) $open->invoice) === 0
                || strcasecmp($code, (string) $open->invdata?->invoice) === 0;
            if (! $same) {
                $this->otherCode = $code;
                $this->dispatch('driver-app-buzz', ok: false);
            }

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

        $all = $this->driverTrip()->boxes()->with('invdata')
            ->where(fn ($q) => $q->where('invoice', $code)->orWhereHas('invdata', fn ($r) => $r->where('invoice', $code)))
            ->latest('id')->get();
        $open = $all->reject(fn ($b) => $b->is_delivered);
        if ($open->count() > 1) {
            // two boxes with this number on the truck: the driver picks the receiver on the sticker (board 57)
            $this->whichIds = $open->pluck('id')->map(fn ($i) => (int) $i)->values()->all();
            $this->whichCode = $code;
            $this->sheet = 'which';
            $this->dispatch('driver-app-buzz', ok: true);

            return;
        }
        $box = $open->first() ?? $all->first();

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
            // straight to this box, even when another box shares its number
            $this->closeSheet();
            $this->screen = 'scan';
            if ($box->is_delivered) {
                $this->scan($box->invoice);

                return;
            }
            $this->boxId = $box->id;
            $this->sheet = 'found';
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

        $dir = \App\Support\Photos\Storage\PhotoFolders::dir($this->sheet === 'deliver' ? 'delivery' : 'not-delivered', $box->invoice);
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
        $which = $this->sheet === 'which' && $this->whichIds
            ? $this->driverTrip()->boxes()->with('invdata.container:id,container_no,batch_no')->whereIn('id', $this->whichIds)->get()
                ->map(fn ($t) => ['id' => $t->id] + ($t->invdata ? \App\Support\Boxes\SameNumber::choice($t->invdata) : ['name' => $t->invoice, 'place' => '', 'sender' => '', 'container' => '']))->all()
            : [];

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
            'which' => $which,
            'seaCard' => ($ps = \App\Support\Shipping\Shipments::forDriverPort($trip->trip)) ? (function () use ($ps, $trip) {
                $ids = \App\Support\Shipping\SeaTrucks::carriedBy((int) $trip->trip->id);
                $n = \App\Models\Tripinvoice::whereIn('deliverylog_id', $ids)->selectRaw('deliverylog_id, count(*) c')->groupBy('deliverylog_id')->pluck('c', 'deliverylog_id');

                return ['code' => $ps->code, 'lcl' => $ps->mode === 'lcl', 'counted' => $ps->port_count,
                    'to' => $ps->mode === 'lcl' ? ($ps->hand_over_at ?: ($ps->forwarder ?: 'the forwarder')) : ($ps->port_from ?: 'the port'),
                    'hubs' => \App\Support\Shipping\Shipments::stops($ps)->whereIn('deliverylog_id', $ids)->sortBy('stop')->map(fn ($x) => ['name' => $x->hub?->hub_name, 'n' => (int) ($n[$x->deliverylog_id] ?? 0)])->values()->all(),
                    'total' => (int) $n->sum()];
            })() : null,
            'roro' => ($rs = \App\Support\Shipping\SeaTrucks::roroFor($trip->trip)) ? ['code' => $rs->code,
                'now' => \App\Support\Shipping\Shipments::label($rs).' · '.\App\Support\Shipping\Shipments::stops($rs)->sortBy('stop')->map(fn ($x) => $x->hub?->hub_name.($x->arrived_at ? ' ✓' : ''))->join(' → '),
                'next' => \App\Support\Shipping\SeaTrucks::roroNext($rs, (int) $trip->trip->id)] : null,
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

# ---------------------------------------------------------------- app/Filament/Pages/BoxPhotoSettings.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/BoxPhotoSettings.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Pages;

use App\Models\BoxPhoto;
use App\Models\PhotoSetting;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use UnitEnum;

/** Admin → Settings → Box photos: where staff can add photos, batch reminder, how long to keep them. */
class BoxPhotoSettings extends Page
{
    protected string $view = 'filament.pages.box-photo-settings';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedCamera;

    protected static ?string $navigationLabel = 'Box photos';

    protected static ?string $title = 'Box photos';

    protected static ?string $slug = 'box-photo-settings';

    /** @var array<string, bool> */
    public array $places = [];

    public int $batchEvery = 0;

    public int $keepMonths = 6;

    /** Board 68: Scan app · the photo is used by itself after … seconds (0 = wait for Use photo). */
    public int $autoUse = 3;

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function getSubheading(): ?string
    {
        return 'Photos are always optional. Scanning never waits for a photo.';
    }

    public function mount(): void
    {
        $s = PhotoSetting::current();
        foreach (array_keys(BoxPhoto::STEPS) as $step) {
            $this->places[$step] = $s->allows($step);
        }
        $this->batchEvery = $s->batch_every;
        $this->keepMonths = $s->keep_months;
        $this->autoUse = (int) \App\Models\AppSetting::get('photos.auto_use', 3);
    }

    public function save(): void
    {
        $this->validate(['batchEvery' => 'required|integer|min:0|max:500', 'keepMonths' => 'required|integer|min:0|max:120', 'autoUse' => 'required|integer|min:0|max:10']);

        PhotoSetting::current()->update([
            'places' => array_map('boolval', array_intersect_key($this->places, BoxPhoto::STEPS)),
            'batch_every' => $this->batchEvery,
            'keep_months' => $this->keepMonths,
        ]);

        \App\Models\AppSetting::put('photos.auto_use', $this->autoUse);

        Notification::make()->title('Box photo settings saved')->success()->send();
    }

    protected function getViewData(): array
    {
        return [
            'steps' => BoxPhoto::STEPS,
            'count' => BoxPhoto::count(),
            'bytes' => (int) BoxPhoto::sum('size'),
            'byStep' => BoxPhoto::selectRaw('step, count(*) as n')->groupBy('step')->pluck('n', 'step'),
        ];
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Providers/AppServiceProvider.php
mkdir -p 'app/Providers'
cat > 'app/Providers/AppServiceProvider.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Providers;

use App\Models\Consolidator;
use App\Support\Navigation\DispatchNavigationManager;
use App\Support\Photos\PhotoShrinker;
use App\Support\SchemaMemo;
use Filament\Actions\DeleteAction;
use Filament\Forms\Components\FileUpload;
use Filament\Navigation\NavigationManager;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Section;
use Filament\Support\Assets\Css;
use Filament\Support\Assets\Js;
use Filament\Support\Facades\FilamentAsset;
use Filament\Tables\Table;
use Illuminate\Console\Events\CommandFinished;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Events\MigrationEnded;
use Illuminate\Database\Events\MigrationsEnded;
use Illuminate\Database\Events\SchemaLoaded;
use Illuminate\Database\QueryException;
use Illuminate\Database\Schema\Builder;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        // Speed: Schema::hasTable / hasColumn answers are remembered (App\Support\SchemaMemo); forgotten when migrations run.
        $this->app->extend('db.schema', fn ($schema) => $schema instanceof Builder ? new SchemaMemo($schema) : $schema);
    }

    public function boot(): void
    {
        // Side menus: groups in the order of the work, clear names, numbers on what waits (App\Support\Navigation\Menu).
        $this->app->scoped(NavigationManager::class, fn () => new DispatchNavigationManager);

        // Forms are built with Filament schemas, which only pass the fields they render.
        Model::unguard();

        // Photos on this server or in a bucket (Settings → Photo storage): the public and box disks.
        \Illuminate\Support\Facades\Storage::extend('routed', function ($app, array $config) {
            $adapter = new \App\Support\Photos\Storage\RoutedAdapter($config['name'], $config);

            return new \Illuminate\Filesystem\FilesystemAdapter(new \League\Flysystem\Filesystem($adapter, $config), $adapter, $config);
        });
        // Local only: buckets as folders, to try the page without R2 (PHOTOS_FAKE_BUCKETS=1 in .env).
        if ($this->app->environment('local') && env('PHOTOS_FAKE_BUCKETS')) {
            \App\Support\Photos\Storage\PhotoStore::$fake = true;
        }
        // The page shows if a queue worker runs (Supervisor or Plesk): it is seen here.
        Event::listen(\Illuminate\Queue\Events\Looping::class, function () {
            static $last = 0;
            if (time() - $last > 60) {
                $last = time();
                \Illuminate\Support\Facades\Cache::put('photos.queue.seen', $last, 3600);
            }
        });

        Section::configureUsing(fn (Section $section) => $section->columnSpanFull());

        // Photos are made smaller on the phone before upload (longest side 1600 px), like the
        // Scan app and the Driver app. A 3 MB phone photo becomes a few hundred KB.
        // Non-photo files are not touched; small pictures (logos) are never made bigger.
        FileUpload::configureUsing(fn (FileUpload $upload) => $upload
            ->automaticallyResizeImagesMode('contain')
            ->automaticallyResizeImagesToWidth((string) PhotoShrinker::MAX_SIDE)
            ->automaticallyResizeImagesToHeight((string) PhotoShrinker::MAX_SIDE)
            ->imageResizeUpscale(false));

        // Consistent, roomier tables in every panel.
        Table::configureUsing(fn (Table $table) => $table
            ->paginationPageOptions([10, 25, 50, 100])
            ->defaultPaginationPageOption(25)
            ->striped());

        // Deleting something that is still in use (e.g. a truck that has trips) used to end in a
        // database error page. Show a clear message instead.
        DeleteAction::configureUsing(fn (DeleteAction $action) => $action->using(
            function (Model $record, DeleteAction $action): bool {
                try {
                    return (bool) $record->delete();
                } catch (QueryException $exception) {
                    if (! in_array($exception->getCode(), ['23000', '23503'], true)) {
                        throw $exception;
                    }

                    Notification::make()
                        ->title('Cannot delete this record')
                        ->body('It is still used by other records (for example trips or invoices). Remove those first.')
                        ->danger()
                        ->persistent()
                        ->send();

                    $action->halt();

                    return false;
                }
            },
        ));

        // Queue workers live for hours; start every job with fresh lookups.
        Queue::looping(function () {
            Consolidator::flushNameCache();
            SchemaMemo::reset();
        });

        // Tables changed: forget the remembered Schema answers.
        Event::listen([MigrationsEnded::class, MigrationEnded::class, SchemaLoaded::class], fn () => SchemaMemo::flush());
        Event::listen(CommandFinished::class, function ($e) {
            if (in_array($e->command, ['optimize:clear', 'cache:clear', 'migrate', 'migrate:fresh', 'migrate:rollback', 'migrate:refresh', 'migrate:reset', 'db:wipe'], true)) {
                SchemaMemo::flush();
            }
        });

        FilamentAsset::register([
            Js::make('barcode-scanner', resource_path('js/barcode-scanner.js')),
            Js::make('driver-offline', resource_path('js/driver-offline.js')),
            // Check photos: full screen with zoom, and Use photo / Retake right after a photo (board 68).
            Js::make('photo-viewer', resource_path('js/photo-viewer.js')),
            // Maps & routes: the stops map (Leaflet 1.9.4 + OpenStreetMap), only on the pages that show it.
            // Kept in resources/vendor so the server does not need node_modules (composer runs
            // filament:upgrade, which publishes these files, before any npm step).
            Js::make('leaflet', resource_path('vendor/leaflet/leaflet.js'))->loadedOnRequest(),
            Css::make('leaflet', resource_path('vendor/leaflet/leaflet.css'))->loadedOnRequest(),
            Js::make('trip-map', resource_path('js/trip-map.js'))->loadedOnRequest(),
            Js::make('truck-map', resource_path('js/truck-map.js'))->loadedOnRequest(),
        ]);
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- public/js/app/driver-offline.js
mkdir -p 'public/js/app'
cat > 'public/js/app/driver-offline.js' <<'DISPATCH_FILE_END_3'
/*
 * Driver app without signal.
 *
 * - Keeps today's trip on the phone (IndexedDB) while there is signal.
 * - Without signal: shows its own screens (find a box, deliver with photos, can't deliver)
 *   and keeps each one on the phone in a queue.
 * - When the signal is back: sends the queue by itself, oldest first, with the real time.
 *   Anything the office changed meanwhile is not forced through: it shows as "Needs attention".
 *
 * Runs on the Driver app home page (/delivery) and on the offline page (/delivery-offline).
 */
(function () {
    /*
     * Make a phone photo smaller before it is sent: longest side 1600 px, JPEG 80%.
     * A 3 MB iPhone photo becomes about 300 KB. Two ways, because iPhone Safari does not
     * always manage the first one; if both fail the photo is sent as it is (the server
     * makes it smaller then). Used by every photo button (window.dsShrinkPhoto).
     */
    async function shrinkPhoto(file, maxSide = 1600, quality = 0.8) {
        if (!file || (file.type && !/^image\//.test(file.type))) return file;
        const draw = (src, w, h) => {
            const s = Math.min(1, maxSide / Math.max(w, h));
            const c = document.createElement('canvas');
            c.width = Math.max(1, Math.round(w * s));
            c.height = Math.max(1, Math.round(h * s));
            c.getContext('2d').drawImage(src, 0, 0, c.width, c.height);
            return new Promise((r) => c.toBlob(r, 'image/jpeg', quality));
        };
        const ways = [
            async () => {
                const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' });
                try { return await draw(bmp, bmp.width, bmp.height); } finally { if (bmp.close) bmp.close(); }
            },
            async () => {
                // iPhone: a plain image keeps the photo the right way up when drawn
                const url = URL.createObjectURL(file);
                try {
                    const img = new Image();
                    img.src = url;
                    if (img.decode) await img.decode();
                    else await new Promise((ok, no) => { img.onload = ok; img.onerror = no; });
                    return await draw(img, img.naturalWidth, img.naturalHeight);
                } finally { URL.revokeObjectURL(url); }
            },
        ];
        for (const way of ways) {
            try {
                const blob = await way();
                if (blob && blob.size > 0) {
                    return blob.size < file.size ? new File([blob], 'photo.jpg', { type: 'image/jpeg', lastModified: Date.now() }) : file;
                }
            } catch (e) { /* try the next way */ }
        }
        return file;
    }
    window.dsShrinkPhoto = window.dsShrinkPhoto || shrinkPhoto;

    if (window.dsDriverOffline) return;

    const TRIP_URL = '/delivery-offline/trip';
    const SYNC_URL = '/delivery-offline/sync';
    const DB_NAME = 'ds-driver';
    const MAX_PHOTO_SIDE = 1600;

    // ------------------------------------------------------------------ storage (IndexedDB)

    let dbPromise = null;
    function db() {
        if (!dbPromise) {
            dbPromise = new Promise((resolve, reject) => {
                const req = indexedDB.open(DB_NAME, 1);
                req.onupgradeneeded = () => {
                    const d = req.result;
                    if (!d.objectStoreNames.contains('kv')) d.createObjectStore('kv');
                    if (!d.objectStoreNames.contains('queue')) d.createObjectStore('queue', { keyPath: 'uuid' });
                };
                req.onsuccess = () => resolve(req.result);
                req.onerror = () => reject(req.error);
            });
        }
        return dbPromise;
    }
    async function tx(store, mode, fn) {
        const d = await db();
        return new Promise((resolve, reject) => {
            const t = d.transaction(store, mode);
            const s = t.objectStore(store);
            const out = fn(s);
            t.oncomplete = () => resolve(out && 'result' in out ? out.result : out);
            t.onerror = () => reject(t.error);
        });
    }
    const kvGet = (k) => tx('kv', 'readonly', (s) => s.get(k));
    const kvSet = (k, v) => tx('kv', 'readwrite', (s) => s.put(v, k));
    const qAll = async () => ((await tx('queue', 'readonly', (s) => s.getAll())) || []).sort((a, b) => a.at.localeCompare(b.at));
    const qPut = (item) => tx('queue', 'readwrite', (s) => s.put(item));
    const qDel = (uuid) => tx('queue', 'readwrite', (s) => s.delete(uuid));

    // ------------------------------------------------------------------ helpers

    const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    }));
    const timeOf = (iso) => new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    const norm = (code) => String(code || '').trim().toUpperCase().replace(/[\x00-\x1F\x7F]+/g, '');
    const buzz = (ok) => { try { navigator.vibrate && navigator.vibrate(ok ? 60 : [80, 60, 80]); } catch (e) {} };

    async function shrink(file) {
        return shrinkPhoto(file, MAX_PHOTO_SIDE);
    }

    // ------------------------------------------------------------------ state

    const state = {
        snapshot: null,      // { trip, boxes, reasons, driver, saved_at }
        queue: [],
        online: navigator.onLine,
        sending: false,
        sent: 0,
        forced: false,       // offline screens shown even with signal (the offline page)
        view: 'home',        // home, box, deliver, miss, queue, camera
        box: null,
        photos: [],          // { blob, url }
        reason: null,
        note: '',
        search: '',
        toast: null,
        authProblem: false,
    };

    async function load() {
        state.snapshot = (await kvGet('snapshot')) || null;
        state.queue = await qAll();
    }

    /** Ask the server for today's boxes (and a fresh security token). */
    async function refreshTrip() {
        const res = await fetch(TRIP_URL, { credentials: 'same-origin', headers: { Accept: 'application/json' }, cache: 'no-store' });
        if (res.status === 401) { state.authProblem = true; throw new Error('auth'); }
        if (!res.ok) throw new Error('http ' + res.status);
        const data = await res.json();
        state.authProblem = false;
        const previous = state.snapshot;
        if (previous && previous.driver && data.driver && previous.driver.id !== data.driver.id) {
            // another driver signed in on this phone: keep only their own queue items
            state.queue = state.queue.filter((q) => q.driver_id === data.driver.id);
        }
        state.snapshot = data;
        await kvSet('snapshot', { ...data, csrf: undefined });
        return data.csrf;
    }

    // ------------------------------------------------------------------ sending

    async function flush() {
        if (state.sending || !navigator.onLine) return false;
        const waiting = state.queue.filter((q) => q.status === 'wait');
        if (!waiting.length) return false;

        state.sending = true; state.sent = 0; render();
        let csrf;
        try { csrf = await refreshTrip(); } catch (e) { state.sending = false; render(); return false; }

        let changed = false;
        for (const item of waiting) {
            const form = new FormData();
            form.append('uuid', item.uuid);
            form.append('type', item.type);
            form.append('tripinvoice_id', item.box_id);
            form.append('at', item.at);
            if (item.reason) form.append('reason', item.reason);
            if (item.note) form.append('note', item.note);
            (item.photos || []).forEach((b, i) => form.append('photos[]', b, `photo-${i + 1}.jpg`));
            try {
                const res = await fetch(SYNC_URL, { method: 'POST', body: form, credentials: 'same-origin', headers: { Accept: 'application/json', 'X-CSRF-TOKEN': csrf } });
                if (res.status === 401 || res.status === 419) { state.authProblem = true; break; }
                if (res.status === 422) {
                    const body = await res.json().catch(() => ({}));
                    item.status = 'fail'; item.message = body.message || 'The office could not save this one.';
                } else if (!res.ok) {
                    break; // server problem: try again later
                } else {
                    const body = await res.json();
                    item.status = body.status === 'saved' ? 'sent' : 'fail';
                    item.message = body.message || null;
                }
                if (item.status !== 'wait') { item.photos = []; item.photoCount = item.photoCount || 0; item.done_at = new Date().toISOString(); }
                await qPut(item);
                state.sent++; changed = true; render();
            } catch (e) {
                break; // signal dropped again
            }
        }
        state.queue = await qAll();
        state.sending = false;
        try { await refreshTrip(); } catch (e) {}
        render();
        if (changed) document.dispatchEvent(new CustomEvent('ds-offline-sent'));
        return changed;
    }

    // ------------------------------------------------------------------ boxes on the phone

    function boxes() {
        const list = (state.snapshot && state.snapshot.boxes) || [];
        const queued = new Map(state.queue.filter((q) => q.status !== 'fail').map((q) => [q.box_id, q.type]));
        return list.map((b) => ({ ...b, local: queued.get(b.id) || null }));
    }
    function counts() {
        const all = boxes();
        const delivered = all.filter((b) => b.delivered || b.local === 'deliver').length;
        return { total: all.length, delivered, left: all.length - delivered, waiting: state.queue.filter((q) => q.status === 'wait').length,
            attention: state.queue.filter((q) => q.status === 'fail').length };
    }
    /** Stops still to visit (Maps & routes), in order. A stop drops off once all its boxes are delivered. */
    function stops() {
        const left = new Map(boxes().filter((b) => !b.delivered && b.local !== 'deliver').map((b) => [b.id, b]));
        return ((state.snapshot && state.snapshot.stops) || []).map((s) => {
            const mine = (s.boxes || []).map((id) => left.get(id)).filter(Boolean);
            return mine.length ? { ...s, count: mine.length, first: mine[0].invoice } : null;
        }).filter(Boolean);
    }
    const IOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    function navUrl(app, s) {
        const to = encodeURIComponent(s.go);
        if (app === 'waze') return s.lat !== null ? 'https://waze.com/ul?ll=' + to + '&navigate=yes' : 'https://waze.com/ul?q=' + to + '&navigate=yes';
        if (app === 'apple') return 'https://maps.apple.com/?daddr=' + to + '&dirflg=d';
        return 'https://www.google.com/maps/dir/?api=1&destination=' + to + '&travelmode=driving';
    }
    function telOf(p) { return p ? 'tel:' + String(p).replace(/[^0-9+]/g, '') : ''; }
    function findBox(code) {
        const c = norm(code);
        return boxes().find((b) => (b.codes || [b.invoice]).some((x) => norm(x) === c));
    }

    // ------------------------------------------------------------------ actions

    function openBox(code) {
        const b = findBox(code);
        if (!b) { toast('bad', `${norm(code)} is not in today's saved list`, 'Keep it aside. Check again when you have signal.'); buzz(false); return; }
        if (b.delivered || b.local === 'deliver') { toast('bad', `${b.invoice} is already delivered`, b.local ? 'Saved on this phone, waiting to send.' : ''); buzz(false); return; }
        state.box = b; state.view = 'box'; state.photos = []; state.note = ''; state.reason = null; buzz(true); render();
    }

    async function addPhotos(files) {
        for (const f of files) {
            if (state.view === 'miss' && state.photos.length >= 3) break;
            const blob = await shrink(f);
            state.photos.push({ blob, url: URL.createObjectURL(blob) });
        }
        render();
    }

    async function save(type) {
        const b = state.box;
        if (!b) return;
        if (type === 'deliver' && !state.photos.length) { toast('bad', 'Take at least one photo', ''); return; }
        const r = type === 'miss' ? reasons().find((x) => x.value === state.reason) : null;
        if (type === 'miss') {
            if (!r) { toast('bad', 'Pick a reason', ''); return; }
            if (r.note && !state.note.trim()) { toast('bad', 'Please add a note for this reason', ''); return; }
            if (r.photo && !state.photos.length) { toast('bad', 'Please add a photo for this reason', ''); return; }
        }
        const item = {
            uuid: uuid(), type, box_id: b.id, invoice: b.invoice, name: b.name, at: new Date().toISOString(),
            reason: r ? r.value : null, reasonLabel: r ? r.label : null, note: state.note.trim() || null,
            photos: state.photos.map((p) => p.blob), photoCount: state.photos.length, status: 'wait',
            driver_id: state.snapshot && state.snapshot.driver ? state.snapshot.driver.id : null,
        };
        await qPut(item);
        state.queue = await qAll();
        state.photos.forEach((p) => URL.revokeObjectURL(p.url));
        state.photos = []; state.box = null; state.view = 'home';
        buzz(true);
        toast('saved', type === 'deliver' ? `${item.invoice} saved on this phone` : `${item.invoice} kept on the truck`,
            'It will send by itself when the signal is back.', item.uuid);
        if (navigator.onLine) flush();
    }

    async function undo(id) {
        const item = state.queue.find((q) => q.uuid === id);
        if (!item || item.status !== 'wait') return;
        await qDel(id);
        state.queue = await qAll();
        state.toast = null;
        render();
    }

    async function clearDone() {
        for (const q of state.queue.filter((x) => x.status === 'sent')) await qDel(q.uuid);
        state.queue = await qAll(); render();
    }

    async function dismiss(id) { await qDel(id); state.queue = await qAll(); render(); }

    const reasons = () => (state.snapshot && state.snapshot.reasons) || [];

    let toastTimer = null;
    function toast(kind, title, sub, undoId) {
        state.toast = { kind, title, sub, undoId };
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => { state.toast = null; render(); }, 6000);
        render();
    }

    // ------------------------------------------------------------------ camera (phones with a built-in barcode reader)

    let camStream = null; let camLoop = null;
    async function startCamera() {
        if (!('BarcodeDetector' in window)) return;
        state.view = 'camera'; render();
        try {
            const detector = new window.BarcodeDetector();
            camStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
            const video = document.querySelector('#dso-video');
            if (!video) return stopCamera();
            video.srcObject = camStream; await video.play();
            camLoop = setInterval(async () => {
                try {
                    const found = await detector.detect(video);
                    if (found && found[0]) { const code = found[0].rawValue; stopCamera(); openBox(code); }
                } catch (e) {}
            }, 350);
        } catch (e) {
            stopCamera(); toast('bad', 'The camera could not start', 'Type the box number instead.');
        }
    }
    function stopCamera() {
        clearInterval(camLoop); camLoop = null;
        if (camStream) camStream.getTracks().forEach((t) => t.stop());
        camStream = null;
        if (state.view === 'camera') { state.view = 'home'; render(); }
    }

    // ------------------------------------------------------------------ rendering

    function shown() { return state.forced || !state.online; }

    function netBar() {
        const c = counts();
        let cls, title, sub;
        if (!state.online) { cls = 'is-off'; title = 'No signal'; sub = c.waiting ? `${c.waiting} waiting to send · kept on this phone` : 'You can keep scanning and delivering'; }
        else if (state.sending) { cls = 'is-send'; title = 'Back online · sending'; sub = `${state.sent} of ${c.waiting + state.sent} sent`; }
        else if (state.authProblem && c.waiting) { cls = 'is-warn'; title = 'Sign in again to send'; sub = `${c.waiting} waiting on this phone`; }
        else if (c.attention) { cls = 'is-warn'; title = `Online · ${c.attention} needs attention`; sub = 'Tap to see why'; }
        else if (c.waiting) { cls = 'is-send'; title = 'Online'; sub = `${c.waiting} waiting to send`; }
        else { cls = 'is-on'; title = 'Online'; sub = 'Every delivery is saved'; }
        return { cls, title, sub, n: c.waiting + c.attention };
    }

    /** The small signal bar shown on the online Driver app. */
    function renderBar() {
        const el = document.getElementById('ds-net');
        if (!el) return;
        const n = netBar();
        el.className = 'dso-net ' + n.cls + (n.n || !state.online ? ' is-shown' : '');
        el.innerHTML = `<i></i><span><strong>${esc(n.title)}</strong><small>${esc(n.sub)}</small></span>${n.n ? `<button type="button" data-dso="queue">${n.n} ›</button>` : ''}`;
    }

    function photoGrid(max) {
        const tiles = state.photos.map((p, i) => `<span class="dso-proof"><img src="${p.url}" alt="Photo ${i + 1}"><b>${i + 1}</b><button type="button" data-dso="rmphoto" data-i="${i}" aria-label="Remove photo">✕</button></span>`).join('');
        const can = !max || state.photos.length < max;
        return `<div class="dso-grid">${tiles}${can ? `<label class="dso-add"><input type="file" accept="image/*" capture="environment" multiple data-dso="photos" hidden><span>📷</span>${state.photos.length ? 'Add another' : 'Take photo'}</label>` : ''}</div>`;
    }

    function screenHtml() {
        const s = state.snapshot;
        const c = counts();
        const n = netBar();
        const bar = `<div class="dso-net ${n.cls} is-shown"><i></i><span><strong>${esc(n.title)}</strong><small>${esc(n.sub)}</small></span>${n.n ? `<button type="button" data-dso="queue">${n.n} ›</button>` : ''}</div>`;
        const toastHtml = state.toast ? `<div class="dso-toast is-${state.toast.kind}"><span>${state.toast.kind === 'bad' ? '!' : '⏳'}</span><span><strong>${esc(state.toast.title)}</strong>${state.toast.sub ? `<small>${esc(state.toast.sub)}</small>` : ''}</span>${state.toast.undoId ? `<button type="button" data-dso="undo" data-id="${esc(state.toast.undoId)}">Undo</button>` : ''}</div>` : '';

        if (!s) {
            return `${bar}<section class="dso-screen"><div class="dso-empty"><strong>Today's trip is not on this phone yet</strong><p>Open the Driver app once with signal (at the warehouse is best). After that it works without signal.</p></div></section>`;
        }
        if (!s.trip) {
            return `${bar}<section class="dso-screen"><div class="dso-empty"><strong>You're not on a trip</strong><p>When the office puts you on a truck, today's boxes are saved here.</p></div></section>`;
        }

        if (state.view === 'nav' && state.stop) {
            const st = state.stop;
            const off = !state.online;
            const app = (key, letter, name, good, bad, dim) => `<button type="button" class="dso-app${dim ? ' is-dim' : ''}" data-dso="go" data-app="${key}"><i class="is-${key}">${letter}</i><span><b>${name}</b><small class="${dim ? 'dso-amber' : 'is-ok'}">${dim ? bad : good}</small></span>›</button>`;
            return `${bar}<section class="dso-screen"><div class="dso-sheet">
                <div class="dso-sheethead"><small>Stop ${st.no}${off ? ' · no signal' : ''}</small><strong>${esc(st.name)}</strong><span>${esc(st.address || st.place)} · ${st.lat !== null ? (st.exact ? '📍 exact pin' : '📍 area pin') : 'no pin'} · ${st.count} ${st.count > 1 ? 'boxes' : 'box'}</span></div>
                ${off ? `<p class="dso-navtip">${st.lat !== null ? 'No signal: use a map app with your area downloaded. It finds the pin and drives you there offline.' : 'This stop has no pin, so the map app has to search the address. That needs signal.'}</p>` : ''}
                ${app('google', 'G', 'Google Maps', off ? '✓ works offline with a downloaded map' : 'Best street and address detail', '', false)}
                ${IOS ? app('apple', 'A', 'Apple Maps', off ? '✓ works offline with a downloaded map' : 'Already on your iPhone', '', false) : ''}
                ${app('waze', 'W', 'Waze', 'Best for traffic and shortcuts', 'needs signal · may not open the route', off)}
                ${off ? '<p class="dso-note">Tip: download your area once on office Wi-Fi. Google Maps: profile → Offline maps. Apple Maps: profile → Offline Maps.</p>' : ''}
                <div class="dso-two">${st.phone ? `<a class="dso-ghostbtn" href="${esc(telOf(st.phone))}">Call ${esc(String(st.name).split(' ')[0])}</a>` : ''}<button type="button" class="dso-primary is-green" style="height:3rem" data-dso="open" data-code="${esc(st.first)}">I'm here · deliver</button></div>
                <button type="button" class="dso-link" data-dso="home">Close</button>
            </div></section>${toastHtml}`;
        }

        if (state.view === 'queue') {
            const rows = state.queue.slice().reverse().map((q) => {
                const st = q.status === 'wait' ? ['⏳', 'Waiting', 'is-wait'] : q.status === 'sent' ? ['✓', 'Sent', 'is-ok'] : ['!', 'Needs attention', 'is-warn'];
                const what = q.type === 'deliver' ? 'Delivered' : `Can't deliver · ${q.reasonLabel || ''}`;
                return `<div class="dso-q ${st[2]}"><span class="dso-qi">${st[0]}</span><span class="dso-qt"><strong>${esc(q.invoice)} <small>${esc(what)}</small></strong><small>${esc(q.name || '')} · ${q.photoCount || 0} photo(s) · ${timeOf(q.at)}</small>${q.message ? `<em>${esc(q.message)}</em>` : ''}</span><span class="dso-qs">${st[1]}${q.status === 'wait' ? `<button type="button" data-dso="undo" data-id="${esc(q.uuid)}">Remove</button>` : q.status === 'fail' ? `<button type="button" data-dso="dismiss" data-id="${esc(q.uuid)}">OK</button>` : ''}</span></div>`;
            }).join('') || '<p class="dso-muted">Nothing waiting.</p>';
            return `${bar}<section class="dso-screen"><div class="dso-head"><button type="button" class="dso-back" data-dso="home">‹</button><strong>Waiting to send</strong></div>
                ${state.sending ? `<div class="dso-sending"><span>Sending… ${state.sent} sent</span><i style="width:${Math.min(100, state.sent / Math.max(1, c.waiting + state.sent) * 100)}%"></i></div>` : ''}
                ${rows}
                ${state.queue.some((q) => q.status === 'sent') ? '<button type="button" class="dso-link" data-dso="cleardone">Clear sent ones</button>' : ''}
                ${state.online && c.waiting && !state.sending ? '<button type="button" class="dso-primary" data-dso="send">Send now</button>' : ''}
                <div class="dso-warn"><b>!</b><span>Don't clear the browser or remove the app until everything is sent. On iPhone, open the app when you have signal so it can send.</span></div>
                ${state.forced && state.online ? '<a class="dso-primary is-ghost" href="/delivery">Open the full Driver app</a>' : ''}</section>${toastHtml}`;
        }

        if (state.view === 'camera') {
            return `<section class="dso-camera"><video id="dso-video" playsinline muted></video><div class="dso-frame"></div><button type="button" class="dso-primary is-ghost" data-dso="stopcam">Close camera</button></section>`;
        }

        if (state.box && ['box', 'deliver', 'miss'].includes(state.view)) {
            const b = state.box;
            let body = '';
            if (state.view === 'box') {
                body = `<div class="dso-tags"><span class="dso-tag is-ok">On your truck</span><strong>${esc(b.invoice)}</strong><span class="dso-tag is-blue">From saved list</span></div>
                    <div class="dso-who"><strong>${esc(b.name)}</strong><span>${esc(b.address)}</span></div>
                    ${b.phone ? `<a class="dso-ghostbtn" href="tel:${esc(String(b.phone).replace(/[^0-9+]/g, ''))}">📞 Call ${esc(b.phone)}</a>` : ''}
                    ${b.attempted ? '<small class="dso-amber">Tried before</small>' : ''}
                    <button type="button" class="dso-primary is-green" data-dso="deliver">Deliver this box</button>
                    <button type="button" class="dso-secondary" data-dso="miss">Can't deliver</button>
                    <button type="button" class="dso-link" data-dso="home">Back</button>`;
            } else if (state.view === 'deliver') {
                body = `<div class="dso-sheethead"><small>${esc(b.invoice)} · ${esc(b.name)}</small><strong>Proof of delivery</strong><span>Take as many photos as you need.</span></div>
                    ${photoGrid(0)}
                    <button type="button" class="dso-primary ${state.photos.length ? 'is-green' : 'is-off'}" data-dso="savedeliver">${state.photos.length ? `Delivered · save on phone (${state.photos.length})` : 'Take at least 1 photo'}</button>
                    <button type="button" class="dso-link" data-dso="box">Back</button>`;
            } else {
                const r = reasons().find((x) => x.value === state.reason);
                body = `<div class="dso-sheethead"><small>${esc(b.invoice)} · ${esc(b.name)}</small><strong>Why couldn't you deliver it?</strong></div>
                    <div class="dso-chips">${reasons().map((x) => `<button type="button" data-dso="reason" data-v="${esc(x.value)}" class="${x.value === state.reason ? 'is-on' : ''}">${esc(x.label)}</button>`).join('')}</div>
                    <input type="text" class="dso-input" data-dso="note" maxlength="500" value="${esc(state.note)}" placeholder="${esc(r ? r.prompt : 'Note')}${r && r.note ? '' : ' (optional)'}">
                    ${photoGrid(3)}
                    <button type="button" class="dso-primary is-amber" data-dso="savemiss">Keep it on the truck</button>
                    <button type="button" class="dso-link" data-dso="box">Back</button>`;
            }
            return `${bar}<section class="dso-screen"><div class="dso-sheet ${state.view === 'miss' ? 'is-warn' : ''}">${body}</div></section>${toastHtml}`;
        }

        const q = norm(state.search);
        const list = boxes().filter((b) => !b.delivered && b.local !== 'deliver')
            .filter((b) => !q || norm(b.invoice).includes(q) || norm(b.name).includes(q) || norm(b.address).includes(q)).slice(0, 80);
        const pct = c.total ? Math.round(c.delivered / c.total * 289) : 0;
        return `${bar}<section class="dso-screen">
            <div class="dso-hello"><small>Trip ${esc(s.trip.number)}${s.trip.plate ? ' · Truck ' + esc(s.trip.plate) : ''}</small><strong>Hi, ${esc(s.driver ? s.driver.first_name : '')}</strong></div>
            <div class="dso-today"><span class="dso-ring"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="t"/><circle cx="55" cy="55" r="46" class="f" style="stroke-dashoffset:${289 - pct}"/></svg><span><strong>${c.delivered}</strong><small>of ${c.total}</small></span></span>
                <dl><dt>Delivered</dt><dd class="is-ok">${c.delivered}</dd><dt>Waiting to send</dt><dd class="is-blue">${c.waiting}</dd><dt>Still on the truck</dt><dd>${c.left}</dd></dl></div>
            <form class="dso-find" data-dso="find"><input type="text" name="code" placeholder="Type a box number" autocomplete="off" autocapitalize="characters" enterkeyhint="go" aria-label="Box number"><button type="submit">Find</button></form>
            ${'BarcodeDetector' in window ? '<button type="button" class="dso-primary" data-dso="camera">Scan with camera</button>' : ''}
            <p class="dso-note">Today's ${c.total} boxes are saved on this phone (${esc(s.saved_at ? timeOf(s.saved_at) : '')}). You can deliver without signal.</p>
            ${stopsHtml()}
            <input type="search" class="dso-input" data-dso="search" value="${esc(state.search)}" placeholder="Search name or barangay">
            <div class="dso-list">${list.map((b) => `<button type="button" class="dso-row" data-dso="open" data-code="${esc(b.invoice)}"><strong>${esc(b.invoice)}${b.local === 'miss' ? ' <em>kept · waiting</em>' : ''}</strong><span>${esc(b.name)}</span><small>${esc(b.address)}</small></button>`).join('') || '<p class="dso-muted">No boxes left to deliver.</p>'}</div>
            ${state.forced && state.online ? '<a class="dso-primary is-ghost" href="/delivery">Signal is back · open the full Driver app</a>' : ''}
        </section>${toastHtml}`;
    }

    function stopsHtml() {
        const list = stops();
        if (!list.length) return '';
        const next = list[0];
        const row = (st) => `<div class="dso-stop"><span class="dso-no${st.priority ? ' is-prio' : ''}">${st.no}</span><span class="dso-stopt"><strong>${esc(st.name)}</strong><small>${esc(st.place)} · ${st.count} ${st.count > 1 ? 'boxes' : 'box'}${st.priority ? ' · priority' : ''}</small>${st.lat === null ? '<em>no pin · needs signal to find</em>' : ''}</span><button type="button" class="dso-go${st.lat === null && !state.online ? ' is-dim' : ''}" data-dso="nav" data-id="${st.id}">Navigate</button></div>`;
        return `<p class="dso-label">Your stops <span>· saved on this phone</span></p>
            <div class="dso-next"><span><small>Next · stop ${next.no}</small><strong>${esc(next.name)}</strong><em>${esc(next.place)} · ${next.count} ${next.count > 1 ? 'boxes' : 'box'}</em></span><button type="button" data-dso="nav" data-id="${next.id}">Navigate</button></div>
            <div class="dso-stops">${list.slice(1, 12).map(row).join('')}</div>`;
    }

    function render() {
        renderBar();
        let root = document.getElementById('dso-root');
        if (!shown()) { if (root) root.hidden = true; return; }
        if (!root) { root = document.createElement('div'); root.id = 'dso-root'; document.body.appendChild(root); }
        root.hidden = false;
        const active = document.activeElement;
        const keep = active && active.dataset && active.dataset.dso && root.contains(active) ? { k: active.dataset.dso, pos: active.selectionStart } : null;
        root.innerHTML = screenHtml();
        if (keep) {
            const el = root.querySelector(`[data-dso="${keep.k}"]`);
            if (el && el.focus) { el.focus(); try { el.setSelectionRange(keep.pos, keep.pos); } catch (e) {} }
        }
    }

    // ------------------------------------------------------------------ events

    document.addEventListener('click', (e) => {
        const t = e.target.closest('[data-dso]');
        if (!t) return;
        const a = t.dataset.dso;
        const actions = {
            queue: () => { state.view = 'queue'; if (!shown()) state.forced = true; render(); },
            home: () => { state.view = 'home'; state.box = null; if (state.online && !document.getElementById('dso-shell')) state.forced = false; render(); },
            open: () => openBox(t.dataset.code),
            nav: () => { state.stop = stops().find((x) => String(x.id) === t.dataset.id) || null; if (state.stop) { state.view = 'nav'; render(); } },
            go: () => { const url = navUrl(t.dataset.app, state.stop); try { localStorage.setItem('ds.navApp', t.dataset.app); } catch (err) {} window.open(url, '_blank') || (window.location.href = url); },
            deliver: () => { state.view = 'deliver'; render(); },
            miss: () => { state.view = 'miss'; state.reason = state.reason || (reasons()[0] || {}).value; render(); },
            box: () => { state.view = 'box'; render(); },
            reason: () => { state.reason = t.dataset.v; render(); },
            rmphoto: () => { const i = +t.dataset.i; URL.revokeObjectURL(state.photos[i].url); state.photos.splice(i, 1); render(); },
            savedeliver: () => save('deliver'),
            savemiss: () => save('miss'),
            undo: () => undo(t.dataset.id),
            dismiss: () => dismiss(t.dataset.id),
            cleardone: () => clearDone(),
            send: () => flush(),
            camera: () => startCamera(),
            stopcam: () => stopCamera(),
        };
        if (actions[a]) { e.preventDefault(); actions[a](); }
    });
    document.addEventListener('change', (e) => {
        if (e.target.dataset && e.target.dataset.dso === 'photos') addPhotos([...e.target.files]);
    });
    document.addEventListener('input', (e) => {
        const d = e.target.dataset && e.target.dataset.dso;
        if (d === 'note') state.note = e.target.value;
        if (d === 'search') { state.search = e.target.value; render(); }
    });
    document.addEventListener('submit', (e) => {
        if (e.target.dataset && e.target.dataset.dso === 'find') {
            e.preventDefault();
            const v = e.target.querySelector('input').value; if (v.trim()) openBox(v);
        }
    });

    window.addEventListener('offline', () => { state.online = false; render(); watchBack(); });
    window.addEventListener('online', async () => {
        state.online = true; render();
        const changed = await flush();
        // back on the full app: reload it so its numbers include what was just sent
        // Board 68: never while a box sheet or a photo is open; it reloads once they are closed.
        if (!document.getElementById('dso-shell') && changed) {
            const busy = () => document.querySelector('.ds-sa__sheet, .dspv, input[type=file]:focus');
            const later = () => (busy() ? setTimeout(later, 1500) : location.reload());
            setTimeout(later, 900);
        }
        else render();
    });

    // ------------------------------------------------------------------ start

    async function start() {
        state.forced = !!document.getElementById('dso-shell');
        try { await load(); } catch (e) {}
        render();
        if (navigator.onLine) {
            try { await refreshTrip(); } catch (e) {}
            await flush();
            render();
        }
        // keep the saved list fresh while the app is open
        setInterval(async () => { if (navigator.onLine && !state.sending) { try { await refreshTrip(); render(); } catch (e) {} } }, 5 * 60 * 1000);
        setInterval(() => { if (navigator.onLine) flush(); }, 30 * 1000);
    }

    window.dsDriverOffline = { state, flush, refreshTrip, render, openBox, save };

    const boot = () => {
        if (document.getElementById('ds-net') || document.getElementById('dso-shell')) start();
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
    document.addEventListener('livewire:navigated', () => render());

    // The phone says it has signal but a tap on the full app could not reach the office:
    // check once, and if the office really can't be reached, switch to the screens without signal.
    async function reachable() {
        try {
            const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 6000);
            const res = await fetch(TRIP_URL, { credentials: 'same-origin', cache: 'no-store', signal: ctl.signal, headers: { Accept: 'application/json' } });
            clearTimeout(t); return res.status < 500;
        } catch (e) { return false; }
    }
    let hooked = false;
    function hookLivewire() {
        if (hooked || !window.Livewire || !window.Livewire.hook) return;
        hooked = true;
        window.Livewire.hook('request', ({ fail }) => {
            fail(async ({ status, preventDefault }) => {
                if (!document.getElementById('ds-net')) return; // only the Driver app
                if (status && status < 500) return;
                preventDefault && preventDefault();
                if (!(await reachable())) { state.online = false; render(); watchBack(); }
            });
        });
    }
    if (window.Livewire) hookLivewire(); else document.addEventListener('livewire:init', hookLivewire);
    let backTimer = null;
    function watchBack() {
        clearInterval(backTimer);
        backTimer = setInterval(async () => {
            if (navigator.onLine && await reachable()) {
                clearInterval(backTimer);
                window.dispatchEvent(new Event('online'));
            }
        }, 15000);
    }

    // ------------------------------------------------------------------ look (same style as the Driver app)

    const css = `
#dso-root{position:fixed;inset:0;z-index:45;overflow:auto;color:#eef3f6;font-family:Archivo,system-ui,sans-serif;background:radial-gradient(120% 70% at 0% 0%,#15293a 0%,#0a1219 55%);-webkit-tap-highlight-color:transparent}
#dso-root[hidden]{display:none}
#dso-root button{font:inherit;cursor:pointer;border:0;background:none;color:inherit}
.dso-net{position:fixed;top:calc(env(safe-area-inset-top) + .6rem);left:1rem;right:1rem;z-index:46;max-width:32rem;margin:0 auto;display:none;align-items:center;gap:.65rem;padding:.55rem .6rem .55rem .9rem;border-radius:1rem;color:#eef3f6;font-family:Archivo,system-ui,sans-serif;backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px)}
.dso-net.is-shown{display:flex}
.dso-net i{width:.6rem;height:.6rem;border-radius:50%;flex:none}
.dso-net>span{flex:1;min-width:0;display:flex;flex-direction:column}
.dso-net strong{font-size:.85rem}.dso-net small{font-size:.72rem;opacity:.8}
.dso-net button{height:2rem;padding:0 .7rem;border-radius:.6rem;background:rgb(255 255 255/.12);color:#eef3f6;font-weight:800;font-size:.8rem;border:0}
.dso-net.is-off{background:rgb(30 40 52/.94);box-shadow:inset 0 0 0 1px rgb(140 196 255/.3)}.dso-net.is-off i{background:#ff6b5e;box-shadow:0 0 0 4px rgb(255 107 94/.2)}
.dso-net.is-send{background:rgb(15 43 35/.95);box-shadow:inset 0 0 0 1px rgb(52 195 143/.4)}.dso-net.is-send i{background:#34c38f}
.dso-net.is-warn{background:rgb(34 26 12/.95);box-shadow:inset 0 0 0 1px rgb(240 169 59/.4)}.dso-net.is-warn i{background:#f0a93b}
.dso-net.is-on{background:rgb(255 255 255/.06)}.dso-net.is-on i{background:#34c38f}
.dso-screen{max-width:34rem;margin:0 auto;padding:calc(env(safe-area-inset-top) + 5rem) 1.35rem calc(env(safe-area-inset-bottom) + 2rem);display:flex;flex-direction:column;gap:1rem}
.dso-hello{display:flex;flex-direction:column;gap:.2rem}.dso-hello small{color:#7f93a1;font-size:.85rem}.dso-hello strong{font-size:1.75rem;letter-spacing:-.025em}
.dso-today{display:flex;align-items:center;gap:1rem;padding:1rem;border-radius:1.5rem;background:rgb(255 255 255/.045);box-shadow:inset 0 0 0 1px rgb(255 255 255/.07)}
.dso-today dl{flex:1;display:grid;grid-template-columns:1fr auto;gap:.5rem .75rem;margin:0;font-size:.88rem}.dso-today dt{color:#7f93a1}.dso-today dd{margin:0;font-weight:700}
.dso-today .is-ok{color:#6fd6ad}.dso-today .is-blue{color:#8cc4ff}
.dso-ring{position:relative;width:5.5rem;height:5.5rem;flex:none}.dso-ring svg{width:100%;height:100%;transform:rotate(-90deg)}
.dso-ring circle{fill:none;stroke-width:9}.dso-ring .t{stroke:rgb(255 255 255/.08)}.dso-ring .f{stroke:#34c38f;stroke-linecap:round;stroke-dasharray:289}
.dso-ring>span{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center}.dso-ring strong{font-size:1.4rem}.dso-ring small{font-size:.65rem;color:#7f93a1}
.dso-find{display:flex;gap:.5rem}.dso-find input,.dso-input{-webkit-appearance:none;appearance:none;box-sizing:border-box;font-family:inherit;flex:1;min-width:0;height:3.1rem;padding:0 1rem;border:0;border-radius:1rem;background:rgb(255 255 255/.06);color:#eef3f6;font-size:1rem;box-shadow:inset 0 0 0 1px rgb(255 255 255/.08);outline:0}
.dso-find button{height:3.1rem;padding:0 1.2rem;border-radius:1rem;background:#f6be00!important;color:#0a1219!important;font-weight:800}
.dso-primary{display:flex;align-items:center;justify-content:center;height:3.5rem;border-radius:1.1rem;background:#f6be00!important;color:#0a1219!important;font-weight:800;font-size:1.02rem;text-decoration:none}
.dso-primary.is-green{background:#34c38f!important}.dso-primary.is-amber{background:#f0a93b!important}.dso-primary.is-off{background:rgb(255 255 255/.08)!important;color:#7f93a1!important}
.dso-primary.is-ghost{background:rgb(255 255 255/.08)!important;color:#eef3f6!important;font-weight:700}
.dso-secondary{height:3rem;border-radius:1rem;background:rgb(255 255 255/.06)!important;font-weight:600}
.dso-link{height:2.6rem;color:#7f93a1!important;font-weight:600}
.dso-note{margin:0;font-size:.82rem;color:#a9b8c2;line-height:1.5}.dso-muted{color:#7f93a1;font-size:.88rem}
.dso-list{display:flex;flex-direction:column;gap:.5rem}
.dso-row{display:flex;flex-direction:column;align-items:flex-start;gap:.1rem;padding:.8rem 1rem;border-radius:1.1rem;background:rgb(255 255 255/.045)!important;box-shadow:inset 0 0 0 1px rgb(255 255 255/.07);text-align:left}
.dso-row strong{font-size:.98rem}.dso-row em{font-style:normal;font-size:.7rem;color:#8cc4ff;margin-left:.35rem}.dso-row span{font-size:.88rem}.dso-row small{font-size:.75rem;color:#7f93a1}
.dso-sheet{display:flex;flex-direction:column;gap:.9rem;padding:1.1rem;border-radius:1.6rem;background:rgb(15 24 32/.98);box-shadow:0 20px 50px rgb(0 0 0/.4),inset 0 1px 0 rgb(255 255 255/.08)}
.dso-sheet.is-warn{background:rgb(34 26 12/.98)}
.dso-tags{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap}.dso-tags strong{color:#c9d5dc}
.dso-tag{padding:.25rem .65rem;border-radius:999px;font-size:.72rem;font-weight:700}.dso-tag.is-ok{background:rgb(52 195 143/.14);color:#6fd6ad}.dso-tag.is-blue{background:rgb(140 196 255/.14);color:#8cc4ff;margin-left:auto}
.dso-who{display:flex;flex-direction:column;gap:.25rem}.dso-who strong{font-size:1.55rem;letter-spacing:-.02em}.dso-who span{color:#a9b8c2;font-size:.9rem}
.dso-ghostbtn{display:flex;align-items:center;justify-content:center;height:3rem;border-radius:.9rem;background:rgb(255 255 255/.06);color:#eef3f6;text-decoration:none;font-weight:600}
.dso-amber{color:#f3c98a}
.dso-sheethead{display:flex;flex-direction:column;gap:.2rem}.dso-sheethead small{color:#7f93a1;font-size:.8rem}.dso-sheethead strong{font-size:1.4rem;letter-spacing:-.02em}.dso-sheethead span{color:#a9b8c2;font-size:.88rem}
.dso-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:.55rem}
.dso-proof{position:relative;aspect-ratio:1;border-radius:1rem;overflow:hidden}.dso-proof img{width:100%;height:100%;object-fit:cover}
.dso-proof b{position:absolute;left:.4rem;bottom:.4rem;padding:0 .45rem;border-radius:999px;background:rgb(10 18 25/.75);font-size:.7rem}
.dso-proof button{position:absolute;right:.3rem;top:.3rem;width:1.6rem;height:1.6rem;border-radius:50%;background:rgb(10 18 25/.7)!important;color:#fff;font-size:.7rem}
.dso-add{aspect-ratio:1;border-radius:1rem;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:.3rem;background:rgb(255 255 255/.05);box-shadow:inset 0 0 0 1.5px rgb(255 255 255/.18);font-size:.8rem;font-weight:600;cursor:pointer}
.dso-add span{font-size:1.4rem}
.dso-chips{display:flex;flex-wrap:wrap;gap:.4rem}.dso-chips button{height:2.3rem;padding:0 .8rem;border-radius:999px;background:rgb(255 255 255/.07)!important;font-size:.8rem;font-weight:700}
.dso-chips button.is-on{background:#f0a93b!important;color:#0a1219}
.dso-head{display:flex;align-items:center;gap:.7rem}.dso-head strong{font-size:1.5rem;letter-spacing:-.02em}
.dso-back{width:2.5rem;height:2.5rem;border-radius:50%;background:rgb(255 255 255/.06)!important;font-size:1.3rem}
.dso-q{display:flex;align-items:flex-start;gap:.7rem;padding:.85rem;border-radius:1.1rem;background:rgb(255 255 255/.045);box-shadow:inset 0 0 0 1px rgb(255 255 255/.07)}
.dso-q.is-warn{box-shadow:inset 0 0 0 1px rgb(240 169 59/.45)}
.dso-qi{display:grid;place-items:center;width:2rem;height:2rem;border-radius:50%;flex:none;font-weight:900;color:#0a1219;background:#8cc4ff}
.dso-q.is-ok .dso-qi{background:#34c38f}.dso-q.is-warn .dso-qi{background:#f0a93b}
.dso-qt{flex:1;min-width:0;display:flex;flex-direction:column;gap:.15rem}.dso-qt strong{font-size:.95rem}.dso-qt strong small{font-weight:500;color:#7f93a1;font-size:.75rem}.dso-qt>small{font-size:.75rem;color:#a9b8c2}
.dso-qt em{font-style:normal;font-size:.78rem;color:#f3c98a;line-height:1.4}
.dso-qs{display:flex;flex-direction:column;align-items:flex-end;gap:.35rem;font-size:.72rem;font-weight:700;color:#8cc4ff;white-space:nowrap}
.dso-q.is-ok .dso-qs{color:#34c38f}.dso-q.is-warn .dso-qs{color:#f0a93b}
.dso-qs button{padding:.25rem .55rem;border-radius:.5rem;background:rgb(255 255 255/.08)!important;color:#eef3f6;font-size:.72rem}
.dso-sending{display:flex;flex-direction:column;gap:.4rem;padding:.8rem 1rem;border-radius:1rem;background:rgb(52 195 143/.1)}.dso-sending i{display:block;height:6px;border-radius:999px;background:#34c38f;transition:width .4s}
.dso-warn{display:flex;gap:.6rem;padding:.75rem .9rem;border-radius:1rem;background:rgb(255 107 94/.08);box-shadow:inset 0 0 0 1px rgb(255 107 94/.25);font-size:.8rem;color:#f3c3bd;line-height:1.45}.dso-warn b{color:#ff8a7e}
.dso-empty{display:flex;flex-direction:column;gap:.5rem;padding:2.5rem 1.2rem;border-radius:1.5rem;background:rgb(255 255 255/.045);text-align:center}.dso-empty strong{font-size:1.15rem}.dso-empty p{margin:0;color:#7f93a1;line-height:1.5}
.dso-toast{position:fixed;top:calc(env(safe-area-inset-top) + 4.8rem);left:1rem;right:1rem;z-index:47;max-width:32rem;margin:0 auto;display:flex;align-items:center;gap:.7rem;padding:.7rem .7rem .7rem .9rem;border-radius:1.1rem;background:rgb(20 36 56/.97);box-shadow:0 16px 40px rgb(0 0 0/.4),inset 0 0 0 1px rgb(140 196 255/.4);animation:dso-in .3s ease-out}
.dso-toast.is-bad{background:rgb(40 18 20/.97);box-shadow:0 16px 40px rgb(0 0 0/.4),inset 0 0 0 1px rgb(255 107 94/.4)}
.dso-toast>span:first-child{display:grid;place-items:center;width:2rem;height:2rem;border-radius:50%;background:#8cc4ff;color:#0a1219;font-weight:900;flex:none}
.dso-toast.is-bad>span:first-child{background:#ff6b5e;color:#fff}
.dso-toast>span:nth-child(2){flex:1;display:flex;flex-direction:column}.dso-toast small{font-size:.75rem;opacity:.8}
.dso-toast button{height:2.3rem;padding:0 .8rem;border-radius:.7rem;background:rgb(255 255 255/.1)!important;font-weight:700}
.dso-label{margin:.2rem 0 -.4rem;font-size:.85rem;font-weight:700}.dso-label span{font-weight:400;color:#7f93a1}
.dso-next{display:flex;align-items:center;gap:.7rem;padding:.85rem .9rem;border-radius:1.1rem;background:rgb(246 190 0/.1);box-shadow:inset 0 0 0 1px rgb(246 190 0/.35)}
.dso-next>span{flex:1;min-width:0;display:flex;flex-direction:column}.dso-next small{font-size:.75rem;color:#f6d36b;font-weight:700}.dso-next strong{font-size:1.02rem}.dso-next em{font-style:normal;font-size:.8rem;color:#a9b8c2}
.dso-next button{height:2.6rem;padding:0 1rem;border-radius:.75rem;background:#f6be00!important;color:#0a1219!important;font-weight:800}
.dso-stops{display:flex;flex-direction:column;border-radius:1.1rem;background:rgb(255 255 255/.045);overflow:hidden}
.dso-stop{display:flex;align-items:center;gap:.65rem;padding:.7rem .8rem;border-top:1px solid rgb(255 255 255/.06)}.dso-stop:first-child{border-top:0}
.dso-no{width:1.9rem;height:1.9rem;flex:none;border-radius:50%;display:grid;place-items:center;font-weight:900;font-size:.82rem;background:rgb(255 255 255/.1)}.dso-no.is-prio{box-shadow:0 0 0 2px #d9534a}
.dso-stopt{flex:1;min-width:0;display:flex;flex-direction:column}.dso-stopt strong{font-size:.92rem}.dso-stopt small{font-size:.75rem;color:#a9b8c2}.dso-stopt em{font-style:normal;font-size:.72rem;color:#f3c98a}
.dso-go{height:2.1rem;padding:0 .7rem;border-radius:.6rem;background:rgb(140 196 255/.14)!important;color:#8cc4ff!important;font-size:.8rem;font-weight:800}.dso-go.is-dim{background:rgb(255 255 255/.06)!important;color:#7f93a1!important}
.dso-navtip{margin:0;padding:.6rem .75rem;border-radius:.75rem;background:rgb(140 196 255/.1);font-size:.82rem;color:#c9e2ff;line-height:1.45}
.dso-app{display:flex;align-items:center;gap:.75rem;height:3.6rem;padding:0 .9rem;border-radius:.9rem;background:rgb(255 255 255/.07)!important;text-align:left;font-size:1.2rem}
.dso-app.is-dim{background:rgb(255 255 255/.03)!important;color:#7f93a1}
.dso-app>span{flex:1;display:flex;flex-direction:column;font-size:1rem}.dso-app small{font-size:.75rem}.dso-app small.is-ok{color:#6fd6ad}
.dso-app i{width:2.4rem;height:2.4rem;flex:none;border-radius:.7rem;display:grid;place-items:center;font-style:normal;font-weight:900;font-size:1.1rem}
.dso-app .is-google{background:#fff;color:#1a73e8}.dso-app .is-apple{background:#e9eef2;color:#0e2433}.dso-app .is-waze{background:#33ccff;color:#0a1219}.dso-app.is-dim .is-waze{opacity:.45}
.dso-two{display:grid;grid-template-columns:1fr 1fr;gap:.5rem}
@keyframes dso-in{from{transform:translateY(-60%);opacity:0}to{transform:none;opacity:1}}
.dso-camera{position:fixed;inset:0;background:#000;display:flex;flex-direction:column;justify-content:flex-end;padding:1.5rem}
.dso-camera video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.dso-frame{position:absolute;left:12%;right:12%;top:30%;height:22%;border:3px solid #fff;border-radius:1rem;box-shadow:0 0 0 999px rgb(0 0 0/.35)}
.dso-camera .dso-primary{position:relative}
`;
    const style = document.createElement('style');
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
})();
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- public/js/app/photo-viewer.js
mkdir -p 'public/js/app'
cat > 'public/js/app/photo-viewer.js' <<'DISPATCH_FILE_END_4'
/*
 * Part 42 · Check photos (board 68), in every app.
 *
 * window.dsPhotoViewer.open(list, index, opts)  full screen: zoom (pinch, double-tap, button),
 *     swipe or ‹ › for the next, ✕ to go back. opts.onDelete(i) / opts.onRetake(i) add the buttons.
 * window.dsPhotoCheck(file, { auto })  the photo big, right after it is taken: Retake or Use photo
 *     (used by itself after `auto` seconds, 0 = wait for a tap). Resolves 'use' or 'retake'.
 * Any <img data-ds-photo> inside [data-ds-gallery] opens the viewer for that gallery on a tap.
 * While a viewer is open, the barcode scanner rests (it never reads a box behind the photo).
 */
(function () {
    if (window.dsPhotoViewer) return;

    const css = `
.dspv{position:fixed;inset:0;z-index:90;background:#05090d;color:#eef3f6;display:flex;flex-direction:column;font-family:Archivo,system-ui,sans-serif;touch-action:none;-webkit-tap-highlight-color:transparent}
.dspv__top{display:flex;align-items:center;justify-content:space-between;gap:.6rem;padding:max(.8rem,env(safe-area-inset-top)) 1rem .6rem}
.dspv__x{width:2.6rem;height:2.6rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:1.15rem;color:#fff}
.dspv__pill{padding:.25rem .7rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:.8rem;font-weight:800}
.dspv__stage{position:relative;flex:1;overflow:hidden;display:flex;align-items:center;justify-content:center}
.dspv__img{max-width:100%;max-height:100%;object-fit:contain;transform-origin:center;transition:transform .15s ease-out;user-select:none;-webkit-user-drag:none}
.dspv__img.is-moving{transition:none}
.dspv__nav{position:absolute;top:50%;margin-top:-1.4rem;width:2.8rem;height:2.8rem;border-radius:99px;background:rgb(0 0 0/.45);color:#fff;font-size:1.4rem}
.dspv__nav.is-prev{left:.6rem}.dspv__nav.is-next{right:.6rem}
.dspv__hint{position:absolute;left:0;right:0;bottom:.7rem;text-align:center;font-size:.75rem;color:#cfd8de;pointer-events:none}
.dspv__cd{position:absolute;top:.7rem;right:.7rem;padding:.25rem .7rem;border-radius:99px;background:rgb(0 0 0/.55);font-size:.8rem;font-weight:800}
.dspv__bar{display:grid;gap:.5rem;padding:.7rem 1rem max(1rem,env(safe-area-inset-bottom))}
.dspv__bar.is-3{grid-template-columns:repeat(3,1fr)}.dspv__bar.is-2{grid-template-columns:1fr 1.4fr}.dspv__bar.is-1{grid-template-columns:1fr}
.dspv__btn{height:3.3rem;border-radius:1rem;background:rgb(255 255 255/.1);color:#fff;font-weight:800;font-size:1rem}
.dspv__btn.is-use{background:#3ddc97;color:#0a1219}.dspv__btn.is-del{background:rgb(200 55 45/.28);color:#ff8a80}
[data-ds-photo]{cursor:zoom-in}`;

    let root = null;
    let keyHandler = null;
    let wasPaused = null;

    function scanner(paused) {
        window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { paused } }));
    }
    /** The scanner rests while a photo is open, and goes back to how it was after. */
    function rest() {
        wasPaused = window.dsScanner ? !!window.dsScanner.paused : null;
        scanner(true);
    }

    function el(tag, cls, html) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (html != null) e.innerHTML = html;
        return e;
    }

    function close() {
        if (!root) return;
        root.remove();
        root = null;
        if (keyHandler) document.removeEventListener('keydown', keyHandler);
        keyHandler = null;
        document.documentElement.style.overflow = '';
        if (wasPaused === false) scanner(false);
        wasPaused = null;
    }

    /** Pinch, drag and double-tap zoom on one image; swipe calls onSwipe(-1|1) when not zoomed. */
    function zoomable(img, stage, onSwipe, onZoom) {
        let z = 1, x = 0, y = 0;
        const pts = new Map();
        let start = null;
        let lastTap = 0;
        const apply = () => { img.style.transform = `translate(${x}px, ${y}px) scale(${z})`; onZoom && onZoom(z); };
        const set = (nz) => { z = Math.min(4, Math.max(1, nz)); if (z === 1) { x = 0; y = 0; } apply(); };
        stage.addEventListener('pointerdown', (e) => {
            stage.setPointerCapture && stage.setPointerCapture(e.pointerId);
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            img.classList.add('is-moving');
            if (pts.size === 1) {
                start = { x: e.clientX, y: e.clientY, ox: x, oy: y, t: Date.now() };
                if (Date.now() - lastTap < 300) { set(z > 1 ? 1 : 2.5); lastTap = 0; } else lastTap = Date.now();
            } else if (pts.size === 2) {
                const [a, b] = [...pts.values()];
                start = { d: Math.hypot(a.x - b.x, a.y - b.y), z };
            }
        });
        stage.addEventListener('pointermove', (e) => {
            if (!pts.has(e.pointerId) || !start) return;
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            if (pts.size === 2 && start.d) {
                const [a, b] = [...pts.values()];
                z = Math.min(4, Math.max(1, start.z * Math.hypot(a.x - b.x, a.y - b.y) / start.d));
                apply();
            } else if (pts.size === 1 && z > 1) {
                x = start.ox + e.clientX - start.x; y = start.oy + e.clientY - start.y; apply();
            }
        });
        const up = (e) => {
            const p = pts.get(e.pointerId);
            pts.delete(e.pointerId);
            img.classList.remove('is-moving');
            if (pts.size === 0 && start && start.x != null && z === 1 && p) {
                const dx = p.x - start.x;
                if (Math.abs(dx) > 60 && Date.now() - start.t < 600 && onSwipe) onSwipe(dx < 0 ? 1 : -1);
            }
            if (pts.size === 0) { start = null; if (z <= 1.05) set(1); }
        };
        stage.addEventListener('pointerup', up);
        stage.addEventListener('pointercancel', up);
        return { zoomStep() { set(z >= 3 ? 1 : z + 1); }, reset() { set(1); } };
    }

    function mount() {
        if (!document.getElementById('dspv-css')) {
            const s = el('style'); s.id = 'dspv-css'; s.textContent = css; document.head.appendChild(s);
        }
        close();
        root = el('div', 'dspv');
        root.setAttribute('role', 'dialog');
        root.setAttribute('aria-modal', 'true');
        document.body.appendChild(root);
        document.documentElement.style.overflow = 'hidden';
        return root;
    }

    window.dsPhotoViewer = {
        /** list: [{ src, label? }] or [src, …] */
        open(list, index = 0, opts = {}) {
            const items = (list || []).map((p) => (typeof p === 'string' ? { src: p } : p)).filter((p) => p && p.src);
            if (!items.length) return;
            let i = Math.min(Math.max(0, index), items.length - 1);
            const r = mount();
            rest();
            const top = el('div', 'dspv__top');
            const x = el('button', 'dspv__x', '✕'); x.type = 'button'; x.setAttribute('aria-label', 'Close');
            const count = el('b');
            const zl = el('span', 'dspv__pill', 'Fit');
            top.append(x, count, zl);
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo'; img.draggable = false;
            const prev = el('button', 'dspv__nav is-prev', '‹'); prev.type = 'button'; prev.setAttribute('aria-label', 'Previous photo');
            const next = el('button', 'dspv__nav is-next', '›'); next.type = 'button'; next.setAttribute('aria-label', 'Next photo');
            const hint = el('span', 'dspv__hint', 'Pinch or double-tap to zoom' + (items.length > 1 ? ' · swipe for the next' : ''));
            stage.append(img, prev, next, hint);
            const btns = [['🔍 Zoom', '', () => z.zoomStep()]];
            if (opts.onRetake) btns.push(['↺ Retake', '', () => { const k = i; close(); opts.onRetake(k); }]);
            if (opts.onDelete) btns.push(['🗑 Delete', 'is-del', () => { const k = i; close(); opts.onDelete(k); }]);
            const bar = el('div', 'dspv__bar is-' + btns.length);
            btns.forEach(([t, c, f]) => { const b = el('button', 'dspv__btn ' + c, t); b.type = 'button'; b.addEventListener('click', f); bar.appendChild(b); });
            r.append(top, stage, bar);

            const show = () => {
                img.src = items[i].src;
                count.textContent = items.length > 1 ? `${i + 1} of ${items.length}` : (items[i].label || 'Photo');
                prev.style.display = i > 0 ? '' : 'none';
                next.style.display = i < items.length - 1 ? '' : 'none';
                z && z.reset();
            };
            const go = (d) => { const n = i + d; if (n >= 0 && n < items.length) { i = n; show(); } };
            const z = zoomable(img, stage, go, (v) => { zl.textContent = v > 1.05 ? `Zoom ${v.toFixed(1)}×` : 'Fit'; });
            prev.addEventListener('click', (e) => { e.stopPropagation(); go(-1); });
            next.addEventListener('click', (e) => { e.stopPropagation(); go(1); });
            prev.addEventListener('pointerdown', (e) => e.stopPropagation());
            next.addEventListener('pointerdown', (e) => e.stopPropagation());
            x.addEventListener('click', () => { close(); opts.onClose && opts.onClose(); });
            keyHandler = (e) => { if (e.key === 'Escape') { close(); opts.onClose && opts.onClose(); } else if (e.key === 'ArrowLeft') go(-1); else if (e.key === 'ArrowRight') go(1); };
            document.addEventListener('keydown', keyHandler);
            show();
        },
        close,
    };

    /** The photo big, right after it is taken: Retake or Use photo (used by itself after `auto` seconds). */
    window.dsPhotoCheck = function (file, opts = {}) {
        return new Promise((resolve) => {
            const r = mount();
            rest();
            const url = URL.createObjectURL(file);
            let left = Math.max(0, parseInt(opts.auto ?? 3, 10) || 0);
            let timer = null;
            const done = (what) => { clearInterval(timer); URL.revokeObjectURL(url); close(); resolve(what); };
            const top = el('div', 'dspv__top');
            top.append(el('b', '', opts.title || 'Check the photo'), el('span', 'dspv__pill', 'Pinch to zoom'));
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo you took'; img.src = url; img.draggable = false;
            const cd = el('span', 'dspv__cd');
            stage.append(img, cd);
            const bar = el('div', 'dspv__bar is-2');
            const re = el('button', 'dspv__btn', '↺ Retake'); re.type = 'button';
            const use = el('button', 'dspv__btn is-use', '✓ Use photo'); use.type = 'button';
            bar.append(re, use);
            r.append(top, stage, bar);
            zoomable(img, stage, null, (v) => { if (v > 1.05 && timer) { clearInterval(timer); timer = null; cd.textContent = 'Waiting for you'; } });
            re.addEventListener('click', () => done('retake'));
            use.addEventListener('click', () => done('use'));
            keyHandler = (e) => { if (e.key === 'Escape') done('retake'); if (e.key === 'Enter') done('use'); };
            document.addEventListener('keydown', keyHandler);
            if (left > 0) {
                cd.textContent = `Uses it in ${left} s`;
                timer = setInterval(() => { left -= 1; if (left <= 0) done('use'); else cd.textContent = `Uses it in ${left} s`; }, 1000);
            } else {
                cd.style.display = 'none';
            }
        });
    };

    // Any photo marked data-ds-photo opens the viewer with the photos of its gallery.
    document.addEventListener('click', (e) => {
        const t = e.target.closest && e.target.closest('[data-ds-photo]');
        if (!t || e.metaKey || e.ctrlKey || e.shiftKey) return;
        const g = t.closest('[data-ds-gallery]') || t.parentElement;
        const all = [...g.querySelectorAll('[data-ds-photo]')];
        const src = (n) => n.getAttribute('data-ds-photo') || n.getAttribute('href') || n.getAttribute('src') || (n.querySelector('img') && n.querySelector('img').src);
        e.preventDefault();
        window.dsPhotoViewer.open(all.map((n) => ({ src: src(n) })), all.indexOf(t), { onClose: () => g.dispatchEvent(new CustomEvent('ds-viewer-closed', { bubbles: true })) });
    });
})();
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- resources/css/filament/admin/theme.css
mkdir -p 'resources/css/filament/admin'
cat > 'resources/css/filament/admin/theme.css' <<'DISPATCH_FILE_END_5'
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
/* Board 68: bigger proof photos (2 a row), tap to open full screen */
.ds-dr__grid.is-big { grid-template-columns: repeat(2, 1fr); }
.ds-dr__grid.is-big .ds-dr__proof, .ds-dr__grid.is-big .ds-dr__add { aspect-ratio: 4 / 3; }
.ds-dr__proof img { cursor: zoom-in; }
.ds-dr__proof em { position: absolute; right: 0.45rem; bottom: 0.45rem; padding: 0.15rem 0.55rem; border-radius: 999px; background: rgb(10 18 25 / 0.75); color: #fff; font-size: 0.72rem; font-style: normal; font-weight: 700; cursor: pointer; }
.ds-dr__proof.is-small img { cursor: zoom-in; }
.ds-dr__other { display: flex; align-items: center; gap: 0.5rem; padding: 0.65rem 0.75rem; border-radius: 1rem; background: rgb(255 196 61 / 0.14); box-shadow: inset 0 0 0 1px rgb(255 196 61 / 0.45); animation: sa-in .2s ease-out; }
.ds-dr__other > span { flex: 1; display: flex; flex-direction: column; gap: 0.1rem; min-width: 0; }
.ds-dr__other b { font-size: 0.85rem; color: #ffd27a; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ds-dr__other small { font-size: 0.75rem; color: var(--sa-text); opacity: 0.8; }
.ds-dr__other button { padding: 0.45rem 0.8rem; border-radius: 999px; background: #ffc43d; color: #0a1219; font-weight: 800; font-size: 0.8rem; }
.ds-dr__other button.is-x { padding: 0; width: 2rem; height: 2rem; background: rgb(255 255 255 / 0.1); color: #fff; }
.ds-snap .ds-sa__shot { cursor: zoom-in; }
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

/* Which camera (board 52) */
.ds-cx__cam { position: absolute; left: 1rem; top: 26%; z-index: 2; height: 1.75rem; padding: 0 0.7rem; border-radius: 999px; display: inline-flex; align-items: center; font-size: 0.78rem; font-weight: 800; background: rgb(255 255 255 / .12); color: #e6edf2; backdrop-filter: blur(6px); }
.ds-cx__cam.is-front { background: rgb(255 107 94 / .25); color: #ffb3ab; }
.ds-cx__dark.is-front { box-shadow: inset 0 0 0 1px rgb(255 107 94 / .6); }
.ds-cx__dark.is-front span { color: #ffb3ab; }
.ds-cx__cams > b { font-size: 1.05rem; }
.ds-cx__cams > button:not(.ds-cx__back) { display: flex; align-items: center; gap: 0.6rem; padding: 0.75rem; border-radius: 0.9rem; text-align: left; color: #fff; background: rgb(255 255 255 / .05); }
.ds-cx__cams > button.is-on { background: rgb(52 195 143 / .14); box-shadow: inset 0 0 0 1px rgb(52 195 143 / .5); }
.ds-cx__cams > button.is-front { opacity: .75; }
.ds-cx__cams > button > span:first-child { font-size: 1.1rem; }
.ds-cx__cams > button > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-cx__cams > button small { color: #9fb0bc; font-size: 0.78rem; }
.ds-cx__cams > button em { font-style: normal; font-weight: 900; color: #34c38f; }

/* Scan app start screen (board 54) */
.ds-sh__resume { display: flex; align-items: center; gap: 0.8rem; width: 100%; padding: 0.9rem 1rem; border-radius: 1.4rem; text-align: left; background: var(--sa-gold); color: #0a1219; box-shadow: 0 16px 30px -18px rgb(246 190 0 / .8); transition: transform .12s; }
.ds-sh__resume:active, .ds-sh__tile:active { transform: scale(.96); }
.ds-sh__ring { position: relative; width: 3.3rem; height: 3.3rem; flex: none; border-radius: 50%; background: conic-gradient(#0a1219 calc(var(--p) * 1%), rgb(10 18 25 / .15) 0); display: grid; place-items: center; }
.ds-sh__ring::before { content: ''; position: absolute; inset: 6px; border-radius: 50%; background: var(--sa-gold); }
.ds-sh__ring b { position: relative; font-size: 0.8rem; font-weight: 900; }
.ds-sh__resumetext { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
.ds-sh__resumetext small { font-size: 0.74rem; font-weight: 800; opacity: .7; }
.ds-sh__resumetext strong { font-size: 1.02rem; font-weight: 900; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-sh__go { flex: none; height: 2rem; padding: 0 0.8rem; border-radius: 999px; background: #0a1219; color: var(--sa-gold); font-size: 0.8rem; font-weight: 900; display: inline-flex; align-items: center; }
.ds-sh__stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.5rem; }
.ds-sh__stats > span { display: flex; flex-direction: column; gap: 2px; padding: 0.6rem 0.75rem; border-radius: 1rem; background: var(--sa-glass); box-shadow: inset 0 0 0 1px var(--sa-line); }
.ds-sh__stats b { font-size: 1.25rem; font-weight: 800; }
.ds-sh__stats small { color: var(--sa-muted); font-size: 0.7rem; font-weight: 700; }
.ds-sh__stats .is-bad b { color: #ff9d93; }
.ds-sh__grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.65rem; }
.ds-sh__tile { position: relative; min-height: 8rem; display: flex; flex-direction: column; align-items: flex-start; gap: 0.35rem; padding: 0.9rem; border-radius: 1.25rem; text-align: left; color: inherit; background: linear-gradient(160deg, rgb(255 255 255 / .09), rgb(255 255 255 / .03)); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .07); transition: transform .12s, opacity .2s; }
.ds-sh__tile.is-done { background: rgb(255 255 255 / .03); }
.ds-sh__tile.is-done strong, .ds-sh__tile.is-done .ds-sh__chip { opacity: .7; }
.ds-sh__chip { width: 2.6rem; height: 2.6rem; border-radius: 0.85rem; display: grid; place-items: center; color: var(--c); background: color-mix(in srgb, var(--c) 16%, transparent); }
.ds-sh__chip svg { width: 1.35rem; height: 1.35rem; }
.ds-sh__tile strong { margin-top: 0.25rem; font-size: 1rem; font-weight: 800; line-height: 1.2; }
.ds-sh__tile small { color: var(--sa-muted); font-size: 0.75rem; line-height: 1.3; }
.ds-sh__badge { position: absolute; top: 0.75rem; right: 0.75rem; min-width: 2.1rem; height: 1.5rem; padding: 0 0.55rem; border-radius: 999px; display: inline-flex; align-items: center; justify-content: center; font-size: 0.7rem; font-weight: 900; color: var(--sa-muted); background: rgb(255 255 255 / .06); }
.ds-sh__badge.is-on { background: var(--c); color: #0a1219; }
.ds-sh__badge.is-wait { animation: ds-skel 1.2s ease-in-out infinite; }
.ds-sh__opening { position: fixed; inset: 0; z-index: 60; flex-direction: column; gap: 0.7rem; padding: calc(env(safe-area-inset-top) + 5.5rem) 1rem 1rem; background: #0b1620; }
.ds-sh__opening i { display: block; height: 5.2rem; border-radius: 1.25rem; background: rgb(255 255 255 / .05); animation: ds-skel 1.2s ease-in-out infinite; }
.ds-sh__opening small { color: var(--sa-muted); text-align: center; }

/* Pick boxes (board 55): full-screen camera, next box on it, short messages, the list in a pull-up sheet */
.ds-sa__scan.is-pick .ds-sa__controls { bottom: calc(env(safe-area-inset-bottom) + 7.4rem); transition: bottom .25s; }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-sa__controls { bottom: calc(62dvh + 0.5rem); }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-sa__frame { top: 22%; }
.ds-pk__next { position: absolute; left: 1rem; top: calc(env(safe-area-inset-top) + 5.2rem); z-index: 3; max-width: calc(100% - 2rem); height: 1.9rem; padding: 0 0.8rem; border-radius: 999px; display: inline-flex; align-items: center; font-size: 0.8rem; font-weight: 800; color: #9ef0e6; background: rgb(46 196 182 / .22); backdrop-filter: blur(6px); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
/* board 56: dark glass messages; only the title, the sign and the edge have the colour */
.ds-pk__msg { position: absolute; left: 1rem; right: 1rem; top: 46%; z-index: 6; display: flex; flex-direction: column; gap: 0.4rem; pointer-events: none; }
.ds-pk__msg > * { pointer-events: auto; }
.ds-sa .ds-pk__toast { --c: #5be3a8; display: flex; align-items: center; gap: 0.6rem; padding: 0.75rem 0.75rem 0.75rem 0.85rem; border-radius: 1.1rem; color: #fff; background: rgb(10 18 25 / .8); -webkit-backdrop-filter: blur(14px) saturate(140%); backdrop-filter: blur(14px) saturate(140%); box-shadow: inset 3px 0 0 var(--c), inset 0 0 0 1px rgb(255 255 255 / .08), 0 16px 30px -18px rgb(0 0 0 / .55); }
.ds-sa .ds-pk__toast.is-warn { --c: #ffd24d; color: #fff; }
.ds-sa .ds-pk__toast.is-bad { --c: #ff8a80; color: #fff; }
.ds-sa .ds-pk__toast.is-ok { color: #fff; }
.ds-pk__sign { width: 2.2rem; height: 2.2rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: var(--c); color: #0a1219; font-weight: 900; font-size: 1.05rem; }
.ds-pk__words { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.ds-pk__words b { font-size: 1.06rem; font-weight: 900; color: var(--c); }
.ds-pk__words small { font-size: 0.8rem; font-weight: 600; color: rgb(255 255 255 / .92); }
.ds-pk__undo2 { flex: none; height: 2.2rem; padding: 0 0.75rem; border-radius: 0.65rem; background: rgb(255 255 255 / .92); color: #0a1219; font-weight: 800; font-size: 0.8rem; }
.ds-pk__ok { flex: none; height: 2.2rem; padding: 0 0.9rem; border-radius: 0.65rem; background: var(--c); color: #0a1219; font-weight: 900; font-size: 0.85rem; }
.ds-pk__after { align-self: center; display: flex; align-items: center; gap: 0.5rem; }
.ds-pk__after small { color: #fff; font-size: 0.7rem; font-weight: 800; text-shadow: 0 1px 2px rgb(0 0 0 / .6); }
.ds-pk__after button { height: 1.6rem; padding: 0 0.6rem; border-radius: 999px; background: rgb(10 18 25 / .75); color: #fff; font-size: 0.7rem; font-weight: 800; }
.ds-pk__timer { width: 3.5rem; height: 4px; border-radius: 9px; background: rgb(255 255 255 / .25); overflow: hidden; }
.ds-pk__timer i { display: block; height: 100%; background: #5be3a8; transition: width .25s linear; }
.ds-pk__last { position: fixed; left: 1rem; top: calc(env(safe-area-inset-top) + 7.6rem); display: inline-flex; align-items: center; gap: 0.5rem; height: 2rem; padding: 0 0.3rem 0 0.8rem; border-radius: 999px; background: rgb(10 18 25 / .8); box-shadow: inset 0 0 0 1px rgb(91 227 168 / .5); color: #5be3a8; font-size: 0.78rem; }
.ds-pk__last button { height: 1.5rem; padding: 0 0.6rem; border-radius: 999px; background: rgb(255 255 255 / .9); color: #0a1219; font-weight: 800; font-size: 0.72rem; }
.ds-pk__sheet2 { position: fixed; left: 0; right: 0; bottom: 0; z-index: 5; display: flex; flex-direction: column; max-height: 62dvh; padding-bottom: env(safe-area-inset-bottom); border-radius: 1.5rem 1.5rem 0 0; background: #0f1d27; box-shadow: 0 -16px 40px rgb(0 0 0 / .45); }
.ds-pk__sheet2.is-open { height: 62dvh; }
.ds-pk__peek { display: flex; flex-direction: column; gap: 0.5rem; width: 100%; padding: 0.5rem 1rem 0.8rem; text-align: left; color: #fff; }
.ds-pk__peek .ds-sa__grab { align-self: center; }
.ds-pk__peekrow { display: flex; align-items: center; gap: 0.6rem; }
.ds-pk__peekrow > span { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
.ds-pk__peekrow b { font-size: 0.95rem; font-weight: 800; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ds-pk__peekrow small { color: #9fb0bc; font-size: 0.8rem; }
.ds-pk__peekrow em { flex: none; font-style: normal; height: 2rem; padding: 0 0.8rem; border-radius: 999px; background: rgb(255 255 255 / .1); display: inline-flex; align-items: center; font-weight: 800; font-size: 0.82rem; }
.ds-pk__peek .ds-pk__bar i { background: #2ec4b6; }
.ds-pk__goload { margin: 0 1rem 0.8rem; }
.ds-pk__sheet2 .ds-pk__list { flex: 1; overflow-y: auto; padding: 0.2rem 1rem 1rem; }
@media (min-width: 700px) { .ds-pk__sheet2 { left: 50%; right: auto; width: 34rem; transform: translateX(-50%); } }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-sa__type, .ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-cx__cam { display: none; }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-sa__frame { top: 17%; transform: translate(-50%, -50%) scale(.85); }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-pk__msg { top: 5.4rem; }
.ds-sa__scan.is-pick:has(.ds-pk__sheet2.is-open) .ds-pk__next { display: none; }

/* Same number on two boxes (board 57): pick the receiver */
.ds-which { gap: 0.6rem; }
.ds-which__head { display: flex; align-items: center; gap: 0.6rem; }
.ds-which__head > span:first-child { width: 2.3rem; height: 2.3rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: #ffd24d; color: #0a1219; font-weight: 900; }
.ds-which__head > span:last-child { display: flex; flex-direction: column; gap: 2px; }
.ds-which__head strong { color: #ffd24d; font-size: 1.05rem; }
.ds-which__head small { color: #c8d3dc; font-size: 0.82rem; }
.ds-which__opt { display: flex; align-items: center; gap: 0.75rem; width: 100%; padding: 0.85rem 0.95rem; border-radius: 1rem; text-align: left; color: #fff; background: rgb(255 255 255 / .06); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .1); }
.ds-which__opt:active { transform: scale(.98); }
.ds-which__opt > span { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.ds-which__opt strong { font-size: 1.3rem; font-weight: 800; letter-spacing: -0.01em; }
.ds-which__opt small { color: #c8d3dc; font-size: 0.82rem; }
.ds-which__opt em { font-style: normal; color: #8fa2b0; font-size: 0.75rem; }
.ds-which__opt > b { color: #9fb0bc; font-size: 1.4rem; }
.ds-ws__same { margin: 0.4rem 0 0.2rem; padding: 0.45rem 0.7rem; border-radius: 0.6rem; background: #fff6db; color: #7a5300; font-weight: 700; font-size: 0.85rem; }
.dark .ds-ws__same { background: rgb(255 210 77 / .14); color: #ffd24d; }
.ds-ws__result + .ds-ws__result { margin-top: 0.45rem; }
/* Search Invoices: delivered rows greyed, shared numbers flagged (board 57) */
.fi-ta-row.ds-row-delivered > td { opacity: .5; }
.fi-ta-row.ds-row-delivered:hover > td { opacity: .8; }
.ds-same-no .fi-ta-text-description, .ds-same-no p:last-child { color: #b45309 !important; font-weight: 700; }

/* Which one? on a desk scanner (board 58) */
.ds-which-desk { display: flex; flex-direction: column; gap: 0.7rem; padding: 1rem; margin-bottom: 0.75rem; border-radius: 1rem; background: #fff8e1; box-shadow: inset 0 0 0 1px #f3d37a; }
.dark .ds-which-desk { background: rgb(255 210 77 / .08); box-shadow: inset 0 0 0 1px rgb(255 210 77 / .3); }
.ds-which-desk__head { display: flex; align-items: center; gap: 0.6rem; }
.ds-which-desk__head > span:first-child { width: 2rem; height: 2rem; flex: none; border-radius: 50%; display: grid; place-items: center; background: #ffd24d; color: #0a1219; font-weight: 900; }
.ds-which-desk__head > span:last-child { display: flex; flex-direction: column; }
.ds-which-desk__head strong { font-size: 1rem; }
.ds-which-desk__head small, .ds-which-desk__hint { color: #6b7b88; font-size: 0.8rem; }
.ds-which-desk__grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr)); gap: 0.6rem; }
.ds-which-desk__opt { position: relative; display: flex; flex-direction: column; gap: 2px; padding: 0.8rem 0.9rem 0.8rem 2.6rem; border-radius: 0.8rem; text-align: left; background: #fff; box-shadow: 0 1px 0 #e3e8ec, 0 8px 20px -16px rgb(14 36 51 / .4); }
.dark .ds-which-desk__opt { background: rgb(255 255 255 / .05); }
.ds-which-desk__opt:hover { box-shadow: inset 0 0 0 2px #f6be00; }
.ds-which-desk__opt kbd { position: absolute; left: 0.8rem; top: 0.85rem; width: 1.3rem; height: 1.3rem; border-radius: 0.35rem; display: grid; place-items: center; font-size: 0.75rem; font-weight: 800; background: #0e2433; color: #fff; }
.ds-which-desk__opt strong { font-size: 1.1rem; }
.ds-which-desk__opt small { color: #33424e; font-size: 0.82rem; }
.ds-which-desk__opt em { font-style: normal; color: #6b7b88; font-size: 0.75rem; }
.ds-sa .ds-which { z-index: 60; }
.ds-which__of { display: inline-block; margin-left: 0.35rem; padding: 0 0.45rem; border-radius: 999px; background: #ffd24d; color: #0a1219; font-weight: 800; font-size: 0.72rem; }

/* Users and Crew (board 59/60) */
.ds-us__person { display: flex; align-items: center; gap: 0.7rem; min-width: 14rem; }
.ds-us__av { width: 2.4rem; height: 2.4rem; flex: none; border-radius: 50%; display: grid; place-items: center; font-weight: 800; font-size: 0.8rem; color: #fff; object-fit: cover; }
.ds-us__who { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
.ds-us__who > span { display: flex; align-items: center; gap: 0.4rem; }
.ds-us__who b { font-size: 0.92rem; color: #0e2433; }
.dark .ds-us__who b { color: #fff; }
.ds-us__who small { color: #6b7b88; font-size: 0.78rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 18rem; }
.ds-us__admin { font-style: normal; font-size: 0.68rem; font-weight: 800; padding: 1px 7px; border-radius: 999px; background: #0e2433; color: #f6be00; }
.ds-us__works { display: flex; flex-direction: column; align-items: flex-start; gap: 3px; }
.ds-us__chip { font-size: 0.72rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; white-space: nowrap; }
.ds-us__works small { color: #51616d; font-size: 0.78rem; }
.ds-us__status { display: inline-flex; align-items: center; gap: 0.4rem; font-size: 0.82rem; font-weight: 700; color: #17895e; }
.ds-us__status i { width: 0.5rem; height: 0.5rem; border-radius: 50%; background: currentColor; }
.ds-us__status.is-off { color: #9aa7b1; }
.fi-ta-row.ds-us__off > td { opacity: .6; }
.ds-us__noapp { display: block; padding: 0.5rem 0.75rem; border-radius: 0.6rem; background: #fff6db; color: #7a5300; font-weight: 700; font-size: 0.82rem; }
.ds-us__panels .fi-fo-toggle-buttons-btn, .ds-us__chips .fi-fo-toggle-buttons-btn { border-radius: 999px; }
.ds-us__av.is-sm { width: 1.8rem; height: 1.8rem; font-size: 0.68rem; }
.ds-cr { display: flex; flex-direction: column; gap: 1rem; }
.ds-cr__top { display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
.ds-cr__sum { color: #6b7b88; margin-right: auto; }
.ds-cr__tabs { display: flex; gap: 4px; padding: 4px; border-radius: 0.8rem; background: #e9eef2; }
.dark .ds-cr__tabs { background: rgb(255 255 255 / .06); }
.ds-cr__tabs button { height: 2.1rem; padding: 0 0.9rem; border-radius: 0.6rem; font-weight: 800; font-size: 0.85rem; color: #51616d; }
.ds-cr__tabs button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 3px rgb(14 36 51 / .15); }
.ds-cr__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(19rem, 1fr)); gap: 0.9rem; align-items: start; }
.ds-cr__truck { display: flex; flex-direction: column; gap: 0.6rem; padding: 1rem; border-radius: 1.1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef, 0 14px 34px -28px rgb(14 36 51 / .4); }
.dark .ds-cr__truck, .dark .ds-cr__list { background: rgb(255 255 255 / .04); box-shadow: 0 0 0 1px rgb(255 255 255 / .08); }
.ds-cr__truck header { display: flex; align-items: center; gap: 0.6rem; }
.ds-cr__truck header > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-cr__truck header b { font-size: 1.05rem; }
.ds-cr__truck header small, .ds-cr__muted { color: #6b7b88; font-size: 0.8rem; }
.ds-cr__ico { width: 2.6rem; height: 2.6rem; border-radius: 0.75rem; background: #0e2433; display: grid; place-items: center; font-size: 1.2rem; }
.ds-cr__state { font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: #fff1c2; color: #7a5600; }
.ds-cr__state.is-ok { background: #e6f6ef; color: #17895e; }
.ds-cr__m { display: flex; align-items: center; gap: 0.6rem; padding: 0.5rem 0.6rem; border-radius: 0.75rem; background: #f6f8fa; }
.dark .ds-cr__m { background: rgb(255 255 255 / .05); }
.ds-cr__who { flex: 1; display: flex; flex-direction: column; text-align: left; min-width: 0; }
.ds-cr__who b { font-size: 0.88rem; }
.ds-cr__who small { color: #6b7b88; font-size: 0.76rem; }
.ds-cr__x { width: 1.75rem; height: 1.75rem; border-radius: 50%; background: #fff; color: #8a99a5; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-cr__none { padding: 0.75rem; border-radius: 0.75rem; border: 1.5px dashed #d4dde3; color: #6b7b88; font-size: 0.82rem; text-align: center; }
.ds-cr__add { height: 2.4rem; border-radius: 0.65rem; background: #eef2f5; font-weight: 800; color: #0e2433; }
.ds-cr__add.is-on { background: #f6be00; color: #0a1219; }
.ds-cr__free { display: flex; flex-direction: column; gap: 0.35rem; padding: 0.6rem; border-radius: 0.75rem; background: #fff8e1; box-shadow: inset 0 0 0 1px #f3d37a; }
.ds-cr__free > small { font-weight: 800; color: #7a5600; }
.ds-cr__free button { display: flex; align-items: center; gap: 0.5rem; padding: 0.35rem 0.5rem; border-radius: 0.6rem; background: #fff; text-align: left; }
.ds-cr__free button b { flex: 1; font-size: 0.85rem; color: #0e2433; }
.ds-cr__free button i, .ds-cr__pos { font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 8px; border-radius: 999px; background: #eef2f5; color: #33424e; }
.ds-cr__pos.is-app { background: #fff1c2; color: #7a5600; }
.ds-cr__list { display: flex; flex-direction: column; border-radius: 1.1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; overflow: hidden; }
.ds-cr__row { display: grid; grid-template-columns: 2.6rem 1.6fr 1fr 1fr 1fr 0.9fr 0.9fr; gap: 0.75rem; align-items: center; padding: 0.6rem 1rem; border-top: 1px solid #f0f3f6; text-align: left; font-size: 0.85rem; }
.ds-cr__row.is-head { font-size: 0.75rem; font-weight: 800; color: #6b7b88; background: #fafbfc; border-top: 0; }
.dark .ds-cr__row.is-head { background: transparent; }
.ds-cr__row:not(.is-head):hover { background: #fffbea; }
.ds-cr__row.is-off { opacity: .6; }
.ds-cr__row small { color: #6b7b88; }
.ds-cr__hint { color: #6b7b88; }
.ds-cr__where { display: block; padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #f1f6fb; color: #1d5fa8; font-weight: 700; font-size: 0.82rem; }
.ds-us__photo { width: 5.5rem !important; max-width: 5.5rem; } .ds-us__photo .filepond--root { width: 5.5rem !important; height: 5.5rem !important; } .ds-us__photo .filepond--drop-label { font-size: 0.65rem; }

/* Sea shipment trucks (board 62) */
.ds-sp__goes { display: inline-block; margin-top: 3px; font-style: normal; font-size: 0.72rem; font-weight: 800; padding: 1px 8px; border-radius: 999px; background: #e7f0fb; color: #1d5fa8; }
.ds-sp__goes.is-own { background: #fff1c2; color: #7a5600; }
.ds-sp__trucks { display: grid; grid-template-columns: repeat(auto-fill, minmax(18rem, 1fr)); gap: 0.75rem; }
.ds-sp__truck { display: flex; flex-direction: column; gap: 0.45rem; padding: 0.8rem; border-radius: 0.8rem; background: #f6f8fa; }
.dark .ds-sp__truck { background: rgb(255 255 255 / .05); }
.ds-sp__truckhead { display: flex; flex-direction: column; }
.ds-sp__truckhead b { font-size: 1rem; }
.ds-sp__truckhead small, .ds-sp__truckline span { color: #6b7b88; font-size: 0.8rem; }
.ds-sp__truckline { display: flex; justify-content: space-between; gap: 0.5rem; font-size: 0.82rem; }
.ds-sp__truckcost { display: flex; align-items: center; gap: 0.5rem; font-size: 0.8rem; color: #51616d; }
.ds-sp__truckcost input { width: 7rem; height: 2rem; border-radius: 0.5rem; border: 1px solid #d4dde3; padding: 0 0.5rem; background: #fff; }
.dark .ds-sp__truckcost input { background: transparent; }
.ds-roro { cursor: default; }
.ds-roro__btn { width: 100%; margin: 0.25rem 0 0.75rem; }
.ds-sp__goes { align-self: flex-start; }

/* Forwarders and ports (board 64) */
.ds-fw { display: flex; flex-direction: column; gap: 1rem; }
.ds-fw__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; }
.ds-fw__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr)); gap: 0.9rem; align-items: start; }
.ds-fw__card { display: flex; flex-direction: column; gap: 0.5rem; padding: 1rem; border-radius: 1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef, 0 14px 30px -26px rgb(14 36 51 / .45); }
.dark .ds-fw__card, .dark .ds-fw__port { background: rgb(255 255 255 / .04); box-shadow: 0 0 0 1px rgb(255 255 255 / .08); }
.ds-fw__card.is-off, .ds-fw__port.is-off { opacity: .6; }
.ds-fw__card header { display: flex; align-items: center; gap: 0.65rem; }
.ds-fw__card header > span:nth-child(2) { flex: 1; display: flex; flex-direction: column; }
.ds-fw__card header b { font-size: 1rem; }
.ds-fw__card small { color: #6b7b88; font-size: 0.78rem; }
.ds-fw__ini { width: 2.5rem; height: 2.5rem; border-radius: 0.7rem; display: grid; place-items: center; background: #e7f0fb; color: #1d5fa8; font-weight: 900; }
.ds-fw__state { font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: #eef2f5; color: #5b6b78; }
.ds-fw__state.is-on { background: #e6f6ef; color: #17895e; }
.ds-fw__branch { display: grid; grid-template-columns: 1fr auto; gap: 2px 0.6rem; padding: 0.55rem 0.7rem; border-radius: 0.7rem; background: #f6f8fa; }
.dark .ds-fw__branch { background: rgb(255 255 255 / .05); }
.ds-fw__branch b { font-size: 0.86rem; }
.ds-fw__branch small:nth-of-type(odd) { text-align: right; }
.ds-fw__card footer { display: flex; justify-content: space-between; align-items: center; }
.ds-fw__ports { display: grid; grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr)); gap: 0.6rem; }
.ds-fw__port { display: flex; flex-direction: column; gap: 2px; padding: 0.75rem 0.9rem; border-radius: 0.8rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef; text-align: left; }
.ds-fw__port small { color: #6b7b88; font-size: 0.78rem; }

/* Sea shipment page laid out as board 62 */
.ds-sv__head { display: flex; justify-content: space-between; align-items: flex-end; gap: 1rem; flex-wrap: wrap; }
.ds-sv__head > span:first-child { display: flex; flex-direction: column; gap: 2px; }
.ds-sv__head small { color: #6b7b88; font-weight: 700; font-size: 0.8rem; }
.ds-sv__head b { color: #33424e; font-weight: 600; font-size: 0.92rem; }
.dark .ds-sv__head b { color: #c8d3dc; }
.ds-sv__modes { display: flex; gap: 4px; padding: 4px; border-radius: 0.8rem; background: #e9eef2; }
.dark .ds-sv__modes { background: rgb(255 255 255 / .06); }
.ds-sv__modes button { height: 2.1rem; padding: 0 1rem; border-radius: 0.6rem; font-weight: 800; font-size: 0.88rem; color: #51616d; }
.ds-sv__modes button.is-on { background: #fff; color: #0e2433; box-shadow: 0 1px 3px rgb(14 36 51 / .15); }
.ds-sv__modes button:disabled:not(.is-on) { opacity: .5; cursor: not-allowed; }
.ds-sv__facts { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.6rem; }
.ds-sv__facts > span { display: flex; flex-direction: column; gap: 3px; padding: 0.55rem 0.7rem; border-radius: 0.6rem; background: #f6f8fa; }
.dark .ds-sv__facts > span, .dark .ds-sv__trip { background: rgb(255 255 255 / .05); }
.ds-sv__facts small, .ds-sv__lbl { color: #51616d; font-size: 0.75rem; font-weight: 700; }
.ds-sv__grid { display: grid; grid-template-columns: 1fr 1.15fr; gap: 1rem; align-items: start; }
@media (max-width: 1100px) { .ds-sv__grid, .ds-sv__facts { grid-template-columns: 1fr 1fr; } }
.ds-sp__box h3 small { font-weight: 600; color: #6b7b88; font-size: 0.78rem; margin-left: 0.4rem; }
.ds-sp__box h3 .ds-fu__link { float: right; font-size: 0.82rem; }
.ds-sv__trip { display: grid; grid-template-columns: 1fr auto; gap: 2px 0.75rem; padding: 0.65rem 0.8rem; border-radius: 0.75rem; background: #f6f8fa; }
.ds-sv__trip > small:first-of-type { color: #6b7b88; font-size: 0.78rem; }
.ds-sv__goes { text-align: right; font-weight: 800; color: #1d5fa8; font-size: 0.78rem; }
.ds-sv__goes.is-own { color: #7a5600; }
.ds-sv__tripacts { grid-column: 1 / -1; display: flex; gap: 0.8rem; }
.ds-sv__add2 { float: right; height: 2rem; padding: 0 0.8rem; border-radius: 0.55rem; background: #eef2f5; font-weight: 800; font-size: 0.82rem; color: #0e2433; }
.ds-sv__second { display: flex; flex-direction: column; gap: 0.4rem; padding: 0.7rem; border-radius: 0.75rem; background: #fff8e1; box-shadow: inset 0 0 0 1px #f3d37a; }
.ds-sv__second small { font-weight: 800; color: #7a5600; }
.ds-sv__secrow { display: flex; align-items: center; gap: 0.5rem; }
.ds-sv__secrow b { flex: 1; font-size: 0.85rem; color: #0e2433; }
.ds-sv__secrow select { height: 2rem; border-radius: 0.5rem; border: 1px solid #d4dde3; padding: 0 0.5rem; background: #fff; }
.ds-sv__tstate { margin-left: auto; font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: #fff1c2; color: #7a5600; align-self: flex-start; }
.ds-sv__tstate.is-ok { background: #e6f6ef; color: #17895e; }
.ds-sp__truckhead { flex-direction: row !important; flex-wrap: wrap; align-items: baseline; gap: 0 0.5rem; }
.ds-sp__truckhead small { flex-basis: 100%; order: 3; }
.ds-sv__tbar { height: 0.45rem; border-radius: 9px; background: #e3e8ec; overflow: hidden; }
.ds-sv__tbar i { display: block; height: 100%; background: #17895e; }
.ds-sv__split { display: grid; grid-template-columns: 1fr 1fr; gap: 0.5rem; }
.ds-sv__split > span { display: flex; justify-content: space-between; padding: 0.55rem 0.75rem; border-radius: 0.6rem; background: #f6f8fa; font-size: 0.88rem; }
.dark .ds-sv__split > span { background: rgb(255 255 255 / .05); }
.ds-sv__chips { display: flex; flex-wrap: wrap; gap: 0.4rem; }
.ds-sv__chips button, .ds-sv__chipadd { height: 2.1rem; padding: 0 0.85rem; border-radius: 999px; font-weight: 800; font-size: 0.85rem; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; color: #0e2433; display: inline-flex; align-items: center; }
.ds-sv__chips button.is-on { background: #fff8e1; box-shadow: inset 0 0 0 2px #f6be00; }
.ds-sv__chipadd { color: #51616d; background: transparent; box-shadow: inset 0 0 0 1px #d4dde3; }
.ds-sv__row { display: flex; justify-content: space-between; align-items: center; }
.ds-sv__sees { padding: 0.6rem 0.75rem; border-radius: 0.6rem; background: #f1f6fb; color: #1d5fa8; font-weight: 700; font-size: 0.82rem; margin: 0; }

/* Partner hub · Incoming shipments (board 63) */
.ds-hi { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-hi__top { display: flex; justify-content: space-between; align-items: center; gap: 1rem; flex-wrap: wrap; }
.ds-hi__top small { color: #6b7b88; margin-left: 2px; }
.ds-hi__card { display: flex; flex-direction: column; gap: 0.75rem; padding: 1rem 1.1rem; border-radius: 1rem; background: #fff; box-shadow: 0 0 0 1px #e6ebef, 0 14px 30px -26px rgb(14 36 51 / .45); }
.dark .ds-hi__card { background: rgb(255 255 255 / .04); box-shadow: 0 0 0 1px rgb(255 255 255 / .08); }
.ds-hi__card header { display: flex; align-items: center; gap: 0.75rem; }
.ds-hi__card header > span:last-child { display: flex; flex-direction: column; gap: 2px; }
.ds-hi__card header small { color: #6b7b88; font-size: 0.8rem; }
.ds-hi__ico { width: 2.75rem; height: 2.75rem; border-radius: 0.75rem; background: #0e2433; display: grid; place-items: center; font-size: 1.25rem; }
.ds-hi__t { display: flex; align-items: center; gap: 0.5rem; }
.ds-hi__t b { font-size: 1.05rem; }
.ds-hi__tag { font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: #e7f0fb; color: #1d5fa8; }
.ds-hi__tag.is-roro { background: #fff1c2; color: #7a5600; }
.ds-hi__tag.is-lcl { background: #f1eafb; color: #7a4fb0; }
.ds-hi__facts { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.6rem; padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; }
.dark .ds-hi__facts { background: rgb(255 255 255 / .05); }
.ds-hi__facts > span { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.ds-hi__facts small { color: #6b7b88; font-size: 0.72rem; font-weight: 700; }
.ds-hi__facts b { font-size: 0.86rem; overflow-wrap: anywhere; }
.ds-hi__steps { display: flex; align-items: center; gap: 0.4rem; flex-wrap: wrap; }
.ds-hi__steps > span { display: flex; align-items: center; gap: 0.4rem; font-size: 0.8rem; font-weight: 600; color: #8a99a5; }
.ds-hi__steps > span i { width: 1.4rem; height: 1.4rem; border-radius: 50%; display: grid; place-items: center; font-style: normal; font-size: 0.7rem; font-weight: 900; color: #fff; background: #b8c3cc; }
.ds-hi__steps > span.is-done { color: #0e2433; }
.ds-hi__steps > span.is-done i { background: #17895e; }
.ds-hi__steps > span.is-now { color: #0e2433; font-weight: 800; }
.ds-hi__steps > span.is-now i { background: #0e2433; }
.dark .ds-hi__steps > span.is-done, .dark .ds-hi__steps > span.is-now { color: #fff; }
.ds-hi__steps em { flex: 1; min-width: 0.9rem; height: 2px; background: #e1e7ec; }
.ds-hi__steps em.is-done { background: #17895e; }
.ds-hi__todo { display: flex; align-items: center; gap: 0.6rem; flex-wrap: wrap; padding: 0.65rem 0.8rem; border-radius: 0.75rem; background: #fff8e1; box-shadow: inset 0 0 0 1px #f3d37a; }
.ds-hi__todo > span { flex: 1; min-width: 14rem; font-size: 0.85rem; color: #5a4300; }
.ds-hi__btn { height: 2.25rem; padding: 0 0.9rem; border-radius: 0.6rem; background: #eef2f5; color: #0e2433; font-weight: 800; font-size: 0.85rem; display: inline-flex; align-items: center; }
.ds-hi__btn.is-primary { background: #f6be00; color: #0a1219; }
@media (max-width: 900px) { .ds-hi__facts { grid-template-columns: 1fr 1fr; } }
.ds-hc { display: flex; flex-wrap: wrap; gap: 0.35rem; margin: 0 0 0.4rem; }
.ds-hc span { padding: 0.25rem 0.6rem; border-radius: 999px; background: rgb(255 255 255 / .1); color: #dbe5ec; font-size: 0.78rem; font-weight: 700; }
.ds-hc span b { color: #fff; margin-left: 2px; }
.ds-hc span.is-done { background: rgb(91 227 168 / .18); color: #5be3a8; }
.ds-ld__spot.is-sea { background: #ffd24d; color: #0a1219; }
.ds-ld__spot.is-sea span { color: #3a2e00; }
.ds-sea { display: flex; flex-direction: column; gap: 0.45rem; padding: 1rem; border-radius: 1.2rem; background: rgb(255 255 255 / .06); box-shadow: inset 0 0 0 1px rgb(255 255 255 / .1); margin-bottom: 0.75rem; }
.ds-sea > small { color: #9fb0bc; font-weight: 700; }
.ds-sea > b { font-size: 1.25rem; color: #fff; }
.ds-sea__hubs { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.ds-sea__hubs i { font-style: normal; font-size: 0.75rem; font-weight: 800; padding: 2px 9px; border-radius: 999px; background: rgb(140 196 255 / .16); color: #8cc4ff; }
.ds-sea__btn { display: flex; align-items: center; justify-content: center; text-decoration: none; }
.ds-sv__hint { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; padding: 0.6rem 0.8rem; border-radius: 0.7rem; background: #fff6db; color: #7a5300; font-weight: 700; font-size: 0.85rem; margin: 0; }
.dark .ds-sv__hint { background: rgb(255 210 77 / .12); color: #ffd24d; }

/* Part 39 · Transfers to warehouses: manual with space bar + Ask the AI */
.ds-tx { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-tx__tools { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
.ds-tx__tools > small { color: #6b7b88; }
.ds-tx__ask { height: 2.6rem; padding: 0 1rem; border-radius: 0.7rem; font-weight: 800; display: inline-flex; align-items: center; gap: 0.5rem; background: #7a4fb0; color: #fff; }
.ds-tx__ask.is-back { background: #eef2f5; color: #0e2433; }
.ds-tx__ask:disabled { opacity: .5; cursor: not-allowed; }
.ds-tx__note, .ds-tx__ai { display: flex; gap: 0.6rem; align-items: center; padding: 0.65rem 0.9rem; border-radius: 0.75rem; background: #eef2f5; color: #33424e; font-size: 0.88rem; }
.ds-tx__note > span, .ds-tx__ai > span { flex: 1; }
.ds-tx__ai { background: #f1eafb; color: #4c2f7a; }
.ds-tx__ai small { color: #7a4fb0; }
.dark .ds-tx__note { background: rgb(255 255 255 / .06); color: inherit; }
.dark .ds-tx__ai { background: rgb(122 79 176 / .2); color: #e2d4f6; }
.ds-tx__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(22rem, 1fr)); gap: 0.9rem; align-items: start; }
.ds-tx__card { display: flex; flex-direction: column; gap: 0.55rem; padding: 0.9rem 1rem; }
.ds-tx__head { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; font-size: 1rem; }
.ds-tx__row { display: flex; justify-content: space-between; gap: 0.5rem; font-size: 0.85rem; padding: 0.35rem 0; border-top: 1px solid #f0f3f6; }
.ds-tx__row small { color: #6b7b88; }
.dark .ds-tx__row { border-color: rgb(255 255 255 / .08); }
.ds-tx__lbl { color: #6b7b88; font-weight: 700; }
.ds-tx__space { display: flex; justify-content: space-between; font-size: 0.82rem; }
.ds-tx__ok { color: #17895e; }
.ds-tx__bad { color: #c8372d; }
.ds-tx__why { color: #4c2f7a; }
.dark .ds-tx__why { color: #cdb6ef; }
.ds-tx__pill { font-size: 0.75rem; font-weight: 800; padding: 0.2rem 0.6rem; border-radius: 999px; background: #e7f0fb; color: #1d5fa8; white-space: nowrap; }
.ds-tx__pill.is-over { background: #fdecea; color: #c8372d; }
.ds-tx__pill.is-made { background: #e6f6ef; color: #17895e; }
.ds-tx__go { height: 2.6rem; border-radius: 0.7rem; font-weight: 800; background: #0e2433; color: #fff; }
.ds-tx__go.is-warn { background: #fff1c7; color: #7a5600; }
.ds-tx__go.is-off { background: #eef2f5; color: #8a99a5; cursor: not-allowed; }
.ds-tx__go.is-made { background: #e6f6ef; color: #17895e; }
.ds-tx__go:disabled:not(.is-made):not(.is-off) { opacity: .5; }
.ds-tx__only { border-radius: 1rem; border: 2px dashed #d5dde3; padding: 1.1rem; display: flex; flex-direction: column; gap: 0.35rem; justify-content: center; color: #6b7b88; font-size: 0.88rem; }
.ds-tx__only b { color: #33424e; }
.dark .ds-tx__only { border-color: rgb(255 255 255 / .15); }
.dark .ds-tx__only b { color: inherit; }
.ds-tx__later { display: flex; gap: 0.75rem; align-items: center; padding: 0.75rem 1rem; flex-wrap: wrap; }
.ds-tx__later small { flex: 1; color: #6b7b88; }
.ds-tx__all { height: 2.5rem; padding: 0 1rem; border-radius: 0.7rem; font-weight: 800; background: #f6be00; color: #0e2433; }
.ds-tx__all:disabled { background: #e6f6ef; color: #17895e; }
.ds-tx__rules { color: #6b7b88; }
.ds-tx__tools .ds-wc__sel { height: 2.6rem; background: #fff; color: #0e2433; }
.dark .ds-tx__tools .ds-wc__sel { background: rgb(255 255 255 / .06); color: inherit; }
.ds-tx__head b:first-child { flex: 1; }
.ds-tx__head > b:last-child { font-size: 0.85rem; text-align: right; }
.ds-tx .ds-tx__later { flex-direction: row; text-align: left; justify-content: flex-start; }

/* Part 40 · Settings → Photo storage (board 66) */
.ds-pst { display: flex; flex-direction: column; gap: 0.9rem; }
.ds-pst__title { display: flex; flex-direction: column; gap: 0.2rem; }
.ds-pst__title h1 { font-size: 1.65rem; font-weight: 800; }
.ds-pst__title small, .ds-pst__mute { color: #6b7b88; }
.ds-pst__card { background: #fff; border-radius: 1rem; box-shadow: 0 0 0 1px #e6ebef, 0 14px 30px -26px rgb(14 36 51 / .45); padding: 1rem 1.1rem; display: flex; flex-direction: column; gap: 0.65rem; min-width: 0; }
.dark .ds-pst__card { background: rgb(255 255 255 / .04); box-shadow: 0 0 0 1px rgb(255 255 255 / .08); }
.ds-pst__card.is-off { opacity: .6; }
.ds-pst__row { display: flex; justify-content: space-between; align-items: center; gap: 0.75rem; flex-wrap: wrap; }
.ds-pst__col { display: flex; flex-direction: column; gap: 0.15rem; min-width: 0; flex: 1; }
.ds-pst__h { font-size: 1rem; font-weight: 800; }
.ds-pst__h2 { font-size: 1.2rem; font-weight: 800; }
.ds-pst__lbl { font-size: 0.75rem; font-weight: 700; color: #6b7b88; }
.ds-pst__grid4 { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.5rem; }
.ds-pst__grid3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 0.5rem; }
.ds-pst__two { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.9rem; }
.ds-pst__two.is-tight { gap: 0.4rem; }
@media (max-width: 900px) { .ds-pst__grid4, .ds-pst__grid3, .ds-pst__two { grid-template-columns: 1fr; } }
.ds-pst__chk { padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #fdecea; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-pst__chk b { color: #c8372d; }
.ds-pst__chk small { color: #33424e; }
.ds-pst__chk.is-ok { background: #e6f6ef; }
.ds-pst__chk.is-ok b { color: #17895e; }
.dark .ds-pst__chk small { color: inherit; }
.ds-pst__tabs { display: flex; gap: 0.35rem; padding: 0.25rem; border-radius: 0.75rem; background: #e8edf1; align-self: flex-start; flex-wrap: wrap; }
.dark .ds-pst__tabs { background: rgb(255 255 255 / .06); }
.ds-pst__tabs button { height: 2.4rem; padding: 0 1rem; border-radius: 0.55rem; font-weight: 800; font-size: 0.9rem; }
.ds-pst__tabs button.is-on { background: #fff; box-shadow: 0 1px 3px rgb(14 36 51 / .15); color: #0e2433; }
.ds-pst__go, .ds-pst__btn { height: 2.5rem; padding: 0 1rem; border-radius: 0.65rem; font-weight: 800; white-space: nowrap; display: inline-flex; align-items: center; justify-content: center; }
.ds-pst__go { background: #0e2433; color: #fff; }
.ds-pst__go.is-yellow { background: #f6be00; color: #0e2433; height: 2.9rem; padding: 0 1.25rem; }
.ds-pst__go.is-blue { background: #1d5fa8; }
.ds-pst__go.is-purple { background: #7a4fb0; }
.ds-pst__go.is-redbg { background: #c8372d; }
.ds-pst__btn { background: #eef2f5; color: #0e2433; }
.ds-pst__btn.is-red { background: #fdecea; color: #c8372d; }
.ds-pst__go:disabled, .ds-pst__btn:disabled { opacity: .45; cursor: not-allowed; }
.ds-pst__acts { display: flex; gap: 0.5rem; align-items: center; flex-wrap: wrap; }
.ds-pst__pill { font-size: 0.72rem; font-weight: 800; padding: 0.2rem 0.6rem; border-radius: 999px; background: #eef2f5; color: #6b7b88; white-space: nowrap; justify-self: start; }
.ds-pst__pill.is-ok { background: #e6f6ef; color: #17895e; }
.ds-pst__pill.is-warn { background: #fff8e1; color: #a35a00; }
.ds-pst__pill.is-blue { background: #e7f0fb; color: #1d5fa8; }
.ds-pst__where { display: flex; gap: 0.5rem; flex-wrap: wrap; }
.ds-pst__where button { flex: 1; min-width: 12rem; min-height: 4rem; padding: 0.6rem 0.9rem; border-radius: 0.75rem; text-align: left; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; display: flex; flex-direction: column; gap: 0.15rem; }
.ds-pst__where button small { color: #6b7b88; }
.ds-pst__where button.is-on { background: #fff8e1; box-shadow: inset 0 0 0 2px #f6be00; }
.ds-pst__where button:disabled { opacity: .5; cursor: not-allowed; }
.dark .ds-pst__where button { background: rgb(255 255 255 / .05); }
.ds-pst__chips { display: flex; gap: 0.35rem; align-items: center; flex-wrap: wrap; }
.ds-pst__chips button, .ds-pst__chip { height: 2rem; padding: 0 0.75rem; border-radius: 999px; font-size: 0.8rem; font-weight: 800; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; }
.ds-pst__chips button.is-on, .ds-pst__chip.is-on { background: #fff8e1; box-shadow: inset 0 0 0 2px #f6be00; }
.ds-pst__fields { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.6rem; }
.ds-pst__fields label, .ds-pst__fields > span { display: flex; flex-direction: column; gap: 0.25rem; min-width: 0; }
.ds-pst__fields input, .ds-pst__inp { height: 2.4rem; border-radius: 0.55rem; background: #f6f8fa; border: 0; box-shadow: inset 0 0 0 1px #e1e7ec; padding: 0 0.7rem; font-family: ui-monospace, monospace; font-size: 0.85rem; min-width: 0; }
.ds-pst__inp { flex: 1; min-width: 14rem; }
.ds-pst__inp.is-short { flex: 0 1 14rem; min-width: 10rem; font-family: inherit; }
.dark .ds-pst__fields input, .dark .ds-pst__inp { background: rgb(255 255 255 / .06); color: inherit; }
.ds-pst__in { min-height: 2.4rem; border-radius: 0.55rem; background: #f6f8fa; box-shadow: inset 0 0 0 1px #e1e7ec; display: flex; align-items: center; padding: 0 0.7rem; font-family: ui-monospace, monospace; font-size: 0.85rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dark .ds-pst__in { background: rgb(255 255 255 / .06); }
.ds-pst__res { font-weight: 700; color: #6b7b88; }
.ds-pst__res.is-ok, .ds-pst__ok { color: #17895e; }
.ds-pst__res.is-bad, .ds-pst__bad { color: #c8372d; }
.ds-pst__warn, .ds-pst__mute.is-warn { color: #a35a00; }
.ds-pst__stat { padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; display: flex; flex-direction: column; gap: 0.1rem; }
.ds-pst__stat > b:first-child { font-size: 1.35rem; }
.ds-pst__stat .ds-pst__sm { font-size: 0.85rem; }
.ds-pst__stat.is-ok { background: #e6f6ef; } .ds-pst__stat.is-ok > b:first-child { color: #17895e; }
.ds-pst__stat.is-warn { background: #fff8e1; } .ds-pst__stat.is-warn > b:first-child { color: #a35a00; }
.ds-pst__stat.is-bad { background: #fdecea; } .ds-pst__stat.is-bad > b:first-child { color: #c8372d; }
.dark .ds-pst__stat { background: rgb(255 255 255 / .05); }
.ds-pst__bar { height: 0.5rem; border-radius: 9px; background: #edf1f4; overflow: hidden; display: block; }
.ds-pst__bar i { display: block; height: 100%; background: #17895e; transition: width .4s; }
.ds-pst__bar.is-blue i { background: #1d5fa8; } .ds-pst__bar.is-purple i { background: #7a4fb0; }
.ds-pst__bar.is-dark { background: rgb(255 255 255 / .12); } .ds-pst__bar.is-dark i { background: #f6be00; }
.ds-pst__mv { display: grid; grid-template-columns: 13rem 1fr auto; gap: 0.75rem; align-items: center; padding-top: 0.6rem; border-top: 1px solid #f0f3f6; }
.ds-pst__switch { border-radius: 1rem; padding: 1rem 1.1rem; display: flex; flex-direction: column; gap: 0.65rem; background: #0e2433; color: #fff; }
.ds-pst__switch small { color: #b9c6d0; }
.ds-pst__sstep { padding: 0.55rem 0.7rem; border-radius: 0.6rem; background: rgb(255 255 255 / .07); display: flex; flex-direction: column; gap: 0.1rem; }
.ds-pst__sstep b { color: #b9c6d0; } .ds-pst__sstep b.is-ok { color: #3ddc97; } .ds-pst__sstep b.is-on { color: #f6be00; }
.ds-pst__tog { display: flex; gap: 0.6rem; align-items: center; text-align: left; padding: 0.6rem 0.75rem; border-radius: 0.75rem; background: #f6f8fa; }
.ds-pst__tog.is-dark { background: rgb(255 255 255 / .07); }
.dark .ds-pst__tog { background: rgb(255 255 255 / .05); }
.ds-pst__tog span { display: flex; flex-direction: column; }
.ds-pst__sw { width: 2.5rem; height: 1.5rem; border-radius: 99px; background: #c5ced6; position: relative; flex: none; }
.ds-pst__sw i { position: absolute; top: 3px; left: 3px; width: 1.125rem; height: 1.125rem; border-radius: 99px; background: #fff; transition: left .2s; }
.ds-pst__sw.is-on { background: #17895e; } .ds-pst__sw.is-on i { left: calc(100% - 1.125rem - 3px); }
.ds-pst__runner { flex-direction: row; align-items: center; gap: 0.9rem; }
.ds-pst__dot { width: 0.75rem; height: 0.75rem; border-radius: 99px; background: #c8372d; flex: none; }
.ds-pst__dot.is-ok { background: #17895e; }
.ds-pst__steps { display: grid; grid-template-columns: 18rem minmax(0, 1fr); gap: 0.9rem; align-items: start; }
@media (max-width: 1000px) { .ds-pst__steps { grid-template-columns: 1fr; } }
.ds-pst__nav { gap: 0.2rem; padding: 0.75rem; }
.ds-pst__nav > button { padding: 0.55rem 0.6rem; border-radius: 0.6rem; display: flex; gap: 0.6rem; align-items: center; text-align: left; }
.ds-pst__nav > button.is-on { background: #fff8e1; }
.dark .ds-pst__nav > button.is-on { background: rgb(246 190 0 / .12); }
.ds-pst__nav small { color: #6b7b88; }
.ds-pst__num { width: 1.65rem; height: 1.65rem; border-radius: 99px; flex: none; display: flex; align-items: center; justify-content: center; font-size: 0.8rem; font-weight: 800; background: #e8edf1; color: #0e2433; }
.ds-pst__num.is-ok { background: #17895e; color: #fff; } .ds-pst__num.is-on { background: #f6be00; }
.ds-pst__body { gap: 0.75rem; }
.ds-pst__tr4, .ds-pst__tr5, .ds-pst__tr2 { display: grid; gap: 0.6rem; align-items: center; font-size: 0.83rem; padding: 0.4rem 0; border-top: 1px solid #f0f3f6; }
.dark .ds-pst__tr4, .dark .ds-pst__tr5, .dark .ds-pst__tr2, .dark .ds-pst__mv { border-color: rgb(255 255 255 / .08); }
.ds-pst__tr4 { grid-template-columns: minmax(0, 1.6fr) minmax(0, 1fr) minmax(0, 1fr) 9rem; }
.ds-pst__tr4.is-head { font-size: 0.75rem; font-weight: 700; color: #6b7b88; border: 0; padding: 0; }
.ds-pst__tr5 { grid-template-columns: minmax(0, 1fr) 1rem minmax(0, 1fr) 8rem 7rem; font-size: 0.78rem; }
.ds-pst__tr2 { grid-template-columns: 1.2rem 1fr auto; font-size: 0.9rem; }
.ds-pst__mono { font-family: ui-monospace, monospace; }
.ds-pst__cut { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.ds-pst__link { color: #1d5fa8; font-weight: 700; }
.ds-pst__pair { display: flex; flex-direction: column; gap: 0.35rem; }
.ds-pst__pair a { position: relative; display: block; height: 8rem; border-radius: 0.6rem; overflow: hidden; background: #3c2f1f; }
.ds-pst__pair img { width: 100%; height: 100%; object-fit: cover; }
.ds-pst__pair em { position: absolute; left: 0.35rem; bottom: 0.35rem; font-style: normal; font-size: 0.7rem; font-weight: 800; padding: 0.15rem 0.5rem; border-radius: 999px; background: rgb(0 0 0 / .55); color: #fff; }
.ds-pst__pair em.is-ok { background: #17895e; }
/* Part 41 · folder map */
.ds-pst__fmap { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.35rem 1.2rem; }
.ds-pst__fmap > span { display: flex; justify-content: space-between; gap: 0.75rem; font-size: 0.83rem; padding: 0.3rem 0; border-top: 1px solid #f0f3f6; }
.ds-pst__fmap code { font-family: ui-monospace, monospace; color: #17895e; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.dark .ds-pst__fmap > span { border-color: rgb(255 255 255 / .08); }
@media (max-width: 900px) { .ds-pst__fmap { grid-template-columns: 1fr; } }
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- resources/js/driver-offline.js
mkdir -p 'resources/js'
cat > 'resources/js/driver-offline.js' <<'DISPATCH_FILE_END_6'
/*
 * Driver app without signal.
 *
 * - Keeps today's trip on the phone (IndexedDB) while there is signal.
 * - Without signal: shows its own screens (find a box, deliver with photos, can't deliver)
 *   and keeps each one on the phone in a queue.
 * - When the signal is back: sends the queue by itself, oldest first, with the real time.
 *   Anything the office changed meanwhile is not forced through: it shows as "Needs attention".
 *
 * Runs on the Driver app home page (/delivery) and on the offline page (/delivery-offline).
 */
(function () {
    /*
     * Make a phone photo smaller before it is sent: longest side 1600 px, JPEG 80%.
     * A 3 MB iPhone photo becomes about 300 KB. Two ways, because iPhone Safari does not
     * always manage the first one; if both fail the photo is sent as it is (the server
     * makes it smaller then). Used by every photo button (window.dsShrinkPhoto).
     */
    async function shrinkPhoto(file, maxSide = 1600, quality = 0.8) {
        if (!file || (file.type && !/^image\//.test(file.type))) return file;
        const draw = (src, w, h) => {
            const s = Math.min(1, maxSide / Math.max(w, h));
            const c = document.createElement('canvas');
            c.width = Math.max(1, Math.round(w * s));
            c.height = Math.max(1, Math.round(h * s));
            c.getContext('2d').drawImage(src, 0, 0, c.width, c.height);
            return new Promise((r) => c.toBlob(r, 'image/jpeg', quality));
        };
        const ways = [
            async () => {
                const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' });
                try { return await draw(bmp, bmp.width, bmp.height); } finally { if (bmp.close) bmp.close(); }
            },
            async () => {
                // iPhone: a plain image keeps the photo the right way up when drawn
                const url = URL.createObjectURL(file);
                try {
                    const img = new Image();
                    img.src = url;
                    if (img.decode) await img.decode();
                    else await new Promise((ok, no) => { img.onload = ok; img.onerror = no; });
                    return await draw(img, img.naturalWidth, img.naturalHeight);
                } finally { URL.revokeObjectURL(url); }
            },
        ];
        for (const way of ways) {
            try {
                const blob = await way();
                if (blob && blob.size > 0) {
                    return blob.size < file.size ? new File([blob], 'photo.jpg', { type: 'image/jpeg', lastModified: Date.now() }) : file;
                }
            } catch (e) { /* try the next way */ }
        }
        return file;
    }
    window.dsShrinkPhoto = window.dsShrinkPhoto || shrinkPhoto;

    if (window.dsDriverOffline) return;

    const TRIP_URL = '/delivery-offline/trip';
    const SYNC_URL = '/delivery-offline/sync';
    const DB_NAME = 'ds-driver';
    const MAX_PHOTO_SIDE = 1600;

    // ------------------------------------------------------------------ storage (IndexedDB)

    let dbPromise = null;
    function db() {
        if (!dbPromise) {
            dbPromise = new Promise((resolve, reject) => {
                const req = indexedDB.open(DB_NAME, 1);
                req.onupgradeneeded = () => {
                    const d = req.result;
                    if (!d.objectStoreNames.contains('kv')) d.createObjectStore('kv');
                    if (!d.objectStoreNames.contains('queue')) d.createObjectStore('queue', { keyPath: 'uuid' });
                };
                req.onsuccess = () => resolve(req.result);
                req.onerror = () => reject(req.error);
            });
        }
        return dbPromise;
    }
    async function tx(store, mode, fn) {
        const d = await db();
        return new Promise((resolve, reject) => {
            const t = d.transaction(store, mode);
            const s = t.objectStore(store);
            const out = fn(s);
            t.oncomplete = () => resolve(out && 'result' in out ? out.result : out);
            t.onerror = () => reject(t.error);
        });
    }
    const kvGet = (k) => tx('kv', 'readonly', (s) => s.get(k));
    const kvSet = (k, v) => tx('kv', 'readwrite', (s) => s.put(v, k));
    const qAll = async () => ((await tx('queue', 'readonly', (s) => s.getAll())) || []).sort((a, b) => a.at.localeCompare(b.at));
    const qPut = (item) => tx('queue', 'readwrite', (s) => s.put(item));
    const qDel = (uuid) => tx('queue', 'readwrite', (s) => s.delete(uuid));

    // ------------------------------------------------------------------ helpers

    const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    }));
    const timeOf = (iso) => new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    const norm = (code) => String(code || '').trim().toUpperCase().replace(/[\x00-\x1F\x7F]+/g, '');
    const buzz = (ok) => { try { navigator.vibrate && navigator.vibrate(ok ? 60 : [80, 60, 80]); } catch (e) {} };

    async function shrink(file) {
        return shrinkPhoto(file, MAX_PHOTO_SIDE);
    }

    // ------------------------------------------------------------------ state

    const state = {
        snapshot: null,      // { trip, boxes, reasons, driver, saved_at }
        queue: [],
        online: navigator.onLine,
        sending: false,
        sent: 0,
        forced: false,       // offline screens shown even with signal (the offline page)
        view: 'home',        // home, box, deliver, miss, queue, camera
        box: null,
        photos: [],          // { blob, url }
        reason: null,
        note: '',
        search: '',
        toast: null,
        authProblem: false,
    };

    async function load() {
        state.snapshot = (await kvGet('snapshot')) || null;
        state.queue = await qAll();
    }

    /** Ask the server for today's boxes (and a fresh security token). */
    async function refreshTrip() {
        const res = await fetch(TRIP_URL, { credentials: 'same-origin', headers: { Accept: 'application/json' }, cache: 'no-store' });
        if (res.status === 401) { state.authProblem = true; throw new Error('auth'); }
        if (!res.ok) throw new Error('http ' + res.status);
        const data = await res.json();
        state.authProblem = false;
        const previous = state.snapshot;
        if (previous && previous.driver && data.driver && previous.driver.id !== data.driver.id) {
            // another driver signed in on this phone: keep only their own queue items
            state.queue = state.queue.filter((q) => q.driver_id === data.driver.id);
        }
        state.snapshot = data;
        await kvSet('snapshot', { ...data, csrf: undefined });
        return data.csrf;
    }

    // ------------------------------------------------------------------ sending

    async function flush() {
        if (state.sending || !navigator.onLine) return false;
        const waiting = state.queue.filter((q) => q.status === 'wait');
        if (!waiting.length) return false;

        state.sending = true; state.sent = 0; render();
        let csrf;
        try { csrf = await refreshTrip(); } catch (e) { state.sending = false; render(); return false; }

        let changed = false;
        for (const item of waiting) {
            const form = new FormData();
            form.append('uuid', item.uuid);
            form.append('type', item.type);
            form.append('tripinvoice_id', item.box_id);
            form.append('at', item.at);
            if (item.reason) form.append('reason', item.reason);
            if (item.note) form.append('note', item.note);
            (item.photos || []).forEach((b, i) => form.append('photos[]', b, `photo-${i + 1}.jpg`));
            try {
                const res = await fetch(SYNC_URL, { method: 'POST', body: form, credentials: 'same-origin', headers: { Accept: 'application/json', 'X-CSRF-TOKEN': csrf } });
                if (res.status === 401 || res.status === 419) { state.authProblem = true; break; }
                if (res.status === 422) {
                    const body = await res.json().catch(() => ({}));
                    item.status = 'fail'; item.message = body.message || 'The office could not save this one.';
                } else if (!res.ok) {
                    break; // server problem: try again later
                } else {
                    const body = await res.json();
                    item.status = body.status === 'saved' ? 'sent' : 'fail';
                    item.message = body.message || null;
                }
                if (item.status !== 'wait') { item.photos = []; item.photoCount = item.photoCount || 0; item.done_at = new Date().toISOString(); }
                await qPut(item);
                state.sent++; changed = true; render();
            } catch (e) {
                break; // signal dropped again
            }
        }
        state.queue = await qAll();
        state.sending = false;
        try { await refreshTrip(); } catch (e) {}
        render();
        if (changed) document.dispatchEvent(new CustomEvent('ds-offline-sent'));
        return changed;
    }

    // ------------------------------------------------------------------ boxes on the phone

    function boxes() {
        const list = (state.snapshot && state.snapshot.boxes) || [];
        const queued = new Map(state.queue.filter((q) => q.status !== 'fail').map((q) => [q.box_id, q.type]));
        return list.map((b) => ({ ...b, local: queued.get(b.id) || null }));
    }
    function counts() {
        const all = boxes();
        const delivered = all.filter((b) => b.delivered || b.local === 'deliver').length;
        return { total: all.length, delivered, left: all.length - delivered, waiting: state.queue.filter((q) => q.status === 'wait').length,
            attention: state.queue.filter((q) => q.status === 'fail').length };
    }
    /** Stops still to visit (Maps & routes), in order. A stop drops off once all its boxes are delivered. */
    function stops() {
        const left = new Map(boxes().filter((b) => !b.delivered && b.local !== 'deliver').map((b) => [b.id, b]));
        return ((state.snapshot && state.snapshot.stops) || []).map((s) => {
            const mine = (s.boxes || []).map((id) => left.get(id)).filter(Boolean);
            return mine.length ? { ...s, count: mine.length, first: mine[0].invoice } : null;
        }).filter(Boolean);
    }
    const IOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    function navUrl(app, s) {
        const to = encodeURIComponent(s.go);
        if (app === 'waze') return s.lat !== null ? 'https://waze.com/ul?ll=' + to + '&navigate=yes' : 'https://waze.com/ul?q=' + to + '&navigate=yes';
        if (app === 'apple') return 'https://maps.apple.com/?daddr=' + to + '&dirflg=d';
        return 'https://www.google.com/maps/dir/?api=1&destination=' + to + '&travelmode=driving';
    }
    function telOf(p) { return p ? 'tel:' + String(p).replace(/[^0-9+]/g, '') : ''; }
    function findBox(code) {
        const c = norm(code);
        return boxes().find((b) => (b.codes || [b.invoice]).some((x) => norm(x) === c));
    }

    // ------------------------------------------------------------------ actions

    function openBox(code) {
        const b = findBox(code);
        if (!b) { toast('bad', `${norm(code)} is not in today's saved list`, 'Keep it aside. Check again when you have signal.'); buzz(false); return; }
        if (b.delivered || b.local === 'deliver') { toast('bad', `${b.invoice} is already delivered`, b.local ? 'Saved on this phone, waiting to send.' : ''); buzz(false); return; }
        state.box = b; state.view = 'box'; state.photos = []; state.note = ''; state.reason = null; buzz(true); render();
    }

    async function addPhotos(files) {
        for (const f of files) {
            if (state.view === 'miss' && state.photos.length >= 3) break;
            const blob = await shrink(f);
            state.photos.push({ blob, url: URL.createObjectURL(blob) });
        }
        render();
    }

    async function save(type) {
        const b = state.box;
        if (!b) return;
        if (type === 'deliver' && !state.photos.length) { toast('bad', 'Take at least one photo', ''); return; }
        const r = type === 'miss' ? reasons().find((x) => x.value === state.reason) : null;
        if (type === 'miss') {
            if (!r) { toast('bad', 'Pick a reason', ''); return; }
            if (r.note && !state.note.trim()) { toast('bad', 'Please add a note for this reason', ''); return; }
            if (r.photo && !state.photos.length) { toast('bad', 'Please add a photo for this reason', ''); return; }
        }
        const item = {
            uuid: uuid(), type, box_id: b.id, invoice: b.invoice, name: b.name, at: new Date().toISOString(),
            reason: r ? r.value : null, reasonLabel: r ? r.label : null, note: state.note.trim() || null,
            photos: state.photos.map((p) => p.blob), photoCount: state.photos.length, status: 'wait',
            driver_id: state.snapshot && state.snapshot.driver ? state.snapshot.driver.id : null,
        };
        await qPut(item);
        state.queue = await qAll();
        state.photos.forEach((p) => URL.revokeObjectURL(p.url));
        state.photos = []; state.box = null; state.view = 'home';
        buzz(true);
        toast('saved', type === 'deliver' ? `${item.invoice} saved on this phone` : `${item.invoice} kept on the truck`,
            'It will send by itself when the signal is back.', item.uuid);
        if (navigator.onLine) flush();
    }

    async function undo(id) {
        const item = state.queue.find((q) => q.uuid === id);
        if (!item || item.status !== 'wait') return;
        await qDel(id);
        state.queue = await qAll();
        state.toast = null;
        render();
    }

    async function clearDone() {
        for (const q of state.queue.filter((x) => x.status === 'sent')) await qDel(q.uuid);
        state.queue = await qAll(); render();
    }

    async function dismiss(id) { await qDel(id); state.queue = await qAll(); render(); }

    const reasons = () => (state.snapshot && state.snapshot.reasons) || [];

    let toastTimer = null;
    function toast(kind, title, sub, undoId) {
        state.toast = { kind, title, sub, undoId };
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => { state.toast = null; render(); }, 6000);
        render();
    }

    // ------------------------------------------------------------------ camera (phones with a built-in barcode reader)

    let camStream = null; let camLoop = null;
    async function startCamera() {
        if (!('BarcodeDetector' in window)) return;
        state.view = 'camera'; render();
        try {
            const detector = new window.BarcodeDetector();
            camStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
            const video = document.querySelector('#dso-video');
            if (!video) return stopCamera();
            video.srcObject = camStream; await video.play();
            camLoop = setInterval(async () => {
                try {
                    const found = await detector.detect(video);
                    if (found && found[0]) { const code = found[0].rawValue; stopCamera(); openBox(code); }
                } catch (e) {}
            }, 350);
        } catch (e) {
            stopCamera(); toast('bad', 'The camera could not start', 'Type the box number instead.');
        }
    }
    function stopCamera() {
        clearInterval(camLoop); camLoop = null;
        if (camStream) camStream.getTracks().forEach((t) => t.stop());
        camStream = null;
        if (state.view === 'camera') { state.view = 'home'; render(); }
    }

    // ------------------------------------------------------------------ rendering

    function shown() { return state.forced || !state.online; }

    function netBar() {
        const c = counts();
        let cls, title, sub;
        if (!state.online) { cls = 'is-off'; title = 'No signal'; sub = c.waiting ? `${c.waiting} waiting to send · kept on this phone` : 'You can keep scanning and delivering'; }
        else if (state.sending) { cls = 'is-send'; title = 'Back online · sending'; sub = `${state.sent} of ${c.waiting + state.sent} sent`; }
        else if (state.authProblem && c.waiting) { cls = 'is-warn'; title = 'Sign in again to send'; sub = `${c.waiting} waiting on this phone`; }
        else if (c.attention) { cls = 'is-warn'; title = `Online · ${c.attention} needs attention`; sub = 'Tap to see why'; }
        else if (c.waiting) { cls = 'is-send'; title = 'Online'; sub = `${c.waiting} waiting to send`; }
        else { cls = 'is-on'; title = 'Online'; sub = 'Every delivery is saved'; }
        return { cls, title, sub, n: c.waiting + c.attention };
    }

    /** The small signal bar shown on the online Driver app. */
    function renderBar() {
        const el = document.getElementById('ds-net');
        if (!el) return;
        const n = netBar();
        el.className = 'dso-net ' + n.cls + (n.n || !state.online ? ' is-shown' : '');
        el.innerHTML = `<i></i><span><strong>${esc(n.title)}</strong><small>${esc(n.sub)}</small></span>${n.n ? `<button type="button" data-dso="queue">${n.n} ›</button>` : ''}`;
    }

    function photoGrid(max) {
        const tiles = state.photos.map((p, i) => `<span class="dso-proof"><img src="${p.url}" alt="Photo ${i + 1}"><b>${i + 1}</b><button type="button" data-dso="rmphoto" data-i="${i}" aria-label="Remove photo">✕</button></span>`).join('');
        const can = !max || state.photos.length < max;
        return `<div class="dso-grid">${tiles}${can ? `<label class="dso-add"><input type="file" accept="image/*" capture="environment" multiple data-dso="photos" hidden><span>📷</span>${state.photos.length ? 'Add another' : 'Take photo'}</label>` : ''}</div>`;
    }

    function screenHtml() {
        const s = state.snapshot;
        const c = counts();
        const n = netBar();
        const bar = `<div class="dso-net ${n.cls} is-shown"><i></i><span><strong>${esc(n.title)}</strong><small>${esc(n.sub)}</small></span>${n.n ? `<button type="button" data-dso="queue">${n.n} ›</button>` : ''}</div>`;
        const toastHtml = state.toast ? `<div class="dso-toast is-${state.toast.kind}"><span>${state.toast.kind === 'bad' ? '!' : '⏳'}</span><span><strong>${esc(state.toast.title)}</strong>${state.toast.sub ? `<small>${esc(state.toast.sub)}</small>` : ''}</span>${state.toast.undoId ? `<button type="button" data-dso="undo" data-id="${esc(state.toast.undoId)}">Undo</button>` : ''}</div>` : '';

        if (!s) {
            return `${bar}<section class="dso-screen"><div class="dso-empty"><strong>Today's trip is not on this phone yet</strong><p>Open the Driver app once with signal (at the warehouse is best). After that it works without signal.</p></div></section>`;
        }
        if (!s.trip) {
            return `${bar}<section class="dso-screen"><div class="dso-empty"><strong>You're not on a trip</strong><p>When the office puts you on a truck, today's boxes are saved here.</p></div></section>`;
        }

        if (state.view === 'nav' && state.stop) {
            const st = state.stop;
            const off = !state.online;
            const app = (key, letter, name, good, bad, dim) => `<button type="button" class="dso-app${dim ? ' is-dim' : ''}" data-dso="go" data-app="${key}"><i class="is-${key}">${letter}</i><span><b>${name}</b><small class="${dim ? 'dso-amber' : 'is-ok'}">${dim ? bad : good}</small></span>›</button>`;
            return `${bar}<section class="dso-screen"><div class="dso-sheet">
                <div class="dso-sheethead"><small>Stop ${st.no}${off ? ' · no signal' : ''}</small><strong>${esc(st.name)}</strong><span>${esc(st.address || st.place)} · ${st.lat !== null ? (st.exact ? '📍 exact pin' : '📍 area pin') : 'no pin'} · ${st.count} ${st.count > 1 ? 'boxes' : 'box'}</span></div>
                ${off ? `<p class="dso-navtip">${st.lat !== null ? 'No signal: use a map app with your area downloaded. It finds the pin and drives you there offline.' : 'This stop has no pin, so the map app has to search the address. That needs signal.'}</p>` : ''}
                ${app('google', 'G', 'Google Maps', off ? '✓ works offline with a downloaded map' : 'Best street and address detail', '', false)}
                ${IOS ? app('apple', 'A', 'Apple Maps', off ? '✓ works offline with a downloaded map' : 'Already on your iPhone', '', false) : ''}
                ${app('waze', 'W', 'Waze', 'Best for traffic and shortcuts', 'needs signal · may not open the route', off)}
                ${off ? '<p class="dso-note">Tip: download your area once on office Wi-Fi. Google Maps: profile → Offline maps. Apple Maps: profile → Offline Maps.</p>' : ''}
                <div class="dso-two">${st.phone ? `<a class="dso-ghostbtn" href="${esc(telOf(st.phone))}">Call ${esc(String(st.name).split(' ')[0])}</a>` : ''}<button type="button" class="dso-primary is-green" style="height:3rem" data-dso="open" data-code="${esc(st.first)}">I'm here · deliver</button></div>
                <button type="button" class="dso-link" data-dso="home">Close</button>
            </div></section>${toastHtml}`;
        }

        if (state.view === 'queue') {
            const rows = state.queue.slice().reverse().map((q) => {
                const st = q.status === 'wait' ? ['⏳', 'Waiting', 'is-wait'] : q.status === 'sent' ? ['✓', 'Sent', 'is-ok'] : ['!', 'Needs attention', 'is-warn'];
                const what = q.type === 'deliver' ? 'Delivered' : `Can't deliver · ${q.reasonLabel || ''}`;
                return `<div class="dso-q ${st[2]}"><span class="dso-qi">${st[0]}</span><span class="dso-qt"><strong>${esc(q.invoice)} <small>${esc(what)}</small></strong><small>${esc(q.name || '')} · ${q.photoCount || 0} photo(s) · ${timeOf(q.at)}</small>${q.message ? `<em>${esc(q.message)}</em>` : ''}</span><span class="dso-qs">${st[1]}${q.status === 'wait' ? `<button type="button" data-dso="undo" data-id="${esc(q.uuid)}">Remove</button>` : q.status === 'fail' ? `<button type="button" data-dso="dismiss" data-id="${esc(q.uuid)}">OK</button>` : ''}</span></div>`;
            }).join('') || '<p class="dso-muted">Nothing waiting.</p>';
            return `${bar}<section class="dso-screen"><div class="dso-head"><button type="button" class="dso-back" data-dso="home">‹</button><strong>Waiting to send</strong></div>
                ${state.sending ? `<div class="dso-sending"><span>Sending… ${state.sent} sent</span><i style="width:${Math.min(100, state.sent / Math.max(1, c.waiting + state.sent) * 100)}%"></i></div>` : ''}
                ${rows}
                ${state.queue.some((q) => q.status === 'sent') ? '<button type="button" class="dso-link" data-dso="cleardone">Clear sent ones</button>' : ''}
                ${state.online && c.waiting && !state.sending ? '<button type="button" class="dso-primary" data-dso="send">Send now</button>' : ''}
                <div class="dso-warn"><b>!</b><span>Don't clear the browser or remove the app until everything is sent. On iPhone, open the app when you have signal so it can send.</span></div>
                ${state.forced && state.online ? '<a class="dso-primary is-ghost" href="/delivery">Open the full Driver app</a>' : ''}</section>${toastHtml}`;
        }

        if (state.view === 'camera') {
            return `<section class="dso-camera"><video id="dso-video" playsinline muted></video><div class="dso-frame"></div><button type="button" class="dso-primary is-ghost" data-dso="stopcam">Close camera</button></section>`;
        }

        if (state.box && ['box', 'deliver', 'miss'].includes(state.view)) {
            const b = state.box;
            let body = '';
            if (state.view === 'box') {
                body = `<div class="dso-tags"><span class="dso-tag is-ok">On your truck</span><strong>${esc(b.invoice)}</strong><span class="dso-tag is-blue">From saved list</span></div>
                    <div class="dso-who"><strong>${esc(b.name)}</strong><span>${esc(b.address)}</span></div>
                    ${b.phone ? `<a class="dso-ghostbtn" href="tel:${esc(String(b.phone).replace(/[^0-9+]/g, ''))}">📞 Call ${esc(b.phone)}</a>` : ''}
                    ${b.attempted ? '<small class="dso-amber">Tried before</small>' : ''}
                    <button type="button" class="dso-primary is-green" data-dso="deliver">Deliver this box</button>
                    <button type="button" class="dso-secondary" data-dso="miss">Can't deliver</button>
                    <button type="button" class="dso-link" data-dso="home">Back</button>`;
            } else if (state.view === 'deliver') {
                body = `<div class="dso-sheethead"><small>${esc(b.invoice)} · ${esc(b.name)}</small><strong>Proof of delivery</strong><span>Take as many photos as you need.</span></div>
                    ${photoGrid(0)}
                    <button type="button" class="dso-primary ${state.photos.length ? 'is-green' : 'is-off'}" data-dso="savedeliver">${state.photos.length ? `Delivered · save on phone (${state.photos.length})` : 'Take at least 1 photo'}</button>
                    <button type="button" class="dso-link" data-dso="box">Back</button>`;
            } else {
                const r = reasons().find((x) => x.value === state.reason);
                body = `<div class="dso-sheethead"><small>${esc(b.invoice)} · ${esc(b.name)}</small><strong>Why couldn't you deliver it?</strong></div>
                    <div class="dso-chips">${reasons().map((x) => `<button type="button" data-dso="reason" data-v="${esc(x.value)}" class="${x.value === state.reason ? 'is-on' : ''}">${esc(x.label)}</button>`).join('')}</div>
                    <input type="text" class="dso-input" data-dso="note" maxlength="500" value="${esc(state.note)}" placeholder="${esc(r ? r.prompt : 'Note')}${r && r.note ? '' : ' (optional)'}">
                    ${photoGrid(3)}
                    <button type="button" class="dso-primary is-amber" data-dso="savemiss">Keep it on the truck</button>
                    <button type="button" class="dso-link" data-dso="box">Back</button>`;
            }
            return `${bar}<section class="dso-screen"><div class="dso-sheet ${state.view === 'miss' ? 'is-warn' : ''}">${body}</div></section>${toastHtml}`;
        }

        const q = norm(state.search);
        const list = boxes().filter((b) => !b.delivered && b.local !== 'deliver')
            .filter((b) => !q || norm(b.invoice).includes(q) || norm(b.name).includes(q) || norm(b.address).includes(q)).slice(0, 80);
        const pct = c.total ? Math.round(c.delivered / c.total * 289) : 0;
        return `${bar}<section class="dso-screen">
            <div class="dso-hello"><small>Trip ${esc(s.trip.number)}${s.trip.plate ? ' · Truck ' + esc(s.trip.plate) : ''}</small><strong>Hi, ${esc(s.driver ? s.driver.first_name : '')}</strong></div>
            <div class="dso-today"><span class="dso-ring"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="t"/><circle cx="55" cy="55" r="46" class="f" style="stroke-dashoffset:${289 - pct}"/></svg><span><strong>${c.delivered}</strong><small>of ${c.total}</small></span></span>
                <dl><dt>Delivered</dt><dd class="is-ok">${c.delivered}</dd><dt>Waiting to send</dt><dd class="is-blue">${c.waiting}</dd><dt>Still on the truck</dt><dd>${c.left}</dd></dl></div>
            <form class="dso-find" data-dso="find"><input type="text" name="code" placeholder="Type a box number" autocomplete="off" autocapitalize="characters" enterkeyhint="go" aria-label="Box number"><button type="submit">Find</button></form>
            ${'BarcodeDetector' in window ? '<button type="button" class="dso-primary" data-dso="camera">Scan with camera</button>' : ''}
            <p class="dso-note">Today's ${c.total} boxes are saved on this phone (${esc(s.saved_at ? timeOf(s.saved_at) : '')}). You can deliver without signal.</p>
            ${stopsHtml()}
            <input type="search" class="dso-input" data-dso="search" value="${esc(state.search)}" placeholder="Search name or barangay">
            <div class="dso-list">${list.map((b) => `<button type="button" class="dso-row" data-dso="open" data-code="${esc(b.invoice)}"><strong>${esc(b.invoice)}${b.local === 'miss' ? ' <em>kept · waiting</em>' : ''}</strong><span>${esc(b.name)}</span><small>${esc(b.address)}</small></button>`).join('') || '<p class="dso-muted">No boxes left to deliver.</p>'}</div>
            ${state.forced && state.online ? '<a class="dso-primary is-ghost" href="/delivery">Signal is back · open the full Driver app</a>' : ''}
        </section>${toastHtml}`;
    }

    function stopsHtml() {
        const list = stops();
        if (!list.length) return '';
        const next = list[0];
        const row = (st) => `<div class="dso-stop"><span class="dso-no${st.priority ? ' is-prio' : ''}">${st.no}</span><span class="dso-stopt"><strong>${esc(st.name)}</strong><small>${esc(st.place)} · ${st.count} ${st.count > 1 ? 'boxes' : 'box'}${st.priority ? ' · priority' : ''}</small>${st.lat === null ? '<em>no pin · needs signal to find</em>' : ''}</span><button type="button" class="dso-go${st.lat === null && !state.online ? ' is-dim' : ''}" data-dso="nav" data-id="${st.id}">Navigate</button></div>`;
        return `<p class="dso-label">Your stops <span>· saved on this phone</span></p>
            <div class="dso-next"><span><small>Next · stop ${next.no}</small><strong>${esc(next.name)}</strong><em>${esc(next.place)} · ${next.count} ${next.count > 1 ? 'boxes' : 'box'}</em></span><button type="button" data-dso="nav" data-id="${next.id}">Navigate</button></div>
            <div class="dso-stops">${list.slice(1, 12).map(row).join('')}</div>`;
    }

    function render() {
        renderBar();
        let root = document.getElementById('dso-root');
        if (!shown()) { if (root) root.hidden = true; return; }
        if (!root) { root = document.createElement('div'); root.id = 'dso-root'; document.body.appendChild(root); }
        root.hidden = false;
        const active = document.activeElement;
        const keep = active && active.dataset && active.dataset.dso && root.contains(active) ? { k: active.dataset.dso, pos: active.selectionStart } : null;
        root.innerHTML = screenHtml();
        if (keep) {
            const el = root.querySelector(`[data-dso="${keep.k}"]`);
            if (el && el.focus) { el.focus(); try { el.setSelectionRange(keep.pos, keep.pos); } catch (e) {} }
        }
    }

    // ------------------------------------------------------------------ events

    document.addEventListener('click', (e) => {
        const t = e.target.closest('[data-dso]');
        if (!t) return;
        const a = t.dataset.dso;
        const actions = {
            queue: () => { state.view = 'queue'; if (!shown()) state.forced = true; render(); },
            home: () => { state.view = 'home'; state.box = null; if (state.online && !document.getElementById('dso-shell')) state.forced = false; render(); },
            open: () => openBox(t.dataset.code),
            nav: () => { state.stop = stops().find((x) => String(x.id) === t.dataset.id) || null; if (state.stop) { state.view = 'nav'; render(); } },
            go: () => { const url = navUrl(t.dataset.app, state.stop); try { localStorage.setItem('ds.navApp', t.dataset.app); } catch (err) {} window.open(url, '_blank') || (window.location.href = url); },
            deliver: () => { state.view = 'deliver'; render(); },
            miss: () => { state.view = 'miss'; state.reason = state.reason || (reasons()[0] || {}).value; render(); },
            box: () => { state.view = 'box'; render(); },
            reason: () => { state.reason = t.dataset.v; render(); },
            rmphoto: () => { const i = +t.dataset.i; URL.revokeObjectURL(state.photos[i].url); state.photos.splice(i, 1); render(); },
            savedeliver: () => save('deliver'),
            savemiss: () => save('miss'),
            undo: () => undo(t.dataset.id),
            dismiss: () => dismiss(t.dataset.id),
            cleardone: () => clearDone(),
            send: () => flush(),
            camera: () => startCamera(),
            stopcam: () => stopCamera(),
        };
        if (actions[a]) { e.preventDefault(); actions[a](); }
    });
    document.addEventListener('change', (e) => {
        if (e.target.dataset && e.target.dataset.dso === 'photos') addPhotos([...e.target.files]);
    });
    document.addEventListener('input', (e) => {
        const d = e.target.dataset && e.target.dataset.dso;
        if (d === 'note') state.note = e.target.value;
        if (d === 'search') { state.search = e.target.value; render(); }
    });
    document.addEventListener('submit', (e) => {
        if (e.target.dataset && e.target.dataset.dso === 'find') {
            e.preventDefault();
            const v = e.target.querySelector('input').value; if (v.trim()) openBox(v);
        }
    });

    window.addEventListener('offline', () => { state.online = false; render(); watchBack(); });
    window.addEventListener('online', async () => {
        state.online = true; render();
        const changed = await flush();
        // back on the full app: reload it so its numbers include what was just sent
        // Board 68: never while a box sheet or a photo is open; it reloads once they are closed.
        if (!document.getElementById('dso-shell') && changed) {
            const busy = () => document.querySelector('.ds-sa__sheet, .dspv, input[type=file]:focus');
            const later = () => (busy() ? setTimeout(later, 1500) : location.reload());
            setTimeout(later, 900);
        }
        else render();
    });

    // ------------------------------------------------------------------ start

    async function start() {
        state.forced = !!document.getElementById('dso-shell');
        try { await load(); } catch (e) {}
        render();
        if (navigator.onLine) {
            try { await refreshTrip(); } catch (e) {}
            await flush();
            render();
        }
        // keep the saved list fresh while the app is open
        setInterval(async () => { if (navigator.onLine && !state.sending) { try { await refreshTrip(); render(); } catch (e) {} } }, 5 * 60 * 1000);
        setInterval(() => { if (navigator.onLine) flush(); }, 30 * 1000);
    }

    window.dsDriverOffline = { state, flush, refreshTrip, render, openBox, save };

    const boot = () => {
        if (document.getElementById('ds-net') || document.getElementById('dso-shell')) start();
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
    document.addEventListener('livewire:navigated', () => render());

    // The phone says it has signal but a tap on the full app could not reach the office:
    // check once, and if the office really can't be reached, switch to the screens without signal.
    async function reachable() {
        try {
            const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 6000);
            const res = await fetch(TRIP_URL, { credentials: 'same-origin', cache: 'no-store', signal: ctl.signal, headers: { Accept: 'application/json' } });
            clearTimeout(t); return res.status < 500;
        } catch (e) { return false; }
    }
    let hooked = false;
    function hookLivewire() {
        if (hooked || !window.Livewire || !window.Livewire.hook) return;
        hooked = true;
        window.Livewire.hook('request', ({ fail }) => {
            fail(async ({ status, preventDefault }) => {
                if (!document.getElementById('ds-net')) return; // only the Driver app
                if (status && status < 500) return;
                preventDefault && preventDefault();
                if (!(await reachable())) { state.online = false; render(); watchBack(); }
            });
        });
    }
    if (window.Livewire) hookLivewire(); else document.addEventListener('livewire:init', hookLivewire);
    let backTimer = null;
    function watchBack() {
        clearInterval(backTimer);
        backTimer = setInterval(async () => {
            if (navigator.onLine && await reachable()) {
                clearInterval(backTimer);
                window.dispatchEvent(new Event('online'));
            }
        }, 15000);
    }

    // ------------------------------------------------------------------ look (same style as the Driver app)

    const css = `
#dso-root{position:fixed;inset:0;z-index:45;overflow:auto;color:#eef3f6;font-family:Archivo,system-ui,sans-serif;background:radial-gradient(120% 70% at 0% 0%,#15293a 0%,#0a1219 55%);-webkit-tap-highlight-color:transparent}
#dso-root[hidden]{display:none}
#dso-root button{font:inherit;cursor:pointer;border:0;background:none;color:inherit}
.dso-net{position:fixed;top:calc(env(safe-area-inset-top) + .6rem);left:1rem;right:1rem;z-index:46;max-width:32rem;margin:0 auto;display:none;align-items:center;gap:.65rem;padding:.55rem .6rem .55rem .9rem;border-radius:1rem;color:#eef3f6;font-family:Archivo,system-ui,sans-serif;backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px)}
.dso-net.is-shown{display:flex}
.dso-net i{width:.6rem;height:.6rem;border-radius:50%;flex:none}
.dso-net>span{flex:1;min-width:0;display:flex;flex-direction:column}
.dso-net strong{font-size:.85rem}.dso-net small{font-size:.72rem;opacity:.8}
.dso-net button{height:2rem;padding:0 .7rem;border-radius:.6rem;background:rgb(255 255 255/.12);color:#eef3f6;font-weight:800;font-size:.8rem;border:0}
.dso-net.is-off{background:rgb(30 40 52/.94);box-shadow:inset 0 0 0 1px rgb(140 196 255/.3)}.dso-net.is-off i{background:#ff6b5e;box-shadow:0 0 0 4px rgb(255 107 94/.2)}
.dso-net.is-send{background:rgb(15 43 35/.95);box-shadow:inset 0 0 0 1px rgb(52 195 143/.4)}.dso-net.is-send i{background:#34c38f}
.dso-net.is-warn{background:rgb(34 26 12/.95);box-shadow:inset 0 0 0 1px rgb(240 169 59/.4)}.dso-net.is-warn i{background:#f0a93b}
.dso-net.is-on{background:rgb(255 255 255/.06)}.dso-net.is-on i{background:#34c38f}
.dso-screen{max-width:34rem;margin:0 auto;padding:calc(env(safe-area-inset-top) + 5rem) 1.35rem calc(env(safe-area-inset-bottom) + 2rem);display:flex;flex-direction:column;gap:1rem}
.dso-hello{display:flex;flex-direction:column;gap:.2rem}.dso-hello small{color:#7f93a1;font-size:.85rem}.dso-hello strong{font-size:1.75rem;letter-spacing:-.025em}
.dso-today{display:flex;align-items:center;gap:1rem;padding:1rem;border-radius:1.5rem;background:rgb(255 255 255/.045);box-shadow:inset 0 0 0 1px rgb(255 255 255/.07)}
.dso-today dl{flex:1;display:grid;grid-template-columns:1fr auto;gap:.5rem .75rem;margin:0;font-size:.88rem}.dso-today dt{color:#7f93a1}.dso-today dd{margin:0;font-weight:700}
.dso-today .is-ok{color:#6fd6ad}.dso-today .is-blue{color:#8cc4ff}
.dso-ring{position:relative;width:5.5rem;height:5.5rem;flex:none}.dso-ring svg{width:100%;height:100%;transform:rotate(-90deg)}
.dso-ring circle{fill:none;stroke-width:9}.dso-ring .t{stroke:rgb(255 255 255/.08)}.dso-ring .f{stroke:#34c38f;stroke-linecap:round;stroke-dasharray:289}
.dso-ring>span{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center}.dso-ring strong{font-size:1.4rem}.dso-ring small{font-size:.65rem;color:#7f93a1}
.dso-find{display:flex;gap:.5rem}.dso-find input,.dso-input{-webkit-appearance:none;appearance:none;box-sizing:border-box;font-family:inherit;flex:1;min-width:0;height:3.1rem;padding:0 1rem;border:0;border-radius:1rem;background:rgb(255 255 255/.06);color:#eef3f6;font-size:1rem;box-shadow:inset 0 0 0 1px rgb(255 255 255/.08);outline:0}
.dso-find button{height:3.1rem;padding:0 1.2rem;border-radius:1rem;background:#f6be00!important;color:#0a1219!important;font-weight:800}
.dso-primary{display:flex;align-items:center;justify-content:center;height:3.5rem;border-radius:1.1rem;background:#f6be00!important;color:#0a1219!important;font-weight:800;font-size:1.02rem;text-decoration:none}
.dso-primary.is-green{background:#34c38f!important}.dso-primary.is-amber{background:#f0a93b!important}.dso-primary.is-off{background:rgb(255 255 255/.08)!important;color:#7f93a1!important}
.dso-primary.is-ghost{background:rgb(255 255 255/.08)!important;color:#eef3f6!important;font-weight:700}
.dso-secondary{height:3rem;border-radius:1rem;background:rgb(255 255 255/.06)!important;font-weight:600}
.dso-link{height:2.6rem;color:#7f93a1!important;font-weight:600}
.dso-note{margin:0;font-size:.82rem;color:#a9b8c2;line-height:1.5}.dso-muted{color:#7f93a1;font-size:.88rem}
.dso-list{display:flex;flex-direction:column;gap:.5rem}
.dso-row{display:flex;flex-direction:column;align-items:flex-start;gap:.1rem;padding:.8rem 1rem;border-radius:1.1rem;background:rgb(255 255 255/.045)!important;box-shadow:inset 0 0 0 1px rgb(255 255 255/.07);text-align:left}
.dso-row strong{font-size:.98rem}.dso-row em{font-style:normal;font-size:.7rem;color:#8cc4ff;margin-left:.35rem}.dso-row span{font-size:.88rem}.dso-row small{font-size:.75rem;color:#7f93a1}
.dso-sheet{display:flex;flex-direction:column;gap:.9rem;padding:1.1rem;border-radius:1.6rem;background:rgb(15 24 32/.98);box-shadow:0 20px 50px rgb(0 0 0/.4),inset 0 1px 0 rgb(255 255 255/.08)}
.dso-sheet.is-warn{background:rgb(34 26 12/.98)}
.dso-tags{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap}.dso-tags strong{color:#c9d5dc}
.dso-tag{padding:.25rem .65rem;border-radius:999px;font-size:.72rem;font-weight:700}.dso-tag.is-ok{background:rgb(52 195 143/.14);color:#6fd6ad}.dso-tag.is-blue{background:rgb(140 196 255/.14);color:#8cc4ff;margin-left:auto}
.dso-who{display:flex;flex-direction:column;gap:.25rem}.dso-who strong{font-size:1.55rem;letter-spacing:-.02em}.dso-who span{color:#a9b8c2;font-size:.9rem}
.dso-ghostbtn{display:flex;align-items:center;justify-content:center;height:3rem;border-radius:.9rem;background:rgb(255 255 255/.06);color:#eef3f6;text-decoration:none;font-weight:600}
.dso-amber{color:#f3c98a}
.dso-sheethead{display:flex;flex-direction:column;gap:.2rem}.dso-sheethead small{color:#7f93a1;font-size:.8rem}.dso-sheethead strong{font-size:1.4rem;letter-spacing:-.02em}.dso-sheethead span{color:#a9b8c2;font-size:.88rem}
.dso-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:.55rem}
.dso-proof{position:relative;aspect-ratio:1;border-radius:1rem;overflow:hidden}.dso-proof img{width:100%;height:100%;object-fit:cover}
.dso-proof b{position:absolute;left:.4rem;bottom:.4rem;padding:0 .45rem;border-radius:999px;background:rgb(10 18 25/.75);font-size:.7rem}
.dso-proof button{position:absolute;right:.3rem;top:.3rem;width:1.6rem;height:1.6rem;border-radius:50%;background:rgb(10 18 25/.7)!important;color:#fff;font-size:.7rem}
.dso-add{aspect-ratio:1;border-radius:1rem;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:.3rem;background:rgb(255 255 255/.05);box-shadow:inset 0 0 0 1.5px rgb(255 255 255/.18);font-size:.8rem;font-weight:600;cursor:pointer}
.dso-add span{font-size:1.4rem}
.dso-chips{display:flex;flex-wrap:wrap;gap:.4rem}.dso-chips button{height:2.3rem;padding:0 .8rem;border-radius:999px;background:rgb(255 255 255/.07)!important;font-size:.8rem;font-weight:700}
.dso-chips button.is-on{background:#f0a93b!important;color:#0a1219}
.dso-head{display:flex;align-items:center;gap:.7rem}.dso-head strong{font-size:1.5rem;letter-spacing:-.02em}
.dso-back{width:2.5rem;height:2.5rem;border-radius:50%;background:rgb(255 255 255/.06)!important;font-size:1.3rem}
.dso-q{display:flex;align-items:flex-start;gap:.7rem;padding:.85rem;border-radius:1.1rem;background:rgb(255 255 255/.045);box-shadow:inset 0 0 0 1px rgb(255 255 255/.07)}
.dso-q.is-warn{box-shadow:inset 0 0 0 1px rgb(240 169 59/.45)}
.dso-qi{display:grid;place-items:center;width:2rem;height:2rem;border-radius:50%;flex:none;font-weight:900;color:#0a1219;background:#8cc4ff}
.dso-q.is-ok .dso-qi{background:#34c38f}.dso-q.is-warn .dso-qi{background:#f0a93b}
.dso-qt{flex:1;min-width:0;display:flex;flex-direction:column;gap:.15rem}.dso-qt strong{font-size:.95rem}.dso-qt strong small{font-weight:500;color:#7f93a1;font-size:.75rem}.dso-qt>small{font-size:.75rem;color:#a9b8c2}
.dso-qt em{font-style:normal;font-size:.78rem;color:#f3c98a;line-height:1.4}
.dso-qs{display:flex;flex-direction:column;align-items:flex-end;gap:.35rem;font-size:.72rem;font-weight:700;color:#8cc4ff;white-space:nowrap}
.dso-q.is-ok .dso-qs{color:#34c38f}.dso-q.is-warn .dso-qs{color:#f0a93b}
.dso-qs button{padding:.25rem .55rem;border-radius:.5rem;background:rgb(255 255 255/.08)!important;color:#eef3f6;font-size:.72rem}
.dso-sending{display:flex;flex-direction:column;gap:.4rem;padding:.8rem 1rem;border-radius:1rem;background:rgb(52 195 143/.1)}.dso-sending i{display:block;height:6px;border-radius:999px;background:#34c38f;transition:width .4s}
.dso-warn{display:flex;gap:.6rem;padding:.75rem .9rem;border-radius:1rem;background:rgb(255 107 94/.08);box-shadow:inset 0 0 0 1px rgb(255 107 94/.25);font-size:.8rem;color:#f3c3bd;line-height:1.45}.dso-warn b{color:#ff8a7e}
.dso-empty{display:flex;flex-direction:column;gap:.5rem;padding:2.5rem 1.2rem;border-radius:1.5rem;background:rgb(255 255 255/.045);text-align:center}.dso-empty strong{font-size:1.15rem}.dso-empty p{margin:0;color:#7f93a1;line-height:1.5}
.dso-toast{position:fixed;top:calc(env(safe-area-inset-top) + 4.8rem);left:1rem;right:1rem;z-index:47;max-width:32rem;margin:0 auto;display:flex;align-items:center;gap:.7rem;padding:.7rem .7rem .7rem .9rem;border-radius:1.1rem;background:rgb(20 36 56/.97);box-shadow:0 16px 40px rgb(0 0 0/.4),inset 0 0 0 1px rgb(140 196 255/.4);animation:dso-in .3s ease-out}
.dso-toast.is-bad{background:rgb(40 18 20/.97);box-shadow:0 16px 40px rgb(0 0 0/.4),inset 0 0 0 1px rgb(255 107 94/.4)}
.dso-toast>span:first-child{display:grid;place-items:center;width:2rem;height:2rem;border-radius:50%;background:#8cc4ff;color:#0a1219;font-weight:900;flex:none}
.dso-toast.is-bad>span:first-child{background:#ff6b5e;color:#fff}
.dso-toast>span:nth-child(2){flex:1;display:flex;flex-direction:column}.dso-toast small{font-size:.75rem;opacity:.8}
.dso-toast button{height:2.3rem;padding:0 .8rem;border-radius:.7rem;background:rgb(255 255 255/.1)!important;font-weight:700}
.dso-label{margin:.2rem 0 -.4rem;font-size:.85rem;font-weight:700}.dso-label span{font-weight:400;color:#7f93a1}
.dso-next{display:flex;align-items:center;gap:.7rem;padding:.85rem .9rem;border-radius:1.1rem;background:rgb(246 190 0/.1);box-shadow:inset 0 0 0 1px rgb(246 190 0/.35)}
.dso-next>span{flex:1;min-width:0;display:flex;flex-direction:column}.dso-next small{font-size:.75rem;color:#f6d36b;font-weight:700}.dso-next strong{font-size:1.02rem}.dso-next em{font-style:normal;font-size:.8rem;color:#a9b8c2}
.dso-next button{height:2.6rem;padding:0 1rem;border-radius:.75rem;background:#f6be00!important;color:#0a1219!important;font-weight:800}
.dso-stops{display:flex;flex-direction:column;border-radius:1.1rem;background:rgb(255 255 255/.045);overflow:hidden}
.dso-stop{display:flex;align-items:center;gap:.65rem;padding:.7rem .8rem;border-top:1px solid rgb(255 255 255/.06)}.dso-stop:first-child{border-top:0}
.dso-no{width:1.9rem;height:1.9rem;flex:none;border-radius:50%;display:grid;place-items:center;font-weight:900;font-size:.82rem;background:rgb(255 255 255/.1)}.dso-no.is-prio{box-shadow:0 0 0 2px #d9534a}
.dso-stopt{flex:1;min-width:0;display:flex;flex-direction:column}.dso-stopt strong{font-size:.92rem}.dso-stopt small{font-size:.75rem;color:#a9b8c2}.dso-stopt em{font-style:normal;font-size:.72rem;color:#f3c98a}
.dso-go{height:2.1rem;padding:0 .7rem;border-radius:.6rem;background:rgb(140 196 255/.14)!important;color:#8cc4ff!important;font-size:.8rem;font-weight:800}.dso-go.is-dim{background:rgb(255 255 255/.06)!important;color:#7f93a1!important}
.dso-navtip{margin:0;padding:.6rem .75rem;border-radius:.75rem;background:rgb(140 196 255/.1);font-size:.82rem;color:#c9e2ff;line-height:1.45}
.dso-app{display:flex;align-items:center;gap:.75rem;height:3.6rem;padding:0 .9rem;border-radius:.9rem;background:rgb(255 255 255/.07)!important;text-align:left;font-size:1.2rem}
.dso-app.is-dim{background:rgb(255 255 255/.03)!important;color:#7f93a1}
.dso-app>span{flex:1;display:flex;flex-direction:column;font-size:1rem}.dso-app small{font-size:.75rem}.dso-app small.is-ok{color:#6fd6ad}
.dso-app i{width:2.4rem;height:2.4rem;flex:none;border-radius:.7rem;display:grid;place-items:center;font-style:normal;font-weight:900;font-size:1.1rem}
.dso-app .is-google{background:#fff;color:#1a73e8}.dso-app .is-apple{background:#e9eef2;color:#0e2433}.dso-app .is-waze{background:#33ccff;color:#0a1219}.dso-app.is-dim .is-waze{opacity:.45}
.dso-two{display:grid;grid-template-columns:1fr 1fr;gap:.5rem}
@keyframes dso-in{from{transform:translateY(-60%);opacity:0}to{transform:none;opacity:1}}
.dso-camera{position:fixed;inset:0;background:#000;display:flex;flex-direction:column;justify-content:flex-end;padding:1.5rem}
.dso-camera video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.dso-frame{position:absolute;left:12%;right:12%;top:30%;height:22%;border:3px solid #fff;border-radius:1rem;box-shadow:0 0 0 999px rgb(0 0 0/.35)}
.dso-camera .dso-primary{position:relative}
`;
    const style = document.createElement('style');
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
})();
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- resources/js/photo-viewer.js
mkdir -p 'resources/js'
cat > 'resources/js/photo-viewer.js' <<'DISPATCH_FILE_END_7'
/*
 * Part 42 · Check photos (board 68), in every app.
 *
 * window.dsPhotoViewer.open(list, index, opts)  full screen: zoom (pinch, double-tap, button),
 *     swipe or ‹ › for the next, ✕ to go back. opts.onDelete(i) / opts.onRetake(i) add the buttons.
 * window.dsPhotoCheck(file, { auto })  the photo big, right after it is taken: Retake or Use photo
 *     (used by itself after `auto` seconds, 0 = wait for a tap). Resolves 'use' or 'retake'.
 * Any <img data-ds-photo> inside [data-ds-gallery] opens the viewer for that gallery on a tap.
 * While a viewer is open, the barcode scanner rests (it never reads a box behind the photo).
 */
(function () {
    if (window.dsPhotoViewer) return;

    const css = `
.dspv{position:fixed;inset:0;z-index:90;background:#05090d;color:#eef3f6;display:flex;flex-direction:column;font-family:Archivo,system-ui,sans-serif;touch-action:none;-webkit-tap-highlight-color:transparent}
.dspv__top{display:flex;align-items:center;justify-content:space-between;gap:.6rem;padding:max(.8rem,env(safe-area-inset-top)) 1rem .6rem}
.dspv__x{width:2.6rem;height:2.6rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:1.15rem;color:#fff}
.dspv__pill{padding:.25rem .7rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:.8rem;font-weight:800}
.dspv__stage{position:relative;flex:1;overflow:hidden;display:flex;align-items:center;justify-content:center}
.dspv__img{max-width:100%;max-height:100%;object-fit:contain;transform-origin:center;transition:transform .15s ease-out;user-select:none;-webkit-user-drag:none}
.dspv__img.is-moving{transition:none}
.dspv__nav{position:absolute;top:50%;margin-top:-1.4rem;width:2.8rem;height:2.8rem;border-radius:99px;background:rgb(0 0 0/.45);color:#fff;font-size:1.4rem}
.dspv__nav.is-prev{left:.6rem}.dspv__nav.is-next{right:.6rem}
.dspv__hint{position:absolute;left:0;right:0;bottom:.7rem;text-align:center;font-size:.75rem;color:#cfd8de;pointer-events:none}
.dspv__cd{position:absolute;top:.7rem;right:.7rem;padding:.25rem .7rem;border-radius:99px;background:rgb(0 0 0/.55);font-size:.8rem;font-weight:800}
.dspv__bar{display:grid;gap:.5rem;padding:.7rem 1rem max(1rem,env(safe-area-inset-bottom))}
.dspv__bar.is-3{grid-template-columns:repeat(3,1fr)}.dspv__bar.is-2{grid-template-columns:1fr 1.4fr}.dspv__bar.is-1{grid-template-columns:1fr}
.dspv__btn{height:3.3rem;border-radius:1rem;background:rgb(255 255 255/.1);color:#fff;font-weight:800;font-size:1rem}
.dspv__btn.is-use{background:#3ddc97;color:#0a1219}.dspv__btn.is-del{background:rgb(200 55 45/.28);color:#ff8a80}
[data-ds-photo]{cursor:zoom-in}`;

    let root = null;
    let keyHandler = null;
    let wasPaused = null;

    function scanner(paused) {
        window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { paused } }));
    }
    /** The scanner rests while a photo is open, and goes back to how it was after. */
    function rest() {
        wasPaused = window.dsScanner ? !!window.dsScanner.paused : null;
        scanner(true);
    }

    function el(tag, cls, html) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (html != null) e.innerHTML = html;
        return e;
    }

    function close() {
        if (!root) return;
        root.remove();
        root = null;
        if (keyHandler) document.removeEventListener('keydown', keyHandler);
        keyHandler = null;
        document.documentElement.style.overflow = '';
        if (wasPaused === false) scanner(false);
        wasPaused = null;
    }

    /** Pinch, drag and double-tap zoom on one image; swipe calls onSwipe(-1|1) when not zoomed. */
    function zoomable(img, stage, onSwipe, onZoom) {
        let z = 1, x = 0, y = 0;
        const pts = new Map();
        let start = null;
        let lastTap = 0;
        const apply = () => { img.style.transform = `translate(${x}px, ${y}px) scale(${z})`; onZoom && onZoom(z); };
        const set = (nz) => { z = Math.min(4, Math.max(1, nz)); if (z === 1) { x = 0; y = 0; } apply(); };
        stage.addEventListener('pointerdown', (e) => {
            stage.setPointerCapture && stage.setPointerCapture(e.pointerId);
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            img.classList.add('is-moving');
            if (pts.size === 1) {
                start = { x: e.clientX, y: e.clientY, ox: x, oy: y, t: Date.now() };
                if (Date.now() - lastTap < 300) { set(z > 1 ? 1 : 2.5); lastTap = 0; } else lastTap = Date.now();
            } else if (pts.size === 2) {
                const [a, b] = [...pts.values()];
                start = { d: Math.hypot(a.x - b.x, a.y - b.y), z };
            }
        });
        stage.addEventListener('pointermove', (e) => {
            if (!pts.has(e.pointerId) || !start) return;
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            if (pts.size === 2 && start.d) {
                const [a, b] = [...pts.values()];
                z = Math.min(4, Math.max(1, start.z * Math.hypot(a.x - b.x, a.y - b.y) / start.d));
                apply();
            } else if (pts.size === 1 && z > 1) {
                x = start.ox + e.clientX - start.x; y = start.oy + e.clientY - start.y; apply();
            }
        });
        const up = (e) => {
            const p = pts.get(e.pointerId);
            pts.delete(e.pointerId);
            img.classList.remove('is-moving');
            if (pts.size === 0 && start && start.x != null && z === 1 && p) {
                const dx = p.x - start.x;
                if (Math.abs(dx) > 60 && Date.now() - start.t < 600 && onSwipe) onSwipe(dx < 0 ? 1 : -1);
            }
            if (pts.size === 0) { start = null; if (z <= 1.05) set(1); }
        };
        stage.addEventListener('pointerup', up);
        stage.addEventListener('pointercancel', up);
        return { zoomStep() { set(z >= 3 ? 1 : z + 1); }, reset() { set(1); } };
    }

    function mount() {
        if (!document.getElementById('dspv-css')) {
            const s = el('style'); s.id = 'dspv-css'; s.textContent = css; document.head.appendChild(s);
        }
        close();
        root = el('div', 'dspv');
        root.setAttribute('role', 'dialog');
        root.setAttribute('aria-modal', 'true');
        document.body.appendChild(root);
        document.documentElement.style.overflow = 'hidden';
        return root;
    }

    window.dsPhotoViewer = {
        /** list: [{ src, label? }] or [src, …] */
        open(list, index = 0, opts = {}) {
            const items = (list || []).map((p) => (typeof p === 'string' ? { src: p } : p)).filter((p) => p && p.src);
            if (!items.length) return;
            let i = Math.min(Math.max(0, index), items.length - 1);
            const r = mount();
            rest();
            const top = el('div', 'dspv__top');
            const x = el('button', 'dspv__x', '✕'); x.type = 'button'; x.setAttribute('aria-label', 'Close');
            const count = el('b');
            const zl = el('span', 'dspv__pill', 'Fit');
            top.append(x, count, zl);
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo'; img.draggable = false;
            const prev = el('button', 'dspv__nav is-prev', '‹'); prev.type = 'button'; prev.setAttribute('aria-label', 'Previous photo');
            const next = el('button', 'dspv__nav is-next', '›'); next.type = 'button'; next.setAttribute('aria-label', 'Next photo');
            const hint = el('span', 'dspv__hint', 'Pinch or double-tap to zoom' + (items.length > 1 ? ' · swipe for the next' : ''));
            stage.append(img, prev, next, hint);
            const btns = [['🔍 Zoom', '', () => z.zoomStep()]];
            if (opts.onRetake) btns.push(['↺ Retake', '', () => { const k = i; close(); opts.onRetake(k); }]);
            if (opts.onDelete) btns.push(['🗑 Delete', 'is-del', () => { const k = i; close(); opts.onDelete(k); }]);
            const bar = el('div', 'dspv__bar is-' + btns.length);
            btns.forEach(([t, c, f]) => { const b = el('button', 'dspv__btn ' + c, t); b.type = 'button'; b.addEventListener('click', f); bar.appendChild(b); });
            r.append(top, stage, bar);

            const show = () => {
                img.src = items[i].src;
                count.textContent = items.length > 1 ? `${i + 1} of ${items.length}` : (items[i].label || 'Photo');
                prev.style.display = i > 0 ? '' : 'none';
                next.style.display = i < items.length - 1 ? '' : 'none';
                z && z.reset();
            };
            const go = (d) => { const n = i + d; if (n >= 0 && n < items.length) { i = n; show(); } };
            const z = zoomable(img, stage, go, (v) => { zl.textContent = v > 1.05 ? `Zoom ${v.toFixed(1)}×` : 'Fit'; });
            prev.addEventListener('click', (e) => { e.stopPropagation(); go(-1); });
            next.addEventListener('click', (e) => { e.stopPropagation(); go(1); });
            prev.addEventListener('pointerdown', (e) => e.stopPropagation());
            next.addEventListener('pointerdown', (e) => e.stopPropagation());
            x.addEventListener('click', () => { close(); opts.onClose && opts.onClose(); });
            keyHandler = (e) => { if (e.key === 'Escape') { close(); opts.onClose && opts.onClose(); } else if (e.key === 'ArrowLeft') go(-1); else if (e.key === 'ArrowRight') go(1); };
            document.addEventListener('keydown', keyHandler);
            show();
        },
        close,
    };

    /** The photo big, right after it is taken: Retake or Use photo (used by itself after `auto` seconds). */
    window.dsPhotoCheck = function (file, opts = {}) {
        return new Promise((resolve) => {
            const r = mount();
            rest();
            const url = URL.createObjectURL(file);
            let left = Math.max(0, parseInt(opts.auto ?? 3, 10) || 0);
            let timer = null;
            const done = (what) => { clearInterval(timer); URL.revokeObjectURL(url); close(); resolve(what); };
            const top = el('div', 'dspv__top');
            top.append(el('b', '', opts.title || 'Check the photo'), el('span', 'dspv__pill', 'Pinch to zoom'));
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo you took'; img.src = url; img.draggable = false;
            const cd = el('span', 'dspv__cd');
            stage.append(img, cd);
            const bar = el('div', 'dspv__bar is-2');
            const re = el('button', 'dspv__btn', '↺ Retake'); re.type = 'button';
            const use = el('button', 'dspv__btn is-use', '✓ Use photo'); use.type = 'button';
            bar.append(re, use);
            r.append(top, stage, bar);
            zoomable(img, stage, null, (v) => { if (v > 1.05 && timer) { clearInterval(timer); timer = null; cd.textContent = 'Waiting for you'; } });
            re.addEventListener('click', () => done('retake'));
            use.addEventListener('click', () => done('use'));
            keyHandler = (e) => { if (e.key === 'Escape') done('retake'); if (e.key === 'Enter') done('use'); };
            document.addEventListener('keydown', keyHandler);
            if (left > 0) {
                cd.textContent = `Uses it in ${left} s`;
                timer = setInterval(() => { left -= 1; if (left <= 0) done('use'); else cd.textContent = `Uses it in ${left} s`; }, 1000);
            } else {
                cd.style.display = 'none';
            }
        });
    };

    // Any photo marked data-ds-photo opens the viewer with the photos of its gallery.
    document.addEventListener('click', (e) => {
        const t = e.target.closest && e.target.closest('[data-ds-photo]');
        if (!t || e.metaKey || e.ctrlKey || e.shiftKey) return;
        const g = t.closest('[data-ds-gallery]') || t.parentElement;
        const all = [...g.querySelectorAll('[data-ds-photo]')];
        const src = (n) => n.getAttribute('data-ds-photo') || n.getAttribute('href') || n.getAttribute('src') || (n.querySelector('img') && n.querySelector('img').src);
        e.preventDefault();
        window.dsPhotoViewer.open(all.map((n) => ({ src: src(n) })), all.indexOf(t), { onClose: () => g.dispatchEvent(new CustomEvent('ds-viewer-closed', { bubbles: true })) });
    });
})();
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- resources/views/filament/ai/check.blade.php
mkdir -p 'resources/views/filament/ai'
cat > 'resources/views/filament/ai/check.blade.php' <<'DISPATCH_FILE_END_8'
<x-filament-panels::page>
<div class="ds-ai">
    @include('filament.ai.paused', ['paused' => $paused])

    <div class="ds-ai__bar">
        <div class="ds-ai__seg">
            @foreach (['today' => 'Today', 'week' => '7 days', 'month' => '30 days'] as $k => $l)
                <button type="button" wire:click="$set('period', '{{ $k }}')" @class(['is-on' => $period === $k])>{{ $l }}</button>
            @endforeach
        </div>
    </div>

    <div class="ds-ai__stats">
        <div><small>Photos checked</small><b>{{ number_format($stats['checked']) }}</b><em>{{ $stats['waiting'] ? number_format($stats['waiting']).' waiting' : 'none waiting' }}</em></div>
        <div><small>Flagged</small><b class="is-red">{{ number_format($stats['flagged']) }}</b><em>looked damaged, wet, open or blurry</em></div>
        <div><small>Worker said Good</small><b class="is-amber">{{ number_format($stats['missed']) }}</b><em>the AI disagrees</em></div>
        <div><small>Decided</small><b class="is-green">{{ number_format($stats['decided']) }} <span>of {{ number_format($stats['flagged']) }}</span></b><em>by your staff</em></div>
    </div>

    <div class="ds-ai__split">
        <section class="ds-ai__card ds-ai__list">
            <div class="ds-ai__card-head">
                <b>To look at</b>
                <div class="ds-ai__seg is-small">
                    @foreach (['open' => 'Not decided', 'missed' => 'Worker said Good', 'delivery' => 'Delivery photos', 'all' => 'All'] as $k => $l)
                        <button type="button" wire:click="$set('show', '{{ $k }}')" @class(['is-on' => $show === $k])>{{ $l }}</button>
                    @endforeach
                </div>
            </div>
            @forelse ($list as $c)
                <button type="button" wire:key="c-{{ $c->id }}" wire:click="pick({{ $c->id }})" @class(['ds-ai__row', 'is-sel' => $cur?->id === $c->id])>
                    <img src="{{ $c->url() }}" alt="" loading="lazy">
                    <span class="ds-ai__row-main">
                        <span><b>{{ $c->invoice ?? 'No box number' }}</b> <i class="ds-ai__tag is-{{ $c->verdict }}">{{ $c->label() }} · {{ $c->confidence }}%</i></span>
                        <span>{{ $c->note }}</span>
                        <small>{{ \App\Models\Ai\AiPhotoCheck::stepLabel($c->step) }} · {{ $c->created_at->format('M j g:i A') }}@if ($c->source === 'scan') · worker said {{ ucfirst($c->worker_said ?: 'good') }}@endif</small>
                    </span>
                    <span class="ds-ai__state is-{{ $c->decision ?? 'open' }}">{{ ['damaged' => 'Issue opened', 'fine' => 'Looks fine'][$c->decision] ?? 'To decide' }}</span>
                </button>
            @empty
                <p class="ds-ai__empty">Nothing here. {{ $stats['checked'] ? 'Every checked photo looks fine.' : 'Photos are checked as staff take them.' }}</p>
            @endforelse
        </section>

        @if ($cur)
            <section class="ds-ai__card ds-ai__detail" wire:key="sel-{{ $cur->id }}">
                <a data-ds-photo href="{{ $cur->url() }}" target="_blank" rel="noopener" class="ds-ai__photo"><img src="{{ $cur->url() }}" alt="Photo of box {{ $cur->invoice }}"><span>{{ \App\Models\Ai\AiPhotoCheck::stepLabel($cur->step) }}</span></a>
                <div class="ds-ai__detail-head"><b>Box {{ $cur->invoice }}</b><small>{{ $cur->created_at->format('M j, g:i A') }}</small></div>
                <div class="ds-ai__said"><span class="ds-ai__badge">AI</span><span><b>{{ $cur->label() }} · {{ $cur->confidence }}% sure</b><small>{{ $cur->note ?: '—' }}</small></span></div>
                @if ($cur->source === 'scan')<p class="ds-board__muted">Worker marked it <b>{{ ucfirst($cur->worker_said ?: 'good') }}</b>.</p>@endif
                @if (! $cur->decision)
                    <div class="ds-ai__two">
                        <x-filament::button color="danger" wire:click="confirmDamaged">{{ $cur->source === 'delivery' ? 'Problem · open issue' : 'Damaged · open issue' }}</x-filament::button>
                        <x-filament::button color="gray" wire:click="looksFine">Looks fine</x-filament::button>
                    </div>
                @else
                    <p class="ds-ai__done is-{{ $cur->decision }}">
                        {{ $cur->decision === 'damaged' ? ($cur->invoiceissue_id ? 'Invoice Issue opened with this photo.' : 'Marked as damaged.') : 'Marked as fine.' }}
                        {{ $cur->decider?->full_name }} · {{ $cur->decided_at?->format('M j g:i A') }}
                        @unless ($cur->invoiceissue_id)<button type="button" wire:click="undoDecision" class="ds-ai__link">Undo</button>@endunless
                    </p>
                @endif
                <p class="ds-board__muted">The AI only suggests. Nothing changes until someone clicks.</p>
            </section>
        @endif
    </div>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- resources/views/filament/company/pages/track-box.blade.php
mkdir -p 'resources/views/filament/company/pages'
cat > 'resources/views/filament/company/pages/track-box.blade.php' <<'DISPATCH_FILE_END_9'
<x-filament-panels::page>
    <div class="ds-co">
        @if ($code !== '')
            <p class="ds-board__muted">Showing <strong>{{ $code }}</strong>. Scan or type another number below.</p>
        @endif
        <x-barcode-scanner method="scanCode" />

        @if ($code !== '' && ! $result)
            <div class="ds-co__empty">
                <x-filament::icon icon="heroicon-o-question-mark-circle" class="h-8 w-8" />
                <strong>{{ $code }} is not one of your hub's boxes</strong>
                <span>Check the number, or ask the main hub where it is.</span>
            </div>
        @elseif ($result)
            <div class="ds-co__track">
                <section class="ds-board__panel">
                    <h2 class="ds-co__h2">What happened</h2>
                    <ol class="ds-co__timeline">
                        @foreach ($result['events'] as $event)
                            <li @class(['is-'.$event['tone'] => $event['tone']])>
                                <span class="ds-co__dot" aria-hidden="true"></span>
                                <span class="ds-co__event">
                                    <strong>{{ $event['title'] }}</strong>
                                    @if ($event['detail']) <span>{{ $event['detail'] }}</span> @endif
                                    @if ($event['photo'] ?? null)
                                        <a data-ds-photo href="{{ $event['photo'] }}" target="_blank" rel="noopener"><img src="{{ $event['photo'] }}" alt="Photo: {{ $event['title'] }}" loading="lazy"></a>
                                    @endif
                                </span>
                                <time class="ds-board__muted">
                                    @if ($event['at'])
                                        {{ \Illuminate\Support\Carbon::parse($event['at'])->format(($event['dateOnly'] ?? false) ? 'M j' : 'M j, g:i A') }}
                                    @endif
                                </time>
                            </li>
                        @endforeach
                    </ol>
                </section>
                <aside class="ds-board__panel ds-co__boxcard">
                    <span @class(['ds-co__status', 'is-ok' => $result['status'] === 'Delivered'])>{{ $result['status'] }}</span>
                    <strong class="ds-co__boxno">{{ $result['box']?->invoice ?? $result['row']->invoice }}</strong>
                    @if ($result['box']?->boxtype) <span class="ds-board__muted">{{ $result['box']->boxtype }}</span> @endif
                    <dl>
                        <dt>Receiver</dt><dd>{{ $result['box']?->receiver_name }}</dd>
                        <dt>Address</dt><dd>{{ collect([$result['box']?->receiver_address, $result['box']?->receiver_barangay, $result['box']?->receiver_city, $result['box']?->receiver_province])->filter()->join(', ') }}</dd>
                        @if ($result['box']?->receiver_mobile_no)
                            <dt>Phone</dt><dd>{{ $result['box']->receiver_mobile_no }} <a href="tel:{{ preg_replace('/[^0-9+]/', '', $result['box']->receiver_mobile_no) }}">Call</a></dd>
                        @endif
                        <dt>Sender</dt><dd>{{ $result['box']?->sender_name }}</dd>
                    </dl>
                </aside>
            </div>
            <section class="ds-board__panel">
                <div class="ds-board__panel-head"><h2>Box photos</h2></div>
                @include('filament.partials.invoice-photos', ['items' => (new \App\Support\Photos\BoxAlbum(auth()->user()))->forInvoice($result['row']->invoice_id)])
            </section>
        @endif
    </div>
</x-filament-panels::page>
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- resources/views/filament/delivery-attempts.blade.php
mkdir -p 'resources/views/filament'
cat > 'resources/views/filament/delivery-attempts.blade.php' <<'DISPATCH_FILE_END_10'
{{-- Delivery history for one box (newest first): failed attempts and undone deliveries. --}}
<ol class="ds-attempts">
    @foreach ($attempts as $attempt)
        @php($isUndo = $attempt instanceof \App\Models\DeliveryReversal)
        <li @class(['ds-attempts__item', 'ds-attempts__item--undo' => $isUndo])>
            <div class="ds-attempts__head">
                @if ($isUndo)
                    <x-filament::badge color="warning" icon="heroicon-m-arrow-uturn-left">
                        Delivery undone · {{ $attempt->reason->getLabel() }}
                    </x-filament::badge>
                @else
                    <x-filament::badge :color="$attempt->reason->getColor()" :icon="$attempt->reason->getIcon()">
                        {{ $attempt->reason->getLabel() }}
                    </x-filament::badge>
                @endif
                <span class="ds-attempts__when">{{ $attempt->created_at->format('M j, Y · g:i A') }}</span>
            </div>

            <p class="ds-attempts__who">
                @if ($isUndo)
                    Undone by {{ $attempt->user?->full_name }} {{ $attempt->by_office ? '(office)' : '(driver)' }}
                    @if ($attempt->delivered_at)
                        · was marked delivered {{ $attempt->delivered_at->format('M j, g:i A') }}
                        @if ($attempt->deliverer) by {{ $attempt->deliverer->full_name }} @endif
                    @endif
                @else
                    {{ $attempt->user?->full_name }}
                @endif
                @if ($attempt->deliverylog)
                    · Trip {{ $attempt->deliverylog->trip_number }}
                @endif
            </p>

            @if ($attempt->note)
                <p class="ds-attempts__note">“{{ $attempt->note }}”</p>
            @endif

            @if ($attempt->photos)
                <div class="ds-attempts__photos">
                    @foreach ($attempt->photos as $photo)
                        <a data-ds-photo href="{{ Storage::disk('public')->url($photo) }}" target="_blank" rel="noopener">
                            <img src="{{ Storage::disk('public')->url($photo) }}" alt="Photo from this delivery">
                        </a>
                    @endforeach
                </div>
            @endif
        </li>
    @endforeach
</ol>
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- resources/views/filament/delivery/pages/dashboard.blade.php
mkdir -p 'resources/views/filament/delivery/pages'
cat > 'resources/views/filament/delivery/pages/dashboard.blade.php' <<'DISPATCH_FILE_END_11'
<x-filament-panels::page>
    {{-- Refresh every minute so new boxes and deliveries show without reloading. --}}
    <div wire:poll.60s class="ds-driver">

        @if (! $trip)
            {{-- Not on a trip --}}
            <section class="ds-driver__empty">
                <span class="ds-driver__empty-icon"><x-filament::icon icon="heroicon-o-truck" class="h-9 w-9" /></span>
                <h2>You're not on a trip right now</h2>
                <p>Ask your dispatcher to add you to a truck. Your boxes will show here as soon as the trip is loaded.</p>
                <x-filament::button wire:click="$refresh" icon="heroicon-m-arrow-path" color="gray" size="lg">
                    Check again
                </x-filament::button>
            </section>

        @elseif ($finished)
            {{-- All delivered --}}
            <section class="ds-driver__trip ds-driver__trip--done">
                <x-filament::icon icon="heroicon-o-check-circle" class="h-12 w-12" />
                <p class="ds-driver__done-title">All {{ $progress['total'] }} boxes delivered</p>
                <p class="ds-driver__done-sub">Trip {{ $trip->trip_number }} · {{ $trip->truck?->plate_no }}</p>
                <div class="ds-driver__bar"><span style="width: 100%"></span></div>
            </section>

            <section class="ds-driver__card">
                <h2>What's next</h2>
                <p>Drive back to the hub. Your dispatcher will close the trip and free the truck.</p>
            </section>

        @else
            {{-- Today's trip --}}
            <section class="ds-driver__trip" aria-label="Today's trip">
                <div class="ds-driver__trip-head">
                    <div>
                        <span class="ds-driver__muted">Trip</span>
                        <span class="ds-driver__trip-no">{{ $trip->trip_number }}</span>
                    </div>
                    <span class="ds-driver__pill">{{ $trip->is_current ? 'On the road' : 'Loading' }}</span>
                </div>

                <div class="ds-driver__trip-grid">
                    <div>
                        <span class="ds-driver__muted">Truck</span>
                        <strong>{{ $trip->truck?->plate_no ?? '—' }}</strong>
                        <span class="ds-driver__soft">{{ $trip->truck?->description }}</span>
                    </div>
                    <div>
                        <span class="ds-driver__muted">With you</span>
                        @forelse ($crew as $mate)
                            <strong>{{ $mate['name'] }}</strong>
                            <span class="ds-driver__soft">{{ $mate['role'] }}</span>
                        @empty
                            <strong>Just you</strong>
                        @endforelse
                    </div>
                </div>

                <div class="ds-driver__progress">
                    <div class="ds-driver__progress-head">
                        <span><strong>{{ $progress['delivered'] }}</strong> of {{ $progress['total'] }} delivered</span>
                        <span class="ds-driver__left">{{ $progress['left'] }} left</span>
                    </div>
                    <div class="ds-driver__bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="{{ $progress['percent'] }}">
                        <span style="width: {{ $progress['percent'] }}%"></span>
                    </div>
                    @if ($progress['notDelivered'])
                        <p class="ds-driver__warn">{{ $progress['notDelivered'] }} not delivered yet — check “My deliveries” for the reasons.</p>
                    @endif
                </div>
            </section>

            <div class="ds-driver__actions">
                <a href="{{ $deliveriesUrl }}" class="ds-driver__action ds-driver__action--primary">
                    <x-filament::icon icon="heroicon-o-qr-code" class="h-6 w-6" />
                    Scan a box
                </a>
                <a href="{{ $deliveriesUrl }}" class="ds-driver__action">
                    <x-filament::icon icon="heroicon-o-list-bullet" class="h-6 w-6" />
                    All boxes
                </a>
            </div>

            @if ($priority->isNotEmpty())
                <section class="ds-driver__section">
                    <h2>Priority boxes <span class="ds-driver__count">{{ $priority->count() }}</span></h2>
                    @foreach ($priority as $stop)
                        <x-driver.stop :stop="$stop" tone="priority" />
                    @endforeach
                </section>
            @endif

            @if ($areas->isNotEmpty())
                <section class="ds-driver__section" x-data="{ open: @js($areas->first()['key']) }">
                    <div class="ds-driver__section-head">
                        <h2>Where to go next</h2>
                        <span class="ds-driver__soft">{{ $areas->sum('boxes') }} boxes · {{ $areas->sum(fn ($a) => $a['stops']->count()) }} stops</span>
                    </div>
                    <div class="ds-driver__areas">
                        @foreach ($areas as $area)
                            <div class="ds-driver__area">
                                <button type="button" class="ds-driver__area-btn"
                                        x-on:click="open = open === @js($area['key']) ? null : @js($area['key'])"
                                        x-bind:aria-expanded="open === @js($area['key'])">
                                    <span class="ds-driver__area-name">
                                        <strong>{{ $area['city'] }}</strong>
                                        @if ($area['barangay'])
                                            <span>{{ $area['barangay'] }}</span>
                                        @endif
                                    </span>
                                    <span class="ds-driver__area-count">
                                        <strong>{{ $area['boxes'] }}</strong>
                                        <span>{{ trans_choice('{1} 1 stop|[2,*] :count stops', $area['stops']->count(), ['count' => $area['stops']->count()]) }}</span>
                                    </span>
                                    <x-filament::icon icon="heroicon-m-chevron-down" class="ds-driver__chev h-5 w-5" x-bind:class="{ 'is-open': open === {{ \Illuminate\Support\Js::from($area['key']) }} }" />
                                </button>
                                <div x-show="open === @js($area['key'])" x-collapse class="ds-driver__stops">
                                    @foreach ($area['stops'] as $stop)
                                        <x-driver.stop :stop="$stop" tone="soft" />
                                    @endforeach
                                </div>
                            </div>
                        @endforeach
                    </div>
                </section>
            @endif

            @if ($problems->isNotEmpty())
                <section class="ds-driver__section">
                    <h2>Check before handing over</h2>
                    @foreach ($problems as $stop)
                        <x-driver.stop :stop="$stop" tone="problem" :label="$stop['issue']">
                            @if ($stop['remarks'])
                                <span class="ds-stop__remark">{{ $stop['remarks'] }}</span>
                            @endif
                        </x-driver.stop>
                    @endforeach
                </section>
            @endif
        @endif

        @if ($trip && $delivered->isNotEmpty())
            <section class="ds-driver__section">
                <h2>Delivered today</h2>
                <p class="ds-driver__soft">You can undo your own delivery for 30 minutes. After that, ask the office.</p>
                <div class="ds-driver__list">
                    @foreach ($delivered as $box)
                        <div class="ds-driver__done-row">
                            @if ($box['photo'])
                                <a data-ds-photo href="{{ $box['photo'] }}" target="_blank" rel="noopener"><img src="{{ $box['photo'] }}" alt="Delivery photo for {{ $box['invoice'] }}"></a>
                            @else
                                <span class="ds-driver__nophoto" aria-hidden="true"><x-filament::icon icon="heroicon-o-camera" class="h-5 w-5" /></span>
                            @endif
                            <span class="ds-driver__done-text">
                                <strong>{{ $box['invoice'] }}</strong>
                                <span>{{ $box['name'] }}</span>
                            </span>
                            <span class="ds-driver__done-when">
                                <span class="ds-driver__ok">Delivered {{ $box['time'] }}</span>
                                @if ($box['undoMinutesLeft'])
                                    <span class="ds-driver__undo">
                                        {{ ($this->undoDeliveryAction)(['tripinvoice' => $box['id']]) }}
                                        <span>{{ $box['undoMinutesLeft'] }} min left</span>
                                    </span>
                                @else
                                    <span class="ds-driver__locked">
                                        <x-filament::icon icon="heroicon-m-lock-closed" class="h-3.5 w-3.5" /> Office only
                                    </span>
                                @endif
                            </span>
                        </div>
                    @endforeach
                </div>
            </section>
        @endif
    </div>
</x-filament-panels::page>
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
        view(i, urls) { window.dsPhotoViewer && window.dsPhotoViewer.open(urls, i, { onDelete: (k) => \$wire.removePhoto(k), onRetake: (k) => \$wire.removePhoto(k).then(() => this.take()) }) },
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

            @if ($seaCard)
                {{-- board 62: one trip for the truck, with every hub it carries --}}
                <div class="ds-sea">
                    <small>{{ $seaCard['code'] }} · {{ count($seaCard['hubs']) }} {{ \Illuminate\Support\Str::plural('trip', count($seaCard['hubs'])) }} · {{ $seaCard['total'] }} boxes</small>
                    <b>To {{ $seaCard['to'] }}</b>
                    <span class="ds-sea__hubs">@foreach ($seaCard['hubs'] as $h)<i>{{ $h['name'] }} {{ $h['n'] }}</i>@endforeach</span>
                    <a href="{{ \App\Filament\Delivery\Pages\AtPort::getUrl() }}" class="ds-sa__primary ds-sea__btn">{{ $seaCard['counted'] !== null ? 'Counted '.$seaCard['counted'].' · change' : ($seaCard['lcl'] ? 'Arrived at the forwarder' : 'Arrived at port') }}</a>
                    <small>{{ $seaCard['lcl'] ? 'Then: count the boxes, photo of the forwarder receipt and waybill.' : 'Then: count the boxes, photo of the port receipt.' }}</small>
                </div>
            @endif
            @if ($roro)
                {{-- board 62: our truck rides the ship and drops at each hub --}}
                <div class="ds-fd__home ds-roro">
                    <span aria-hidden="true">⛴️</span>
                    <span><b>RoRo · {{ $roro['code'] }}</b><small>{{ $roro['now'] }}</small></span>
                </div>
                @if ($roro['next'])
                    <button type="button" class="ds-sa__primary ds-roro__btn" wire:click="roroStep('{{ $roro['next'][0] }}')" wire:confirm="{{ $roro['next'][1] }}?">{{ $roro['next'][1] }}</button>
                @endif
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
                        <button type="button" class="ds-sa__round" x-show="scanning && cameras.length > 1" x-on:click.stop="listCameras(true).then(() => camList = ! camList)" x-bind:class="{ 'is-on': camList }" aria-label="Switch camera" x-cloak><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><path d="M9.5 12.5a2.6 2.6 0 0 1 4.6-1.4M14.5 14a2.6 2.6 0 0 1-4.6 1.4"/><path d="m14.4 9.6-.1 1.7-1.6-.2M9.6 16.4l.1-1.7 1.6.2"/></svg></button>
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
                    @if ($otherCode)
                        <div class="ds-dr__other" role="status"><span><b>Another box read: {{ $otherCode }}</b><small>This delivery stays open.</small></span><button type="button" wire:click="openOther">Open it</button><button type="button" class="is-x" wire:click="$set('otherCode', null)" aria-label="Stay on this box">✕</button></div>
                    @endif
                    <div class="ds-dr__grid is-big" x-data="{{ $photoJs }}">
                        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                        @foreach ($photoUrls as $i => $url)
                            <span class="ds-dr__proof" wire:key="ph-{{ $i }}-{{ md5($url) }}"><img src="{{ $url }}" alt="Photo {{ $i + 1 }}" x-on:click="view({{ $i }}, @js(array_values($photoUrls)))"><b>{{ $i + 1 }} / {{ count($photoUrls) }}</b><em x-on:click="view({{ $i }}, @js(array_values($photoUrls)))">⤢ Open</em><button type="button" wire:click="removePhoto({{ $i }})" aria-label="Remove photo {{ $i + 1 }}">✕</button></span>
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
                    @if ($otherCode)
                        <div class="ds-dr__other" role="status"><span><b>Another box read: {{ $otherCode }}</b><small>This box stays open.</small></span><button type="button" wire:click="openOther">Open it</button><button type="button" class="is-x" wire:click="$set('otherCode', null)" aria-label="Stay on this box">✕</button></div>
                    @endif
                    <div class="ds-sa__photos" x-data="{{ $photoJs }}">
                        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                        @foreach ($photoUrls as $i => $url)
                            <span class="ds-sa__shot ds-dr__proof is-small"><img src="{{ $url }}" alt="Photo {{ $i + 1 }}" x-on:click="view({{ $i }}, @js(array_values($photoUrls)))"><button type="button" wire:click="removePhoto({{ $i }})" aria-label="Remove photo">✕</button></span>
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

            @if ($sheet === 'which' && $which)
                {{-- board 57: two boxes with one number on the truck; pick the receiver on the sticker --}}
                <div class="ds-sa__sheet ds-which" wire:key="which-{{ $whichCode }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-which__head"><span>{{ count($which) }}</span><span><strong>{{ count($which) }} boxes have number {{ $whichCode }}</strong><small>Which one? Look at the receiver on the sticker.</small></span></div>
                    @foreach ($which as $w)
                        <button type="button" class="ds-which__opt" wire:click="pickBox({{ $w['id'] }})" wire:key="w-{{ $w['id'] }}">
                            <span><strong>{{ $w['name'] }}</strong>@if ($w['place'])<small>{{ $w['place'] }}</small>@endif @if ($w['sender'])<em>from {{ $w['sender'] }}</em>@endif</span><b>›</b>
                        </button>
                    @endforeach
                    <button type="button" class="ds-sa__secondary" wire:click="closeSheet">Not this box · scan again</button>
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

# ---------------------------------------------------------------- resources/views/filament/delivery/pages/fuel.blade.php
mkdir -p 'resources/views/filament/delivery/pages'
cat > 'resources/views/filament/delivery/pages/fuel.blade.php' <<'DISPATCH_FILE_END_13'
@php
    $peso = fn ($n, $d = 2) => '₱'.number_format((float) $n, $d);
    $photoJs = "{ busy: false, failed: false, pct: 0,
        take() { this.failed = false; this.\$refs.file.value = ''; this.\$refs.file.click() },
        async send(e) {
            const file = e.target.files[0]; if (! file) return;
            this.busy = true; this.pct = 0;
            const out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
            await new Promise(done => \$wire.upload('upload', out, () => \$wire.savePhoto().then(done), () => { this.failed = true; done() }, (ev) => { this.pct = ev.detail.progress }));
            this.busy = false;
        } }";
    $placeJs = "{ init() { if (navigator.geolocation) navigator.geolocation.getCurrentPosition(p => \$wire.setPlace(p.coords.latitude, p.coords.longitude), () => {}, { enableHighAccuracy: true, timeout: 15000, maximumAge: 120000 }) } }";
@endphp
<x-filament-panels::page>
<div class="ds-sa ds-dr ds-fd" x-data="{{ $placeJs }}">
    <section class="ds-sa__screen" wire:key="fuel-{{ $step }}">
        <header class="ds-fd__top">
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-fd__back" aria-label="Back to today">‹</a>
            <span><small>{{ $truck ? 'Truck '.$truck->plate_no.($truck->fuel_type ? ' · '.ucfirst($truck->fuel_type) : '') : 'No truck yet' }}</small><strong>Add fuel</strong></span>
            <span class="ds-fd__dots" aria-hidden="true">
                @foreach (['receipt', 'check', 'odometer'] as $s)<i @class(['is-on' => $step === $s, 'is-done' => array_search($step, ['receipt', 'check', 'odometer', 'done']) > $loop->index])></i>@endforeach
            </span>
        </header>

        @if ($cash && ! $cash->settled_at)
            <div class="ds-fd__cash">💵 Fuel cash for this trip <b>{{ $peso($cash->given, 0) }}</b> · left <b>{{ $peso($cash->left(), 0) }}</b><small>Use the fuel card first. Cash only if the card can't be used.</small></div>
        @endif

        {{-- ============ 1. receipt ============ --}}
        @if ($step === 'receipt')
            <div class="ds-fd__intro">
                <span class="ds-fd__big" aria-hidden="true">🧾</span>
                <strong>Take a photo of the receipt</strong>
                <p>Lay it flat, all of it in the photo: station, liters, price, total, VAT.{{ $aiOn ? ' The numbers are read for you.' : '' }}</p>
                @if ($companyTin)<p class="ds-fd__tin">For ₱1,000 and up, show the cashier the company card so they write <b>{{ $companyName ?: 'the company name' }}</b> and <b>TIN {{ $companyTin }}</b> on the receipt.</p>@endif
            </div>
            <div x-data="{{ $photoJs }}" class="ds-fd__actions">
                <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                <button type="button" class="ds-sa__primary" x-on:click="take()" x-bind:disabled="busy">
                    <span x-show="! busy">📷 Take receipt photo</span>
                    <span x-show="busy" x-cloak>{{ $aiOn ? 'Reading the receipt…' : 'Saving…' }} <span x-text="pct < 100 ? pct + '%' : ''"></span></span>
                </button>
                <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                @error('upload')<p class="ds-sa__err">{{ $message }}</p>@enderror
                <button type="button" class="ds-dr__link" wire:click="noReceiptPhoto">No receipt · type it in</button>
            </div>
        @endif

        {{-- ============ 2. check ============ --}}
        @if ($step === 'check')
            @if ($receiptUrl)
                <a data-ds-photo href="{{ $receiptUrl }}" target="_blank" rel="noopener" class="ds-fd__thumb"><img src="{{ $receiptUrl }}" alt="Receipt"><span>{{ $aiRead ? '✨ Read from the photo · check it' : 'Type what the receipt says' }}</span></a>
            @endif
            @if ($wrongFuel)
                <div class="ds-fd__warn is-bad">⛽ This truck uses <b>{{ $truck->fuel_type }}</b>, the receipt says <b>{{ $f['fuel_type'] }}</b>. Check the receipt, or tell the office right away.</div>
            @endif
            @foreach ($problems as $p)<div class="ds-fd__warn">⚠ {{ $p }} Check the numbers.</div>@endforeach

            <div class="ds-fd__seg" role="radiogroup" aria-label="Fuel">
                @foreach (\App\Support\Fuel\Fuel::TYPES as $k => $label)
                    <button type="button" role="radio" aria-checked="{{ $f['fuel_type'] === $k ? 'true' : 'false' }}" wire:click="$set('f.fuel_type', '{{ $k }}')" @class(['is-on' => $f['fuel_type'] === $k])>{{ $label }}</button>
                @endforeach
            </div>
            @error('f.fuel_type')<p class="ds-sa__err">{{ $message }}</p>@enderror

            <div class="ds-fd__form">
                <label class="is-wide"><small>Station</small><input type="text" wire:model.blur="f.station" placeholder="Petron Imus"></label>
                <label class="is-wide"><small>Product</small><input type="text" wire:model.blur="f.product" placeholder="Diesel Max"></label>
                <label><small>Liters</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.liters" placeholder="0.00"></label>
                <label><small>Price per liter</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.price_per_liter" placeholder="₱"></label>
                <label class="is-wide is-total"><small>Total</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.total" placeholder="₱"></label>
                @error('f.liters')<p class="ds-sa__err">{{ $message }}</p>@enderror
                @error('f.total')<p class="ds-sa__err">{{ $message }}</p>@enderror
                <label><small>VATable sales</small><input type="text" inputmode="decimal" wire:model.blur="f.vatable" placeholder="₱"></label>
                <label><small>VAT 12%</small><input type="text" inputmode="decimal" wire:model.blur="f.vat" placeholder="₱"></label>
                <label><small>Invoice no.</small><input type="text" wire:model.blur="f.invoice_no"></label>
                <label><small>Date and time</small><input type="datetime-local" wire:model.blur="f.filled_at"></label>
            </div>

            @if ($needTin)
                <div class="ds-fd__ask">
                    <span>Is <b>TIN {{ $companyTin }}</b> written on the receipt?</span>
                    <span class="ds-fd__seg is-small">
                        <button type="button" wire:click="$set('f.buyer_tin_ok', '1')" @class(['is-on' => $f['buyer_tin_ok'] === '1'])>Yes</button>
                        <button type="button" wire:click="$set('f.buyer_tin_ok', '0')" @class(['is-on' => $f['buyer_tin_ok'] === '0'])>No</button>
                    </span>
                </div>
            @endif

            <div class="ds-fd__ask">
                <span>Paid with</span>
                <span class="ds-fd__seg is-small">
                    <button type="button" wire:click="$set('f.paid_with', 'card')" @class(['is-on' => $f['paid_with'] === 'card'])>💳 Fuel card</button>
                    <button type="button" wire:click="$set('f.paid_with', 'cash')" @class(['is-on' => $f['paid_with'] === 'cash'])>💵 Cash</button>
                </span>
            </div>
            @if ($f['paid_with'] === 'cash' && $cash && (float) $f['total'] > $cash->left() + 0.5)
                <div class="ds-fd__warn">This is more than the fuel cash left ({{ $peso($cash->left(), 0) }}).</div>
            @endif

            <button type="button" class="ds-sa__primary" wire:click="toOdometer">Next · odometer</button>
            <button type="button" class="ds-dr__link" wire:click="back">Take the receipt photo again</button>
        @endif

        {{-- ============ 3. odometer ============ --}}
        @if ($step === 'odometer')
            <div class="ds-fd__intro">
                <span class="ds-fd__big" aria-hidden="true">🚚</span>
                <strong>Photo of the odometer</strong>
                <p>The total km on the dashboard (not the trip meter). It shows how far the truck goes on a liter.</p>
            </div>
            <div x-data="{{ $photoJs }}" class="ds-fd__actions">
                <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                @if ($odometerUrl)<img src="{{ $odometerUrl }}" alt="Odometer" class="ds-fd__odo">@endif
                <button type="button" class="{{ $odometerUrl ? 'ds-sa__secondary' : 'ds-sa__primary' }}" x-on:click="take()" x-bind:disabled="busy">
                    <span x-show="! busy">📷 {{ $odometerUrl ? 'Take again' : 'Take odometer photo' }}</span>
                    <span x-show="busy" x-cloak>Saving… <span x-text="pct < 100 ? pct + '%' : ''"></span></span>
                </button>
                <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
            </div>
            <div class="ds-fd__form">
                <label class="is-wide is-total"><small>Odometer (km)</small><input type="text" inputmode="numeric" wire:model.live.debounce.600ms="f.odometer" placeholder="{{ $prevOdo ? 'last fill '.number_format($prevOdo) : '123456' }}"></label>
                @error('f.odometer')<p class="ds-sa__err">Type the km as a number.</p>@enderror
            </div>
            @if ($kmSince)
                <div class="ds-fd__kml"><span><small>Since the last fill</small><b>{{ number_format($kmSince) }} km</b></span><span><small>km per liter</small><b>{{ $kml }}</b></span></div>
            @elseif ($prevOdo && (int) $f['odometer'] > 0)
                <div class="ds-fd__warn">The last fill was at {{ number_format($prevOdo) }} km. Check the number.</div>
            @endif
            <button type="button" class="ds-sa__primary is-green" wire:click="save" wire:loading.attr="disabled">Save fill</button>
            <button type="button" class="ds-dr__link" wire:click="back">Back</button>
        @endif

        {{-- ============ done ============ --}}
        @if ($step === 'done' && $saved)
            <div class="ds-fd__intro">
                <span class="ds-fd__big is-ok" aria-hidden="true">✓</span>
                <strong>Fill saved</strong>
                <p>{{ rtrim(rtrim(number_format($saved->liters, 2), '0'), '.') }} L {{ $saved->fuel_type }} · {{ $peso($saved->total) }} · {{ $saved->paid_with === 'cash' ? 'cash' : 'fuel card' }}{{ $saved->km_per_liter ? ' · '.$saved->km_per_liter.' km/L' : '' }}</p>
                <p>Keep the paper receipt and give it to the office.</p>
            </div>
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-sa__primary ds-fd__btn">Back to today</a>
            <button type="button" class="ds-dr__link" wire:click="another">Add another fill</button>
        @endif
    </section>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- resources/views/filament/fuel/page.blade.php
mkdir -p 'resources/views/filament/fuel'
cat > 'resources/views/filament/fuel/page.blade.php' <<'DISPATCH_FILE_END_14'
@php
    $peso = fn ($n, $d = 0) => '₱'.number_format((float) $n, $d);
    $lit = fn ($n) => rtrim(rtrim(number_format((float) $n, 2), '0'), '.').' L';
    $t = $totals;
@endphp
<x-filament-panels::page>
<div class="ds-fu">
    <div class="ds-fu__top">
        <span class="ds-tm__tabs" role="tablist">
            @foreach (['trucks' => 'Trucks', 'fills' => 'Fills', 'alerts' => 'Alerts'.(count($alerts) ? ' · '.count($alerts) : ''), 'cards' => 'Fuel cards', 'prices' => 'Prices', 'vat' => 'VAT'] as $k => $label)
                <button type="button" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k]) role="tab" aria-selected="{{ $tab === $k ? 'true' : 'false' }}">{{ $label }}</button>
            @endforeach
        </span>
        <select wire:model.live="month" class="ds-fu__month" aria-label="Month">
            @foreach ($months as $k => $label)<option value="{{ $k }}">{{ $label }}</option>@endforeach
        </select>
    </div>

    <div class="ds-tm__stats is-five">
        <span class="ds-board__panel"><small>Spent</small><b>{{ $peso($t['spent']) }}</b><em>{{ $t['fills'] }} {{ str('fill')->plural($t['fills']) }}</em></span>
        <span class="ds-board__panel"><small>Liters</small><b>{{ $lit($t['liters']) }}</b><em>Diesel {{ $lit($t['diesel']) }} · Gasoline {{ $lit($t['gasoline']) }}</em></span>
        <span class="ds-board__panel"><small>VAT 12% on fuel</small><b>{{ $peso($t['vat']) }}</b><em @class(['is-bad' => $t['vatNoTin'] > 0])>{{ $t['vatNoTin'] > 0 ? '⚠ '.$peso($t['vatNoTin'], 2).' without your TIN' : 'from the receipts' }}</em></span>
        <span class="ds-board__panel"><small>Paid with</small><b>{{ 100 - $t['cashPct'] }}% card</b><em>{{ $t['cashPct'] }}% cash{{ $t['unsettled'] ? ' · '.$t['unsettled'].' cash not settled' : '' }}</em></span>
        <span class="ds-board__panel"><small>Fuel per box delivered</small><b>{{ $t['perBox'] ? $peso($t['perBox'], 2) : '—' }}</b><em>{{ number_format($t['boxes']) }} boxes · {{ $t['kml'] ? $t['kml'].' km/L' : 'km/L after 2 fills with odometer' }}</em></span>
    </div>

    {{-- ============================== trucks ============================== --}}
    @if ($tab === 'trucks')
        @if (count($alerts))
            <button type="button" class="ds-fu__alertbar" wire:click="setTab('alerts')">⚠ {{ count($alerts) }} {{ str('thing')->plural(count($alerts)) }} to check · {{ $alerts[0]['title'] }} <span aria-hidden="true">›</span></button>
        @endif
        <section class="ds-board__panel ds-fu__table">
            <div class="ds-fu__tr is-head is-trucks"><span>Truck</span><span>Liters</span><span>Spent</span><span>km per liter</span><span>₱ per km</span><span>Last fill</span></div>
            @forelse ($rows as $r)
                <button type="button" class="ds-fu__tr is-trucks" wire:click="showTruck({{ $r['truck']->id }})" wire:key="tr-{{ $r['truck']->id }}">
                    <span><b>{{ $r['truck']->plate_no }}</b> <small>{{ $r['truck']->description ?: $r['truck']->category }}{{ $r['truck']->fuel_type ? ' · '.$r['truck']->fuel_type : '' }}</small></span>
                    <span>{{ $r['fills'] ? $lit($r['liters']) : '—' }}</span>
                    <span>{{ $r['fills'] ? $peso($r['spent']) : '—' }}</span>
                    <span><b>{{ $r['kml'] ?? '—' }}</b>@if ($r['change'] !== null && abs($r['change']) >= 3) <em @class(['ds-fu__chg', 'is-bad' => $r['change'] <= -10])>{{ $r['change'] > 0 ? '▲' : '▼' }} {{ abs($r['change']) }}%</em>@endif</span>
                    <span>{{ $r['perKm'] ? $peso($r['perKm'], 2) : '—' }}</span>
                    <span><small>{{ $r['last'] ?? 'no fills this month' }}</small></span>
                </button>
            @empty
                <p class="ds-board__muted">No fills this month yet. Drivers add each fill in the Driver app: ⛽ Add fuel.</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== fills ============================== --}}
    @if ($tab === 'fills')
        @if ($truckName)
            <p class="ds-fu__filter">Showing <b>{{ $truckName }}</b> · <button type="button" wire:click="$set('truck', null)">show all trucks</button></p>
        @endif
        <section class="ds-fu__fills">
            @forelse ($fills as $f)
                <article class="ds-board__panel ds-fu__fill" wire:key="fill-{{ $f->id }}">
                    @if ($f->receiptUrl())<a data-ds-photo href="{{ $f->receiptUrl() }}" target="_blank" rel="noopener" class="ds-fu__photo"><img src="{{ $f->receiptUrl() }}" alt="Receipt" loading="lazy"></a>@else<span class="ds-fu__photo is-none">no photo</span>@endif
                    <span class="ds-fu__fillmain">
                        <b>{{ $f->truck?->plate_no }} · {{ $f->station ?: 'Station not read' }}</b>
                        <small>{{ $f->filled_at->format('M j, g:i A') }} · {{ $f->driver?->full_name ?? '—' }}{{ $f->trip ? ' · trip '.$f->trip->trip_number : '' }}</small>
                        <span class="ds-fu__chips">
                            <em @class(['is-bad' => $f->truck?->fuel_type && $f->fuel_type && $f->truck->fuel_type !== $f->fuel_type])>⛽ {{ $f->fuel_type ? ucfirst($f->fuel_type) : 'fuel ?' }}{{ $f->product ? ' · '.$f->product : '' }}</em>
                            <em>{{ $f->paid_with === 'cash' ? '💵 cash' : '💳 card'.($f->card_last4 ? ' ****'.$f->card_last4 : '') }}</em>
                            @if ($f->gps_ok === true)<em class="is-ok">📍 with the truck</em>@elseif ($f->gps_ok === false)<em class="is-bad">📍 {{ number_format($f->gps_distance_m / 1000, 1) }} km from the truck</em>@endif
                            @if ($f->km_per_liter)<em>{{ $f->km_since }} km · {{ $f->km_per_liter }} km/L</em>@endif
                            @if ($f->buyer_tin_ok === false)<em class="is-bad">⚠ your TIN missing</em>@elseif ($f->buyer_tin_ok === true)<em class="is-ok">✓ your TIN</em>@endif
                            @if ($f->ai_read)<em>✨ read by AI</em>@endif
                        </span>
                    </span>
                    <span class="ds-fu__fillnums">
                        <b>{{ $peso($f->total, 2) }}</b>
                        <small>{{ $lit($f->liters) }} × {{ $f->price_per_liter ? $peso($f->price_per_liter, 2) : '—' }}</small>
                        @if ($f->vat !== null)<small>VAT {{ $peso($f->vat, 2) }}</small>@endif
                        @if ($f->odometer)<small>Odo {{ number_format($f->odometer) }}</small>@endif
                    </span>
                </article>
            @empty
                <p class="ds-board__muted">No fills this month.</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== alerts ============================== --}}
    @if ($tab === 'alerts')
        <section class="ds-fu__alerts">
            @forelse ($alerts as $a)
                <div @class(['ds-fu__alert', 'is-red' => $a['kind'] === 'red']) wire:key="al-{{ $loop->index }}">
                    <span class="ds-fu__alerticon" aria-hidden="true">{{ $a['icon'] }}</span>
                    <span><b>{{ $a['title'] }}</b><small>{{ $a['text'] }}</small></span>
                    <small class="ds-fu__when">{{ $a['when'] }}</small>
                </div>
            @empty
                <p class="ds-board__muted">Nothing to check this month. 👍</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== fuel cards ============================== --}}
    @if ($tab === 'cards')
        <div class="ds-fu__two">
            <section class="ds-board__panel ds-fu__import">
                <h3>Import the fuel card statement</h3>
                <p class="ds-board__muted">Download the transactions from your fuel card website as <b>CSV</b> (Excel: File → Save As → CSV) and add the file here. Each charge is matched to a fill in the Driver app: same truck (by the card's last 4 digits or the plate), within 3 hours, same liters.</p>
                <ul class="ds-fu__where">
                    <li><b>Petron Fleet Card</b> · fleet.petron.com → statements</li>
                    <li><b>Shell Fleet Card</b> · Shell Fleet Hub → transactions</li>
                    <li><b>Caltex StarCard</b> · StarCard Online → reports</li>
                    <li><b>SEAOIL</b> · PriceLOCQ for Business → export</li>
                </ul>
                <form wire:submit="importStatement" class="ds-fu__form">
                    <select wire:model="provider" aria-label="Fuel card">
                        @foreach (\App\Support\Fuel\Fuel::PROVIDERS as $k => $label)<option value="{{ $k }}">{{ $label }}</option>@endforeach
                    </select>
                    <input type="file" wire:model="statementFile" accept=".csv,text/csv,text/plain">
                    <x-filament::button type="submit" wire:loading.attr="disabled" wire:target="statementFile,importStatement">Import</x-filament::button>
                </form>
                @error('statementFile')<p class="ds-fu__err">{{ $message }}</p>@enderror
                <p class="ds-board__muted">Set each truck's card (last 4 digits) in {{ $isAdmin ? 'Settings → Fuel' : 'Admin → Settings → Fuel' }}, so charges find their truck.</p>
            </section>
            <section class="ds-board__panel">
                @if ($statement)
                    <h3>{{ \App\Support\Fuel\Fuel::PROVIDERS[$statement->provider] ?? 'Statement' }} · {{ $statement->from?->format('M j') }}–{{ $statement->to?->format('M j') }} · {{ $statement->lines }} charges</h3>
                    <span class="ds-fu__counts">
                        <button type="button" wire:click="$set('lineStatus', '')" @class(['is-on' => $lineStatus === ''])>All</button>
                        @foreach (\App\Support\Fuel\FuelStatements::STATUS as $k => $label)
                            @if (($lineCounts[$k] ?? 0) > 0)
                                <button type="button" wire:click="$set('lineStatus', '{{ $k }}')" @class(['is-on' => $lineStatus === $k, 'is-bad' => $k !== 'matched'])>{{ $label }} · {{ $lineCounts[$k] }}</button>
                            @endif
                        @endforeach
                    </span>
                    <div class="ds-fu__lines">
                        @foreach ($lines as $l)
                            <div class="ds-fu__line" wire:key="ln-{{ $l->id }}">
                                <span><b>{{ $l->truck?->plate_no ?? ($l->plate ?: $l->card ?: '—') }}</b> <small>{{ $l->charged_at?->format('M j g:i A') }} · {{ $l->station }} · {{ $l->product }}</small></span>
                                <span>{{ $l->liters ? $lit($l->liters) : '' }} · {{ $peso($l->amount, 2) }}</span>
                                <em @class(['is-ok' => $l->status === 'matched', 'is-bad' => $l->status !== 'matched'])>{{ \App\Support\Fuel\FuelStatements::STATUS[$l->status] ?? $l->status }}{{ $l->status === 'liters_differ' && $l->fuelFill ? ' (app '.$lit($l->fuelFill->liters).')' : '' }}</em>
                            </div>
                        @endforeach
                    </div>
                    @if ($statements->count() > 1)
                        <p class="ds-board__muted">Earlier: @foreach ($statements as $s)@if ($s->id !== $statement->id)<button type="button" class="ds-fu__link" wire:click="$set('statementId', {{ $s->id }})">{{ $s->created_at->format('M j') }} ({{ $s->lines }})</button> @endif @endforeach</p>
                    @endif
                @else
                    <h3>No statement imported yet</h3>
                    <p class="ds-board__muted">After the first import, the charges and how they matched show here.</p>
                @endif
            </section>
        </div>
    @endif

    {{-- ============================== prices ============================== --}}
    @if ($tab === 'prices')
        <div class="ds-fu__two">
            <section class="ds-board__panel">
                <h3>This week's price · from {{ \App\Support\Fuel\Fuel::weekStart()->format('M j') }}</h3>
                <p class="ds-board__muted">The middle price of the receipts your drivers sent this week. Prices change every Tuesday. Used for the fuel cash estimate of a trip.</p>
                <div class="ds-fu__prices">
                    @foreach (['diesel' => 'Diesel', 'gasoline' => 'Gasoline'] as $k => $label)
                        <span><small>{{ $label }}</small><b>{{ $prices[$k]['price'] ? $peso($prices[$k]['price'], 2) : '—' }}</b><em>{{ $prices[$k]['from'] }}</em></span>
                    @endforeach
                </div>
                @if ($isAdmin)
                    <form wire:submit="savePrices" class="ds-fu__form">
                        <input type="text" inputmode="decimal" wire:model="priceDiesel" placeholder="Diesel ₱/L" aria-label="Diesel price">
                        <input type="text" inputmode="decimal" wire:model="priceGasoline" placeholder="Gasoline ₱/L" aria-label="Gasoline price">
                        <x-filament::button type="submit" color="gray">Set this week's price</x-filament::button>
                    </form>
                    <p class="ds-board__muted">Only needed when there are no receipts yet this week. Leave a box empty to use the receipts again.</p>
                @endif
            </section>
            <section class="ds-board__panel ds-fu__table">
                <div class="ds-fu__tr is-head is-weeks"><span>Week of</span><span>Diesel</span><span>Gasoline</span></div>
                @foreach ($weeks as $i => $w)
                    @php($prev = $weeks[$i + 1] ?? null)
                    <div class="ds-fu__tr is-weeks">
                        <span><b>{{ $w['week']->format('M j') }}</b></span>
                        @foreach (['diesel', 'gasoline'] as $k)
                            <span>{{ $w[$k] ? $peso($w[$k], 2) : '—' }}@if ($w[$k] && $prev && $prev[$k] && abs($w[$k] - $prev[$k]) >= 0.01) <em @class(['ds-fu__chg', 'is-bad' => $w[$k] > $prev[$k], 'is-ok' => $w[$k] < $prev[$k]])>{{ $w[$k] > $prev[$k] ? '▲' : '▼' }} {{ number_format(abs($w[$k] - $prev[$k]), 2) }}</em>@endif</span>
                        @endforeach
                    </div>
                @endforeach
            </section>
        </div>
    @endif

    {{-- ============================== VAT ============================== --}}
    @if ($tab === 'vat')
        @php($noTin = $fills->filter(fn ($f) => $f->buyer_tin_ok === false))
        <div class="ds-fu__vat">
            <span class="ds-board__panel"><small>VAT on fuel</small><b>{{ $peso($fills->sum('vat'), 2) }}</b><em>{{ $fills->whereNotNull('vat')->count() }} receipts · VATable {{ $peso($fills->sum('vatable'), 2) }}</em></span>
            <span class="ds-board__panel is-ok"><small>Can be claimed</small><b>{{ $peso($fills->sum('vat') - $noTin->sum('vat'), 2) }}</b><em>{{ $companyTin ? 'your company TIN on the receipt (or under ₱1,000)' : 'set your company TIN in Settings → Fuel' }}</em></span>
            <span @class(['ds-board__panel', 'is-bad' => $noTin->isNotEmpty()])><small>Company TIN missing</small><b>{{ $peso($noTin->sum('vat'), 2) }}</b><em>{{ $noTin->count() }} receipts of ₱1,000+ without your TIN</em></span>
            <a href="{{ $vatUrl }}" class="ds-fu__export">⬇ Excel for the accountant</a>
        </div>
        <section class="ds-board__panel ds-fu__table">
            <div class="ds-fu__tr is-head is-vat"><span>Date</span><span>Station · TIN</span><span>Invoice no.</span><span>VATable</span><span>VAT 12%</span><span>Total</span><span>Your TIN</span></div>
            @forelse ($fills as $f)
                <div class="ds-fu__tr is-vat" wire:key="vat-{{ $f->id }}">
                    <span>{{ $f->filled_at->format('M j') }}</span>
                    <span><b>{{ $f->station ?: '—' }}</b><small>{{ $f->station_tin ? 'TIN '.$f->station_tin : '' }}</small></span>
                    <span>{{ $f->invoice_no ?: '—' }}</span>
                    <span>{{ $f->vatable !== null ? $peso($f->vatable, 2) : '—' }}</span>
                    <span><b>{{ $f->vat !== null ? $peso($f->vat, 2) : '—' }}</b></span>
                    <span>{{ $peso($f->total, 2) }}</span>
                    <span>@if ($f->buyer_tin_ok === true)<em class="is-ok">✓ on receipt</em>@elseif ($f->buyer_tin_ok === false)<em class="is-bad">⚠ missing</em>@else<small>{{ $f->total < 1000 ? 'not needed' : '—' }}</small>@endif</span>
                </div>
            @empty
                <p class="ds-board__muted">No receipts this month.</p>
            @endforelse
        </section>
        <p class="ds-board__muted">Keep the paper receipts: card statements alone are not enough to claim VAT. Check the rules with your accountant.</p>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- resources/views/filament/pages/box-photo-settings.blade.php
mkdir -p 'resources/views/filament/pages'
cat > 'resources/views/filament/pages/box-photo-settings.blade.php' <<'DISPATCH_FILE_END_15'
<x-filament-panels::page>
    <form wire:submit="save" class="ds-tp ds-gm">
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Where staff can add photos</h2><span>photos so far</span></div>
            @foreach ($steps as $key => $label)
                <label class="ds-gm__check ds-ps__row" wire:key="pl-{{ $key }}">
                    <input type="checkbox" wire:model="places.{{ $key }}">
                    <span><b>{{ $label }}</b></span>
                    <small class="ds-board__muted">{{ number_format($byStep[$key] ?? 0) }}</small>
                </label>
            @endforeach
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Reminders and storage</h2></div>
            <div class="ds-gm__grid">
                <label class="ds-gm__field"><span>Batch photo reminder every … boxes (0 = off)</span><input type="number" min="0" wire:model="batchEvery"></label>
                <label class="ds-gm__field"><span>Keep photos for … months (0 = keep forever)</span><input type="number" min="0" wire:model="keepMonths"></label>
                <label class="ds-gm__field"><span>Scan app: use the photo by itself after … seconds (0 = wait for Use photo)</span><input type="number" min="0" max="10" wire:model="autoUse"></label>
            </div>
            <p class="ds-board__muted">Used now: {{ number_format($count) }} photos · {{ number_format($bytes / 1048576, 1) }} MB. Photos are made smaller (about 200 KB) before upload. Photos of a box with an open Invoice Issue are never deleted.</p>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Who sees the photos</h2></div>
            <p>Admin and warehouse staff: all photos. Partner hubs: photos of boxes sent to their hub, and photos they took.</p>
        </section>

        <div class="ds-gm__save"><x-filament::button type="submit">Save</x-filament::button></div>
    </form>
</x-filament-panels::page>
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- resources/views/filament/partials/scan-photo.blade.php
mkdir -p 'resources/views/filament/partials'
cat > 'resources/views/filament/partials/scan-photo.blade.php' <<'DISPATCH_FILE_END_16'
{{-- Optional box photos on a scan station. Photos are made smaller in the browser before upload. --}}
@if ($this->photosEnabled() && ($this->canPhotoBox() || $this->batchDue()))
    @php($photoBox = $this->canPhotoBox())
    <div class="ds-ph" wire:key="ph-{{ $lastInvoiceId }}-{{ $lastStatus }}"
         x-data="{
            busy: false, failed: false, pct: 0, batch: false,
            take(batch) { this.batch = batch; this.failed = false; this.$refs.file.value = ''; this.$refs.file.click() },
            async send(event) {
                const file = event.target.files[0];
                if (! file) return;
                this.busy = true; this.pct = 0;
                let out = file;
                out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
                $wire.upload('boxPhoto', out,
                    () => $wire.saveBoxPhoto(this.batch).then(() => { this.busy = false }),
                    () => { this.busy = false; this.failed = true },
                    (e) => { this.pct = e.detail.progress });
            },
         }">
        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">

        @if ($photoBox)
            <div class="ds-ph__cond" role="group" aria-label="How does the box look?">
                <span>How does the box look?</span>
                <div>
                    @foreach (\App\Models\BoxPhoto::CONDITIONS as $key => $label)
                        <button type="button" wire:click="setPhotoCondition('{{ $photoCondition === $key ? '' : $key }}')"
                                aria-pressed="{{ $photoCondition === $key ? 'true' : 'false' }}"
                                @class(['ds-ph__chip', 'is-'.$key, 'is-on' => $photoCondition === $key])>{{ $label }}</button>
                    @endforeach
                </div>
            </div>

            @if (in_array($photoCondition, ['damaged', 'wet', 'open'], true))
                <p class="ds-ph__tip">Tip: add a photo of this {{ \App\Models\BoxPhoto::CONDITIONS[$photoCondition] }} box. It is optional.</p>
                <input type="text" class="ds-ph__note" wire:model.blur="photoNote" maxlength="250" placeholder="What is wrong? (optional)" aria-label="What is wrong?">
            @endif

            @php($shots = $this->lastBoxPhotos())
            @if ($shots->isNotEmpty())
                <div class="ds-ph__shots">
                    @foreach ($shots as $shot)
                        <a data-ds-photo href="{{ $shot->url() }}" target="_blank" title="{{ $shot->fileName() }}"><img src="{{ $shot->url() }}" alt="Photo {{ $loop->iteration }} of {{ $shot->invoice }}" loading="lazy"></a>
                    @endforeach
                    <span>{{ $shots->count() }} {{ str('photo')->plural($shots->count()) }} saved</span>
                </div>
            @endif

            <button type="button" class="ds-ph__add" x-on:click="take(false)" x-bind:disabled="busy">
                <x-filament::icon icon="heroicon-o-camera" class="h-5 w-5" />
                <span x-show="! busy">{{ $shots->isEmpty() ? 'Add photo (optional)' : 'Add another photo' }}</span>
                <span x-show="busy" x-cloak>Saving photo… <span x-text="pct + '%'"></span></span>
            </button>
        @endif

        @if ($this->batchDue())
            <div class="ds-ph__batch">
                <span><strong>Batch photo?</strong> {{ $sinceBatch }} boxes since the last one.</span>
                <button type="button" x-on:click="take(true)" x-bind:disabled="busy">Take</button>
                <button type="button" class="is-skip" wire:click="skipBatch">Skip</button>
            </div>
        @endif

        <p class="ds-ph__err" x-show="failed" x-cloak>The photo did not upload. Check the signal and try again.</p>
    </div>
@endif
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- resources/views/filament/scan/app.blade.php
mkdir -p 'resources/views/filament/scan'
cat > 'resources/views/filament/scan/app.blade.php' <<'DISPATCH_FILE_END_17'
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

            @if (! $homeReady)
                <span class="hidden" wire:init="loadHome"></span>
            @endif
            @if ($resume)
                <button type="button" class="ds-sh__resume" wire:click="continueLast">
                    <span class="ds-sh__ring" style="--p: {{ $resume['pct'] }}"><b>{{ $resume['pct'] }}%</b></span>
                    <span class="ds-sh__resumetext"><small>Continue · {{ $resume['label'] }}</small><strong>{{ $resume['name'] }}</strong><small>{{ $resume['done'] }} of {{ $resume['total'] }} done · {{ $resume['total'] - $resume['done'] }} left</small></span>
                    <span class="ds-sh__go">Continue ›</span>
                </button>
            @endif
            <div class="ds-sh__stats">
                <span><b>{{ number_format($today['scans']) }}</b><small>scanned today</small></span>
                <span><b>{{ number_format($today['photos']) }}</b><small>photos</small></span>
                <span @class(['is-bad' => $today['problems'] > 0])><b>{{ $today['problems'] }}</b><small>{{ \Illuminate\Support\Str::plural('problem', $today['problems']) }}</small></span>
            </div>
            @if ($modes)
                @php
                    $tiles = collect($modes)->map(fn ($m, $key) => $m + ['key' => $key, 'n' => (int) ($waiting[$key] ?? 0)] + \App\Support\ScanModes::look($key));
                    $groups = $tiles->groupBy('group');
                    $groupOrder = ['Daily work', 'Between warehouses', 'Port and hubs', 'In the warehouse'];
                    $groups = $groups->sortBy(fn ($g, $name) => array_search($name, $groupOrder, true));
                @endphp
                @foreach ($groups as $name => $group)
                    <p class="ds-sa__label">{{ $name }}</p>
                    <div class="ds-sh__grid">
                        @foreach ($group->sortBy(fn ($t) => $homeReady && $t['n'] > 0 ? 0 : 1) as $t)
                            <button type="button" @class(['ds-sh__tile', 'is-done' => $homeReady && ! $t['n']]) style="--c: {{ $t['color'] }}" wire:click="open('{{ $t['key'] }}')" wire:key="tile-{{ $t['key'] }}">
                                <span class="ds-sh__chip">@include('filament.scan.icon', ['name' => $t['icon']])</span>
                                <strong>{{ $t['label'] }}</strong>
                                <small>{{ $t['sub'] }}</small>
                                <span @class(['ds-sh__badge', 'is-wait' => ! $homeReady, 'is-on' => $homeReady && $t['n']])>{{ ! $homeReady ? '···' : ($t['n'] ? $t['n'].' to do' : '✓') }}</span>
                            </button>
                        @endforeach
                    </div>
                @endforeach
            @else
                <div class="ds-sa__note">Your account can't scan here. Ask the office to set your account to Warehouse or Company.</div>
            @endif
            <div class="ds-sh__opening" wire:loading.flex wire:target="open,continueLast">
                <i></i><i></i><i></i><i></i><small>Opening…</small>
            </div>
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
                        <button type="button" class="ds-sa__round" x-show="scanning && cameras.length > 1" x-on:click.stop="listCameras(true).then(() => camList = ! camList)" x-bind:class="{ 'is-on': camList }" aria-label="Switch camera" x-cloak><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><path d="M9.5 12.5a2.6 2.6 0 0 1 4.6-1.4M14.5 14a2.6 2.6 0 0 1-4.6 1.4"/><path d="m14.4 9.6-.1 1.7-1.6-.2M9.6 16.4l.1-1.7 1.6.2"/></svg></button>
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

            @if (! empty($hubCounts))
                {{-- board 62: one truck for more hubs --}}
                <div class="ds-hc" aria-label="Boxes per hub">
                    @foreach ($hubCounts as $hc)<span @class(['is-done' => $hc['total'] && $hc['done'] >= $hc['total']])>{{ $hc['hub'] }} <b>{{ $hc['done'] }}/{{ $hc['total'] }}</b></span>@endforeach
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

            @if ($which)
                @include('filament.partials.which-box', ['which' => $which, 'phone' => true, 'choose' => 'chooseBox', 'cancel' => 'skipBox'])
            @endif

            @if ($this->mode === 'pick')
                @php($allPicked = ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total'])
                @php($nextGroup = collect($pickGroups)->first(fn ($g) => collect($g['boxes'])->contains(fn ($b) => ! $b['picked'] && ! $b['missing'])))
                @php($nextBox = $nextGroup ? collect($nextGroup['boxes'])->first(fn ($b) => ! $b['picked'] && ! $b['missing']) : null)
                @php($hereLeft = $nextGroup ? collect($nextGroup['boxes'])->filter(fn ($b) => ! $b['picked'] && ! $b['missing'])->count() : 0)
                @php($allLeft = max(0, ($progress['total'] ?? 0) - ($progress['loaded'] ?? 0)))
                {{-- board 55: the next box on the camera, a short message after each scan, the list in a pull-up sheet --}}
                @if ($nextBox)
                    <span class="ds-pk__next" wire:key="pk-next-{{ $nextBox['id'] }}">Next: {{ \Illuminate\Support\Str::before($nextGroup['name'], ' · ') }} · {{ $nextBox['code'] }}</span>
                @endif
                @if ($pickResult)
                    {{-- board 56: dark glass; Picked goes small after 4 s (📌 Keep holds it); yellow and red stay until OK or the next scan --}}
                    @php($tone = $pickResult['tone'])
                    <div class="ds-pk__msg" wire:key="pk-msg-{{ $pickSeq }}"
                         x-data="{ on: true, small: false, pinned: false, left: 4000, sticky: @js($tone !== 'ok') }"
                         x-init="window.dsResultSound && window.dsResultSound(@js($tone)); if (! sticky) { const t = setInterval(() => { if (pinned) return; left -= 250; if (left <= 0) { clearInterval(t); small = true; } }, 250); }">
                        <div @class(['ds-pk__toast', 'is-ok' => $tone === 'ok', 'is-warn' => $tone === 'warn', 'is-bad' => $tone === 'bad']) x-show="on && ! small" x-transition.opacity>
                            <span class="ds-pk__sign">{{ $tone === 'ok' ? '✓' : ($tone === 'bad' ? '✕' : '!') }}</span>
                            <span class="ds-pk__words"><b>{{ preg_replace('/^✕\s*/u', '', $pickResult['title']) }}</b><small>{{ $pickResult['code'] ? $pickResult['code'].' · ' : '' }}{{ $pickResult['why'] }}</small></span>
                            @if ($pickResult['undo'])
                                <button type="button" class="ds-pk__undo2" wire:click="undoPick({{ $pickResult['undo'] }})">↶ Undo</button>
                            @endif
                            @if ($tone !== 'ok')
                                <button type="button" class="ds-pk__ok" x-on:click="on = false">OK</button>
                            @endif
                        </div>
                        <div class="ds-pk__after" x-show="on && ! small">
                            <template x-if="! sticky && ! pinned"><span class="ds-pk__timer"><i x-bind:style="'width:' + (left / 40) + '%'"></i></span></template>
                            <small x-text="sticky ? 'Stays until the next scan or OK' : (pinned ? 'Kept on screen' : 'Goes small in 4 s')"></small>
                            <template x-if="! sticky"><button type="button" x-on:click="pinned = ! pinned" x-text="pinned ? 'Let it go' : '📌 Keep'"></button></template>
                        </div>
                        @if ($tone === 'ok')
                            <span class="ds-pk__last" x-show="on && small" x-cloak>
                                <b>Last: {{ $pickResult['code'] }} ✓</b>
                                @if ($pickResult['undo'])
                                    <button type="button" wire:click="undoPick({{ $pickResult['undo'] }})">↶ Undo</button>
                                @endif
                            </span>
                        @endif
                    </div>
                @endif
                <div class="ds-pk__sheet2" x-data="{ open: false }" x-bind:class="{ 'is-open': open }" wire:key="pk-sheet" wire:poll.6s.visible>
                    <button type="button" class="ds-pk__peek" x-on:click="open = ! open">
                        <span class="ds-sa__grab"></span>
                        <span class="ds-pk__peekrow">
                            <span>
                                @if ($allPicked)
                                    <b>✓ All {{ $progress['total'] }} boxes picked</b><small>Bring them to the truck</small>
                                @elseif ($nextGroup)
                                    <b>Next: {{ $nextGroup['name'] }}</b><small>{{ $hereLeft }} {{ \Illuminate\Support\Str::plural('box', $hereLeft) }} here · {{ $allLeft }} left in all</small>
                                @else
                                    <b>{{ $allLeft }} left</b><small>The rest are marked not found</small>
                                @endif
                            </span>
                            <em x-text="open ? 'Hide ˅' : 'List ˄'">List ˄</em>
                        </span>
                        <span class="ds-pk__bar"><i style="width: {{ ($progress['total'] ?? 0) ? round(($progress['loaded'] ?? 0) / $progress['total'] * 100) : 0 }}%"></i></span>
                    </button>
                    @if ($allPicked)
                        <button type="button" class="ds-sa__primary ds-pk__goload" wire:click="goLoad">Go to Load truck</button>
                    @endif
                    <div class="ds-pk__list" x-show="open" x-cloak>
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
                        <span><strong>{{ $box->invoice }}</strong><small>{{ $def['ok'] }}@if (preg_match('/ · (\d+) of (\d+)/', (string) $message, $sameM)) <b class="ds-which__of">{{ $sameM[1] }} of {{ $sameM[2] }} with this number</b>@endif</small></span>
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
                        <div @class(['ds-ld__spot', 'is-'.$spot['zone'], 'is-sea' => ! empty($spot['hub'])])><strong>{{ ! empty($spot['hub']) ? 'Put at the '.mb_strtoupper(\App\Models\Maps\TripStop::ZONES[$spot['zone']] ?? $spot['zone']) : (\App\Models\Maps\TripStop::ZONES[$spot['zone']] ?? '') }}</strong><span>{{ ! empty($spot['hub']) ? $spot['hub'].' (stop '.$spot['stop'].')' : 'Stop '.$spot['stop'] }} · {{ ['front' => 'deep inside, next to the cab', 'middle' => 'in the middle', 'back' => 'near the door'][$spot['zone']] ?? '' }}</span></div>
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

                        <div class="ds-sa__photos ds-snap" wire:ignore data-ds-gallery
                             x-data="{ rendered: @js($shots->pluck('id')->all()), inv: {{ (int) $box->id }}, code: @js($box->invoice), busy: false, msg: null,
                                mine() { return window.dsPhotos ? window.dsPhotos.of(this.inv).filter((i) => ! this.rendered.includes(i.serverId)) : [] },
                                info() { return { invoiceId: this.inv, code: this.code, condition: $wire.condition, note: $wire.note, url: @js(route('scan.box-photo')) } },
                                async here() {
                                    if (this.busy || ! window.dsScanner) return; this.busy = true; this.msg = null;
                                    const f = await window.dsScanner.snapPhoto();
                                    if (! f) { this.busy = false; this.msg = 'The camera is off. Use Camera app.'; return; }
                                    // Board 68: the photo big first · Retake or Use photo (used by itself after the set seconds)
                                    const said = window.dsPhotoCheck ? await window.dsPhotoCheck(f, { auto: {{ (int) \App\Models\AppSetting::get('photos.auto_use', 3) }} }) : 'use';
                                    this.busy = false;
                                    if (said === 'use') window.dsPhotos.add(f, this.info());
                                    else this.msg = 'Not saved. Aim and tap Take photo here again.';
                                },
                                app() { window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { release: true } })); this.$refs.file.value = ''; this.$refs.file.click() },
                                picked(e) { const f = e.target.files[0]; if (f) window.dsPhotos.add(f, this.info()) } }">
                            <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="picked($event)">
                            @foreach ($shots as $shot)
                                <span class="ds-sa__shot" data-ds-photo="{{ $shot->url() }}"><img src="{{ $shot->url() }}" alt="Photo {{ $loop->iteration }}"><b class="is-done">✓</b></span>
                            @endforeach
                            <template x-for="it in mine()" :key="it.id">
                                <span class="ds-sa__shot" x-bind:data-ds-photo="it.failed ? null : it.thumb" x-on:click="it.failed && window.dsPhotos.retry(it)"><img :src="it.thumb" alt="Photo"><b :class="{ 'is-done': it.done, 'is-bad': it.failed }" x-text="it.failed ? 'Retry' : (it.done ? '✓' : it.p + '%')"></b></span>
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
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- resources/views/filament/shipping/detail.blade.php
mkdir -p 'resources/views/filament/shipping'
cat > 'resources/views/filament/shipping/detail.blade.php' <<'DISPATCH_FILE_END_18'
@php
    $peso = fn ($n) => '₱'.number_format((float) $n, 2);
@endphp
<x-filament-panels::page>
<div class="ds-sp">
    @php
        $unit = $s->mode === 'lcl' ? 'LCL lot' : ($s->mode === 'roro' ? 'RoRo truck' : 'container');
        $to = $s->mode === 'lcl' ? 'the forwarder' : ($s->mode === 'roro' ? 'the ship' : 'the port');
        $allBoxes = (int) $stopBoxes->sum();
        $canMode = ! $hubSide && in_array($s->status, ['preparing', 'sealed'], true);
    @endphp
    {{-- board 62: what it is, and how it goes --}}
    <div class="ds-sv__head">
        <span><small>Sea shipment · {{ $s->port_from ?: 'Manila' }} → {{ $s->port_to ?: $s->hub?->hub_name }}</small>
            <b>{{ $stops->count() }} {{ \Illuminate\Support\Str::plural('trip', $stops->count()) }} · {{ $allBoxes }} boxes · {{ $trucks->count() ?: 1 }} {{ \Illuminate\Support\Str::plural('truck', $trucks->count() ?: 1) }} · {{ \App\Support\Shipping\Shipments::label($s) }}</b></span>
        <span class="ds-sv__modes" role="group" aria-label="How it is shipped">
            @foreach (['container' => 'Container', 'roro' => 'RoRo', 'lcl' => 'LCL'] as $mk => $ml)
                <button type="button" @class(['is-on' => $s->mode === $mk]) @if ($canMode) wire:click="setMode('{{ $mk }}')" @else disabled @endif>{{ $ml }}</button>
            @endforeach
        </span>
    </div>

    <section class="ds-board__panel ds-sp__steps">
        @foreach ($steps as $k => $label)
            @php
                $i = array_search($k, $stepKeys);
                $now = array_search($s->status, $stepKeys);
            @endphp
            <span @class(['ds-sp__step', 'is-done' => $i < $now, 'is-now' => $i === $now])><i></i><b>{{ $label }}</b><small>{{ $whenOf($k) ?? '' }}</small></span>
        @endforeach
    </section>

    <div class="ds-sp__head">
        <span class="ds-sp__track"><span aria-hidden="true">{{ $s->mode === 'roro' ? '⛴️' : ($s->mode === 'lcl' ? '📦' : '🚢') }}</span><span><b>{{ $track }}</b><small>What the receiver sees on tracking</small></span></span>
        <span class="ds-sp__acts">
            @if ($canPress)
                <x-filament::button wire:click="advance" :color="$blockers ? 'gray' : 'primary'">Mark: {{ $nextLabel }}</x-filament::button>
            @endif
            @if ($canReceive)
                <x-filament::button color="success" wire:click="finishReceiving" wire:confirm="Finish receiving{{ $stops->count() > 1 ? ' at '.$receiveStop?->hub?->hub_name : '' }}? Boxes not scanned in get an Invoice Issue each.">Finish receiving{{ $stops->count() > 1 ? ' · '.$receiveStop?->hub?->hub_name : '' }}{{ $nextAfter ? ' · pass on to '.$nextAfter : '' }}</x-filament::button>
            @endif
        </span>
    </div>

    @if ($canMode && $s->mode === 'container' && $allBoxes > 0 && $allBoxes < \App\Support\Shipping\Shipments::LCL_HINT)
        <div class="ds-sv__hint"><span>Few boxes ({{ $allBoxes }}): LCL with a forwarder may cost less than a whole container.</span><button type="button" class="ds-fu__link" wire:click="setMode('lcl')">Send as LCL</button></div>
    @endif

    {{-- the key details of this kind --}}
    @if ($s->mode === 'lcl' && ! $hubSide)
        <section class="ds-board__panel ds-sp__box ds-sv__lcl">
            <h3>LCL · with a forwarder (no van, no seal)</h3>
            <span class="ds-sv__lbl">Forwarder</span>
            <span class="ds-sv__chips">
                @foreach ($forwarders as $fw)
                    <button type="button" @class(['is-on' => (string) $fw->id === (string) ($f['forwarder_id'] ?? '')]) wire:click="pickForwarder({{ $fw->id }})" wire:key="fw-{{ $fw->id }}">{{ $fw->name }}</button>
                @endforeach
                <a class="ds-sv__chipadd" href="{{ \App\Filament\Pages\Forwarders::getUrl() }}" target="_blank">＋ New forwarder</a>
            </span>
            @php($fwSel = $forwarders->firstWhere('id', (int) ($f['forwarder_id'] ?? 0)))
            <div class="ds-sp__fields">
                <label><span>Hand over at (our truck goes here)</span><select wire:model="f.hand_over_branch_id" @disabled(! $fwSel)><option value="">{{ $fwSel ? 'Choose a branch' : 'Pick the forwarder first' }}</option>@foreach ($fwSel?->branches ?? [] as $b)<option value="{{ $b->id }}">{{ $b->name }}</option>@endforeach</select></label>
                <label><span>Pick up at (the hub goes here)</span><select wire:model="f.pick_up_branch_id" @disabled(! $fwSel)><option value="">{{ $fwSel ? 'Choose a branch' : 'Pick the forwarder first' }}</option>@foreach ($fwSel?->branches ?? [] as $b)<option value="{{ $b->id }}">{{ $b->name }}</option>@endforeach</select></label>
                <label><span>Waybill / booking no.</span><input type="text" wire:model="f.waybill_no"></label>
                <label><span>Charged by</span><select wire:model="f.charge_basis"><option value="">—</option>@foreach ($charges as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                <label><span>Rate ₱</span><input type="text" inputmode="decimal" wire:model="f.charge_rate"></label>
            </div>
            <span class="ds-sv__row">
                @if ($fwSel)<button type="button" class="ds-fu__link" wire:click="mountAction('newBranch')">＋ New branch for {{ $fwSel->name }}</button>@endif
                <x-filament::button size="sm" wire:click="save">Save</x-filament::button>
            </span>
            @if ($s->pick_up_at)
                <p class="ds-sv__sees">The partner hub sees: pick up at {{ $s->pick_up_at }}.</p>
            @endif
        </section>
    @else
        @php($facts = match ($s->mode) {
            'lcl' => ['Forwarder' => $s->forwarder, 'Waybill / booking no.' => $s->waybill_no, 'Charged by' => $s->charge_rate ? '₱'.number_format($s->charge_rate, 2).' '.strtolower($charges[$s->charge_basis] ?? '') : null, 'Pick up at' => $s->pick_up_at],
            'roro' => ['Shipping line' => $s->shipping_line, 'Vessel · voyage' => trim($s->vessel.($s->voyage ? ' · '.$s->voyage : '')), 'Booking / ticket no.' => $s->bl_no, 'ETD → ETA' => trim(($s->etd?->format('M j') ?? '').' → '.($s->eta?->format('M j') ?? ''), ' →')],
            default => ['Van no. · size' => trim($s->van_no.($s->van_size ? ' · '.$s->van_size : '')), 'Seal no.' => $s->seal_no, 'Vessel · BL' => trim($s->vessel.($s->bl_no ? ' · '.$s->bl_no : '')), 'ETD → ETA' => trim(($s->etd?->format('M j') ?? '').' → '.($s->eta?->format('M j') ?? ''), ' →')],
        })
        <section class="ds-board__panel ds-sp__box">
            <h3>{{ ['container' => 'Container', 'roro' => 'RoRo · the truck rides the ship', 'lcl' => 'LCL · with a forwarder'][$s->mode] ?? 'Container' }} @if (! $hubSide)<a class="ds-fu__link" href="#details">Edit</a>@endif</h3>
            <div class="ds-sv__facts">@foreach ($facts as $l => $v)<span><small>{{ $l }}</small><b>{{ $v ?: '—' }}</b></span>@endforeach</div>
        </section>
    @endif

    <div class="ds-sv__grid">
        {{-- trips (one per partner hub) --}}
        <section class="ds-board__panel ds-sp__box">
            <h3>Trips in this {{ $unit }} <small>one per partner hub</small></h3>
            @foreach ($stops as $st)
                <div class="ds-sv__trip" wire:key="st-{{ $st->deliverylog_id }}">
                    <b>{{ $st->hub?->hub_name }}</b><b class="num">{{ (int) ($stopBoxes[$st->deliverylog_id] ?? 0) }} boxes</b>
                    <small>Trip {{ $st->trip?->trip_number }} · stop {{ $st->stop }}{{ $st->received_at ? ' · received '.$st->received_at->format('M j g:i A').($st->missing ? ' · '.$st->missing.' missing' : '') : ($st->arrived_at ? ' · truck arrived '.$st->arrived_at->format('M j g:i A') : '') }}</small>
                    <small @class(['ds-sv__goes', 'is-own' => ! $rides($st)])>{{ $carrierPlate($st) ? ($rides($st) ? 'Goes with '.$carrierPlate($st) : 'Truck '.$carrierPlate($st)) : 'No truck yet' }}</small>
                    @if (! $hubSide && ($canTruck || $s->status === 'preparing') && $st->deliverylog_id != $s->deliverylog_id)
                        <span class="ds-sv__tripacts">
                            @if ($canTruck && ! $rides($st))<button type="button" class="ds-fu__link" wire:click="goWithMain({{ $st->deliverylog_id }})">Go with the main truck</button>@endif
                            @if ($s->status === 'preparing')<button type="button" class="ds-fu__link" wire:click="removeStop({{ $st->deliverylog_id }})" wire:confirm="Take trip {{ $st->trip?->trip_number }} out of this {{ $unit }}? The trip and its boxes stay as they are.">Take out</button>@endif
                        </span>
                    @endif
                </div>
            @endforeach
            <small class="ds-board__muted">The hub trips do not pick a truck: they go with the truck of this {{ $unit }}.</small>
            @if ($s->status === 'preparing' && ! $hubSide)
                <x-filament::button color="gray" size="sm" wire:click="openAdd({{ $adding ? 'false' : 'true' }})" icon="heroicon-o-plus">Add another hub's trip</x-filament::button>
                @if ($adding)
                    @forelse ($addTrips as $at)
                        <button type="button" class="ds-sp__pick" wire:click="addStop({{ $at->id }})" wire:key="at-{{ $at->id }}"><i aria-hidden="true"></i><span><b>Trip {{ $at->trip_number }} → {{ $at->destination?->hub_name }}</b><small>{{ $at->truck?->plate_no ?? 'no truck yet' }} · same port</small></span><em>{{ $at->tripinvoices_count }} boxes</em></button>
                    @empty
                        <p class="ds-sp__none">No other open trip to a hub at the same port.</p>
                    @endforelse
                @endif
            @endif
        </section>

        {{-- trucks to the port / ship / forwarder --}}
        <section class="ds-board__panel ds-sp__box">
            <h3>{{ $trucks->count() > 1 ? $trucks->count().' trucks to '.$to : 'Truck to '.$to }}
                @if ($canTruck && $stops->count() > 1 && $trucks->count() < $stops->count())
                    <button type="button" class="ds-sv__add2" wire:click="$toggle('second')">{{ $second ? 'Close' : '+ Add a second truck' }}</button>
                @endif
            </h3>
            @if ($second)
                <div class="ds-sv__second">
                    <small>Which trip goes on the second truck?</small>
                    @foreach ($stops->filter(fn ($st) => $rides($st)) as $st)
                        <span class="ds-sv__secrow" wire:key="sec-{{ $st->deliverylog_id }}">
                            <b>{{ $st->hub?->hub_name }} · {{ (int) ($stopBoxes[$st->deliverylog_id] ?? 0) }} boxes</b>
                            <select wire:model="secondTruck.{{ $st->deliverylog_id }}"><option value="">{{ $st->own_truck_id ? 'Its own truck ('.\App\Models\Truck::whereKey($st->own_truck_id)->value('plate_no').')' : 'Choose a truck' }}</option>@foreach ($hubTrucks as $tid => $plate)<option value="{{ $tid }}">{{ $plate }}</option>@endforeach</select>
                            <x-filament::button size="xs" wire:click="useSecondTruck({{ $st->deliverylog_id }})">Use</x-filament::button>
                        </span>
                    @endforeach
                </div>
            @endif
            @foreach ($trucks as $tk)
                <div class="ds-sp__truck" wire:key="tk-{{ $tk['tripId'] }}">
                    <span class="ds-sp__truckhead"><b>{{ $tk['plate'] ?? 'No truck yet' }}</b><small>{{ $tk['crew'] ? implode(' · ', $tk['crew']) : 'No crew yet' }}</small>
                        <i @class(['ds-sv__tstate', 'is-ok' => $tk['total'] && $tk['loaded'] >= $tk['total']])>{{ $tk['total'] && $tk['loaded'] >= $tk['total'] ? 'Loaded' : 'Loading' }}</i></span>
                    <span class="ds-sp__truckline"><span>Loaded {{ $tk['loaded'] }} / {{ $tk['total'] }}</span><span>{{ $tk['stops']->count() > 1 ? 'All '.$tk['stops']->count().' trips' : $tk['stops']->first()?->hub?->hub_name }} · {{ $tk['total'] }} boxes</span></span>
                    <span class="ds-sv__tbar"><i style="width: {{ $tk['total'] ? round($tk['loaded'] * 100 / $tk['total']) : 0 }}%"></i></span>
                    @if (! $hubSide)
                        <label class="ds-sp__truckcost"><span>Trucking ₱</span><input type="text" inputmode="decimal" wire:model="truckCost.{{ $tk['tripId'] }}" placeholder="0"><button type="button" class="ds-fu__link" wire:click="saveTruckCost({{ $tk['tripId'] }})">Save</button></label>
                    @else
                        <span class="ds-sp__truckline"><span>Trucking</span><b>{{ $tk['cost'] ? '₱'.number_format($tk['cost'], 2) : '—' }}</b></span>
                    @endif
                </div>
            @endforeach
        </section>
    </div>

    @if ($trucks->sum(fn ($t) => (float) $t['cost']) > 0)
        <section class="ds-board__panel ds-sp__box">
            <h3>Trucking split by boxes <small>goes into each hub's Cost per box</small></h3>
            <div class="ds-sv__split">
                @foreach ($trucks as $tk)
                    @foreach ($tk['stops'] as $st)
                        @php($n = (int) ($stopBoxes[$st->deliverylog_id] ?? 0))
                        <span><span>{{ $st->hub?->hub_name }} · {{ $tk['stops']->count() > 1 ? $n.'/'.$tk['total'].' boxes' : 'its own truck' }}</span><b>₱{{ number_format($tk['total'] ? (float) $tk['cost'] * $n / $tk['total'] : (float) $tk['cost'], 0) }}</b></span>
                    @endforeach
                @endforeach
            </div>
        </section>
    @endif

    @if ($s->status === 'preparing' && ! $hubSide)
        <section class="ds-board__panel ds-sp__box">
            <h3>Picked the wrong trip, or made it by mistake?</h3>
            <p class="ds-board__muted">Nothing is sealed yet, so you can still change it.</p>
            <div class="ds-sp__acts">
                <x-filament::button color="gray" wire:click="openChange({{ $changing ? 'false' : 'true' }})" icon="heroicon-o-arrows-right-left">Change trip</x-filament::button>
                <x-filament::button color="danger" outlined wire:click="removeShipment" wire:confirm="Remove {{ $s->code }}? Only the shipment is removed. Trip {{ $s->trip?->trip_number }} and its boxes stay as they are.">Remove shipment</x-filament::button>
            </div>
            @if ($changing)
                <label class="ds-sp__search"><span aria-hidden="true">🔍</span><input type="text" wire:model.live.debounce.300ms="changeSearch" placeholder="Search trip no., hub or truck" aria-label="Search trips"></label>
                @forelse ($changeTrips as $ct)
                    <button type="button" class="ds-sp__pick" wire:click="changeTrip({{ $ct->id }})" wire:key="ct-{{ $ct->id }}"><i aria-hidden="true"></i><span><b>Trip {{ $ct->trip_number }} → {{ $ct->destination?->hub_name }}</b><small>{{ $ct->truck?->plate_no ?? 'no truck yet' }}</small></span><em>{{ $ct->tripinvoices_count }} boxes</em></button>
                @empty
                    <p class="ds-sp__none">No other open trip to a hub reached by sea.</p>
                @endforelse
            @endif
        </section>
    @endif
    @if ($blockers && $canPress)
        <div class="ds-sp__block">@foreach ($blockers as $b)<span>⚠ {{ $b }}</span>@endforeach</div>
    @endif

    <div class="ds-sp__grid">
        <section class="ds-board__panel ds-sp__box">
            <h3>Boxes</h3>
            <div class="ds-sp__nums4">
                <span><small>On trip {{ $s->trip?->trip_number }}</small><b class="num">{{ $counts['onTrip'] }}</b></span>
                <span><small>Left the warehouse</small><b class="num">{{ $counts['loaded'] }}</b></span>
                <span @class(['is-bad' => $counts['port'] !== null && $counts['port'] < $counts['loaded']])><small>At the port</small><b class="num">{{ $counts['port'] ?? '—' }}</b></span>
                <span @class(['is-bad' => $counts['missingHub']->isNotEmpty()])><small>Received at the hub</small><b class="num">{{ $counts['received'] }}</b></span>
            </div>
            @if ($counts['port'] !== null && $counts['port'] < $counts['loaded'])
                <p class="ds-sp__warn">⚠ {{ $counts['loaded'] - $counts['port'] }} {{ $counts['loaded'] - $counts['port'] === 1 ? 'box' : 'boxes' }} left the warehouse but {{ $counts['loaded'] - $counts['port'] === 1 ? 'was' : 'were' }} not handed over at the port{{ $counts['missingPort']->isNotEmpty() ? ': '.$counts['missingPort']->take(8)->join(', ') : '. Which ones is not known: only a full scan tells.' }}</p>
            @endif
            @if ($counts['missingHub']->isNotEmpty())
                <p class="ds-sp__warn">Not scanned in at the hub yet: {{ $counts['missingHub']->take(10)->join(', ') }}{{ $counts['missingHub']->count() > 10 ? '…' : '' }}</p>
            @endif
            @if ($openSets)
                <div class="ds-sp__sets">
                    <b>Customers with boxes left behind</b>
                    @foreach ($openSets as $o)
                        <span>{{ $o['name'] }} · {{ $o['have'] }} of {{ $o['of'] }} · @foreach ($o['missing'] as $m){{ $m['invoice'] }} ({{ $m['reason'] ? \App\Models\Boxes\SetSplit::REASONS[$m['reason']] ?? $m['reason'] : 'no reason yet' }}) @endforeach</span>
                    @endforeach
                </div>
            @endif
            @if ($wrong->isNotEmpty())
                <div class="ds-sp__sets">
                    <b>Not for {{ $s->hub?->hub_name }}</b>
                    @foreach ($wrong as $w)<span>{{ $w->invoice?->invoice }} → {{ $w->correctHub?->hub_name ?? '?' }} · {{ \App\Models\Shipping\WrongHubBox::STATUS[$w->status] ?? $w->status }}</span>@endforeach
                </div>
            @endif
            @if (! $hubSide)
                <p class="ds-board__muted">Load the boxes with Scan app → Load truck (trip {{ $s->trip?->trip_number }}). Sets and wrong hub are checked there.</p>
            @else
                <p class="ds-board__muted">Scan the boxes in with Scan app → Receive container, then press Finish receiving.</p>
            @endif
        </section>

        <section class="ds-board__panel ds-sp__box">
            <h3>Cost</h3>
            <dl class="ds-sp__dl">
                <dt>Freight</dt><dd>{{ $s->cost_freight !== null ? $peso($s->cost_freight) : '—' }}</dd>
                <dt>Trucking to {{ $s->mode === 'lcl' ? 'the forwarder' : 'port' }}{{ $trucks->count() > 1 ? ' ('.$trucks->count().' trucks)' : '' }}</dt><dd>{{ ($tc = $trucks->sum(fn ($t) => (float) $t['cost'])) > 0 ? $peso($tc) : ($s->cost_trucking !== null ? $peso($s->cost_trucking) : '—') }}</dd>
                @if ($s->mode === 'lcl' && $s->charge_rate)<dt>Forwarder rate</dt><dd>{{ $peso($s->charge_rate) }} {{ strtolower($charges[$s->charge_basis] ?? '') }}</dd>@endif
                <dt>Port fees (wharfage, arrastre)</dt><dd>{{ $s->cost_port !== null ? $peso($s->cost_port) : '—' }}</dd>
                <dt>Other</dt><dd>{{ $s->cost_other !== null ? $peso($s->cost_other) : '—' }}</dd>
            </dl>
            <p class="ds-sp__perbox"><span>Per box</span><b class="num">{{ $counts['perBox'] ? $peso($counts['perBox']) : '—' }}</b></p>
            @if (($s->pickup_count ?? null) !== null)
                <p class="ds-board__muted">Picked up at the forwarder: {{ $s->pickup_count }} boxes{{ $s->pickup_at ? ' · '.$s->pickup_at->format('M j g:i A') : '' }}</p>
            @endif
            @if ($s->seal_photo || $s->port_receipt || ($s->pickup_photo ?? null))
                <span class="ds-sp__pics">
                    @if ($s->seal_photo)<a data-ds-photo href="{{ $s->fileUrl($s->seal_photo) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->seal_photo) }}" alt="Seal"><small>Seal</small></a>@endif
                    @if ($s->port_receipt)<a data-ds-photo href="{{ $s->fileUrl($s->port_receipt) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->port_receipt) }}" alt="Port receipt"><small>{{ $s->mode === 'lcl' ? 'Forwarder receipt' : 'Port receipt' }}</small></a>@endif
                    @if ($s->pickup_photo ?? null)<a data-ds-photo href="{{ $s->fileUrl($s->pickup_photo) }}" target="_blank" rel="noopener"><img src="{{ $s->fileUrl($s->pickup_photo) }}" alt="Release at pick-up"><small>Release at pick-up</small></a>@endif
                </span>
            @endif
        </section>
    </div>

    @if (! $hubSide)
        <form wire:submit="save" class="ds-board__panel ds-sp__form" id="details">
            <h3>Details</h3>
            <div class="ds-sp__fields">
                @if ($f['mode'] !== 'lcl')
                <label><span>{{ $f['mode'] === 'roro' ? 'Truck door seal no.' : 'Seal no.' }}</span><input type="text" wire:model="f.seal_no"></label>
                @endif
                @if ($f['mode'] === 'container')
                    <label><span>Container van no.</span><input type="text" wire:model="f.van_no" placeholder="MSKU 220871"></label>
                    <label><span>Size</span><input type="text" wire:model="f.van_size" placeholder="20 ft"></label>
                @endif
                @if ($f['mode'] !== 'lcl')
                <label><span>{{ $f['mode'] === 'roro' ? 'Ferry company' : 'Shipping line' }}</span><input type="text" wire:model="f.shipping_line" placeholder="2GO"></label>
                <label><span>Vessel</span><input type="text" wire:model="f.vessel"></label>
                <label><span>Voyage</span><input type="text" wire:model="f.voyage"></label>
                <label><span>{{ $f['mode'] === 'roro' ? 'Ticket no.' : 'BL no.' }}</span><input type="text" wire:model="f.bl_no"></label>
                @endif
                @if ($f['mode'] !== 'lcl')
                <label><span>From port</span><input type="text" list="ds-ports" wire:model="f.port_from" placeholder="Manila North Harbor"></label>
                <label><span>To port</span><input type="text" list="ds-ports" wire:model="f.port_to" placeholder="Cebu Port"></label>
                <datalist id="ds-ports">@foreach ($ports as $pn)<option value="{{ $pn }}"></option>@endforeach</datalist>
                @endif
                <label><span>Leaves (ETD)</span><input type="date" wire:model="f.etd"></label>
                <label><span>Arrives (ETA)</span><input type="date" wire:model="f.eta"></label>
                @if ($f['mode'] !== 'lcl')
                <label class="is-file"><span>Seal photo</span><input type="file" wire:model="sealPhoto" accept="image/*"></label>
                @endif
            </div>
            <h3>Port check</h3>
            <div class="ds-sp__fields">
                <label><span>Port check</span><select wire:model.live="f.port_check">@foreach ($checks as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                @if ($f['port_check'] === 'count')
                    <label><span>Boxes handed over (count)</span><input type="number" min="0" wire:model="f.port_count"></label>
                    <label class="is-file"><span>Photo of the forwarder receipt</span><input type="file" wire:model="receipt" accept="image/*"></label>
                @elseif ($f['port_check'] === 'off')
                    <label class="is-wide"><span>Why is it off? (required)</span><input type="text" wire:model="f.port_reason" placeholder="Container sealed at our warehouse"></label>
                @else
                    <p class="ds-board__muted is-wide">The crew scans every box at the port: Scan app → Port check.</p>
                @endif
            </div>
            <h3>Cost</h3>
            <div class="ds-sp__fields">
                <label><span>Freight ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_freight"></label>
                <label><span>Trucking to port ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_trucking"></label>
                <label><span>Port fees ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_port"></label>
                <label><span>Other ₱</span><input type="text" inputmode="decimal" wire:model="f.cost_other"></label>
                <label class="is-wide"><span>Note</span><input type="text" wire:model="f.note" maxlength="500"></label>
            </div>
            @if ($errors->any())<p class="ds-sp__err">{{ $errors->first() }}</p>@endif
            <div><x-filament::button type="submit" wire:loading.attr="disabled" wire:target="save,sealPhoto,receipt">Save details</x-filament::button></div>
        </form>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_18

# ---------------------------------------------------------------- resources/views/filament/widgets/module-board.blade.php
mkdir -p 'resources/views/filament/widgets'
cat > 'resources/views/filament/widgets/module-board.blade.php' <<'DISPATCH_FILE_END_19'
<x-filament-widgets::widget>
    <div class="ds-board" wire:poll.120s>
        <div class="ds-board__cards">
            @foreach ($cards as $card)
                <div class="ds-board__card ds-board__card--static">
                    <span class="ds-board__card-head">
                        <span>{{ $card['label'] }}</span>
                        <span class="ds-board__dot ds-board__dot--{{ $card['tone'] }}"></span>
                    </span>
                    <span @class(['ds-board__card-value', 'is-alert' => $card['alert'] ?? false])>{{ $card['value'] }}</span>
                    @if (($card['pct'] ?? null) !== null)
                        <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $card['tone'] }}" style="width: {{ $card['pct'] }}%"></span></span>
                    @endif
                    <span class="ds-board__card-sub">{{ $card['sub'] }}</span>
                </div>
            @endforeach
        </div>

        @if ($attention->isNotEmpty())
            <section class="ds-board__panel">
                <div class="ds-board__panel-head">
                    <h2>Needs attention</h2>
                    <span>{{ $attention->count() }} {{ Str::plural('item', $attention->count()) }}</span>
                </div>
                <ul class="ds-board__attention">
                    @foreach ($attention as $item)
                        <li>
                            <span class="ds-board__tag ds-board__tag--{{ $item['tone'] }}">{{ $item['tag'] }}</span>
                            <span class="ds-board__attention-text">
                                <strong>{{ $item['title'] }}</strong>
                                @if ($item['sub'] ?? null) <span class="ds-board__muted">· {{ $item['sub'] }}</span> @endif
                                <span class="ds-board__detail">{{ $item['detail'] }}</span>
                            </span>
                            <span class="ds-board__muted ds-board__truck">{{ $item['meta'] ?? '' }}</span>
                            @if ($item['url'] ?? null)
                                <x-filament::button size="sm" tag="a" :href="$item['url']" :color="($item['primary'] ?? false) ? 'primary' : 'gray'" :outlined="! ($item['primary'] ?? false)">
                                    {{ $item['action'] }}
                                </x-filament::button>
                            @else
                                <span></span>
                            @endif
                        </li>
                    @endforeach
                </ul>
            </section>
        @endif

        @if ($charts)
            <div @class(['ds-board__trends', 'ds-board__trends--even' => collect($charts)->every(fn ($c) => $c['type'] === 'bars')])>
                @foreach ($charts as $chart)
                    <section class="ds-board__panel">
                        <div class="ds-board__panel-head">
                            <h2>{{ $chart['title'] }}</h2>
                            <span>{{ $chart['note'] }}</span>
                        </div>

                        @if ($chart['type'] === 'days')
                            @php($max = max(1, $chart['rows']->max('boxes')))
                            <div class="ds-board__chart" role="img" aria-label="{{ $chart['title'] }}: {{ $chart['rows']->map(fn ($d) => $d['date']->format('M j').' '.$d['boxes'])->join(', ') }}">
                                @foreach ($chart['rows'] as $day)
                                    <span class="ds-board__col" title="{{ $day['date']->format('D, M j') }}: {{ $day['boxes'] }}">
                                        <span class="ds-board__col-n">{{ $day['boxes'] ?: '' }}</span>
                                        <span @class(['ds-board__col-bar', 'is-today' => $day['date']->isToday(), 'is-zero' => ! $day['boxes']]) style="height: {{ max(2, round($day['boxes'] / $max * 120)) }}px"></span>
                                        <span class="ds-board__col-day">{{ $day['date']->isToday() ? 'Today' : $day['date']->format('j') }}</span>
                                    </span>
                                @endforeach
                            </div>
                        @else
                            @php($max = max(1, $chart['rows']->max('count') ?? 0))
                            @forelse ($chart['rows'] as $row)
                                <div class="ds-board__reason">
                                    <span class="ds-board__reason-row"><span>{{ $row['label'] }}</span><strong>{{ number_format($row['count']) }}</strong></span>
                                    <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $chart['tone'] ?? 'navy' }}" style="width: {{ round($row['count'] / $max * 100) }}%"></span></span>
                                </div>
                            @empty
                                <p class="ds-board__muted">{{ $chart['empty'] }}</p>
                            @endforelse
                        @endif
                    </section>
                @endforeach
            </div>
        @endif

        @if ($openCount !== null || $photos->isNotEmpty())
            <section class="ds-board__panel">
                <div class="ds-board__panel-head">
                    <h2>{{ $photosTitle }}</h2>
                    <span>{{ $openCount !== null ? trans_choice('{0} None open|{1} 1 open, newest first|[2,*] :count open, newest first', $openCount, ['count' => $openCount]) : 'Newest first' }}</span>
                </div>

                @if ($photos->isEmpty())
                    <p class="ds-slider__empty">
                        <x-filament::icon icon="heroicon-m-check-circle" class="h-5 w-5" />
                        No open issues. Every reported box is resolved.
                    </p>
                @else
                    <div class="ds-slider"
                         wire:key="slider-{{ $photos->pluck('id')->join('-') }}"
                         x-data="{
                            index: 0,
                            count: {{ $photos->count() }},
                            perView: 4,
                            timer: null,
                            paused: false,
                            get last() { return Math.max(0, this.count - this.perView) },
                            init() {
                                this.measure();
                                window.addEventListener('resize', () => this.measure());
                                if (! window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
                                    this.timer = setInterval(() => { if (! this.paused && ! document.hidden) this.next(true) }, 4000);
                                }
                            },
                            destroy() { clearInterval(this.timer) },
                            measure() {
                                const w = this.$refs.viewport.clientWidth;
                                this.perView = w < 520 ? 1 : w < 820 ? 2 : w < 1100 ? 3 : 4;
                                this.index = Math.min(this.index, this.last);
                            },
                            next(auto = false) { this.index = this.index >= this.last ? 0 : this.index + 1 },
                            prev() { this.index = this.index <= 0 ? this.last : this.index - 1 },
                         }"
                         x-on:mouseenter="paused = true"
                         x-on:mouseleave="paused = false"
                         x-on:focusin="paused = true"
                         x-on:focusout="paused = false"
                         role="region"
                         aria-roledescription="carousel"
                         aria-label="{{ $photosTitle }}">
                        <div class="ds-slider__viewport" x-ref="viewport">
                            <div class="ds-slider__track" x-bind:style="`transform: translateX(-${index * (100 / perView)}%)`">
                                @foreach ($photos as $i => $photo)
                                    <figure class="ds-slider__slide" x-bind:style="`flex-basis: ${100 / perView}%`" wire:key="issue-{{ $photo['id'] }}"
                                            role="group" aria-roledescription="slide" aria-label="{{ $i + 1 }} of {{ $photos->count() }}">
                                        <div class="ds-slider__card">
                                            <div class="ds-slider__photo">
                                                @if ($photo['url'])
                                                    <a data-ds-photo href="{{ $photo['url'] }}" target="_blank" rel="noopener"><img src="{{ $photo['url'] }}" alt="Photo of {{ $photo['title'] }}" loading="lazy"></a>
                                                @else
                                                    <span class="ds-board__photo-none">No photo</span>
                                                @endif
                                                <span class="ds-board__tag ds-board__tag--warn">{{ $photo['label'] }}</span>
                                            </div>
                                            <figcaption>
                                                <strong>{{ $photo['title'] }}</strong>
                                                <span>{{ $photo['meta'] }}</span>
                                                @if ($photo['note'] ?? null)
                                                    <span class="ds-slider__note">{{ $photo['note'] }}</span>
                                                @endif
                                            </figcaption>
                                            @isset($photo['id'])
                                                <x-filament::button size="sm" color="success" outlined icon="heroicon-m-check"
                                                    wire:click="resolveIssue({{ $photo['id'] }})"
                                                    wire:confirm="Mark {{ $photo['title'] }} as resolved? It will leave the slider.">
                                                    Mark resolved
                                                </x-filament::button>
                                            @endisset
                                        </div>
                                    </figure>
                                @endforeach
                            </div>
                        </div>

                        <div class="ds-slider__controls" x-show="count > perView">
                            <button type="button" class="ds-slider__arrow" x-on:click="prev()" aria-label="Previous issues">
                                <x-filament::icon icon="heroicon-m-chevron-left" class="h-5 w-5" />
                            </button>
                            <span class="ds-slider__counter" x-show="last + 1 > 10" x-text="`${index + 1} / ${last + 1}`" aria-live="polite"></span>
                            <div class="ds-slider__dots" x-show="last + 1 <= 10">
                                <template x-for="n in last + 1" :key="n">
                                    <button type="button" class="ds-slider__dot" x-bind:class="{ 'is-active': n - 1 === index }"
                                            x-on:click="index = n - 1" x-bind:aria-label="`Go to slide ${n}`" x-bind:aria-current="n - 1 === index"></button>
                                </template>
                            </div>
                            <button type="button" class="ds-slider__arrow" x-on:click="next()" aria-label="Next issues">
                                <x-filament::icon icon="heroicon-m-chevron-right" class="h-5 w-5" />
                            </button>
                        </div>
                    </div>
                @endif
            </section>
        @endif
    </div>
</x-filament-widgets::widget>
DISPATCH_FILE_END_19

# ---------------------------------------------------------------- tests/Feature/PhotoReviewTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/PhotoReviewTest.php' <<'DISPATCH_FILE_END_20'
<?php

use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Pages\BoxPhotoSettings;
use App\Models\AppSetting;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\User;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $open = Tripinvoice::where('deliverylog_id', $this->trip->id)->where('is_delivered', false)->get();
    $this->box = $open->first();
    $this->other = $open->first(fn ($b) => $b->invoice !== $this->box->invoice);
});

function onDriverApp(): void
{
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    test()->actingAs(test()->driver);
}

it('keeps the delivery open when another box is read by accident', function () {
    expect($this->other)->not->toBeNull();
    onDriverApp();

    $page = Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->call('startDeliver')
        ->set('upload', UploadedFile::fake()->image('door.jpg', 800, 600))->call('savePhoto');

    // the same box read again: nothing changes
    $page->call('scan', $this->box->invoice)->assertSet('sheet', 'deliver')->assertSet('otherCode', null)
        ->assertSee('Delivered · 1 photo');

    // another box: the sheet and its photo stay, the driver is asked
    $page->call('scan', $this->other->invoice)
        ->assertSet('sheet', 'deliver')->assertSet('boxId', $this->box->id)
        ->assertSet('otherCode', $this->other->invoice)
        ->assertSee('Another box read: '.$this->other->invoice)->assertSee('This delivery stays open')
        ->assertSee('Delivered · 1 photo');

    // ✕ stays on this box
    $page->set('otherCode', null)->assertDontSee('Another box read');

    // Open it: goes to the other box
    $page->call('scan', $this->other->invoice)->call('openOther')
        ->assertSet('sheet', 'found')->assertSet('boxId', $this->other->id)->assertSet('otherCode', null);
});

it('keeps the cannot-deliver sheet open too', function () {
    onDriverApp();

    Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->call('startMiss')
        ->call('scan', $this->other->invoice)
        ->assertSet('sheet', 'miss')->assertSet('otherCode', $this->other->invoice)->assertSee('This box stays open');
});

it('still opens the next box when nothing is being done', function () {
    onDriverApp();

    Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->assertSet('sheet', 'found')
        ->call('scan', $this->other->invoice)->assertSet('sheet', 'found')->assertSet('boxId', $this->other->id);
});

it('shows bigger proof photos that open full screen', function () {
    onDriverApp();

    Livewire::test(Dashboard::class)
        ->call('scan', $this->box->invoice)->call('startDeliver')
        ->set('upload', UploadedFile::fake()->image('a.jpg', 800, 600))->call('savePhoto')
        ->set('upload', UploadedFile::fake()->image('b.jpg', 800, 600))->call('savePhoto')
        ->assertSeeHtml('ds-dr__grid is-big')->assertSee('1 / 2')->assertSee('2 / 2')->assertSee('⤢ Open')
        ->assertSeeHtml('dsPhotoViewer');
});

it('saves how long the Scan app waits before using a photo', function () {
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $admin->assignRole('super_admin');
    $this->actingAs($admin);

    expect((int) AppSetting::get('photos.auto_use', 3))->toBe(3);
    Livewire::test(BoxPhotoSettings::class)->assertSet('autoUse', 3)
        ->set('autoUse', 0)->call('save')->assertHasNoErrors();
    expect((int) AppSetting::get('photos.auto_use', 3))->toBe(0);

    Livewire::test(BoxPhotoSettings::class)->set('autoUse', 30)->call('save')->assertHasErrors('autoUse');
});

it('ships the photo viewer and never reloads the driver app over an open sheet', function () {
    $viewer = file_get_contents(resource_path('js/photo-viewer.js'));
    expect($viewer)->toContain('window.dsPhotoViewer')->toContain('window.dsPhotoCheck')->toContain("detail: { paused }");

    $offline = file_get_contents(resource_path('js/driver-offline.js'));
    expect($offline)->toContain(".ds-sa__sheet, .dspv");

    expect(collect(\Filament\Support\Facades\FilamentAsset::getScripts())->map->getId()->all())->toContain('photo-viewer');
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
