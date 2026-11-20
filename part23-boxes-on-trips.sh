#!/usr/bin/env bash
#
# Dispatch System — Part 23: boxes on trips, new boxes, partner hub unload, done by itself
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part23-boxes-on-trips.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 24 files"

# ---------------------------------------------------------------- app/Filament/Concerns/PlacesOnHubTrips.php
mkdir -p 'app/Filament/Concerns'
cat > 'app/Filament/Concerns/PlacesOnHubTrips.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Filament\Concerns;

use App\Models\Tripinvoice;
use App\Support\Trips\TripFill;
use Filament\Notifications\Notification;
use Illuminate\Support\Facades\Auth;

/**
 * Partner hub unload scans (Receive truck, Receive container): each box goes on the hub's open trip
 * of its city; full → a new hub trip, with Add anyway (board 45d).
 */
trait PlacesOnHubTrips
{
    /** Where the last box went. */
    public ?array $hubTrip = null;

    protected function placeOnHubTrip(Tripinvoice $row): ?array
    {
        $placed = TripFill::placeAtHub($row->fresh('invdata'), (int) Auth::user()?->logistichub_id, Auth::user());
        $this->hubTrip = $placed ? $placed + ['row' => $row->id] : null;

        return $placed;
    }

    /** Add anyway: the box (and its combo) goes on the full trip instead of the new one. */
    public function hubAnyway(): void
    {
        if (! $this->hubTrip || empty($this->hubTrip['full'])) {
            return;
        }
        $row = Tripinvoice::find($this->hubTrip['row']);
        if (! $row) {
            return;
        }
        $res = TripFill::hubAddAnyway($row, (int) $this->hubTrip['full']['id'], Auth::user());
        if ($res['ok']) {
            $this->hubTrip = ['trip' => $this->hubTrip['full']['number'], 'tripId' => $this->hubTrip['full']['id'], 'kind' => 'anyway',
                'why' => 'Added anyway: over the estimate · saved with your name. '.$res['msg'], 'row' => $row->id];
        }
        Notification::make()->title($res['msg'])->{$res['ok'] ? 'success' : 'warning'}()->send();
    }
}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Pages/NewBoxes.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/NewBoxes.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Pages;

use App\Filament\Shared\Trips\NewBoxesPage;

/** New boxes since the trips were made (board 45b). */
class NewBoxes extends NewBoxesPage {}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Scan/Pages/ScanApp.php
mkdir -p 'app/Filament/Scan/Pages'
cat > 'app/Filament/Scan/Pages/ScanApp.php' <<'DISPATCH_FILE_END_2'
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
    }

    public function pick(int $id): void
    {
        $station = $this->station();
        if (! $station || ! $station->appChoices()->contains('id', $id)) {
            Notification::make()->title('That one is not open for you any more.')->warning()->send();

            return;
        }
        $this->choice = $id;
        $this->returned = 0;
        $this->screen = 'scan';
        $this->clearResult();
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

        return $station->appChoices()->values()->map(function (array $c, int $i) use ($modeKey) {
            $p = $this->station($c['id'], $modeKey)->progress();
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
        $this->reset('status', 'message', 'invoiceId', 'missing', 'condition', 'note', 'boxPhoto', 'early', 'spot', 'route', 'setInfo', 'wrongHub', 'bypass', 'hubTrip');
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

        if ($this->status === 'success') {
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
            $target = $station->appChoices()->firstWhere('id', $this->choice);
            $loadNext = $this->screen === 'scan' && method_exists($station, 'loadNext') ? $station->loadNext() : null;
            $team = method_exists($station, 'team') ? $station->team() : [];
            $trucks = $this->mode === 'unload' && method_exists($station, 'truckStatus') ? $station->truckStatus() : [];
            $openSets = $this->screen === 'done' && method_exists($station, 'openSets') ? $station->openSets() : [];
            $countResult = $this->screen === 'done' && method_exists($station, 'countResult') ? $station->countResult() : null;
            $receiveResult = $this->screen === 'done' && method_exists($station, 'receiveResult') ? $station->receiveResult() : null;
            // Box sizes: space on the truck while loading (a big box takes more).
            if (in_array($this->mode, ['load', 'hub_load'], true) && BoxSizes::on() && ($trip = Deliverylog::with('truck')->find($this->choice))) {
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
            'cityTopUp' => $this->mode === 'load' && $this->choice && empty($this->topUpSkipped[(int) $this->choice]) && ($st = $this->station()) && method_exists($st, 'cityTopUp')
                ? (function () use ($st) {
                    $st->data['deliverylog_id'] = $this->choice;

                    return $st->cityTopUp();
                })() : null,
            'bypassReasons' => TripRules::reasons(),
            'noReason' => collect($openSets)->filter(fn ($o) => collect($o['missing'])->contains(fn ($m) => ! $m['reason']))->count(),
            'splitReasons' => SetSplit::REASONS,
            'box' => $box = ($this->invoiceId ? Invoice::find($this->invoiceId) : null),
            'space' => $space ?? null,
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
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/ShipmentScanStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/ShipmentScanStation.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\PlacesOnHubTrips;
use App\Filament\Concerns\ScansInvoices;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\SeaShipmentScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use Filament\Pages\Page;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Scan station for a sea shipment, used by the Scan app: Port check (the boxes handed over at
 * the port) or Receive (the partner hub scans the container in).
 */
abstract class ShipmentScanStation extends Page
{
    use PlacesOnHubTrips;
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    /** port or received */
    protected static string $step = 'port';

    /** The box's set at the hub: "2 of 3 arrived · 1 still in Manila". */
    public ?array $setInfo = null;

    /** The box is for another hub (added to the Wrong hub list). */
    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'sea_shipment_id';
    }

    protected function selectionLabel(): string
    {
        return 'a shipment';
    }

    /** Shipments open for this scan. */
    abstract protected function shipments(): Builder;

    protected function selected(): ?SeaShipment
    {
        return $this->shipments()->find($this->data['sea_shipment_id'] ?? null);
    }

    /** Receive: the trips of this hub's stop. Port check: every trip in the container. */
    protected function myTripIds(SeaShipment $s): array
    {
        if (static::$step !== 'received') {
            return Shipments::tripIds($s);
        }
        $stop = Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s);

        return $stop ? [(int) $stop->deliverylog_id] : [];
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $this->hubTrip = null;
        $s = $this->selected();
        if (! $s) {
            $this->scanResult('danger', 'That shipment is not open for this scan any more.');

            return;
        }
        $row = Tripinvoice::with('invdata.whSection')->whereIn('deliverylog_id', $this->myTripIds($s))->where('invoice', $code)->latest('id')->first();
        if (! $row) {
            $other = $this->invoicesMatching($code)->first();
            // One container, more hubs: the box is for another stop.
            $theirs = Tripinvoice::whereIn('deliverylog_id', Shipments::tripIds($s))->where('invoice', $code)->latest('id')->first();
            $stop = $theirs ? Shipments::stopOf($s, (int) $theirs->deliverylog_id) : null;
            if ($stop && $stop->received_at) {
                $this->scanResult('warning', "{$code} was already received at ".($stop->hub?->hub_name ?? 'the hub before').'. Not counted again.', $other);
            } elseif ($stop) {
                $this->route = ['kind' => 'wrong', 'code' => '→', 'name' => 'For '.($stop->hub?->hub_name ?? 'the next hub').': leave it in the container', 'color' => '#7a4fb0', 'why' => 'Stop '.$stop->stop.'. Not counted, not missing.'];
                $this->scanResult('warning', "{$code} is for ".($stop->hub?->hub_name ?? 'the next hub').': leave it in the container.', $other);
            } else {
                $this->scanResult('danger', "{$code} is not in shipment {$s->code}.", $other);
            }

            return;
        }
        if (static::$step === 'port' && ! $row->is_loaded) {
            $this->scanResult('warning', "{$code} was never scanned onto trip {$s->trip?->trip_number} at the warehouse. Check where it came from.", $row->invdata);

            return;
        }
        $prev = SeaShipmentScan::where('sea_shipment_id', $s->id)->where('invoice_id', $row->invoice_id)->where('step', static::$step)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', "{$code} was already scanned".($who ? " by {$who}" : '').($prev->created_at ? ' at '.Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

            return;
        }
        Shipments::scan($s, $row, static::$step);

        if (static::$step === 'received') {
            $this->setInfo = $row->invdata ? Shipments::setAtHub($s, $row->invdata) : null;
            if ($wrong = Shipments::checkWrongHub($s, $row)) {
                $this->route = ['kind' => 'wrong', 'code' => '⛔', 'name' => 'Not ours: for '.($wrong->correctHub?->hub_name ?? 'another hub'), 'color' => '#c8372d', 'why' => 'Put it aside. It is on the Wrong hub & returns list.'];
                $this->scanResult('warning', "{$code} is for ".($wrong->correctHub?->hub_name ?? 'another hub').'. Received, and put on the Wrong hub & returns list.', $row->invdata);

                return;
            }
        }
        // received at the partner hub: the box goes on the hub's trip of its city (board 45d)
        $placed = static::$step === 'received' ? $this->placeOnHubTrip($row) : null;
        $this->scanResult('success', "{$code} ".(static::$step === 'port' ? 'handed over at the port.' : 'received.').($placed ? ' → '.$placed['trip'] : ''), $row->invdata);
    }

    public function progress(): array
    {
        $s = $this->selected();
        if (! $s) {
            return ['loaded' => 0, 'total' => 0];
        }

        return [
            'loaded' => SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', static::$step)
                ->whereIn('invoice_id', Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->select('invoice_id'))->count(),
            'total' => Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->where('is_loaded', true)->count(),
        ];
    }

    public function team(): array
    {
        $id = $this->data['sea_shipment_id'] ?? null;
        if (! $id) {
            return [];
        }
        $counts = SeaShipmentScan::where('sea_shipment_id', $id)->where('step', static::$step)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    /** Receive container asks for the photo of the box at the partner hub (Box photo settings: Receiving at a partner hub). */
    public function photoStep(): ?string
    {
        return static::$step === 'received' ? 'hub_receive' : null;
    }

    public function photoContext(): array
    {
        $s = $this->selected();
        $stop = $s ? (Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s)) : null;

        return ['deliverylog_id' => $stop?->deliverylog_id ?? $s?->deliverylog_id, 'logistichub_id' => $stop?->logistichub_id ?? $s?->logistichub_id];
    }

    /** Receive container, Done screen: received, missing, and Finish receiving. */
    public function receiveResult(): ?array
    {
        $s = static::$step === 'received' ? $this->selected() : null;
        if (! $s) {
            return null;
        }
        $p = $this->progress();
        $missing = Tripinvoice::whereIn('deliverylog_id', $this->myTripIds($s))->where('is_loaded', true)
            ->whereNotIn('invoice_id', SeaShipmentScan::where('sea_shipment_id', $s->id)->where('step', 'received')->select('invoice_id'))->limit(30)->pluck('invoice');
        $stop = Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ?? Shipments::currentStop($s);
        $next = Shipments::stops($s)->first(fn ($x) => $stop && $x->stop > $stop->stop && ! $x->received_at);

        return ['got' => $p['loaded'], 'of' => $p['total'], 'finished' => $s->status === 'received' || (bool) $stop?->received_at,
            'next' => $next?->hub?->hub_name,
            'missing' => $missing->map(fn ($code) => ['code' => $code, 'sub' => 'Not scanned off the container'])->all()];
    }

    public function finishReceiving(): ?int
    {
        $s = static::$step === 'received' ? $this->selected() : null;

        return $s ? Shipments::finishReceiving($s, null, Shipments::stopFor($s, (int) Auth::user()?->logistichub_id) ? (int) Auth::user()?->logistichub_id : null) : null;
    }

    public function appChoices(): Collection
    {
        return $this->shipments()->latest('id')->limit(40)->get()->map(fn (SeaShipment $s) => [
            'id' => $s->id, 'name' => $s->code.' → '.($s->hub?->hub_name ?? ''), 'active' => true,
            'sub' => collect([$s->van_no ? 'Van '.$s->van_no : null, Shipments::label($s), $s->eta ? 'ETA '.$s->eta->format('M j') : null])->filter()->join(' · '),
        ]);
    }

    protected function hub(string $panel): int|false|null
    {
        return Tracker::hubFor(Auth::user(), $panel);
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Shared/Shipping/TruckReceiveStation.php
mkdir -p 'app/Filament/Shared/Shipping'
cat > 'app/Filament/Shared/Shipping/TruckReceiveStation.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Filament\Shared\Shipping;

use App\Filament\Concerns\PlacesOnHubTrips;
use App\Filament\Concerns\ScansInvoices;
use App\Models\Deliverylog;
use App\Models\Shipping\TruckReceiptScan;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Support\Shipping\Shipments;
use App\Support\Shipping\TruckReceive;
use Filament\Pages\Page;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Scan app · Receive truck: the partner hub (by truck) scans every box in when the truck from Manila arrives. */
class TruckReceiveStation extends Page
{
    use PlacesOnHubTrips;
    use ScansInvoices;

    protected string $view = 'filament.pages.scaninvoice';

    protected static bool $shouldRegisterNavigation = false;

    public ?array $setInfo = null;

    public ?array $route = null;

    protected function selectionField(): ?string
    {
        return 'deliverylog_id';
    }

    protected function selectionLabel(): string
    {
        return 'a truck';
    }

    protected function hubId(): int
    {
        return (int) Auth::user()?->logistichub_id;
    }

    protected function selected(): ?Deliverylog
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);

        return $id && TruckReceive::rows($id, $this->hubId())->exists() ? Deliverylog::find($id) : null;
    }

    protected function handleScan(string $code): void
    {
        $this->setInfo = null;
        $this->route = null;
        $this->hubTrip = null;
        $trip = $this->selected();
        $hub = $this->hubId();
        if (! $trip) {
            $this->scanResult('danger', 'Pick the truck that arrived first.');

            return;
        }
        $row = Tripinvoice::with('invdata.whSection')->where('deliverylog_id', $trip->id)->where('logistichub_id', $hub)->where('invoice', $code)->latest('id')->first();
        if (! $row) {
            $other = Tripinvoice::where('invoice', $code)->latest('id')->first();
            $sea = $other ? Shipments::forTrip((int) $other->deliverylog_id) : null;
            $box = $this->invoicesMatching($code)->first();
            if ($sea) {
                $this->scanResult('warning', "{$code} came on sea shipment {$sea->code}. Use Receive container.", $box);
            } elseif ($other && (int) $other->deliverylog_id !== $trip->id) {
                $this->route = ['kind' => 'wrong', 'code' => '!', 'name' => 'Not on this truck', 'color' => '#b07400', 'why' => 'It is on trip '.Deliverylog::whereKey($other->deliverylog_id)->value('trip_number').'. Keep it apart and tell the office.'];
                $this->scanResult('warning', "{$code} is not on this truck.", $box);
            } else {
                $this->scanResult('danger', "{$code} is not on trip {$trip->trip_number} for your hub.", $box);
            }

            return;
        }
        $prev = TruckReceiptScan::where('deliverylog_id', $trip->id)->where('invoice_id', $row->invoice_id)->first();
        if ($prev) {
            $who = $prev->user_id && $prev->user_id !== Auth::id() ? User::find($prev->user_id)?->first_name : null;
            $this->scanResult('warning', "{$code} was already received".($who ? " by {$who}" : '').($prev->created_at ? ' at '.Carbon::parse($prev->created_at)->format('g:i A') : '').'. Not counted again.', $row->invdata);

            return;
        }
        $wasLoaded = (bool) $row->is_loaded;
        TruckReceive::scan($trip->id, $hub, $row);
        $this->setInfo = $row->invdata ? TruckReceive::setAtHub($trip->id, $hub, $row->invdata) : null;
        if ($wrong = TruckReceive::checkWrongHub($hub, $row)) {
            $this->route = ['kind' => 'wrong', 'code' => '⛔', 'name' => 'Not ours: for '.($wrong->correctHub?->hub_name ?? 'another hub'), 'color' => '#c8372d', 'why' => 'Put it aside. It is on the Wrong hub & returns list.'];
            $this->scanResult('warning', "{$code} is for ".($wrong->correctHub?->hub_name ?? 'another hub').'. Received, and put on the Wrong hub & returns list.', $row->invdata);

            return;
        }
        // the box goes on the hub's open trip of its city: full → a new hub trip (Add anyway offered)
        $placed = $this->placeOnHubTrip($row);
        $this->scanResult('success', "{$code} received at your hub.".($placed ? ' → '.$placed['trip'] : '').($wasLoaded ? '' : ' It was not scanned onto the truck in Manila.'), $row->invdata);
    }

    public function progress(): array
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);
        if (! $id) {
            return ['loaded' => 0, 'total' => 0];
        }
        $c = TruckReceive::counts($id, $this->hubId());

        return ['loaded' => $c['got'], 'total' => $c['of']];
    }

    /** Done screen: received, missing, and Finish receiving. */
    public function receiveResult(): ?array
    {
        $trip = $this->selected();
        if (! $trip) {
            return null;
        }
        $c = TruckReceive::counts($trip->id, $this->hubId());
        $names = User::whereIn('id', $c['missing']->pluck('loaded_by')->filter())->pluck('first_name', 'id');

        return ['got' => $c['got'], 'of' => $c['of'], 'finished' => (bool) TruckReceive::receipt($trip->id, $this->hubId())?->finished_at,
            'missing' => $c['missing']->take(30)->map(fn ($r) => ['code' => $r->invoice,
                'sub' => 'Loaded in Manila'.($r->loaded_by && isset($names[$r->loaded_by]) ? ' by '.$names[$r->loaded_by] : '').($r->loaded_at ? ' at '.Carbon::parse($r->loaded_at)->format('M j g:i A') : '')])->all()];
    }

    public function finishReceiving(): ?int
    {
        $trip = $this->selected();

        return $trip ? TruckReceive::finish($trip, $this->hubId()) : null;
    }

    public function team(): array
    {
        $id = (int) ($this->data['deliverylog_id'] ?? 0);
        if (! $id) {
            return [];
        }
        $counts = TruckReceiptScan::where('deliverylog_id', $id)->whereNotNull('user_id')->selectRaw('user_id, count(*) n')->groupBy('user_id')->pluck('n', 'user_id');
        $names = User::whereIn('id', $counts->keys())->pluck('first_name', 'id');

        return $counts->sortDesc()->map(fn ($n, $uid) => ['name' => (int) $uid === Auth::id() ? 'You' : ($names[$uid] ?? '?'), 'n' => (int) $n, 'me' => (int) $uid === Auth::id()])->values()->all();
    }

    public function household(): array
    {
        return [];
    }

    public function photoStep(): ?string
    {
        return 'hub_receive';
    }

    public function photoContext(): array
    {
        return ['deliverylog_id' => $this->data['deliverylog_id'] ?? null, 'logistichub_id' => $this->hubId()];
    }

    public function appChoices(): Collection
    {
        return TruckReceive::trips($this->hubId())->map(fn (Deliverylog $t) => [
            'id' => $t->id, 'name' => $t->trip_number.' from Manila', 'active' => true,
            'sub' => collect([$t->truck?->plate_no ? 'Truck '.$t->truck->plate_no : null, $t->delivery_date ? 'Date '.Carbon::parse($t->delivery_date)->format('M j') : null])->filter()->join(' · '),
        ])->values();
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Filament/Shared/Trips/NewBoxesPage.php
mkdir -p 'app/Filament/Shared/Trips'
cat > 'app/Filament/Shared/Trips/NewBoxesPage.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Filament\Shared\Trips;

use App\Support\BoxSizes;
use App\Support\Tracking\Tracker;
use App\Support\Trips\CityTrips;
use App\Support\Trips\TripFill;
use App\Support\Trips\TripRules;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;

/**
 * New boxes since the trips were made (board 45b): boxes of cities that already have a trip.
 * Space left → add (combos first, never split); full → new trip or Add anyway; locked or left → new trip.
 */
class NewBoxesPage extends Page
{
    protected string $view = 'filament.trips.new-boxes';

    protected static ?string $slug = 'new-boxes';

    protected static ?string $title = 'New boxes';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-inbox-arrow-down';

    /** Picker: city key, trip id, chosen combo keys, Add anyway reason. */
    public ?string $pickCity = null;

    public ?int $pickTrip = null;

    /** @var array<string, bool> */
    public array $sel = [];

    public string $reason = '';

    public static function canAccess(): bool
    {
        $u = Auth::user();

        return CityTrips::ready() && $u?->logistichub_id && Tracker::hubFor($u, Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    /** Rows once per request. */
    protected ?array $rowsMemo = null;

    public function rows(): array
    {
        return $this->rowsMemo ??= TripFill::newBoxes(Auth::user());
    }

    protected function fresh(): void
    {
        $this->rowsMemo = null;
        Cache::forget('menu:'.Filament::getCurrentPanel()?->getId().':'.Auth::id().':newBoxes');
    }

    public function openPick(string $city, ?bool $anyway = false): void
    {
        $row = collect($this->rows())->firstWhere('key', $city);
        if (! $row || empty($row['trip']) || ! empty($row['trip']['locked'])) {
            return;
        }
        $this->pickCity = $city;
        $this->pickTrip = (int) $row['trip']['id'];
        $this->reason = '';
        // space left: what fits is picked (combos first); full: nothing picked
        $this->sel = $anyway ? [] : collect($row['fit'])->mapWithKeys(fn ($k) => [$k => true])->all();
    }

    public function toggle(string $key): void
    {
        $this->sel[$key] = empty($this->sel[$key]);
    }

    public function pickFit(): void
    {
        $row = collect($this->rows())->firstWhere('key', $this->pickCity);
        $this->sel = $row ? collect($row['fit'])->mapWithKeys(fn ($k) => [$k => true])->all() : [];
    }

    public function pickNone(): void
    {
        $this->sel = [];
    }

    public function closePick(): void
    {
        $this->pickCity = null;
        $this->pickTrip = null;
        $this->sel = [];
    }

    public function confirmPick(): void
    {
        if (! $this->pickCity || ! $this->pickTrip) {
            return;
        }
        $keys = array_keys(array_filter($this->sel));
        $p = $this->picker();
        $res = TripFill::addPicked(Auth::user(), $this->pickCity, $this->pickTrip, $keys, (bool) ($p['over'] ?? false), $this->reason);
        Notification::make()->title($res['msg'])->{$res['ok'] ? 'success' : 'warning'}()->send();
        if ($res['ok']) {
            $this->closePick();
            $this->fresh();
        }
    }

    public function newTrip(string $city): void
    {
        $made = TripFill::newTrips(Auth::user(), [$city]);
        $this->fresh();
        Notification::make()->title($made ? 'New trip '.collect($made)->pluck('number')->join(', ').' made with these boxes · ✦ AI' : 'No boxes to put on a new trip.')
            ->{$made ? 'success' : 'warning'}()->send();
    }

    public function applyAll(): void
    {
        $res = TripFill::applyAll(Auth::user());
        $this->fresh();
        $msg = $res['added'].' '.Str::plural('box', $res['added']).' added to trips with room'
            .($res['made'] ? ' · new '.Str::plural('trip', count($res['made'])).' '.collect($res['made'])->pluck('number')->join(', ') : '').'. No combo was split.';
        Notification::make()->title($msg)->success()->send();
    }

    /** The open picker: rows, space, over. */
    public function picker(): ?array
    {
        if (! $this->pickCity) {
            return null;
        }
        $row = collect($this->rows())->firstWhere('key', $this->pickCity);
        if (! $row || empty($row['trip'])) {
            return null;
        }
        $t = $row['trip'];
        $chosen = collect($row['combos'])->filter(fn ($c) => ! empty($this->sel[$c['key']]));
        $space = (float) $chosen->sum('space');
        $n = (int) $chosen->sum('n');
        $over = max(0, $t['used'] + $space - $t['cap']);

        return ['row' => $row, 'trip' => $t, 'n' => $n, 'space' => $space, 'over' => $over > 0.001, 'overBy' => $over,
            // the bar grows past the truck space when over, so the part over shows in amber
            'usedPct' => round($t['used'] / max(1, $t['cap'], $t['used'] + $space) * 100), 'newPct' => round($space / max(1, $t['cap'], $t['used'] + $space) * 100),
            'reasons' => TripRules::ready() ? TripRules::reasons() : ['It still fits (small box)', 'Other']];
    }

    protected function getViewData(): array
    {
        $rows = $this->rows();
        $plan = collect(Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => is_subclass_of($p, PlanTripsPage::class));

        return ['rows' => $rows, 'total' => (int) collect($rows)->sum('n'),
            'toAdd' => (int) collect($rows)->where('kind', 'open')->sum(fn ($r) => $r['n'] - $r['newN']),
            'toNew' => (int) collect($rows)->sum(fn ($r) => $r['kind'] === 'open' ? $r['newN'] : $r['n']),
            'p' => $this->picker(), 'planUrl' => $plan ? $plan::getUrl() : null, 'fmt' => fn ($v) => BoxSizes::fmt((float) $v)];
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Filament/Shared/Trips/PlanTripsPage.php
mkdir -p 'app/Filament/Shared/Trips'
cat > 'app/Filament/Shared/Trips/PlanTripsPage.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Filament\Shared\Trips;

use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Support\Ai\Ai;
use App\Support\Hubs\HubAreas;
use App\Support\Sms\SmsSettings;
use App\Support\Tracking\Tracker;
use App\Support\Trips\CityTrips;
use App\Support\Trips\TripRules;
use App\Support\Warehouses\Coverage;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;

/** Plan trips by city: the AI groups nearby cities into truckloads; Create puts the boxes on the trips. */
class PlanTripsPage extends Page
{
    protected string $view = 'filament.trips.plan';

    protected static ?string $slug = 'plan-trips';

    protected static ?string $title = 'Plan trips';

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-sparkles';

    public string $day = 'today';

    public string $date = '';

    public string $ask = 'oldest';

    public string $instruction = '';

    public array $trips = [];

    public ?int $kept = null;

    public string $note = '';

    public bool $ai = false;

    public string $open = '';

    public array $made = [];

    public ?string $given = null;

    /** Reason for changing the AI plan (trip rules: Change the AI plan). */
    public string $planReason = '';

    /** A partner hub plans its own trips (Partner hub panel): direct to customers of its area only. */
    protected static bool $atHub = false;

    /** Direct to customers, or To hubs. */
    public string $tab = 'direct';

    /** Cities of a hub's area delivered direct instead ("hubId|province|city"). */
    public array $direct = [];

    /** Waiting for a reason: deliver this hub city direct ("hubId|province|city"). */
    public ?string $askDirect = null;

    public array $hubPlan = [];

    /** @var array<int, string> hub id => made|wait */
    public array $hubState = [];

    /** @var array<int, string> hub id => now|later (Trip 2 and more) */
    public array $hubWhen = [];

    /** @var array<int, string> hub id => message after Create */
    public array $hubMade = [];

    public static function canAccess(): bool
    {
        $u = Auth::user();

        return CityTrips::ready() && $u?->logistichub_id && Tracker::hubFor($u, Filament::getCurrentPanel()?->getId()) !== false;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    /** One per request: every list is read once per click. */
    protected ?CityTrips $cityMemo = null;

    protected function city(): CityTrips
    {
        if (! $this->cityMemo) {
            $this->cityMemo = new CityTrips(Auth::user(), static::$atHub);
            $this->cityMemo->direct = $this->direct;
        }

        return $this->cityMemo;
    }

    public function mount(): void
    {
        $this->date = today()->toDateString();
        $this->replan();
        $this->open = Str::lower((string) ($this->trips[0]['province'] ?? ''));
    }

    public function topProvince(): ?string
    {
        return $this->city()->places()->groupBy('province')->map->sum('boxes')->sortDesc()->keys()->reject(fn ($p) => $p === 'No province')->first();
    }

    public function replan(): void
    {
        $plan = $this->city()->plan([
            'first' => $this->ask === 'first' ? $this->topProvince() : null,
            'keep' => $this->ask === 'keep', 'full' => $this->ask === 'full',
            'instruction' => trim($this->instruction),
        ]);
        $this->trips = $plan['trips'];
        $this->kept = $plan['kept'];
        $this->note = $plan['note'];
        $this->ai = $plan['ai'];
        $this->replanHubs();
    }

    protected function replanHubs(): void
    {
        $used = collect($this->trips)->where('on', true)->pluck('truck_id')->filter()->values()->all();
        $this->hubPlan = HubAreas::ready() && ! static::$atHub ? json_decode(json_encode($this->city()->planHubs($used)), true) : [];
        foreach ($this->hubPlan as $h) {
            $this->hubWhen[$h['hub']] ??= collect($h['trips'])->contains('when', 'later') ? 'later' : 'now';
        }
    }

    public function setTab(string $t): void
    {
        $this->tab = $t === 'hubs' ? 'hubs' : 'direct';
    }

    public function setWhen(int $hub, string $when): void
    {
        $this->hubWhen[$hub] = $when === 'later' ? 'later' : 'now';
    }

    public function waitHub(int $hub): void
    {
        $this->hubState[$hub] = 'wait';
    }

    public function makeHub(int $hub): void
    {
        $h = collect($this->hubPlan)->firstWhere('hub', $hub);
        if (! $h) {
            return;
        }
        $trips = ($this->hubWhen[$hub] ?? 'now') === 'later' ? array_slice($h['trips'], 0, 1) : $h['trips'];
        try {
            $this->city()->made = [];
            $made = $this->city()->createHub($hub, $trips, Carbon::parse($this->date ?: today()), $h['tip']);
        } catch (\Throwable $e) {
            report($e);
            Notification::make()->title('Could not create the trip')->body($e->getMessage())->danger()->send();

            return;
        }
        $nums = collect($made)->pluck('number')->join(' and ');
        $later = count($h['trips']) - count($trips);
        $this->hubState[$hub] = 'made';
        $this->hubMade[$hub] = '✓ '.$nums.' to '.$h['name'].($later ? ' now · the rest shows again tomorrow' : ' · the hub sees '.(count($made) > 1 ? 'them' : 'it').' in Incoming boxes');
        Notification::make()->title(count($made).' '.Str::plural('trip', count($made)).' to '.$h['name'].' created')->body($nums)->success()->send();
    }

    /** "Deliver direct instead": a hub city moves to the Direct tab (with a reason, per the trip rules). */
    public function askDirectCity(int $hub, string $key): void
    {
        $need = TripRules::need('direct_hub', Auth::user());
        if ($need === 'office') {
            Notification::make()->title('Only the office can deliver a hub’s boxes direct')->warning()->send();

            return;
        }
        $this->askDirect = $hub.'|'.$key;
        if ($need === 'free') {
            $this->directWith('');
        }
    }

    public function directWith(string $reason): void
    {
        if (! $this->askDirect) {
            return;
        }
        [$hub, $p, $c] = array_pad(explode('|', $this->askDirect, 3), 3, '');
        TripRules::record('direct_hub', Auth::user(), $reason ?: null, ['note' => Str::title($c).', '.Str::title($p).': '.HubAreas::name((int) $hub).' → direct']);
        $this->direct[] = $this->askDirect;
        $this->direct = array_values(array_unique($this->direct));
        $this->askDirect = null;
        $this->cityMemo = null;
        $this->made = [];
        $this->replan();
    }

    public function cancelDirect(): void
    {
        $this->askDirect = null;
    }

    public function toggleSms(int $i): void
    {
        if (isset($this->trips[$i])) {
            $this->trips[$i]['sms'] = ! ($this->trips[$i]['sms'] ?? true);
        }
    }

    public function setAsk(string $k): void
    {
        $this->ask = in_array($k, ['oldest', 'first', 'keep', 'full'], true) ? $k : 'oldest';
        $this->instruction = '';
        $this->made = [];
        $this->replan();
    }

    public function askAi(): void
    {
        $this->made = [];
        $this->replan();
        if (filled($this->instruction) && ! $this->ai) {
            Notification::make()->title('Planned without AI')->body(Ai::whyOff('trips') ?: $this->note)->warning()->send();
        }
    }

    public function setDay(string $d): void
    {
        $this->day = in_array($d, ['today', 'tomorrow', 'date'], true) ? $d : 'today';
        if ($this->day !== 'date') {
            $this->date = ($this->day === 'tomorrow' ? today()->addDay() : today())->toDateString();
        }
    }

    /** Trip rules: may this person change the AI plan? */
    protected function mayChange(): bool
    {
        if (TripRules::need('change_plan', Auth::user()) === 'office') {
            Notification::make()->title('Only the office can change the AI plan')->body('Ask an admin, or create the trips as suggested.')->warning()->send();

            return false;
        }

        return true;
    }

    public function toggleTrip(int $i): void
    {
        if (isset($this->trips[$i]) && $this->mayChange()) {
            $this->trips[$i]['on'] = ! $this->trips[$i]['on'];
            $this->trips[$i]['changed'] = true;
            $this->trips[$i]['changedNote'] = $this->trips[$i]['on'] ? 'Switched off, then on again' : 'Switched off';
            $this->made = [];
        }
    }

    /** Top-up: the city picked in a trip's suggestion box. */
    public function pickTop(int $i, string $key): void
    {
        if (isset($this->trips[$i])) {
            $this->trips[$i]['topPick'] = $key;
        }
    }

    public function addTop(int $i): void
    {
        $t = $this->trips[$i] ?? null;
        $opt = $t ? collect($this->topOptions($i))->firstWhere('key', $t['topPick'] ?? null) ?? collect($this->topOptions($i))->first() : null;
        if (! $opt) {
            return;
        }
        $this->trips[$i]['cities'][] = ['city' => $opt['city'], 'key' => $opt['key'], 'boxes' => $opt['boxes'], 'space' => $opt['space'], 'province' => $opt['province']];
        $this->trips[$i]['load'] += $opt['space'];
        $this->trips[$i]['topped'] = $opt['city'].($opt['province'] !== $t['province'] ? ', '.$opt['province'] : '').' added · '.$opt['boxes'].' '.Str::plural('box', $opt['boxes']).' · now about '.$this->trips[$i]['load'].' of '.$t['cap'].' space';
        $this->made = [];
    }

    public function skipTop(int $i): void
    {
        if (isset($this->trips[$i])) {
            $this->trips[$i]['noTop'] = true;
        }
    }

    /** Waiting cities that fit the room left on trip $i: same province first. */
    public function topOptions(int $i): array
    {
        $t = $this->trips[$i] ?? null;
        $room = $t ? $t['cap'] - $t['load'] : 0;
        if (! $t || ! $t['on'] || $room < 5 || ! empty($t['noTop']) || ! empty($t['topped'])) {
            return [];
        }
        $c = $this->city();
        $taken = collect($this->trips)->flatMap(fn ($x) => collect($x['cities'])->pluck('key'))->flip();
        $covered = $c->covered();

        return $c->places()->reject(fn ($p) => $p['unclear'] || isset($taken[$p['key']]) || isset($covered[$p['key']]) || $p['space'] > $room)
            ->sortBy(fn ($p) => [Str::lower($p['province']) === Str::lower($t['province']) ? 0 : 1, -$p['days'], -$p['boxes']])
            ->take(2)->values()->map(fn ($p) => $p + ['same' => Str::lower($p['province']) === Str::lower($t['province'])])->all();
    }

    public function toggleOpen(string $p): void
    {
        $this->open = $this->open === $p ? '' : $p;
    }

    /** Truck button: free trucks, then trucks still out (the trip waits), then no truck yet. */
    public function cycleTruck(int $i): void
    {
        if (! isset($this->trips[$i]) || ! $this->mayChange()) {
            return;
        }
        $this->trips[$i]['changed'] = true;
        $trucks = $this->city()->trucks();
        $usedFree = collect($this->trips)->except($i)->where('on', true)->pluck('truck_id')->filter()->all();
        $options = $trucks->where('state', 'free')->reject(fn ($t) => $t['id'] === $this->kept || in_array($t['id'], $usedFree, true))->pluck('id')
            ->merge($trucks->where('state', 'busy')->pluck('id'))->push(null)->values();
        $at = $options->search($this->trips[$i]['truck_id'], true);
        $n = ($at === false ? -1 : $at) + 1;
        $next = $options->has($n) ? $options[$n] : $options[0];
        $plate = fn ($id) => $id ? ($trucks->firstWhere('id', $id)['plate'] ?? '#'.$id) : 'no truck';
        $this->trips[$i]['changedNote'] = 'Truck '.$plate($this->trips[$i]['changedFrom'] ??= $this->trips[$i]['truck_id']).' → '.$plate($next);
        $this->trips[$i]['truck_id'] = $next;
        $this->trips[$i]['cap'] = $next ? ($trucks->firstWhere('id', $next)['capacity'] ?? CityTrips::DEFAULT_CAPACITY) : CityTrips::DEFAULT_CAPACITY;
        $this->made = [];
    }

    public function create(): void
    {
        $date = Carbon::parse($this->date ?: today());
        $changed = collect($this->trips)->filter(fn ($t) => ! empty($t['changed']));
        if ($changed->isNotEmpty() && TripRules::need('change_plan', Auth::user()) === 'reason') {
            if (! in_array($this->planReason, TripRules::reasons(), true)) {
                Notification::make()->title('Pick why you changed the AI plan')->warning()->send();

                return;
            }
            foreach ($changed as $t) {
                TripRules::record('change_plan', Auth::user(), $this->planReason, ['note' => $t['province'].' › '.collect($t['cities'])->pluck('city')->join(', ').($t['on'] ? '' : ' (switched off)')]);
            }
        }
        $this->city()->made = ['ai' => $this->ai, 'instruction' => trim($this->instruction), 'reason' => $this->planReason];
        try {
            $this->made = $this->city()->create($this->trips, $date);
        } catch (\Throwable $e) {
            report($e);
            Notification::make()->title('Could not create the trips')->body($e->getMessage())->danger()->send();

            return;
        }
        if ($this->made) {
            Notification::make()->title(count($this->made).' '.Str::plural('trip', count($this->made)).' created')->success()->send();
        }
        $made = $this->made;
        $this->replan();
        $this->made = $made;
    }

    public function give(int $tripId, int $truckId): void
    {
        $trip = Deliverylog::where('logistichub_id', Auth::user()->logistichub_id)->whereNull('truck_id')->findOrFail($tripId);
        $truck = $this->city()->give($trip, $truckId);
        $this->given = $truck->plate_no.' is on '.$trip->trip_number.' '.($trip->cities()->first()?->province ?? '');
        $this->replan();
    }

    protected function getViewData(): array
    {
        $c = $this->city();
        $places = $c->places();
        $covered = $c->covered();
        $draft = collect($this->trips)->where('on', true)->flatMap(fn ($t) => collect($t['cities'])->pluck('key'))->flip();
        $trucks = $c->trucks();
        $byId = $trucks->keyBy('id');
        $waitingTrips = $c->waitingForTruck();
        $freeTruck = $trucks->where('state', 'free')->reject(fn ($t) => $t['id'] === $this->kept)->first();
        $provinces = $places->reject(fn ($p) => $p['unclear'])->groupBy('province')->map(fn ($g, $p) => [
            'key' => Str::lower($p), 'name' => $p, 'boxes' => $g->sum('boxes'), 'days' => $g->max('days'),
            'planned' => $g->contains(fn ($x) => isset($draft[$x['key']]) || isset($covered[$x['key']])),
            'trip' => $g->map(fn ($x) => $covered[$x['key']] ?? null)->filter()->unique()->join(', '),
            'cities' => $g->sortByDesc('days')->values(),
        ])->sortByDesc('days')->values();
        $addrPage = str_replace('PlanTrips', 'AddressesToCheck', static::class);
        $here = (int) Auth::user()->warehouse_id;
        $out = $here && Coverage::active() ? Coverage::waitingTransfer($here)->countBy('home') : collect();
        $trPage = str_replace('PlanTrips', 'WarehouseTransfers', static::class);

        return [
            'provinces' => $provinces, 'max' => max(1, $provinces->max('boxes') ?? 1), 'waitTotal' => $places->sum('boxes'),
            'unclear' => $places->where('unclear', true)->sum('boxes'),
            'addrUrl' => static::class !== self::class && class_exists($addrPage) && $addrPage::canAccess() ? $addrPage::getUrl(['show' => 'all']) : null,
            'covered' => $covered, 'draft' => $draft,
            'cards' => collect($this->trips)->map(function ($t, $i) use ($byId) {
                $truck = $t['truck_id'] ? ($byId[$t['truck_id']] ?? null) : null;
                $pct = $t['cap'] ? min(100, (int) round($t['load'] / $t['cap'] * 100)) : 0;

                return $t + ['i' => $i, 'truck' => $truck, 'pct' => $pct, 'path' => collect($t['cities'])->pluck('city')->join(', ')];
            }),
            'onTrips' => collect($this->trips)->where('on', true),
            'trucks' => $trucks, 'kept' => $this->kept,
            'waitingTrips' => $waitingTrips, 'freeTruck' => $freeTruck,
            'unload' => $c->unloadingNow(),
            'top' => $this->topProvince(),
            'aiOn' => Ai::enabled('trips'),
            'tops' => collect($this->trips)->keys()->mapWithKeys(fn ($i) => [$i => $this->topOptions($i)])->all(),
            'sets' => collect($this->trips)->map(fn ($t) => $t['on'] ? $c->sets(collect($t['cities'])->pluck('key')->all()) : [])->all(),
            'changedAny' => collect($this->trips)->contains(fn ($t) => ! empty($t['changed'])),
            'needPlan' => TripRules::need('change_plan', Auth::user()),
            'reasons' => TripRules::reasons(),
            'transferOut' => $out->map(fn ($n, $w) => ['n' => $n, 'name' => Coverage::name((int) $w)])->values(),
            'arriving' => $here && Coverage::active() ? Coverage::arriving($here) : 0,
            'trUrl' => static::class !== self::class && class_exists($trPage) ? $trPage::getUrl() : null,
            'smsOn' => SmsSettings::on(static::$atHub ? 'out_for_delivery_hub' : 'out_for_delivery'),
            'smsUrl' => class_exists(\App\Filament\Pages\SmsSettings::class) && Filament::getCurrentPanel()?->getId() === 'admin' ? \App\Filament\Pages\SmsSettings::getUrl() : null,
            'hubsOn' => ! static::$atHub && HubAreas::ready() && HubAreas::hubs()->isNotEmpty(),
            'atHub' => static::$atHub, 'notMine' => $c->notMine(),
            'hubName' => static::$atHub ? Logistichub::whereKey(Auth::user()->logistichub_id)->value('hub_name') : null,
            'hubBoxes' => collect($this->hubPlan)->sum('boxes'),
            'directBoxes' => $places->reject(fn ($p) => $p['unclear'])->sum('boxes'),
            'hubColors' => ['#1d6fb8', '#c97a00', '#17895e', '#7a4fd6', '#c2410c', '#0e7490'],
        ];
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Filament/Tables/TripList.php
mkdir -p 'app/Filament/Tables'
cat > 'app/Filament/Tables/TripList.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Filament\Tables;

use App\Models\Deliverylog;
use App\Models\TripCity;
use App\Models\TripCrew;
use App\Models\TripOverride;
use App\Support\Hubs\HubAreas;
use App\Support\TripFlow;
use App\Support\Trips\TripRules;
use Filament\Actions\Action;
use Filament\Forms\Components\ToggleButtons;
use Filament\Schemas\Components\Tabs\Tab;
use Filament\Tables\Columns\ViewColumn;
use Filament\Tables\Filters\Filter;
use Illuminate\Contracts\Pagination\Paginator;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Delivery trips list (board 42): one clear row per trip, who made it (✦ AI, ✦ Plan trips, changed, by hand),
 * where it goes, truck and crew, boxes, status; tabs, Made by and Going to filters, details on the side.
 */
class TripList
{
    public const MADE = [
        'ai' => ['✦ AI', 'ai'],
        'plan' => ['✦ Plan trips', 'plan'],
        'changed' => ['✦ Plan trips · changed', 'changed'],
        'manual' => ['✎ By hand', 'manual'],
    ];

    /** Rows loaded once for the whole page by prime(): trip id => cities, cities from boxes, crew. */
    protected static array $primed = ['app' => null, 'cities' => [], 'boxCities' => [], 'crew' => []];

    protected static function primed(string $kind, int $id)
    {
        return static::$primed['app'] === spl_object_id(app()) ? (static::$primed[$kind][$id] ?? null) : null;
    }

    /** Load what every row needs in a few queries instead of several per trip (speed). */
    public static function prime(iterable $trips): void
    {
        $trips = collect($trips instanceof Paginator ? $trips->items() : $trips)->filter(fn ($t) => $t instanceof Model);
        if ($trips->isEmpty()) {
            return;
        }
        (new Collection($trips->all()))->loadMissing(['truck', 'user', 'destination']);
        $ids = $trips->pluck('id')->all();
        TripFlow::known($trips);
        static::$primed = ['app' => spl_object_id(app()), 'cities' => [], 'boxCities' => [], 'crew' => []];
        $cities = TripCity::whereIn('deliverylog_id', $ids)->get()->groupBy('deliverylog_id');
        $crew = TripCrew::with('user.workposition')->whereIn('deliverylog_id', $ids)->get()->groupBy('deliverylog_id');
        $noCities = array_values(array_diff($ids, $cities->keys()->all()));
        $box = collect();
        if ($noCities) {
            $sel = fn (string $col) => DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                ->whereIn('tripinvoices.'.$col, $noCities)->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                ->select('tripinvoices.'.$col.' as trip', 'invoices.receiver_province as province', 'invoices.receiver_city as city')->distinct()->get();
            $box = $sel('deliverylog_id')->concat($sel('deliveryloghub_id'))->groupBy('trip');
        }
        foreach ($ids as $id) {
            static::$primed['cities'][$id] = $cities->get($id, collect());
            static::$primed['crew'][$id] = $crew->get($id, collect());
            static::$primed['boxCities'][$id] = $box->get($id, collect())->unique(fn ($r) => $r->province.'|'.$r->city)->take(6)->values();
        }
    }

    protected static function citiesOf(Model $trip)
    {
        return static::primed('cities', $trip->id) ?? TripCity::where('deliverylog_id', $trip->id)->get();
    }

    protected static function hasMade(): bool
    {
        static $has = null;

        return $has ??= Schema::hasColumn('deliverylogs', 'made_by');
    }

    /** How the trip was made. Old trips: Plan trips when they have cities, else by hand. */
    public static function madeKey(Model $trip): string
    {
        $m = static::hasMade() ? $trip->made_by : null;
        if ($m && isset(self::MADE[$m])) {
            return $m;
        }

        return static::citiesOf($trip)->isNotEmpty() ? 'plan' : 'manual';
    }

    public static function isHubTrip(Model $trip): bool
    {
        return $trip->assigned_to && (int) $trip->assigned_to !== (int) $trip->logistichub_id;
    }

    /** @return array{to: string, cities: string, dot: string} */
    public static function goes(Model $trip): array
    {
        $cities = static::citiesOf($trip);
        if ($cities->isEmpty()) {
            $rows = static::primed('boxCities', $trip->id) ?? DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                ->where(fn ($q) => $q->where('tripinvoices.deliverylog_id', $trip->id)->orWhere('tripinvoices.deliveryloghub_id', $trip->id))
                ->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                ->select('invoices.receiver_province as province', 'invoices.receiver_city as city')->distinct()->limit(6)->get();
            $prov = Str::title((string) ($rows->first()->province ?? ''));
            $list = $rows->pluck('city')->map(fn ($c) => Str::title($c))->unique();
        } else {
            $prov = (string) $cities->first()->province;
            $list = $cities->pluck('city')->unique();
        }
        $cityText = $list->isEmpty() ? 'No boxes yet' : $list->take(3)->join(', ').($list->count() > 3 ? ' +'.($list->count() - 3) : '');
        if (static::isHubTrip($trip)) {
            $color = class_exists(HubAreas::class) ? HubAreas::color((int) $trip->assigned_to) : '#1d6fb8';

            return ['to' => '→ '.($trip->destination?->hub_name ?? 'Hub'), 'cities' => $cityText, 'dot' => $color];
        }

        return ['to' => $prov ?: ($list->isEmpty() ? 'Not set yet' : 'Direct'), 'cities' => $cityText, 'dot' => '#17895e'];
    }

    public static function crew(Model $trip)
    {
        return (static::primed('crew', $trip->id) ?? TripCrew::with('user.workposition')->where('deliverylog_id', $trip->id)->get())->sortBy(fn ($c) => TripFlow::isLead($c) ? 0 : 1)->values();
    }

    /** @return array{label: string, tone: string, when: string} */
    public static function status(Model $trip): array
    {
        $stage = TripFlow::ready() ? TripFlow::stage($trip) : ($trip->is_active ? 'loading' : 'closed');
        $label = $stage === 'back' ? 'Coming back' : (TripFlow::STAGES[$stage][0] ?? Str::title($stage));
        if ($stage === 'closed' && $trip->release_reason === 'auto') {
            $label = 'Done';
        }
        $when = match ($stage) {
            'road' => $trip->taken_at ? 'Left '.$trip->taken_at->format('g:i A') : 'On the road',
            'back' => ($n = TripFlow::left($trip)) > 0 ? $n.' '.Str::plural('return', $n).' to scan at the office' : ($trip->back_at ? 'Back '.$trip->back_at->format('g:i A') : 'Back at the hub'),
            'closed' => $trip->closed_at ? 'Done '.$trip->closed_at->format('M j g:i A') : 'Done',
            'ready' => $trip->ready_at ? 'Locked '.$trip->ready_at->format('g:i A') : 'Locked',
            'waiting' => 'Waits for the truck',
            default => $trip->departure_date ? 'Leaves '.Carbon::parse($trip->departure_date)->format('M j') : '',
        };

        return ['label' => $label, 'tone' => $stage, 'when' => $when];
    }

    /** "How this trip was made" lines for the details panel. */
    public static function how(Deliverylog $trip): array
    {
        $key = static::madeKey($trip);
        $note = static::hasMade() ? $trip->made_note : null;
        $lines = [];
        $lines[] = match ($key) {
            'ai' => ['✦', 'Plan trips with the AI'.($note ? ': “'.$note.'”' : '').'.'],
            'changed' => ['✎', 'Plan trips, changed before Create'.($note ? ': '.$note : '').'.'],
            'plan' => ['✦', ($note ?: (static::isHubTrip($trip) ? 'Plan trips › To hubs' : 'Plan trips')).' (system rules).'],
            default => ['✎', 'Made by hand in Delivery trips › New trip.'],
        };
        if ($trip->plan_why) {
            $lines[] = ['💬', 'Why: '.$trip->plan_why];
        }
        if (static::isHubTrip($trip)) {
            $lines[] = ['⌂', ($trip->destination?->hub_name ?? 'The hub').' delivers the boxes with its own trucks.'];
        }
        if (TripRules::ready()) {
            foreach (TripOverride::where('trip_id', $trip->id)->latest('id')->limit(4)->get() as $o) {
                $lines[] = ['⇄', (TripRules::RULES[$o->rule][0] ?? $o->rule).($o->box ? ' · '.$o->box : '').($o->reason ? ': '.$o->reason : '').' ('.$o->status.')'];
            }
        }

        return $lines;
    }

    /** @return list<ViewColumn> */
    public static function columns(): array
    {
        return [
            ViewColumn::make('trip_number')->label('Trip · made by')->view('filament.trips.list.trip')->searchable()->sortable(),
            ViewColumn::make('goes')->label('Going to')->view('filament.trips.list.goes'),
            ViewColumn::make('truck_view')->label('Truck · crew')->view('filament.trips.list.truck')
                ->searchable(query: fn (Builder $query, string $search) => $query->whereHas('truck', fn ($t) => $t->where('plate_no', 'like', "%{$search}%"))),
            ViewColumn::make('boxes_bar')->label('Boxes')->view('filament.trips.list.boxes'),
            ViewColumn::make('stage_view')->label('Status')->view('filament.trips.list.status'),
        ];
    }

    /** Made by and Going to, as chips above the list. */
    public static function filters(): array
    {
        return [
            Filter::make('made')
                ->schema([ToggleButtons::make('v')->label('Made by')->inline()->options(['all' => 'All', 'ai' => '✦ AI', 'plan' => '✦ Plan trips', 'manual' => '✎ By hand'])->default('all')])
                ->query(function (Builder $query, array $data) {
                    $q = $query;
                    $v = $data['v'] ?? 'all';
                    if ($v === 'all' || ! $v) {
                        return $q;
                    }
                    $hasCities = fn ($w) => $w->select(DB::raw(1))->from('trip_cities')->whereColumn('trip_cities.deliverylog_id', 'deliverylogs.id');
                    $made = static::hasMade();

                    return match ($v) {
                        'ai' => $made ? $q->where('deliverylogs.made_by', 'ai') : $q->whereRaw('1 = 0'),
                        'plan' => $q->where(fn ($w) => $made
                            ? $w->whereIn('deliverylogs.made_by', ['plan', 'changed'])->orWhere(fn ($n) => $n->whereNull('deliverylogs.made_by')->whereExists($hasCities))
                            : $w->whereExists($hasCities)),
                        'manual' => $q->where(fn ($w) => $made
                            ? $w->where('deliverylogs.made_by', 'manual')->orWhere(fn ($n) => $n->whereNull('deliverylogs.made_by')->whereNotExists($hasCities))
                            : $w->whereNotExists($hasCities)),
                        default => $q,
                    };
                })
                ->columnSpan(2)
                ->indicateUsing(fn (array $data) => ($data['v'] ?? 'all') !== 'all' ? 'Made by: '.(['ai' => 'AI', 'plan' => 'Plan trips', 'manual' => 'By hand'][$data['v']] ?? '') : null),
            Filter::make('going')
                ->schema([ToggleButtons::make('v')->label('Going to')->inline()->options(['all' => 'All', 'direct' => 'Direct', 'hub' => 'To hubs'])->default('all')])
                ->query(fn (Builder $query, array $data) => match ($data['v'] ?? 'all') {
                    'direct' => $query->whereColumn('deliverylogs.assigned_to', 'deliverylogs.logistichub_id'),
                    'hub' => $query->whereColumn('deliverylogs.assigned_to', '!=', 'deliverylogs.logistichub_id'),
                    default => $query,
                })
                ->indicateUsing(fn (array $data) => ($data['v'] ?? 'all') !== 'all' ? 'Going to: '.(['direct' => 'Direct', 'hub' => 'To hubs'][$data['v']] ?? '') : null),
        ];
    }

    /** Click a trip: its details on the side. */
    public static function details(): Action
    {
        return Action::make('details')
            ->label('Details')
            ->icon('heroicon-o-ellipsis-horizontal')
            ->iconButton()
            ->slideOver()
            ->modalWidth('lg')
            ->modalHeading(fn (Deliverylog $record) => 'Trip '.$record->trip_number)
            ->modalContent(fn (Deliverylog $record, $livewire) => view('filament.trips.list.details', ['trip' => $record,
                'editUrl' => method_exists($livewire, 'getResource') ? $livewire::getResource()::getUrl('edit', ['record' => $record]) : null]))
            ->modalSubmitAction(false)
            ->modalCancelActionLabel('Close');
    }

    /** All / Planned / Loading / On the road / Done. */
    public static function tabs(Builder $base): array
    {
        $loaded = fn ($w) => $w->select(DB::raw(1))->from('tripinvoices')->where('tripinvoices.is_loaded', true)
            ->where(fn ($x) => $x->whereColumn('tripinvoices.deliverylog_id', 'deliverylogs.id')->orWhereColumn('tripinvoices.deliveryloghub_id', 'deliverylogs.id'));
        $taken = Schema::hasColumn('deliverylogs', 'taken_at');
        $back = Schema::hasColumn('deliverylogs', 'back_at');
        $q = [
            'work' => fn (Builder $b) => $b->where('deliverylogs.is_active', true),
            'planned' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNull('deliverylogs.taken_at'))->whereNotExists($loaded),
            'loading' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNull('deliverylogs.taken_at'))->whereExists($loaded),
            'road' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNotNull('deliverylogs.taken_at'), fn ($x) => $x->whereRaw('1 = 0'))
                ->when($back, fn ($x) => $x->whereNull('deliverylogs.back_at')),
            'back' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($back, fn ($x) => $x->whereNotNull('deliverylogs.back_at'), fn ($x) => $x->whereRaw('1 = 0')),
            'done' => fn (Builder $b) => $b->where('deliverylogs.is_active', false),
            'all' => fn (Builder $b) => $b,
        ];
        // board 45c: only trips still at work by default; done trips stay in the Done tab
        $labels = ['work' => 'Still at work', 'planned' => 'Planned', 'loading' => 'Loading', 'road' => 'On the road', 'back' => 'Coming back', 'done' => 'Done', 'all' => 'All'];

        return collect($q)->mapWithKeys(fn ($fn, $k) => [$k => Tab::make($labels[$k])
            ->badge(fn () => $fn((clone $base))->count())
            ->modifyQueryUsing(fn (Builder $query) => $fn($query))])->all();
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Filament/Warehouse/Pages/NewBoxes.php
mkdir -p 'app/Filament/Warehouse/Pages'
cat > 'app/Filament/Warehouse/Pages/NewBoxes.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Filament\Warehouse\Pages;

use App\Filament\Shared\Trips\NewBoxesPage;

/** New boxes since the trips were made (board 45b). */
class NewBoxes extends NewBoxesPage {}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Support/Navigation/Menu.php
mkdir -p 'app/Support/Navigation'
cat > 'app/Support/Navigation/Menu.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Support\Navigation;

use App\Models\Shipping\WrongHubBox;
use App\Support\Shipping\Shipments;
use App\Support\Tracking\Tracker;
use App\Support\Trips\TripFill;
use Filament\Navigation\NavigationGroup;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;

/**
 * The side menu of the Admin, Warehouse and Partner hub panels, in one place:
 * the groups (in the order of the work of the day) and, per page, its group, name and place.
 * Pages not listed here keep their own group and name.
 */
class Menu
{
    /** Panel => [group name => folded at first]. */
    public const GROUPS = [
        'admin' => [
            'Boxes' => false, 'Trips & delivery' => false, 'Sea & partner hubs' => false, 'Money' => false,
            'AI helpers' => true, 'Scan on this computer' => false,
            'Settings · company & people' => true, 'Settings · places & routes' => true,
            'Settings · trucks & boxes' => true, 'Settings · messages & AI' => true, 'Help' => false,
        ],
        'warehouse' => [
            'Boxes' => false, 'Trips' => false, 'Sea & returns' => false, 'Scan on this computer' => false,
            'Trucks' => false, 'AI helpers' => true, 'Settings & help' => true,
        ],
        'company' => [
            'Coming in' => false, 'Delivery' => false, 'Returns' => false, 'Scan on this computer' => false,
            'Trucks & people' => false, 'AI helpers' => true, 'Settings & help' => true,
        ],
    ];

    /** Panel => [page or resource class (short, after the panel's namespace) => [group, name or null to keep, sort]]. */
    public const ITEMS = [
        'admin' => [
            'Resources\\ContainerResource' => ['Boxes', null, 1],
            'Resources\\Unmanifesteds\\UnmanifestedResource' => ['Boxes', null, 2],
            'Resources\\Inventories\\InventoryResource' => ['Boxes', 'Inventory', 3],
            'Pages\\WhereToUnload' => ['Boxes', null, 1],
            'Resources\\Boxsummaries\\BoxsummaryResource' => ['Boxes', 'Box summary', 4],
            'Resources\\Searchinvs\\SearchinvResource' => ['Boxes', 'Find a box', 5],
            'Resources\\Invoiceissues\\InvoiceissueResource' => ['Boxes', 'Box issues', 6],
            'Pages\\BoxPhotos' => ['Boxes', 'Box photos', 7],

            'Resources\\Deliverylogs\\DeliverylogResource' => ['Trips & delivery', 'Delivery trips', 1],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Trips & delivery', 'Delivery invoices', 2],
            'Pages\\PlanTrips' => ['Trips & delivery', null, 0],
            'Pages\\NewBoxes' => ['Trips & delivery', null, 0],
            'Pages\\AddressesToCheck' => ['Trips & delivery', null, 2],
            'Pages\\Overrides' => ['Trips & delivery', null, 2],
            'Pages\\WarehouseTransfers' => ['Trips & delivery', null, 2],
            'Pages\\CrewBoard' => ['Trips & delivery', null, 3],
            'Pages\\TruckTracking' => ['Trips & delivery', null, 4],
            'Pages\\TruckDay' => ['Trips & delivery', null, 5],

            'Pages\\SeaShipments' => ['Sea & partner hubs', null, 1],
            'Pages\\WrongHub' => ['Sea & partner hubs', null, 2],

            'Pages\\CostPerBox' => ['Money', null, 1],
            'Pages\\Fuel' => ['Money', null, 2],

            'Pages\\Scaninvoice' => ['Scan on this computer', 'Unload container', 1],
            'Pages\\Scanload' => ['Scan on this computer', 'Load truck', 2],
            'Pages\\ReturnBoxes' => ['Scan on this computer', 'Return boxes', 3],

            'Pages\\Companyinfo' => ['Settings · company & people', 'Company info', 1],
            'Pages\\AppIcons' => ['Settings · company & people', null, 2],
            'Pages\\PrintSettings' => ['Settings · company & people', null, 3],
            'Resources\\UserResource' => ['Settings · company & people', null, 4],
            '\\BezhanSalleh\\FilamentShield\\Resources\\Roles\\RoleResource' => ['Settings · company & people', null, 5],
            'Resources\\Workpositions\\WorkpositionResource' => ['Settings · company & people', 'Job positions', 6],
            'Resources\\PanelcategoryResource' => ['Settings · company & people', 'Account types', 7],

            'Resources\\Warehouses\\WarehouseResource' => ['Settings · places & routes', null, 1],
            'Pages\\WarehouseSections' => ['Settings · places & routes', null, 2],
            'Pages\\WarehouseCoverage' => ['Settings · places & routes', null, 2],
            'Pages\\HubAreas' => ['Settings · places & routes', null, 2],
            'Resources\\Logistichubs\\LogistichubResource' => ['Settings · places & routes', 'Logistic hubs', 3],
            'Pages\\HubIslands' => ['Settings · places & routes', null, 4],
            'Resources\\RouteareaResource' => ['Settings · places & routes', 'Route areas', 5],
            'Pages\\MapsRoutes' => ['Settings · places & routes', null, 6],

            'Pages\\Fleet' => ['Settings · trucks & boxes', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Settings · trucks & boxes', null, 1],
            'Resources\\Truckteams\\TruckteamResource' => ['Settings · trucks & boxes', 'Truck teams', 2],
            'Pages\\TrackingSettings' => ['Settings · trucks & boxes', 'Truck tracking settings', 3],
            'Pages\\FuelSettings' => ['Settings · trucks & boxes', 'Fuel settings', 4],
            'Pages\\BoxSizeSettings' => ['Settings · trucks & boxes', null, 5],
            'Pages\\TripRules' => ['Settings · trucks & boxes', null, 5],
            'Resources\\Boxissues\\BoxissueResource' => ['Settings · trucks & boxes', 'Box issue types', 6],
            'Pages\\BoxPhotoSettings' => ['Settings · trucks & boxes', 'Box photo settings', 7],
            'Pages\\AgingLimits' => ['Settings · trucks & boxes', null, 8],
            'Resources\\ConsolidatorResource' => ['Settings · trucks & boxes', null, 9],
            'Resources\\CompanyResource' => ['Settings · trucks & boxes', 'Agents', 10],

            'Pages\\SmsSettings' => ['Settings · messages & AI', null, 1],
            'Pages\\SmsLog' => ['Settings · messages & AI', null, 2],
            'Pages\\AiSettings' => ['Settings · messages & AI', 'AI settings', 3],
            'Pages\\AddressAi' => ['Settings · messages & AI', null, 4],
            'Resources\\HelpGuides\\HelpGuideResource' => ['Settings · messages & AI', 'Help guides (edit)', 4],

            'Pages\\HelpGuide' => ['Help', null, 1],
        ],
        'warehouse' => [
            'Resources\\Containers\\ContainerResource' => ['Boxes', null, 1],
            'Resources\\Inventories\\InventoryResource' => ['Boxes', 'Inventory', 2],
            'Pages\\Sections' => ['Boxes', null, 3],
            'Resources\\Searchinvs\\SearchinvResource' => ['Boxes', 'Find a box', 4],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Boxes', 'Delivery invoices', 5],
            'Resources\\Invoiceissues\\InvoiceissueResource' => ['Boxes', 'Box issues', 6],
            'Pages\\BoxPhotos' => ['Boxes', 'Box photos', 7],

            'Resources\\Deliverylogs\\DeliverylogResource' => ['Trips', 'Delivery trips', 1],
            'Resources\\Whdeliverylogs\\WhdeliverylogResource' => ['Trips', 'Transfers to other warehouses', 2],
            'Pages\\PlanTrips' => ['Trips', null, 0],
            'Pages\\NewBoxes' => ['Trips', null, 0],
            'Pages\\AddressesToCheck' => ['Trips', null, 2],
            'Pages\\Overrides' => ['Trips', null, 2],
            'Pages\\WarehouseTransfers' => ['Trips', null, 2],
            'Pages\\CrewBoard' => ['Trips', null, 3],
            'Pages\\TruckTracking' => ['Trips', null, 3],
            'Pages\\TruckDay' => ['Trips', null, 4],
            'Pages\\Fuel' => ['Trips', null, 5],

            'Pages\\SeaShipments' => ['Sea & returns', null, 1],
            'Pages\\ComingBack' => ['Sea & returns', null, 2],

            'Pages\\Unloadedcontainer' => ['Scan on this computer', 'Unload container', 1],
            'Pages\\Hubloaded' => ['Scan on this computer', 'Load delivery truck', 2],
            'Pages\\HubReturnBoxes' => ['Scan on this computer', 'Return boxes', 3],
            'Pages\\Whloaded' => ['Scan on this computer', 'Load transfer truck', 4],
            'Pages\\Whunloaded' => ['Scan on this computer', 'Receive transfer truck', 5],

            'Pages\\Fleet' => ['Trucks', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Trucks', null, 2],
            'Resources\\Truckteams\\TruckteamResource' => ['Trucks', 'Truck teams', 2],

            'Pages\\MapsRoutes' => ['Settings & help', null, 1],
            'Pages\\WarehouseCoverage' => ['Settings & help', null, 1],
            'Pages\\InstallApps' => ['Settings & help', null, 2],
            'Pages\\HelpGuide' => ['Settings & help', null, 3],
        ],
        'company' => [
            'Pages\\IncomingShipments' => ['Coming in', null, 1],
            'Pages\\IncomingBoxes' => ['Coming in', null, 2],

            'Pages\\PlanTrips' => ['Delivery', null, 0],
            'Resources\\Deliverylogs\\DeliverylogResource' => ['Delivery', 'Delivery trips', 1],
            'Resources\\Deliveryinvs\\DeliveryinvResource' => ['Delivery', 'Delivery invoices', 2],
            'Pages\\NotDelivered' => ['Delivery', null, 3],
            'Pages\\AddressesToCheck' => ['Delivery', null, 3],
            'Pages\\TrackBox' => ['Delivery', null, 4],
            'Pages\\MyArea' => ['Settings & help', 'My area', 0],

            'Pages\\WrongHub' => ['Returns', null, 1],

            'Pages\\LoadTruck' => ['Scan on this computer', 'Load truck', 1],
            'Pages\\ReturnBoxes' => ['Scan on this computer', 'Return boxes', 2],

            'Pages\\Fleet' => ['Trucks & people', 'Trucks', 1],
            'Pages\\RentalTrucks' => ['Trucks & people', null, 2],
            'Pages\\CrewBoard' => ['Trucks & people', null, 2],
            'Pages\\HubDrivers' => ['Trucks & people', null, 2],
            'Resources\\DriverResource' => ['Trucks & people', 'Crew', 3],
            'Pages\\TruckTracking' => ['Trucks & people', null, 4],
            'Pages\\TruckDay' => ['Trucks & people', null, 5],
            'Pages\\Fuel' => ['Trucks & people', null, 6],

            'Pages\\BoxPhotos' => ['Settings & help', 'Box photos', 1],
            'Pages\\MapsRoutes' => ['Settings & help', null, 2],
            'Pages\\InstallApps' => ['Settings & help', null, 3],
            'Pages\\HelpGuide' => ['Settings & help', null, 4],
        ],
    ];

    /** Pages with a number of what waits: panel => [short class => counter]. */
    public const BADGES = [
        'admin' => ['Pages\\SeaShipments' => 'sea', 'Pages\\WrongHub' => 'wrongHub', 'Pages\\NewBoxes' => 'newBoxes'],
        'warehouse' => ['Pages\\SeaShipments' => 'sea', 'Pages\\ComingBack' => 'comingBack', 'Pages\\NewBoxes' => 'newBoxes'],
        'company' => ['Pages\\IncomingShipments' => 'sea', 'Pages\\WrongHub' => 'wrongHub'],
    ];

    protected const BASE = ['admin' => 'App\\Filament\\', 'warehouse' => 'App\\Filament\\Warehouse\\', 'company' => 'App\\Filament\\Company\\'];

    public static function has(?string $panel): bool
    {
        return isset(self::GROUPS[$panel ?? '']);
    }

    /** @return array<NavigationGroup> */
    public static function groups(string $panel): array
    {
        return collect(self::GROUPS[$panel] ?? [])
            ->map(fn (bool $folded, string $name) => NavigationGroup::make($name)->collapsible()->collapsed($folded))
            ->values()->all();
    }

    protected static function full(string $panel, string $short): string
    {
        return str_starts_with($short, '\\') ? ltrim($short, '\\') : self::BASE[$panel].$short;
    }

    /** @return array<class-string, array{0: string, 1: ?string, 2: int}> */
    public static function items(string $panel): array
    {
        return collect(self::ITEMS[$panel] ?? [])->mapWithKeys(fn ($v, $k) => [static::full($panel, $k) => $v])->all();
    }

    /** @return array<class-string, string> */
    public static function badges(string $panel): array
    {
        return collect(self::BADGES[$panel] ?? [])->mapWithKeys(fn ($v, $k) => [static::full($panel, $k) => $v])->all();
    }

    /** The number shown beside a page, kept for a minute; null when nothing waits. */
    public static function count(string $panel, string $counter): ?string
    {
        $user = Auth::user();
        if (! $user) {
            return null;
        }
        try {
            $n = Cache::remember("menu:{$panel}:{$user->getKey()}:{$counter}", 60, function () use ($panel, $user, $counter): int {
                if ($counter === 'newBoxes') {
                    // new boxes of cities that already have a trip (board 45b)
                    return (int) collect(TripFill::newBoxes($user))->sum('n');
                }
                if (! Shipments::ready()) {
                    return 0;
                }
                $hub = Tracker::hubFor($user, $panel);
                if ($hub === false) {
                    return 0;
                }

                return match ($counter) {
                    'sea' => Shipments::visible($hub)->where('status', '!=', 'received')->count(),
                    'wrongHub' => WrongHubBox::query()->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->where('status', 'waiting')->count(),
                    'comingBack' => WrongHubBox::query()->where('status', 'returning')->count(),
                    default => 0,
                };
            });
        } catch (\Throwable) {
            return null;
        }

        return $n > 0 ? (string) $n : null;
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Support/TripFlow.php
mkdir -p 'app/Support'
cat > 'app/Support/TripFlow.php' <<'DISPATCH_FILE_END_10'
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
            }
        }
    }

    /** @return Collection<int, TripCrew> */
    public static function crew(Deliverylog $trip): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        static::copyCrew($trip);

        return TripCrew::with('user.workposition', 'replaces')->where('deliverylog_id', $trip->id)->orderBy('id')->get()
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
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- app/Support/Trips/CityTrips.php
mkdir -p 'app/Support/Trips'
cat > 'app/Support/Trips/CityTrips.php' <<'DISPATCH_FILE_END_11'
<?php

namespace App\Support\Trips;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\TripPlanner;
use App\Support\Hubs\HubAreas;
use App\Support\Maps\Barangays;
use App\Support\Rentals;
use App\Support\TripFlow;
use App\Support\TruckSpace;
use App\Support\Warehouses\Coverage;
use Filament\Facades\Filament;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Trips by city: nearby cities of one province fill one truck. A trip keeps its cities;
 * waiting boxes of those cities join when they are scanned onto the truck.
 */
class CityTrips
{
    public const DEFAULT_CAPACITY = 50;

    /** $atHub: a partner hub plans its own trips (boxes that arrived at the hub; added at Create). */
    public function __construct(public readonly User $user, public readonly bool $atHub = false) {}

    public static function ready(): bool
    {
        static $ready = null;

        return $ready ??= Schema::hasTable('trip_cities');
    }

    public static function isCityTrip(?Deliverylog $trip): bool
    {
        return $trip && static::ready() && TripCity::where('deliverylog_id', $trip->id)->exists();
    }

    /** Kept for this request: Plan trips asks for the same lists many times in one click. */
    protected ?TripPlanner $plannerMemo = null;

    protected ?Collection $placesMemo = null;

    protected ?array $coveredMemo = null;

    protected ?Collection $trucksMemo = null;

    protected function planner(): TripPlanner
    {
        return $this->plannerMemo ??= new TripPlanner($this->user, $this->atHub ? 'hub' : 'delivery');
    }

    /**
     * Waiting boxes by city: [key, province, city, boxes, space, receivers, biggest, days, prio, retry].
     */
    public function places(): Collection
    {
        return $this->placesMemo ??= $this->freshPlaces();
    }

    /** How these trips are made (Delivery trips › Made by): ['ai' => bool, 'instruction' => what was typed, 'reason' => why the plan was changed]. */
    public array $made = [];

    /** made_by / made_note of one planned trip. */
    protected function madeFields(array $t, string $default = 'plan'): array
    {
        if (! Schema::hasColumn('deliverylogs', 'made_by')) {
            return [];
        }
        if (! empty($t['changed'])) {
            return ['made_by' => 'changed', 'made_note' => Str::limit(trim(($t['changedNote'] ?? 'changed').(! empty($this->made['reason']) ? '. Reason: '.$this->made['reason'] : '')), 295, '')];
        }
        if (! empty($this->made['ai']) && filled($this->made['instruction'] ?? null)) {
            return ['made_by' => 'ai', 'made_note' => Str::limit((string) $this->made['instruction'], 295, '')];
        }

        return ['made_by' => $default, 'made_note' => null];
    }

    /** Cities of a hub's area delivered direct instead (keys "hubId|province|city"), set by Plan trips. */
    public array $direct = [];

    protected function isDirect(array $u): bool
    {
        if ($this->atHub) {
            // at a hub: only the boxes of its own area (a box of another hub came by mistake)
            return ! $u['hub'] || (int) $u['hub'] === (int) $this->user->logistichub_id;
        }

        return ! $u['hub'] || in_array($u['hub'].'|'.Str::lower($u['province']).'|'.Barangays::cityKey($u['city']), $this->direct, true);
    }

    /** Waiting boxes (one unit per receiver) this hub delivers itself. */
    public function waitingUnits(): Collection
    {
        return $this->planner()->units()->map(fn ($u) => $u + ['hub' => null])->filter(fn ($u) => $this->isDirect($u))->values();
    }

    /**
     * Put the waiting boxes of the trip's cities on it (board 45): urgent first, combos whole, up to the truck's space.
     * $hubId: boxes a partner hub delivers (a trip to that hub).
     */
    protected function fillTrip(Deliverylog $trip, array $cityKeys, float $cap, ?int $hubId = null): int
    {
        $keys = array_flip($cityKeys);
        $units = ($hubId ? $this->planner()->units()->filter(fn ($u) => (int) ($u['hub'] ?? 0) === $hubId) : $this->waitingUnits())
            ->filter(fn ($u) => isset($keys[TripFill::cityKey($u['province'], $u['city'])]));
        // boxes put on an earlier trip of this Create are not waiting any more
        $free = Invoice::whereIn('id', $units->flatMap(fn ($u) => $u['ids']))->where('is_assigned', false)->pluck('id')->flip();
        $units = $units->map(fn ($u) => ['ids' => array_values(array_filter($u['ids'], fn ($id) => isset($free[$id])))] + $u)
            ->filter(fn ($u) => $u['ids'])->map(fn ($u) => count($u['ids']) === $u['n'] ? $u : ['n' => count($u['ids']), 'space' => $u['space'] * count($u['ids']) / max(1, $u['n'])] + $u);
        [$picked] = TripFill::pick(TripFill::combos($units), $cap);

        return TripFill::addInvoices($trip, $picked);
    }

    /** Days a box has waited, per box id. */
    protected ?Collection $sinceMemo = null;

    protected function daysOf(array $u): int
    {
        if (! $this->sinceMemo) {
            $ids = $this->planner()->units()->flatMap(fn ($x) => $x['ids']);
            $this->sinceMemo = $ids->isEmpty() ? collect() : ($this->atHub
                ? Tripinvoice::whereIn('id', $ids)->get(['id', 'created_at'])->mapWithKeys(fn ($t) => [$t->id => $t->created_at])
                : Invoice::whereIn('id', $ids)->get(['id', 'verified_at', 'created_at'])->mapWithKeys(fn ($i) => [$i->id => $i->verified_at ?? $i->created_at]));
        }

        return (int) (collect($u['ids'])->map(fn ($id) => $this->sinceMemo[$id] ?? null)->filter()->map(fn ($d) => (int) floor(Carbon::parse($d)->diffInHours(now()) / 24))->max() ?? 0);
    }

    protected function freshPlaces(): Collection
    {
        // only the boxes the warehouse delivers direct; a hub's boxes are planned in "To hubs"
        $units = $this->planner()->units()->map(fn ($u) => $u + ['hub' => null])->filter(fn ($u) => $this->isDirect($u));
        $days = fn ($u) => $this->daysOf($u);

        return $units->groupBy(fn ($u) => Str::lower($u['province']).'|'.Barangays::cityKey($u['city']))->map(fn ($g, $k) => [
            'key' => $k, 'province' => $g->first()['province'], 'city' => $g->first()['city'],
            'boxes' => $g->sum('n'), 'space' => (int) ceil($g->sum('space')), 'receivers' => $g->count(), 'biggest' => (int) ceil($g->max('space')),
            'days' => (int) $g->map($days)->max(), 'prio' => $g->sum('prio'), 'retry' => $g->sum('retry'),
            'unclear' => $g->first()['city'] === 'No city',
            'via' => $this->atHub ? [] : $g->pluck('hub')->filter()->unique()->values()->all(),
        ])->values();
    }

    /**
     * Boxes a partner hub delivers, by hub and city.
     *
     * @return Collection<int, array{hub: int, name: string, boxes: int, space: int, days: int, prio: int, cities: Collection}>
     */
    public function hubPlaces(): Collection
    {
        if ($this->atHub) {
            return collect();
        }
        $units = $this->planner()->units()->map(fn ($u) => $u + ['hub' => null])->reject(fn ($u) => $this->isDirect($u));
        $names = Logistichub::whereIn('id', $units->pluck('hub')->unique())->pluck('hub_name', 'id');

        return $units->groupBy('hub')->map(function ($g, $hub) use ($names) {
            $cities = $g->groupBy(fn ($u) => Str::lower($u['province']).'|'.Barangays::cityKey($u['city']))->map(fn ($c, $k) => [
                'key' => $k, 'province' => $c->first()['province'], 'city' => $c->first()['city'], 'boxes' => $c->sum('n'),
                'space' => (int) ceil($c->sum('space')), 'days' => (int) $c->map(fn ($u) => $this->daysOf($u))->max(), 'prio' => $c->sum('prio') + $c->sum('retry'),
            ])->sortBy(fn ($c) => [-$c['prio'], -$c['days'], -$c['boxes']])->values();

            return ['hub' => (int) $hub, 'name' => (string) ($names[$hub] ?? 'Hub #'.$hub), 'boxes' => $cities->sum('boxes'), 'space' => $cities->sum('space'),
                'days' => (int) $cities->max('days'), 'prio' => $cities->sum('prio'), 'cities' => $cities];
        })->sortBy(fn ($h) => [-$h['prio'], -$h['days'], -$h['boxes']])->values();
    }

    /** Boxes for a hub still on the way (in containers not unloaded yet), for "wait for the next container". */
    public function comingFor(int $hubId): int
    {
        $map = HubAreas::map();
        if (! in_array($hubId, $map, true)) {
            return 0;
        }

        return Invoice::query()->where('is_verified', false)->where('is_delivered', false)->where('created_at', '>=', now()->subDays(60))->limit(3000)->get()
            ->filter(fn ($i) => HubAreas::hubOf($i, $map) === $hubId)->count();
    }

    /**
     * Trips to the hubs: one trip per hub, or more when the boxes do not fit one truck.
     * Whole cities go together (a city bigger than a truck goes on two trips: the truck-full check stops each truck).
     *
     * @param  array<int>  $usedTrucks  trucks already in the direct plan
     * @return list<array>
     */
    public function planHubs(array $usedTrucks = []): array
    {
        $trucks = $this->trucks();
        $free = $trucks->where('state', 'free')->reject(fn ($t) => in_array($t['id'], $usedTrucks, true))->values();
        $busy = $trucks->where('state', 'busy')->values();
        $fi = 0;
        $out = [];
        $open = $this->hubTripsOpen();
        foreach ($this->hubPlaces() as $h) {
            if (isset($open[$h['hub']])) {
                // a trip to this hub is open: its boxes join it when scanned
                $out[] = $h + ['trips' => [], 'coming' => 0, 'tip' => 'On '.implode(', ', $open[$h['hub']]).': boxes join when scanned onto the truck.', 'wait' => false, 'open' => $open[$h['hub']]];

                continue;
            }
            $slot = $free[$fi] ?? null;
            $cap = $slot['capacity'] ?? self::DEFAULT_CAPACITY;
            // first fit: each city (most urgent first) goes on the first trip with room, so trucks fill up;
            // a city bigger than a truck goes on more trips (the truck-full check stops each truck)
            $parts = [];
            foreach ($h['cities'] as $c) {
                $left = $c['space'];
                while ($left > 0) {
                    $fit = null;
                    foreach ($parts as $pi => $pt) {
                        if ($cap - $pt['load'] >= min($left, $cap)) {
                            $fit = $pi;
                            break;
                        }
                    }
                    if ($fit === null) {
                        $parts[] = ['cities' => [], 'load' => 0];
                        $fit = array_key_last($parts);
                    }
                    $take = min($left, $cap - $parts[$fit]['load']);
                    $parts[$fit]['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'province' => $c['province'],
                        'boxes' => $take === $c['space'] ? $c['boxes'] : (int) round($c['boxes'] * $take / max(1, $c['space'])), 'space' => $take];
                    $parts[$fit]['load'] += $take;
                    $left -= $take;
                }
            }
            $trips = [];
            foreach ($parts as $n => $pt) {
                $t = $free[$fi] ?? null;
                if ($t) {
                    $fi++;
                }
                $trips[] = ['cities' => $pt['cities'], 'load' => $pt['load'], 'cap' => $t['capacity'] ?? $cap, 'truck_id' => $t['id'] ?? null, 'plate' => $t['plate'] ?? null,
                    'when' => $t ? 'now' : 'later'];
            }
            $coming = $this->comingFor($h['hub']);
            $small = $h['space'] < $cap * 0.3;
            $tip = match (true) {
                $small && $coming > 0 && $h['prio'] === 0 => 'Wait: only '.$h['boxes'].' boxes; '.$coming.' more are on the way. One trip instead of two.',
                $small && $h['prio'] === 0 && $h['days'] < 3 => 'Small: only '.$h['boxes'].' boxes. Wait for more, or send if the hub needs them.',
                count($trips) > 1 && collect($trips)->contains('when', 'later') => 'Not enough free trucks: Trip 1 now with the priority and oldest boxes, the rest '.($coming ? 'with the next container' : 'when a truck is free').'.',
                count($trips) > 1 => count($trips).' trips: '.$h['boxes'].' boxes do not fit one truck. Priority and oldest on Trip 1.',
                $h['prio'] > 0 => 'Send today: '.$h['prio'].' priority or tried-before '.Str::plural('box', $h['prio']).', oldest '.$h['days'].' '.Str::plural('day', $h['days']).'.',
                default => 'Send: '.$h['boxes'].' boxes, oldest '.$h['days'].' '.Str::plural('day', $h['days']).'.',
            };
            if (! $free->count() && $busy->isNotEmpty()) {
                $tip .= ' No free truck now: '.$busy->first()['plate'].' comes back'.($busy->first()['on'] ? ' from '.$busy->first()['on'] : '').'.';
            }
            $out[] = $h + ['trips' => $trips, 'coming' => $coming, 'tip' => $tip, 'wait' => $small && $h['prio'] === 0, 'open' => []];
        }

        return $out;
    }

    /**
     * Make trips to a hub. The hub's waiting boxes go on them now (combos whole, up to the truck's space).
     *
     * @return list<array{id: int, number: string, truck: ?string}>
     */
    public function createHub(int $hubId, array $trips, Carbon $date, ?string $why = null): array
    {
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['cities'])) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date, $hubId, $why) {
                $truck = ! empty($t['truck_id']) ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $hubId, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) $why, 295), 'plan_space' => (int) $t['load'],
                ] + $this->madeFields([]));
                foreach (collect($t['cities'])->unique('key') as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $c['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'),
                        'planned_boxes' => (int) $c['boxes'], 'hub_id' => $hubId]);
                }
                // the hub's boxes go on the trip now (board 45)
                $this->fillTrip($trip, collect($t['cities'])->map(fn ($c) => TripFill::cityKey($c['province'], $c['city']))->unique()->all(),
                    (float) ($t['cap'] ?? self::DEFAULT_CAPACITY), $hubId);
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }

        return $made;
    }

    /**
     * Customers with 2+ boxes in these cities: kept together on the trip.
     *
     * @return list<array{name: string, city: string, n: int, missing: int}>
     */
    public function sets(array $cityKeys): array
    {
        $keys = array_flip($cityKeys);
        $units = $this->planner()->units()->filter(fn ($u) => isset($keys[Str::lower($u['province']).'|'.Barangays::cityKey($u['city'])]) && $u['n'] >= 2);
        $out = [];
        foreach ($units as $u) {
            $invIds = $this->atHub ? Tripinvoice::whereIn('id', $u['ids'])->pluck('invoice_id') : $u['ids'];
            $setKeys = Invoice::whereIn('id', $invIds)->pluck('set_key')->filter()->unique();
            $missing = $setKeys->isEmpty() ? 0 : Invoice::whereIn('set_key', $setKeys)->where('is_verified', false)->where('is_delivered', false)->count();
            $out[] = ['name' => $u['name'], 'city' => $u['city'], 'n' => $u['n'], 'missing' => $missing];
        }

        return collect($out)->sortBy(fn ($x) => [$x['missing'] ? 0 : 1, -$x['n']])->take(4)->values()->all();
    }

    /** Cities already on an open trip (planned or loading, not locked): city key => trip number. */
    public function covered(): array
    {
        return $this->coveredMemo ??= $this->freshCovered();
    }

    /** At a hub: boxes of another hub's area that came here by mistake. */
    public function notMine(): int
    {
        return $this->atHub ? $this->planner()->units()->filter(fn ($u) => ($u['hub'] ?? null) && (int) $u['hub'] !== (int) $this->user->logistichub_id)->sum('n') : 0;
    }

    protected function freshCovered(): array
    {
        if (! static::ready() || $this->atHub) {
            return [];
        }

        return TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->where('d.logistichub_id', $this->user->logistichub_id)
            ->when(Schema::hasColumn('trip_cities', 'hub_id'), fn ($q) => $q->whereNull('trip_cities.hub_id'))
            ->get(['trip_cities.province', 'trip_cities.city_key', 'd.trip_number'])
            ->mapWithKeys(fn ($r) => [Str::lower((string) $r->province).'|'.$r->city_key => $r->trip_number])->all();
    }

    /**
     * Open trips to each hub (not locked yet): hub id => trip numbers.
     *
     * @return array<int, list<string>>
     */
    public function hubTripsOpen(): array
    {
        if (! static::ready() || ! Schema::hasColumn('trip_cities', 'hub_id')) {
            return [];
        }

        return TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->where('d.logistichub_id', $this->user->logistichub_id)->whereNotNull('trip_cities.hub_id')->whereColumn('d.assigned_to', 'trip_cities.hub_id')
            ->get(['trip_cities.hub_id', 'd.trip_number'])->groupBy('hub_id')->map(fn ($g) => $g->pluck('trip_number')->unique()->values()->all())->all();
    }

    /** Trucks of the hub: free, out on a trip, kept, or off. */
    public function trucks(): Collection
    {
        return $this->trucksMemo ??= $this->freshTrucks();
    }

    protected function freshTrucks(): Collection
    {
        $all = Truck::where('logistichub_id', $this->user->logistichub_id)->orderBy('plate_no')->get();
        $usable = Rentals::usable(Truck::where('logistichub_id', $this->user->logistichub_id)->where('is_active', true))->pluck('id')->flip();
        // speed: every truck's crew in one query
        $crews = Truckcrew::with('member')->whereIn('truck_id', $all->pluck('id'))->get()->groupBy('truck_id');

        return $all->map(function (Truck $t) use ($usable, $crews) {
            $on = $t->is_assigned ? TripFlow::runningOn($t->id) : null;
            $state = match (true) {
                ! $t->is_active => 'off',
                ! isset($usable[$t->id]) => 'off',
                $on !== null => 'busy',
                (bool) $t->is_assigned => 'busy',
                default => 'free',
            };
            $sub = match ($state) {
                'free' => collect($crews->get($t->id, []))->map(fn ($c) => $c->member?->first_name)->filter()->join(' · ') ?: 'No crew yet',
                'busy' => $on ? 'On '.$on->trip_number.' · '.TripFlow::label($on) : 'On a trip',
                default => $t->is_active ? 'Rental, not booked today' : 'Inactive',
            };

            $stage = $on ? TripFlow::stage($on) : null;

            return ['id' => $t->id, 'plate' => $t->plate_no, 'state' => $state, 'sub' => $sub,
                'label' => match (true) {
                    $state === 'free' => 'Free now', $state === 'off' => 'Off', $stage === 'road' => 'Out', $stage === 'back' => 'Coming back', default => 'On a trip'
                }, 'on' => $on?->trip_number, 'onId' => $on?->id,
                'capacity' => TruckSpace::usable($t, self::DEFAULT_CAPACITY), 'rental' => $t->isRental()];
        })->sortBy(fn ($t) => [['free' => 0, 'busy' => 1, 'off' => 2][$t['state']], $t['rental'] ? 1 : 0, $t['plate']])->values();
    }

    /**
     * The draft: trips by province and city.
     *
     * @param  array{order?: string, first?: ?string, keep?: bool, full?: bool, instruction?: string}  $opt
     * @return array{trips: list<array>, kept: ?int, note: string, ai: bool}
     */
    public function plan(array $opt = []): array
    {
        $covered = $this->covered();
        $places = $this->places()->reject(fn ($p) => $p['unclear'] || isset($covered[$p['key']]));
        $trucks = $this->trucks();
        $free = $trucks->where('state', 'free')->values();
        $kept = ! empty($opt['keep']) && $free->count() > 1 ? $free->last()['id'] : null;
        $slots = $free->reject(fn ($t) => $t['id'] === $kept)->values()
            ->merge($trucks->where('state', 'busy')->values())
            ->push(null)->push(null)->values();

        $note = '';
        $ai = false;
        $why = [];
        $provinceOrder = null;
        if (filled($opt['instruction'] ?? null) && Ai::enabled('trips')) {
            try {
                $out = Ai::json('trips',
                    'You help plan delivery trips by city for a Philippine balikbayan box company. Read what the staff asked and answer the order of provinces to plan first, '
                    .'which truck ids to keep free, and one short reason per province. Answer as {"order":["Province",...],"keep_truck_ids":[id,...],"why":{"Province":"..."},"note":"one short sentence"}.',
                    json_encode(['asked' => $opt['instruction'], 'provinces' => $places->groupBy('province')->map(fn ($g, $p) => ['province' => $p, 'boxes' => $g->sum('boxes'), 'oldest_days' => $g->max('days'), 'cities' => $g->pluck('city')])->values(),
                        'trucks' => $trucks->where('state', '!=', 'off')->map(fn ($t) => ['id' => $t['id'], 'plate' => $t['plate'], 'state' => $t['state']])->values()], JSON_UNESCAPED_UNICODE),
                    'fast', 1200);
                $provinceOrder = array_values(array_filter((array) ($out['order'] ?? []), 'is_string'));
                $keepIds = array_map('intval', (array) ($out['keep_truck_ids'] ?? []));
                if ($keepIds) {
                    $slots = $slots->reject(fn ($t) => $t && in_array($t['id'], $keepIds, true))->values();
                    $kept = $keepIds[0];
                }
                $why = array_change_key_case((array) ($out['why'] ?? []));
                $note = Str::limit((string) ($out['note'] ?? ''), 200);
                $ai = true;
            } catch (AiUnavailable $e) {
                $note = 'Planned without AI ('.$e->getMessage().').';
            }
        }

        // provinces: oldest boxes first (or the one asked first), then the most boxes
        $byProv = $places->groupBy('province')->map(fn ($g, $p) => ['province' => $p, 'days' => $g->max('days'), 'boxes' => $g->sum('boxes'), 'urgent' => $g->sum('prio') + $g->sum('retry'), 'cities' => $g]);
        $rank = fn ($p) => [
            $provinceOrder ? (array_search(Str::lower($p['province']), array_map('strtolower', $provinceOrder), true) === false ? 99 : array_search(Str::lower($p['province']), array_map('strtolower', $provinceOrder), true)) : 0,
            ! empty($opt['first']) && Str::lower($p['province']) === Str::lower($opt['first']) ? 0 : 1,
            $p['urgent'] > 0 ? 0 : 1, -$p['days'], -$p['boxes'],
        ];
        $provs = $byProv->sortBy($rank)->values();

        $trips = [];
        $si = 0;
        foreach ($provs as $prov) {
            $cities = $prov['cities']->sortBy(fn ($c) => [-($c['prio'] + $c['retry']), -$c['days'], -$c['boxes']])->values();
            while ($cities->isNotEmpty() && $si < $slots->count()) {
                $slot = $slots[$si];
                $cap = $slot['capacity'] ?? self::DEFAULT_CAPACITY;
                $trip = ['province' => $prov['province'], 'cities' => [], 'load' => 0, 'cap' => $cap, 'days' => 0, 'truck_id' => $slot['id'] ?? null, 'on' => true, 'left' => []];
                $rest = collect();
                foreach ($cities as $c) {
                    if (! $trip['cities'] && $c['space'] > $cap) {
                        $trip['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space'], 'via' => $c['via'] ?? []];
                        $trip['load'] = $cap;
                        $trip['left'][] = $c['city'].' has '.$c['boxes'].' boxes: about '.max(0, $c['space'] - $cap).' wait for the next '.$prov['province'].' trip';
                        $trip['days'] = max($trip['days'], $c['days']);

                        continue;
                    }
                    if ($cap >= $trip['load'] + $c['space']) {
                        $trip['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space'], 'via' => $c['via'] ?? []];
                        $trip['load'] += $c['space'];
                        $trip['days'] = max($trip['days'], $c['days']);
                    } else {
                        $rest->push($c);
                    }
                }
                if (! $trip['cities']) {
                    break;
                }
                $trip['why'] = $this->why($trip, $prov, $rest, $slot, $why[Str::lower($prov['province'])] ?? null);
                $trips[] = $trip;
                $si++;
                $cities = $rest->values();
                // a city left over goes on the next trip of the same province only if it would be a real truckload
                if ($cities->sum('space') < ($slots[$si]['capacity'] ?? self::DEFAULT_CAPACITY) * 0.5) {
                    break;
                }
            }
        }

        foreach ($trips as &$t) {
            if (! empty($opt['full'])) {
                $t['on'] = $t['load'] >= $t['cap'] * 0.9;
            } elseif ($t['load'] < $t['cap'] * 0.3 && $t['days'] < 3) {
                // a small trip waits for more boxes (switch it on to send it anyway)
                $t['on'] = false;
                $t['why'] = 'Small trip: waits for more boxes. Switch it on to send it anyway. '.$t['why'];
            }
        }
        unset($t);
        if ($note === '') {
            $planned = collect($trips)->flatMap(fn ($t) => collect($t['cities'])->pluck('key'))->flip();
            $waitCities = $places->reject(fn ($p) => isset($planned[$p['key']]))->count();
            $note = $places->isEmpty() ? 'No boxes are waiting for a trip.' : count($trips).' '.Str::plural('trip', count($trips)).' · '.($waitCities ? $waitCities.' '.Str::plural('city', $waitCities).' wait' : 'every city planned');
        }

        return ['trips' => $trips, 'kept' => $kept, 'note' => $note, 'ai' => $ai];
    }

    protected function why(array $trip, array $prov, Collection $rest, ?array $slot, ?string $ai): string
    {
        $parts = [];
        if ($ai) {
            $parts[] = Str::finish(Str::limit($ai, 140), '.');
        } else {
            $urgent = collect($prov['cities'])->whereIn('key', collect($trip['cities'])->pluck('key'))->sum(fn ($c) => $c['prio'] + $c['retry']);
            $parts[] = ($trip['days'] >= 3 ? 'Oldest boxes ('.$trip['days'].' days)' : ($trip['days'] ? 'Boxes '.$trip['days'].' '.Str::plural('day', $trip['days']).' old' : 'New today'))
                .($urgent ? ', '.$urgent.' priority or tried before' : '').'.';
        }
        if ($rest->isNotEmpty()) {
            $parts[] = ($trip['load'] >= $trip['cap'] * 0.85 ? 'Full truck: ' : 'No room: ').$rest->map(fn ($c) => $c['city'].' ('.$c['boxes'].')')->join(', ').' '.($rest->count() > 1 ? 'wait' : 'waits').' for the next '.$prov['province'].' trip.';
        }
        $parts = array_merge($parts, $trip['left']);
        if ($slot && $slot['state'] === 'busy') {
            $parts[] = 'Waits for '.$slot['plate'].($slot['on'] ? ' ('.$slot['on'].')' : '').' to come back.';
        } elseif (! $slot) {
            $parts[] = 'No truck yet: give it to the next free truck.';
        }

        return implode(' ', $parts);
    }

    /**
     * Make the trips with their boxes (board 45): combos whole, urgent first, up to the truck's space.
     *
     * @return list<array{id: int, number: string, truck: ?string}>
     */
    public function create(array $trips, Carbon $date): array
    {
        if ($this->atHub) {
            return $this->createAtHub($trips, $date);
        }
        $this->plannerMemo = null; // fresh waiting boxes
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['on']) || empty($t['cities'])) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date) {
                $truck = $t['truck_id'] ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $this->user->logistichub_id, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) ($t['why'] ?? ''), 295), 'plan_space' => (int) $t['load'],
                ] + (Schema::hasColumn('deliverylogs', 'no_sms') ? ['no_sms' => array_key_exists('sms', $t) && ! $t['sms']] : []) + $this->madeFields($t));
                foreach ($t['cities'] as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => (int) $c['boxes']]);
                    // a hub's boxes of this city delivered direct instead
                    foreach ($c['via'] ?? [] as $hub) {
                        TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => 0, 'hub_id' => (int) $hub]);
                    }
                }
                // the boxes go on the trip now (board 45): combos whole, up to the truck's space
                $this->fillTrip($trip, collect($t['cities'])->map(fn ($c) => TripFill::cityKey($t['province'], $c['city']))->all(),
                    (float) ($t['cap'] ?? ($truck ? TruckSpace::usable($truck, self::DEFAULT_CAPACITY) : self::DEFAULT_CAPACITY)));
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }

        return $made;
    }

    /** A hub's own trips: the boxes of the trip's cities that are at the hub go on it now. */
    protected function createAtHub(array $trips, Carbon $date): array
    {
        $units = $this->planner()->units()->filter(fn ($u) => $this->isDirect($u));
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['on']) || empty($t['cities'])) {
                continue;
            }
            $keys = collect($t['cities'])->pluck('key')->flip();
            $ids = $units->filter(fn ($u) => isset($keys[Str::lower($u['province']).'|'.Barangays::cityKey($u['city'])]))->flatMap(fn ($u) => $u['ids'])->values();
            if ($ids->isEmpty()) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date, $ids) {
                $truck = $t['truck_id'] ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $this->user->logistichub_id, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) ($t['why'] ?? ''), 295), 'plan_space' => (int) $t['load'],
                ] + (Schema::hasColumn('deliverylogs', 'no_sms') ? ['no_sms' => array_key_exists('sms', $t) && ! $t['sms']] : []) + $this->madeFields($t));
                foreach ($t['cities'] as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => (int) $c['boxes']]);
                }
                app(TripAssignment::class)->addToHubTrip($trip, Tripinvoice::whereKey($ids)->get());
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }
        $this->plannerMemo = null;
        $this->placesMemo = null;

        return $made;
    }

    /** City trips that still wait for a truck, most urgent first. */
    public function waitingForTruck(): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $places = $this->places()->keyBy('key');

        return Deliverylog::with('cities')->whereNull('truck_id')->where('is_active', true)->where('logistichub_id', $this->user->logistichub_id)
            ->whereHas('cities')->get()
            ->map(fn ($trip) => ['trip' => $trip, 'province' => $trip->cities->first()?->province, 'cities' => $trip->cities->pluck('city')->join(', '),
                'days' => (int) $trip->cities->map(fn ($c) => $places[Str::lower((string) $c->province).'|'.$c->city_key]['days'] ?? 0)->max()])
            ->sortByDesc('days')->values();
    }

    /** "Give": a free truck takes a trip that waits for a truck. */
    public function give(Deliverylog $trip, int $truckId): Truck
    {
        return DB::transaction(function () use ($trip, $truckId) {
            $truck = Truck::whereKey($truckId)->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->where('is_assigned', false)->lockForUpdate()->firstOrFail();
            $trip->update(['truck_id' => $truck->id]);
            $truck->update(['is_assigned' => true]);
            TripFlow::copyCrew($trip->fresh());

            return $truck;
        });
    }

    /**
     * Load truck: a waiting box of one of the trip's cities joins the trip.
     *
     * @return array{0: ?Tripinvoice, 1: ?string} the box on the trip now, or why not
     */
    public static function join(Deliverylog $trip, string $code, bool $force = false, bool $forceHub = false): array
    {
        if (! static::ready()) {
            return [null, null];
        }
        $cities = TripCity::where('deliverylog_id', $trip->id)->get();
        if ($cities->isEmpty()) {
            return [null, null];
        }
        $inv = Invoice::where('invoice', $code)->where('is_delivered', false)->latest('id')->first();
        if (! $inv) {
            return [null, null];
        }
        if ($inv->is_assigned || Tripinvoice::where('invoice_id', $inv->id)->where('is_delivered', false)->whereHas('deliverylog', fn ($q) => $q->where('is_active', true))->exists()) {
            return [null, null];
        }
        if ($trip->is_lock) {
            return [null, 'Trip '.$trip->trip_number.' is locked: no more boxes join. Unlock it to add '.$code.'.'];
        }
        if (! $inv->is_verified) {
            return [null, $code.' is not unloaded yet (not scanned at Unload container).'];
        }
        $key = Barangays::cityKey($inv->receiver_city);
        // same city name in two provinces: the province must match too (a city saved without a province takes only boxes without one)
        $sameCity = $cities->filter(fn ($c) => $c->city_key === $key && Str::lower(Str::squish((string) $c->province)) === Str::lower(Str::squish((string) $inv->receiver_province)));
        $hasHub = Schema::hasColumn('trip_cities', 'hub_id');
        $boxHub = $hasHub ? HubAreas::hubOf($inv) : null;
        $match = $hasHub ? $sameCity->first(fn ($c) => (int) $c->hub_id === (int) $boxHub) : $sameCity->first();
        if (! $match && $hasHub && ! $forceHub) {
            $toHubTrip = $cities->every(fn ($c) => $c->hub_id && $trip->assigned_to && (int) $trip->assigned_to !== (int) $trip->logistichub_id);
            // a hub's box on our own trip, our box on a trip to a hub, or a box of another hub
            if ($sameCity->isNotEmpty() || $boxHub || $toHubTrip) {
                return [null, 'hub:'.(int) $boxHub];
            }
        }
        if (! $match && ! $force && ! $forceHub) {
            return [null, 'other-city'];
        }
        $added = app(TripAssignment::class)->addToDeliveryTrip($trip, collect([$inv]));
        if (! $added) {
            return [null, $code.' could not be added to '.$trip->trip_number.'.'];
        }

        return [Tripinvoice::with('invdata')->where('deliverylog_id', $trip->id)->where('invoice_id', $inv->id)->latest('id')->first(), null];
    }

    /** Unloading now: today's unloaded boxes by province, and where they go. */
    public function unloadingNow(): array
    {
        if ($this->atHub) {
            return ['container' => null, 'rows' => []];
        }
        $wh = $this->user->warehouse_id;
        $rows = Invoice::where('is_assigned', false)->where('is_delivered', false)->where('verified_at', '>=', today())
            ->when($wh && Filament::getCurrentPanel()?->getId() === 'warehouse', fn ($q) => $q->where('warehouse_id', $wh))
            ->with('container:id,container_no')->get(['id', 'container_id', 'receiver_province', 'receiver_city', 'wh_section_id', 'warehouse_id']);
        if ($rows->isEmpty()) {
            return ['container' => null, 'rows' => []];
        }
        $loading = static::ready() ? TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->whereNotNull('d.truck_id')->whereNull('d.waits_for')->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->leftJoin('trucks as t', 't.id', '=', 'd.truck_id')->get(['trip_cities.province', 'trip_cities.city_key', 't.plate_no'])
            ->mapWithKeys(fn ($r) => [Str::lower((string) $r->province).'|'.$r->city_key => $r->plate_no]) : collect();
        $byProv = $rows->groupBy(fn ($r) => Str::title(Str::squish((string) $r->receiver_province)) ?: 'No province')->sortByDesc(fn ($g) => $g->count());
        $out = [];
        $here = $this->user->warehouse_id;
        foreach ($byProv->take(2) as $prov => $g) {
            $plate = $g->map(fn ($r) => $loading[Str::lower(Str::squish((string) $r->receiver_province)).'|'.Barangays::cityKey($r->receiver_city)] ?? null)->filter()->first();
            $to = $here ? Coverage::transferTo($g->first(), $here) : null;
            $out[] = [$prov.' · '.$g->count().' '.Str::plural('box', $g->count()), $to ? 'Transfer → '.Coverage::name($to) : ($plate ? $plate.' is here → straight on' : 'Sections'), (bool) $plate];
        }
        if ($byProv->count() > 2) {
            $n = $byProv->slice(2)->sum(fn ($g) => $g->count());
            $out[] = ['Others · '.$n.' '.Str::plural('box', $n), 'Sections', false];
        }

        return ['container' => $rows->sortByDesc('id')->first()->container?->container_no, 'rows' => $out];
    }
}
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- app/Support/Trips/TripFill.php
mkdir -p 'app/Support/Trips'
cat > 'app/Support/Trips/TripFill.php' <<'DISPATCH_FILE_END_12'
<?php

namespace App\Support\Trips;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\TripPlanner;
use App\Support\BoxSizes;
use App\Support\Maps\Barangays;
use App\Support\TruckSpace;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Boxes onto trips (boards 45, 45b, 45d).
 *
 * - Combos: one receiver's boxes, and the boxes of one set, always go together (never split).
 * - pick(): fills the room of a trip, urgent first, combos before single boxes, first fit.
 * - newBoxes(): waiting boxes of cities that already have a trip: add to a trip with room,
 *   full → new trip or Add anyway (space is an estimate), locked or on the road → new trip.
 * - placeAtHub(): a partner hub's unload scan puts each box on the hub's open trip of its city.
 */
class TripFill
{
    public const RULE = 'truck_full';

    public static function cityKey(?string $province, ?string $city): string
    {
        return Str::lower(Str::squish((string) $province)).'|'.Barangays::cityKey((string) $city);
    }

    /** The space a trip can take: the truck's usable space, else the default. */
    public static function cap(Deliverylog $trip): int
    {
        $truck = $trip->truck;

        return $truck ? TruckSpace::usable($truck, CityTrips::DEFAULT_CAPACITY) : CityTrips::DEFAULT_CAPACITY;
    }

    /** Space of every box on the trip (loaded or not). A partner hub's own trip counts deliveryloghub_id. */
    public static function used(Deliverylog $trip): float
    {
        $hubOwn = (int) $trip->assigned_to === (int) $trip->logistichub_id && Tripinvoice::where('deliveryloghub_id', $trip->id)->exists();
        $rows = Tripinvoice::with('invdata:id,boxtype')->where($hubOwn ? 'deliveryloghub_id' : 'deliverylog_id', $trip->id)->get();

        return (float) $rows->sum(fn ($r) => BoxSizes::spaceOf($r->invdata?->boxtype));
    }

    /**
     * Combos from planner units (one unit = one receiver): units that share a set are merged.
     *
     * @return Collection<int, array{key: string, ids: list<int>, n: int, space: float, prio: int, retry: int, name: string, province: string, city: string, city_key: string, kind: string, codes: list<string>}>
     */
    public static function combos(Collection $units, bool $hubRows = false): Collection
    {
        $units = $units->values();
        if ($units->isEmpty()) {
            return collect();
        }
        $allIds = $units->flatMap(fn ($u) => $u['ids'])->values();
        $invIds = $hubRows ? Tripinvoice::whereIn('id', $allIds)->pluck('invoice_id', 'id') : null;
        $inv = Invoice::whereIn('id', $hubRows ? $invIds->values() : $allIds)->get(['id', 'invoice', 'set_key'])->keyBy('id');
        $invOf = fn ($id) => $inv[$hubRows ? ($invIds[$id] ?? 0) : $id] ?? null;

        // union units that share a set key
        $parent = range(0, $units->count() - 1);
        $find = function ($i) use (&$parent, &$find) {
            return $parent[$i] === $i ? $i : ($parent[$i] = $find($parent[$i]));
        };
        $bySet = [];
        foreach ($units as $i => $u) {
            foreach ($u['ids'] as $id) {
                $sk = $invOf($id)?->set_key;
                if ($sk) {
                    if (isset($bySet[$sk])) {
                        $parent[$find($i)] = $find($bySet[$sk]);
                    } else {
                        $bySet[$sk] = $i;
                    }
                }
            }
        }
        $groups = [];
        foreach ($units as $i => $u) {
            $groups[$find($i)][] = $i;
        }

        return collect($groups)->map(function ($members) use ($units, $invOf) {
            $us = collect($members)->map(fn ($i) => $units[$i]);
            $first = $us->first();
            $ids = $us->flatMap(fn ($u) => $u['ids'])->values()->all();
            $n = count($ids);
            // a set: the same receiver name, phone and city (one set key); else boxes of one receiver
            $set = $n >= 2 && collect($ids)->map(fn ($id) => $invOf($id)?->set_key)->filter()->unique()->count() === 1;

            return [
                'key' => 'c'.md5(implode(',', $ids)), 'ids' => $ids, 'n' => $n, 'space' => (float) $us->sum('space'),
                'prio' => (int) $us->sum('prio'), 'retry' => (int) $us->sum('retry'), 'name' => (string) $first['name'],
                'province' => (string) $first['province'], 'city' => (string) $first['city'], 'city_key' => static::cityKey($first['province'], $first['city']),
                'barangay' => (string) ($first['barangay'] ?? ''), 'hub' => $first['hub'] ?? null,
                'kind' => $n < 2 ? 'single' : ($set ? 'set' : 'receiver'),
                'codes' => collect($ids)->map(fn ($id) => $invOf($id)?->invoice)->filter()->values()->all(),
            ];
        })->values();
    }

    /** Urgent first, combos before single boxes, bigger combos first. */
    public static function order(Collection $combos): Collection
    {
        return $combos->sortBy(fn ($c) => [-($c['prio'] + $c['retry']), $c['n'] >= 2 ? 0 : 1, -$c['n'], $c['barangay'] ?? '', $c['name']])->values();
    }

    /**
     * Fill $room: first fit, a combo is taken whole or not at all.
     *
     * @return array{0: Collection, 1: Collection} [picked, rest]
     */
    public static function pick(Collection $combos, float $room): array
    {
        $picked = collect();
        $rest = collect();
        $left = $room;
        foreach (static::order($combos) as $c) {
            if ($c['space'] <= $left + 0.001) {
                $picked->push($c);
                $left -= $c['space'];
            } else {
                $rest->push($c);
            }
        }

        return [$picked, $rest];
    }

    /** Put these combos (invoice ids) on a delivery trip. Returns boxes added. */
    public static function addInvoices(Deliverylog $trip, Collection $combos): int
    {
        $ids = $combos->flatMap(fn ($c) => $c['ids'])->unique()->values();
        if ($ids->isEmpty()) {
            return 0;
        }
        $added = app(TripAssignment::class)->addToDeliveryTrip($trip, Invoice::whereIn('id', $ids)->where('is_assigned', false)->get());
        static::countCities($trip);

        return $added;
    }

    /** Planned boxes per city = boxes now on the trip (Delivery trips, the trip page). */
    public static function countCities(Deliverylog $trip, bool $hubOwn = false): void
    {
        if (! CityTrips::ready() || ! Schema::hasColumn('trip_cities', 'planned_boxes')) {
            return;
        }
        $rows = DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
            ->where('tripinvoices.'.($hubOwn ? 'deliveryloghub_id' : 'deliverylog_id'), $trip->id)
            ->get(['invoices.receiver_province as p', 'invoices.receiver_city as c'])
            ->countBy(fn ($r) => static::cityKey($r->p, $r->c));
        foreach (TripCity::where('deliverylog_id', $trip->id)->get() as $tc) {
            if ($tc->hub_id && (int) $tc->hub_id !== (int) $trip->assigned_to) {
                continue;
            }
            $tc->update(['planned_boxes' => (int) ($rows[static::cityKey($tc->province, $tc->city)] ?? 0)]);
        }
    }

    // ------------------------------------------------------------------ new boxes (Admin and Warehouse)

    /** Open trips of the hub (not locked, not left) and today's closed-to-new-boxes trips, per city key. */
    protected static function tripsByCity(User $user): array
    {
        if (! CityTrips::ready()) {
            return [[], []];
        }
        $taken = Schema::hasColumn('deliverylogs', 'taken_at');
        $rows = TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where('d.logistichub_id', $user->logistichub_id)
            ->when(Schema::hasColumn('trip_cities', 'hub_id'), fn ($q) => $q->whereNull('trip_cities.hub_id'))
            ->get(['trip_cities.province', 'trip_cities.city', 'd.id', 'd.is_lock', $taken ? 'd.taken_at' : DB::raw('null as taken_at')]);
        $open = [];
        $closed = [];
        foreach ($rows as $r) {
            $k = static::cityKey($r->province, $r->city);
            if ($r->is_lock || $r->taken_at) {
                $closed[$k][$r->id] = $r->id;
            } else {
                $open[$k][$r->id] = $r->id;
            }
        }

        return [$open, $closed];
    }

    /**
     * Waiting boxes of cities that already have a trip.
     *
     * @return list<array{key: string, city: string, province: string, n: int, combos: list<array>, kind: string, trip: ?array, fit: list<string>, newN: int}>
     */
    public static function newBoxes(User $user): array
    {
        $ct = new CityTrips($user);
        [$open, $closed] = static::tripsByCity($user);
        if (! $open && ! $closed) {
            return [];
        }
        $units = $ct->waitingUnits()->filter(fn ($u) => isset($open[static::cityKey($u['province'], $u['city'])]) || isset($closed[static::cityKey($u['province'], $u['city'])]));
        if ($units->isEmpty()) {
            return [];
        }
        $trips = Deliverylog::with('truck')->whereIn('id', collect($open)->flatten()->merge(collect($closed)->flatten())->unique())->get()->keyBy('id');
        $usedOf = [];
        $out = [];
        foreach (static::combos($units)->groupBy('city_key') as $key => $combos) {
            $best = null;
            foreach ($open[$key] ?? [] as $id) {
                $t = $trips[$id] ?? null;
                if (! $t) {
                    continue;
                }
                $used = $usedOf[$id] ??= static::used($t);
                $room = static::cap($t) - $used;
                if (! $best || $room > $best['room']) {
                    $best = ['id' => $t->id, 'number' => (string) $t->trip_number, 'used' => $used, 'cap' => static::cap($t), 'room' => $room];
                }
            }
            $kind = $best ? ($best['room'] >= min($combos->min('space'), 1) ? 'open' : 'full') : 'closed';
            [$fit] = $best ? static::pick($combos, max(0, $best['room'])) : [collect()];
            $first = $combos->first();
            if (! $best && ($cl = collect($closed[$key] ?? [])->map(fn ($id) => $trips[$id] ?? null)->filter()->first())) {
                $best = ['id' => $cl->id, 'number' => (string) $cl->trip_number, 'used' => 0, 'cap' => static::cap($cl), 'room' => 0, 'locked' => true,
                    'state' => $cl->is_lock ? 'Locked' : 'On the road'];
            }
            $out[] = [
                'key' => $key, 'city' => $first['city'], 'province' => $first['province'], 'n' => (int) $combos->sum('n'), 'space' => (float) $combos->sum('space'),
                'combos' => static::order($combos)->map(fn ($c) => $c + ['fits' => $fit->contains('key', $c['key'])])->all(),
                'kind' => $kind, 'trip' => $best, 'fit' => $fit->pluck('key')->all(), 'newN' => (int) ($combos->sum('n') - $fit->sum('n')),
            ];
        }

        return collect($out)->sortBy(fn ($r) => [['open' => 0, 'full' => 1, 'closed' => 2][$r['kind']], $r['province'], $r['city']])->values()->all();
    }

    /**
     * Add picked combos of a city to a trip. Over the room needs $anyway and a reason (saved with the name).
     *
     * @return array{ok: bool, msg: string, added?: int}
     */
    public static function addPicked(User $user, string $cityKey, int $tripId, array $comboKeys, bool $anyway = false, ?string $reason = null): array
    {
        $row = collect(static::newBoxes($user))->firstWhere('key', $cityKey);
        $trip = Deliverylog::where('logistichub_id', $user->logistichub_id)->find($tripId);
        if (! $row || ! $trip || ! $trip->is_active) {
            return ['ok' => false, 'msg' => 'These boxes or this trip changed. Look again.'];
        }
        if ($trip->is_lock || (Schema::hasColumn('deliverylogs', 'taken_at') && $trip->taken_at)) {
            return ['ok' => false, 'msg' => 'Trip '.$trip->trip_number.' is locked or on the road: no more boxes join. Make a new trip.'];
        }
        $picked = collect($row['combos'])->whereIn('key', $comboKeys);
        if ($picked->isEmpty()) {
            return ['ok' => false, 'msg' => 'Pick at least one box.'];
        }
        $over = static::used($trip) + $picked->sum('space') - static::cap($trip);
        if ($over > 0.001 && ! $anyway) {
            return ['ok' => false, 'msg' => 'Over the space of '.$trip->trip_number.'. Use Add anyway (space is an estimate).'];
        }
        if ($over > 0.001 && blank($reason)) {
            return ['ok' => false, 'msg' => 'Add anyway needs a reason.'];
        }
        $added = static::addInvoices($trip, $picked);
        if ($over > 0.001) {
            TripRules::record(self::RULE, $user, $reason, ['trip_id' => $trip->id, 'trip_number' => $trip->trip_number,
                'note' => 'Add anyway: '.$added.' new '.Str::plural('box', $added).' of '.$row['city'].' over the estimate']);
        }

        return ['ok' => true, 'added' => $added, 'msg' => $added.' '.Str::plural('box', $added).' added to '.$trip->trip_number.' as “Not loaded”'.($over > 0.001 ? ' (Add anyway, saved with your name)' : '').'.'];
    }

    /**
     * A new trip for the waiting boxes of these cities (one trip per province), with a free truck,
     * else the truck that is free first (the trip waits for it).
     *
     * @return list<array{id: int, number: string, truck: ?string}>
     */
    public static function newTrips(User $user, array $cityKeys, ?string $why = null): array
    {
        $ct = new CityTrips($user);
        $keys = array_flip($cityKeys);
        $places = $ct->places()->filter(fn ($p) => isset($keys[static::cityKey($p['province'], $p['city'])]));
        if ($places->isEmpty()) {
            return [];
        }
        $trucks = $ct->trucks();
        $slots = $trucks->where('state', 'free')->values()->merge($trucks->where('state', 'busy')->values());
        $si = 0;
        $trips = [];
        foreach ($places->groupBy('province') as $prov => $cities) {
            $slot = $slots[$si++] ?? null;
            $trips[] = ['province' => $prov, 'cities' => $cities->map(fn ($c) => ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space'], 'via' => []])->values()->all(),
                'load' => (int) $cities->sum('space'), 'cap' => $slot['capacity'] ?? CityTrips::DEFAULT_CAPACITY, 'truck_id' => $slot['id'] ?? null, 'on' => true,
                'why' => $why ?? 'New boxes for cities whose trip is full, locked or on the road.'];
        }
        $ct->made = ['ai' => true, 'instruction' => 'New boxes after the trips were made'];

        return $ct->create($trips, today());
    }

    /** Apply: every city's boxes to its trip with room; the rest on new trips. */
    public static function applyAll(User $user): array
    {
        $added = 0;
        $toNew = [];
        foreach (static::newBoxes($user) as $r) {
            if ($r['kind'] === 'open' && $r['fit']) {
                $res = static::addPicked($user, $r['key'], $r['trip']['id'], $r['fit']);
                $added += $res['added'] ?? 0;
                if ($r['newN'] > 0) {
                    $toNew[] = $r['key'];
                }
            } else {
                $toNew[] = $r['key'];
            }
        }
        $made = $toNew ? static::newTrips($user, $toNew) : [];

        return ['added' => $added, 'made' => $made];
    }

    // ------------------------------------------------------------------ partner hub unload scan

    /** The hub's own trips open for boxes (not locked, not left). */
    protected static function hubOpenTrips(int $hubId, string $cityKey): Collection
    {
        if (! CityTrips::ready()) {
            return collect();
        }
        $ids = TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where('d.logistichub_id', $hubId)->where('d.assigned_to', $hubId)
            ->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->when(Schema::hasColumn('deliverylogs', 'taken_at'), fn ($q) => $q->whereNull('d.taken_at'))
            ->get(['trip_cities.province', 'trip_cities.city', 'd.id'])
            ->filter(fn ($r) => static::cityKey($r->province, $r->city) === $cityKey)->pluck('id')->unique();

        return Deliverylog::with('truck')->whereIn('id', $ids)->orderBy('id')->get();
    }

    /** Boxes of the same combo (same receiver, or same set) waiting at the hub or still on the truck. */
    protected static function siblings(Tripinvoice $row, int $hubId): Collection
    {
        $inv = $row->invdata;
        if (! $inv) {
            return collect();
        }
        $rk = TripPlanner::receiverKey($inv);
        $cands = Tripinvoice::with('invdata')->where('logistichub_id', $hubId)->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->whereKeyNot($row->id)
            ->whereHas('invdata', fn ($q) => $q->where('receiver_city', $inv->receiver_city))->limit(200)->get();

        return $cands->filter(fn ($t) => $t->invdata && (TripPlanner::receiverKey($t->invdata) === $rk || ($inv->set_key && $t->invdata->set_key === $inv->set_key)))->values();
    }

    /**
     * Scan app · Receive truck at a partner hub: put the box on the hub's open trip of its city.
     * Its combo goes where the rest of the combo is. Full → a new hub trip (Add anyway offered).
     *
     * @return ?array{trip: string, tripId: int, why: string, kind: string, full?: array{id: int, number: string}}
     */
    public static function placeAtHub(Tripinvoice $row, int $hubId, ?User $by = null): ?array
    {
        $row->loadMissing('invdata');
        if ($row->hub_assigned || $row->deliveryloghub_id || ! $row->invdata) {
            return null;
        }
        $inv = $row->invdata;
        $key = static::cityKey($inv->receiver_province, $inv->receiver_city);
        $open = static::hubOpenTrips($hubId, $key);
        $sib = static::siblings($row, $hubId);
        $space = BoxSizes::spaceOf($inv->boxtype);
        $assign = app(TripAssignment::class);

        // the combo's other boxes are already on an open trip: this one goes with them (never split)
        $with = $sib->first(fn ($s) => $s->deliveryloghub_id && $open->contains('id', $s->deliveryloghub_id));
        if ($with) {
            $trip = $open->firstWhere('id', $with->deliveryloghub_id);
            $assign->addToHubTrip($trip, [$row]);
            static::countCities($trip, true);

            return ['trip' => $trip->trip_number, 'tripId' => $trip->id, 'kind' => 'ok', 'why' => 'With the rest of its combo ('.$inv->receiver_name.') · '.static::fmt($trip)];
        }
        if ($open->isEmpty()) {
            return null; // no trip for this city yet: Plan trips makes it
        }
        // room for the box and the rest of its combo still coming
        $need = $space + $sib->filter(fn ($s) => ! $s->deliveryloghub_id)->sum(fn ($s) => BoxSizes::spaceOf($s->invdata?->boxtype));
        $fits = $open->first(fn ($t) => static::cap($t) - static::used($t) >= $need - 0.001);
        if ($fits) {
            $assign->addToHubTrip($fits, [$row]);
            static::countCities($fits, true);

            return ['trip' => $fits->trip_number, 'tripId' => $fits->id, 'kind' => 'ok', 'why' => 'Added · '.static::fmt($fits)];
        }
        // full: a new hub trip with a free truck (made at unload, by the AI)
        $full = $open->first();
        $new = static::newHubTrip($hubId, $inv, $by);
        $assign->addToHubTrip($new, [$row]);
        static::countCities($new, true);

        return ['trip' => $new->trip_number, 'tripId' => $new->id, 'kind' => 'new', 'full' => ['id' => $full->id, 'number' => (string) $full->trip_number],
            'why' => $full->trip_number.' is full ('.static::fmt($full).') · new trip '.$new->trip_number.($new->truck ? ' with '.$new->truck->plate_no : ' (no free truck yet)')];
    }

    /** "34 of 35" */
    public static function fmt(Deliverylog $trip): string
    {
        return BoxSizes::fmt(static::used($trip)).' of '.static::cap($trip);
    }

    /** A new hub trip for one city: the hub's free truck (else none yet). */
    protected static function newHubTrip(int $hubId, Invoice $inv, ?User $by): Deliverylog
    {
        $user = $by ?? User::where('logistichub_id', $hubId)->first();
        $ct = new CityTrips($user, true);
        // a free truck that is not on another open trip
        $onTrips = Deliverylog::where('is_active', true)->whereNotNull('truck_id')->pluck('truck_id')->flip();
        $free = $ct->trucks()->where('state', 'free')->first(fn ($t) => ! isset($onTrips[$t['id']]));
        $truck = $free ? Truck::find($free['id']) : null;

        return DB::transaction(function () use ($hubId, $inv, $user, $truck) {
            $trip = Deliverylog::create([
                'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => today()->addDay()->toDateString(), 'departure_date' => today()->addDay()->toDateString(),
                'logistichub_id' => $hubId, 'assigned_to' => $hubId, 'user_id' => $user?->id,
                'plan_why' => 'The trip for '.Str::title((string) $inv->receiver_city).' was full when the boxes were unloaded.',
            ] + (Schema::hasColumn('deliverylogs', 'made_by') ? ['made_by' => 'ai', 'made_note' => 'New trip at unload (trip full)'] : []));
            TripCity::create(['deliverylog_id' => $trip->id, 'province' => Str::title((string) $inv->receiver_province), 'city' => Str::title((string) $inv->receiver_city),
                'city_key' => Barangays::cityKey((string) $inv->receiver_city), 'planned_boxes' => 0]);
            if ($truck && ! $truck->is_assigned) {
                $truck->update(['is_assigned' => true]);
            }

            return $trip->fresh('truck');
        });
    }

    /** Add anyway at the hub: move the box (and its combo) from the new trip to the full one. */
    public static function hubAddAnyway(Tripinvoice $row, int $fullTripId, User $by, ?string $reason = null): array
    {
        $full = Deliverylog::where('logistichub_id', $by->logistichub_id)->find($fullTripId);
        if (! $full || ! $full->is_active || $full->is_lock || (Schema::hasColumn('deliverylogs', 'taken_at') && $full->taken_at)) {
            return ['ok' => false, 'msg' => 'That trip is locked or left: the box stays on the new trip.'];
        }
        $from = $row->deliveryloghub_id ? Deliverylog::find($row->deliveryloghub_id) : null;
        $move = collect([$row])->merge(static::siblings($row, (int) $by->logistichub_id)->filter(fn ($s) => $from && (int) $s->deliveryloghub_id === $from->id));
        foreach ($move as $m) {
            $m->update(['deliveryloghub_id' => $full->id, 'hub_assigned' => true]);
        }
        static::countCities($full, true);
        TripRules::record(self::RULE, $by, $reason ?: 'It still fits (crew)', ['trip_id' => $full->id, 'trip_number' => $full->trip_number, 'box' => $row->invoice,
            'note' => 'Add anyway at unload: '.$move->count().' '.Str::plural('box', $move->count()).' over the estimate']);
        // the new trip is empty now: take it away and free its truck
        if ($from && $from->id !== $full->id && ! Tripinvoice::where('deliveryloghub_id', $from->id)->exists() && (string) ($from->made_note ?? '') === 'New trip at unload (trip full)') {
            $from->truck?->update(['is_assigned' => false]);
            TripCity::where('deliverylog_id', $from->id)->delete();
            $from->delete();
        } elseif ($from) {
            static::countCities($from, true);
        }

        return ['ok' => true, 'msg' => $move->count().' '.Str::plural('box', $move->count()).' on '.$full->trip_number.' anyway ('.static::fmt($full).').'];
    }
}
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- resources/css/filament/admin/theme.css
mkdir -p 'resources/css/filament/admin'
cat > 'resources/css/filament/admin/theme.css' <<'DISPATCH_FILE_END_13'
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
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- resources/views/filament/pages/scaninvoice.blade.php
mkdir -p 'resources/views/filament/pages'
cat > 'resources/views/filament/pages/scaninvoice.blade.php' <<'DISPATCH_FILE_END_14'
<x-filament-panels::page>
    @php($progress = $this->progress())

    <x-scan.station :heading="$this->stationHeading()" :description="$this->stationDescription()" :icon="$this->stationIcon()">
        <x-slot name="form">
            {{ $this->form }}

            <x-barcode-scanner method="scan" continuous :cooldown="1500" />
        </x-slot>

        <x-slot name="progress">
            @if ($this->data['container_id'] ?? null)
                <x-scan.progress :loaded="$progress['loaded']" :total="$progress['total']" :label="$this->progressLabel()"
                    :last="$progress['last'] ?? null" :issues="$progress['issues'] ?? 0" :unmanifested="$progress['unmanifested'] ?? 0"
                    done-text="Every box on the manifest is scanned." />
            @endif
        </x-slot>

        <x-slot name="result">
            <x-scan.result :invoice="$this->lastInvoice()" :status="$lastStatus" :title="$lastMessage">
                <div class="ds-result__actions">
                    {{ $this->reportIssueAction }}
                </div>
            </x-scan.result>

            @if ($route)
                <div class="ds-ws__result" style="--c: {{ $route['color'] ?? '#1d6fb8' }}">
                    <strong>{{ ($route['kind'] ?? '') === 'truck' ? '🚚' : $route['code'] }}</strong>
                    <span><b>{{ ($route['kind'] ?? '') === 'truck' ? 'Truck '.$route['trip'].' → '.$route['name'] : 'Section '.$route['code'].' · '.$route['name'] }}</b>
                        @if ($setInfo)<small>{{ $setInfo['name'] }} · box {{ $setInfo['n'] }} of {{ $setInfo['of'] }} · {{ $setInfo['text'] }}</small>@endif
                        @if (! empty($route['why']))<small>{{ $route['why'] }}</small>@endif</span>
                </div>
            @endif

            @if (property_exists($this, 'hubTrip') && $this->hubTrip)
                @php($ht = $this->hubTrip)
                <div @class(['ds-ws__trip', 'is-new' => $ht['kind'] === 'new', 'is-anyway' => $ht['kind'] === 'anyway'])>
                    <b class="ds-ws__to">→ {{ $ht['kind'] === 'new' ? 'new trip ' : '' }}{{ $ht['trip'] }}</b>
                    <small>{{ $ht['why'] }}</small>
                    @if ($ht['kind'] === 'new' && ! empty($ht['full']))
                        <button type="button" wire:click="hubAnyway" wire:loading.attr="disabled">Add anyway to {{ $ht['full']['number'] }}</button>
                    @endif
                </div>
            @endif

            @if ($missingCode)
                <div class="ds-result__actions">
                    {{ $this->unmanifestedAction }}
                </div>
            @endif
            @include('filament.partials.scan-photo')
        </x-slot>

        <x-slot name="aside">
            <x-scan.household :rows="$this->household()" done-label="verified" />
        </x-slot>
    </x-scan.station>

</x-filament-panels::page>
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- resources/views/filament/scan/app.blade.php
mkdir -p 'resources/views/filament/scan'
cat > 'resources/views/filament/scan/app.blade.php' <<'DISPATCH_FILE_END_15'
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

            @forelse ($choices as $i => $c)
                <button type="button" @class(['ds-sa__choice', 'is-finished' => $c['finished']]) style="animation-delay: {{ $i * 50 }}ms" wire:click="pick({{ $c['id'] }})" wire:key="c-{{ $c['id'] }}">
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

            @if ($finishedCount)
                <button type="button" class="ds-sa__more" wire:click="toggleFinished">
                    {{ $showFinished ? 'Hide finished' : 'Show finished ('.$finishedCount.')' }}
                </button>
            @endif
        </section>
    @endif

    {{-- ============================== scan ============================== --}}
    @if ($screen === 'scan' && $def)
        <section class="ds-sa__screen ds-sa__scan" wire:key="scan-{{ $this->mode }}-{{ $choice }}">
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
                 x-data="barcodeScanner(@js(['method' => 'scan', 'formats' => ['code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'itf', 'qr_code'], 'autoStart' => true, 'continuous' => true, 'cooldown' => 2500, 'beep' => true]))">
                <video x-ref="video" playsinline muted autoplay></video>
                <div class="ds-sa__frame" x-bind:class="{ 'is-hit': flash }"><i></i><i></i><i></i><i></i><span x-show="scanning" class="ds-sa__sweep"></span></div>
                <p class="ds-sa__camtext" x-show="loading" x-cloak>Starting camera…</p>
                <p class="ds-sa__camtext" x-show="! scanning && ! loading && ! error">Camera is off · tap the round button</p>
                <p class="ds-sa__camtext is-error" x-show="error" x-text="error" x-cloak></p>
                <p class="ds-sa__camtext is-hint" x-show="hint && ! error" x-text="hint" x-cloak></p>

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

            @if ($bypass)
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
                        </div>
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

                        <div class="ds-sa__photos"
                             x-data="{ busy: false, failed: false, pct: 0,
                                take() { this.failed = false; this.$refs.file.value = ''; this.$refs.file.click() },
                                async send(e) {
                                    const file = e.target.files[0]; if (! file) return;
                                    this.busy = true; this.pct = 0; let out = file;
                                    out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
                                    $wire.upload('boxPhoto', out, () => $wire.saveBoxPhoto().then(() => { this.busy = false }), () => { this.busy = false; this.failed = true }, (ev) => { this.pct = ev.detail.progress });
                                } }">
                            <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                            @foreach ($shots as $shot)
                                <a href="{{ $shot->url() }}" target="_blank" class="ds-sa__shot"><img src="{{ $shot->url() }}" alt="Photo {{ $loop->iteration }}"></a>
                            @endforeach
                            <button type="button" class="ds-sa__addphoto" x-on:click="take()" x-bind:disabled="busy">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                                <span x-show="! busy">{{ $shots->isEmpty() ? 'Add photo · optional' : 'Add another' }}</span>
                                <span x-show="busy" x-cloak>Saving… <span x-text="pct + '%'"></span></span>
                            </button>
                            <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                        </div>
                    @endif
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">Scan next box</button>
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
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- resources/views/filament/trips/new-boxes.blade.php
mkdir -p 'resources/views/filament/trips'
cat > 'resources/views/filament/trips/new-boxes.blade.php' <<'DISPATCH_FILE_END_16'
<x-filament-panels::page>
<div class="ds-nb">
    <span class="ds-te__title"><h1>New boxes since the trips were made</h1><small>Boxes of cities that already have a trip. Space left → add (combos first, never split). Full → a new trip, or Add anyway (space is an estimate). Locked or on the road → a new trip.</small></span>

    @if (! $rows)
        <section class="ds-cb__card ds-nb__empty">
            <b>No new boxes for cities with a trip.</b>
            <small>Boxes of cities without a trip are planned in ✦ Plan trips.</small>
            @if ($planUrl)<a href="{{ $planUrl }}" class="ds-nt__plan">✦ Plan trips</a>@endif
        </section>
    @else
        <section class="ds-cb__card ds-nb__apply">
            <span><b>✦ {{ $total }} new {{ Str::plural('box', $total) }}: {{ $toAdd }} go on trips with space{{ $toNew ? ', '.$toNew.' on a new trip' : '' }}</b>
                <small>Combos (one receiver, or one set) always go together. Same rules in Admin, Warehouse and Partner hubs.</small></span>
            <button type="button" class="ds-nt__go" wire:click="applyAll" wire:loading.attr="disabled">Apply</button>
        </section>

        <section class="ds-cb__card ds-nb__list">
            <div class="ds-nb__row ds-nb__head"><span>City</span><span>New boxes</span><span>✦ The AI suggests</span><span></span></div>
            @foreach ($rows as $r)
                @php($t = $r['trip'])
                @php($pct = $t && ! empty($t['cap']) ? min(100, round($t['used'] / max(1, $t['cap']) * 100)) : 100)
                <div class="ds-nb__row" wire:key="nb-{{ $r['key'] }}">
                    <span class="ds-nb__city"><b>{{ $r['city'] }}</b><small>{{ $r['province'] }}</small></span>
                    <b class="ds-nb__n">{{ $r['n'] }}</b>
                    <span class="ds-nb__trip">
                        <span class="ds-nb__tline"><b>{{ $t['number'] ?? '—' }}</b>
                            <span @class(['ds-nb__pill', 'is-'.$r['kind']])>{{ ['open' => 'Space left', 'full' => 'Full', 'closed' => ($t['state'] ?? 'Locked')][$r['kind']] }}</span></span>
                        @if ($r['kind'] !== 'closed')
                            <span class="ds-nb__space"><span class="ds-tl__bar"><i style="width: {{ $pct }}%"></i></span><small>{{ $fmt($t['used']) }} of {{ $t['cap'] }}{{ $t['room'] > 0 ? ' · room for '.$fmt($t['room']) : ' · full' }}</small></span>
                        @else
                            <small class="ds-te__hint">No more boxes join a locked trip or one on the road.</small>
                        @endif
                    </span>
                    <span class="ds-nb__acts">
                        @if ($r['kind'] === 'open')
                            <button type="button" class="ds-nt__go ds-nb__btn" wire:click="openPick('{{ $r['key'] }}')">Add to {{ $t['number'] }}</button>
                        @elseif ($r['kind'] === 'full')
                            <button type="button" class="ds-nt__go ds-nb__btn" wire:click="newTrip('{{ $r['key'] }}')">New trip</button>
                            <button type="button" class="ds-nt__only ds-nb__btn is-anyway" wire:click="openPick('{{ $r['key'] }}', true)">Add anyway</button>
                        @else
                            <button type="button" class="ds-nt__only ds-nb__btn" wire:click="newTrip('{{ $r['key'] }}')">+ New trip for these</button>
                        @endif
                    </span>
                </div>
            @endforeach
        </section>
    @endif

    @if ($p)
        <div class="ds-nb__modal" wire:key="nb-pick">
            <section class="ds-cb__card ds-nb__pick">
                <span class="ds-nb__ph"><b>Add {{ $p['row']['city'] }} boxes to {{ $p['trip']['number'] }}</b><small>Combos first: a set or one receiver’s boxes go together, never split. Pick one box or many.</small></span>
                <span class="ds-nb__meter"><span class="ds-tl__bar"><i class="is-used" style="width: {{ $p['usedPct'] }}%"></i><i @class(['is-new', 'is-over' => $p['over']]) style="width: {{ $p['newPct'] }}%"></i></span>
                    <small @class(['is-over' => $p['over']])>{{ $p['trip']['number'] }}: {{ $fmt($p['trip']['used']) }} of {{ $p['trip']['cap'] }} + {{ $fmt($p['space']) }} picked = {{ $fmt($p['trip']['used'] + $p['space']) }} of {{ $p['trip']['cap'] }}{{ $p['over'] ? ' · '.$fmt($p['overBy']).' over' : ' · room for '.$fmt(max(0, $p['trip']['cap'] - $p['trip']['used'] - $p['space'])).' more' }}</small></span>
                <span class="ds-nb__items">
                    @foreach ($p['row']['combos'] as $c)
                        @php($on = ! empty($sel[$c['key']]))
                        <button type="button" wire:click="toggle('{{ $c['key'] }}')" @class(['ds-nb__item', 'is-on' => $on])>
                            <i class="ds-nb__check">{{ $on ? '✓' : '' }}</i>
                            <span><b>{{ $c['n'] >= 2 ? ($c['kind'] === 'set' ? 'Set' : 'Receiver').' · '.$c['name'] : 'Box '.($c['codes'][0] ?? '').' · '.$c['name'] }}</b>
                                <small>{{ $c['n'] >= 2 ? $c['n'].' boxes · '.implode(', ', array_slice($c['codes'], 0, 6)).(count($c['codes']) > 6 ? ' …' : '') : 'single box' }}{{ $c['barangay'] ? ' · '.$c['barangay'] : '' }}{{ $c['prio'] ? ' · ▲ priority' : '' }}</small></span>
                            <em @class(['ds-nb__tag', 'is-combo' => $c['n'] >= 2])>{{ $c['n'] >= 2 ? 'Combo · '.($c['kind'] === 'set' ? 'set' : 'receiver') : 'Single' }}</em>
                        </button>
                    @endforeach
                </span>
                @if ($p['over'])
                    <span class="ds-nb__warn">Over the space by {{ $fmt($p['overBy']) }}. Space is an estimate: Add anyway saves your name and a reason.
                        <select wire:model="reason" class="ds-te__input"><option value="">Why? (needed)</option>@foreach ($p['reasons'] as $why)<option value="{{ $why }}">{{ $why }}</option>@endforeach</select></span>
                @endif
                <span class="ds-nb__foot">
                    <span><button type="button" class="ds-nt__only ds-nb__btn" wire:click="pickFit">Pick what fits</button><button type="button" class="ds-te__link" wire:click="pickNone">Clear</button></span>
                    <span><button type="button" class="ds-nt__only ds-nb__btn" wire:click="closePick">Cancel</button>
                        <button type="button" @class(['ds-nt__go', 'ds-nb__btn', 'is-anyway' => $p['over']]) wire:click="confirmPick" @disabled($p['n'] === 0)>{{ $p['n'] === 0 ? 'Pick boxes' : ($p['over'] ? 'Add anyway · ' : 'Add ').$p['n'].' '.Str::plural('box', $p['n']) }}</button></span>
                </span>
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- resources/views/filament/trips/plan-hubs.blade.php
mkdir -p 'resources/views/filament/trips'
cat > 'resources/views/filament/trips/plan-hubs.blade.php' <<'DISPATCH_FILE_END_17'
{{-- Plan trips › To hubs: one trip per partner hub (more when the boxes do not fit one truck). The hub delivers with its own trucks. --}}
@php($tips = collect($hubPlan)->reject(fn ($h) => ($hubState[$h['hub']] ?? null) || ! empty($h['open']))->take(3))
<section class="ds-ph__ai">
    <span class="ds-pt__spark" aria-hidden="true">✦</span>
    <span class="ds-ph__aitext">
        <b>Suggested for today</b>
        @forelse ($tips as $h)
            <span>• <b>{{ $h['name'] }}:</b> {{ $h['tip'] }}</span>
        @empty
            <span>Nothing waits for a hub right now.</span>
        @endforelse
    </span>
</section>
@if ($askDirect)
    <section class="ds-ph__why">
        @php([$ah, $ap, $ac] = array_pad(explode('|', $askDirect, 3), 3, ''))
        <b>{{ Str::title($ac) }} → direct instead of {{ \App\Support\Hubs\HubAreas::name((int) $ah) }}. Why? (the office sees this)</b>
        <span class="ds-ph__reasons">@foreach (\App\Support\Trips\TripRules::reasons() as $r)<button type="button" wire:click="directWith(@js($r))">{{ $r }}</button>@endforeach<button type="button" class="is-cancel" wire:click="cancelDirect">Cancel</button></span>
    </section>
@endif
<div class="ds-ph__grid">
    @forelse ($hubPlan as $n => $h)
        @php($state = $hubState[$h['hub']] ?? null)
        @php($when = $hubWhen[$h['hub']] ?? 'now')
        @php($multi = count($h['trips']) > 1)
        <section class="ds-cb__card ds-ph__card" wire:key="hub-{{ $h['hub'] }}" style="--hub: {{ \App\Support\Hubs\HubAreas::color($h['hub']) }}">
            <span class="ds-ph__head">
                <span><b>⌂ {{ $h['name'] }}</b><small>{{ $h['boxes'] }} {{ Str::plural('box', $h['boxes']) }} · {{ count($h['cities']) }} {{ Str::plural('city', count($h['cities'])) }}{{ $multi ? ' · '.count($h['trips']).' trips' : '' }}</small></span>
                <span @class(['ds-cb__pill', 'is-bad' => $h['days'] >= 4, 'is-warn' => $h['days'] === 3, 'is-muted' => $h['days'] < 3])>{{ $h['days'] ? 'Oldest '.$h['days'].' '.Str::plural('day', $h['days']) : 'Today' }}</span>
            </span>
            <span class="ds-ph__cities">
                @foreach (collect($h['cities'])->take(5) as $c)
                    <span><span><b>{{ $c['city'] }}</b> · {{ $c['boxes'] }} {{ Str::plural('box', $c['boxes']) }}{{ $c['prio'] ? ' · '.$c['prio'].' priority' : '' }}</span>
                        @if (! $state && empty($h['open']))<button type="button" wire:click="askDirectCity({{ $h['hub'] }}, @js($c['key']))">Deliver direct instead</button>@endif</span>
                @endforeach
                @if (count($h['cities']) > 5)<small class="ds-pt__muted">+ {{ count($h['cities']) - 5 }} more {{ Str::plural('city', count($h['cities']) - 5) }}</small>@endif
            </span>
            @if (! empty($h['open']))
                <span class="ds-ph__done is-made">On {{ implode(', ', $h['open']) }}: new boxes of the hub join it while it has room (New boxes).</span>
            @elseif ($multi)
                <span class="ds-fl__seg ds-ph__when">
                    <button type="button" wire:click="setWhen({{ $h['hub'] }}, 'now')" @class(['is-on' => $when === 'now'])>Both now</button>
                    <button type="button" wire:click="setWhen({{ $h['hub'] }}, 'later')" @class(['is-on' => $when === 'later'])>Trip 2{{ count($h['trips']) > 2 ? '+' : '' }} tomorrow</button>
                </span>
                @foreach ($h['trips'] as $ti => $t)
                    @php($later = $ti > 0 && $when === 'later')
                    <span class="ds-ph__part">
                        <span class="ds-ph__head"><b>Trip {{ $ti + 1 }}</b><span @class(['ds-cb__pill', 'is-own' => ! $later, 'is-warn' => $later])>{{ $later ? 'Tomorrow' : 'Now' }}</span></span>
                        <small>🚚 {{ $later ? 'next free truck' : ($t['plate'] ?? 'No truck yet') }} · {{ collect($t['cities'])->pluck('city')->unique()->join(', ') }}</small>
                        <span class="ds-ph__bar"><i style="width: {{ min(100, round($t['load'] / max(1, $t['cap']) * 100)) }}%">About {{ $t['load'] }} of {{ $t['cap'] }} space</i></span>
                        <small class="ds-pt__muted">✦ {{ $ti === 0 ? 'Priority, tried-before and oldest boxes first. Whole customers only.' : ($later ? 'Waits for a truck'.($h['coming'] ? ' and the next container ('.$h['coming'].' boxes on the way)' : '').'.' : 'Same cities kept together, so the hub splits them easily.') }}</small>
                    </span>
                @endforeach
            @elseif ($h['trips'])
                @php($t = $h['trips'][0])
                <span @class(['ds-cb__pill', 'ds-ph__truck', 'is-own' => $t['plate'], 'is-none' => ! $t['plate']])>🚚 {{ $t['plate'] ?? 'No truck yet' }}{{ $t['plate'] ? ' · '.$t['cap'].' space' : '' }}</span>
                <span class="ds-ph__bar"><i style="width: {{ min(100, round($t['load'] / max(1, $t['cap']) * 100)) }}%">About {{ $t['load'] }} of {{ $t['cap'] }} space</i></span>
            @endif
            <small class="ds-ph__tip">✦ {{ $h['tip'] }}</small>
            @if ($state)
                <span @class(['ds-ph__done', 'is-made' => $state === 'made'])>{{ $state === 'made' ? $hubMade[$h['hub']] ?? '✓ Created' : 'Waiting · shows again on the next plan' }}</span>
            @elseif (empty($h['open']))
                <span class="ds-ph__btns">
                    <button type="button" class="ds-te__btn is-main" wire:click="makeHub({{ $h['hub'] }})" wire:loading.attr="disabled">{{ $multi ? ($when === 'later' ? 'Create Trip 1 to '.$h['name'] : 'Create '.count($h['trips']).' trips to '.$h['name']) : 'Create trip to '.$h['name'] }}</button>
                    <button type="button" class="ds-te__btn ds-wc__ghost" wire:click="waitHub({{ $h['hub'] }})">Wait</button>
                </span>
            @endif
        </section>
    @empty
        <p class="ds-cb__card ds-cb__muted">No boxes wait for a hub. Places get a hub in Settings › Hub areas.</p>
    @endforelse
</div>
<span class="ds-wc__asked">One trip per hub, not split by city: the hub splits the boxes into its own trips. The hub’s boxes go on the trip when you press Create. No SMS from here; the hub texts the receivers when it locks its own trip.</span>
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- resources/views/filament/trips/plan.blade.php
mkdir -p 'resources/views/filament/trips'
cat > 'resources/views/filament/trips/plan.blade.php' <<'DISPATCH_FILE_END_18'
<x-filament-panels::page>
<div class="ds-pt">
    <header class="ds-pt__top">
        <span class="ds-pt__title">
            <span class="ds-pt__h"><span class="ds-pt__logo" aria-hidden="true">✦</span><h1>Plan trips</h1></span>
            @if ($atHub)
                <small>{{ $hubName }}: direct to customers in your area only. Your trucks, your trip numbers. The boxes at your hub go on the trip when you press Create.</small>
            @else
                <small>The AI makes trips by city: nearby cities of one province fill one truck. Create puts the waiting boxes on the trips. Boxes of a new container: New boxes (to a trip with room).</small>
            @endif
        </span>
        {{-- the day only matters when you press Create: switching it happens in the browser, no wait --}}
        <span class="ds-pt__days" x-data="{ day: $wire.entangle('day'), date: $wire.entangle('date') }">
            <span class="ds-fl__seg">
                @foreach (['today' => [__('Today'), today()->toDateString()], 'tomorrow' => [__('Tomorrow'), today()->addDay()->toDateString()], 'date' => [__('Pick a date'), null]] as $k => [$l, $d])
                    <button type="button" x-on:click="day = '{{ $k }}'{{ $d ? "; date = '".$d."'" : '' }}" :class="{ 'is-on': day === '{{ $k }}' }" @class(['is-on' => $day === $k])>{{ $l }}</button>
                @endforeach
            </span>
            <input type="date" x-show="day === 'date'" x-model="date" @style(['display: none' => $day !== 'date']) class="ds-te__input ds-pt__date" aria-label="Trip date">
        </span>
    </header>

    @if ($hubsOn)
        <nav class="ds-pt__tabs" role="tablist">
            <button type="button" role="tab" wire:click="setTab('direct')" @class(['is-on' => $tab === 'direct']) aria-selected="{{ $tab === 'direct' ? 'true' : 'false' }}">Direct to customers <span>{{ $directBoxes }}</span></button>
            <button type="button" role="tab" wire:click="setTab('hubs')" @class(['is-on' => $tab === 'hubs']) aria-selected="{{ $tab === 'hubs' ? 'true' : 'false' }}">To hubs <span>{{ count($hubPlan) }} {{ Str::plural('hub', count($hubPlan)) }} · {{ $hubBoxes }}</span></button>
        </nav>
    @endif

    @if ($tab === 'hubs' && $hubsOn)
        @include('filament.trips.plan-hubs')
    @else
    <section class="ds-cb__card ds-pt__ask">
        <span class="ds-pt__spark" aria-hidden="true">✦</span>
        <span class="ds-pt__asktext">
            <b>What matters today?</b>
            <span class="ds-pt__chips">
                @foreach (array_filter(['oldest' => 'Oldest boxes first', 'first' => $top ? $top.' first' : null, 'keep' => 'Keep a truck free', 'full' => 'Only full trucks']) as $k => $l)
                    <button type="button" wire:click="setAsk('{{ $k }}')" @class(['ds-pt__chip', 'is-on' => $ask === $k && $instruction === ''])>{{ $l }}</button>
                @endforeach
            </span>
        </span>
        <form wire:submit="askAi" class="ds-pt__type">
            <input type="text" wire:model="instruction" class="ds-te__input" placeholder="Or type it: “{{ $top ?? 'Bulacan' }} first, keep one truck”" @disabled(! $aiOn) title="{{ $aiOn ? '' : 'Switch on the AI trip helper in Settings → AI' }}">
        </form>
    </section>

    <div class="ds-pt__grid">
        <section class="ds-cb__card ds-pt__left">
            <span class="ds-pt__lhead"><b>{{ $atHub ? 'Arrived, by city' : 'Waiting, by city' }}</b><small>{{ number_format($waitTotal) }} boxes</small></span>
            @if ($notMine)<span class="ds-pt__transfer is-bad"><span>{{ $notMine }} {{ Str::plural('box', $notMine) }} here {{ $notMine === 1 ? 'belongs' : 'belong' }} to another hub’s area: not planned. Tell the office.</span></span>@endif
            <small class="ds-pt__muted">Click a province to see its cities</small>
            <span class="ds-pt__provs" x-data="{ open: $wire.entangle('open') }">
            @forelse ($provinces as $p)
                <span @class(['ds-pt__prov', 'is-planned' => $p['planned']]) wire:key="p-{{ $p['key'] }}">
                    <button type="button" class="ds-pt__provhead" x-on:click="open = open === @js($p['key']) ? '' : @js($p['key'])" :aria-expanded="open === @js($p['key'])"><b><span x-text="open === @js($p['key']) ? '▾' : '▸'">{{ $open === $p['key'] ? '▾' : '▸' }}</span> {{ $p['name'] }}</b><span>{{ $p['boxes'] }} boxes</span></button>
                    <span class="ds-pt__bar"><i style="width: {{ round($p['boxes'] / $max * 100) }}%" @class(['is-old' => $p['days'] >= 4, 'is-mid' => $p['days'] === 3])></i></span>
                    <span class="ds-pt__provfoot"><span>{{ $p['days'] ? 'Oldest '.$p['days'].' '.Str::plural('day', $p['days']) : 'Today' }}</span><b @class(['is-in' => $p['planned']])>{{ $p['trip'] ? 'On '.$p['trip'] : ($p['planned'] ? 'In a trip' : 'Not planned') }}</b></span>
                    <span class="ds-pt__cities" x-show="open === @js($p['key'])" @style(['display: none' => $open !== $p['key']])>
                            @foreach ($p['cities'] as $c)
                                <span><span>{{ $c['city'] }}@if (isset($covered[$c['key']])) <em>· {{ $covered[$c['key']] }}</em>@elseif (isset($draft[$c['key']])) <em>· in a trip</em>@endif</span><span class="ds-pt__muted">{{ $c['boxes'] }} · {{ $c['days'] ? $c['days'].' '.Str::plural('day', $c['days']) : 'today' }}</span></span>
                            @endforeach
                    </span>
                </span>
            @empty
                <p class="ds-cb__muted">No boxes are waiting for a trip.</p>
            @endforelse
            </span>
            @foreach ($transferOut as $t)
                <a href="{{ $trUrl }}" class="ds-pt__transfer"><span>{{ $t['n'] }} {{ Str::plural('box', $t['n']) }} → transfer to {{ $t['name'] }} (not planned here)</span><b>Open ›</b></a>
            @endforeach
            @if ($arriving)<span class="ds-pt__transfer"><span>{{ $arriving }} {{ Str::plural('box', $arriving) }} arriving on a transfer: planned when received</span></span>@endif
            @if ($unclear)
                @if ($addrUrl)<a href="{{ $addrUrl }}" class="ds-pt__unclear"><span>📍 {{ $unclear }} {{ Str::plural('box', $unclear) }}: city not clear</span><b>Addresses to check ›</b></a>
                @else<span class="ds-pt__unclear"><span>📍 {{ $unclear }} {{ Str::plural('box', $unclear) }}: city not clear</span></span>@endif
            @endif
            <small class="ds-pt__muted">No barangay is fine: the box goes by its city, the barangay only sets the stop order.</small>
        </section>

        <section class="ds-pt__mid">
            <span class="ds-pt__lhead"><b class="ds-pt__big">Suggested trips</b><small>{{ $ai ? '✦ ' : '' }}{{ $note }}</small></span>
            @if ($made)
                <span class="ds-pt__made">✓ {{ count($made) }} {{ Str::plural('trip', count($made)) }} created: {{ collect($made)->pluck('number')->join(', ') }}. Boxes join when they are scanned onto the truck.</span>
            @endif
            @forelse ($cards as $t)
                <article @class(['ds-cb__card', 'ds-pt__trip', 'is-off' => ! $t['on']]) wire:key="t-{{ $t['i'] }}-{{ $t['province'] }}">
                    <span class="ds-pt__trow">
                        <button type="button" role="switch" aria-checked="{{ $t['on'] ? 'true' : 'false' }}" aria-label="Include this trip" wire:click="toggleTrip({{ $t['i'] }})" @class(['ds-te__switch', 'ds-ad__smswitch', 'is-on' => $t['on']])><i></i></button>
                        <span class="ds-pt__tname"><b>{{ $t['province'] }} <span>› {{ $t['path'] }}</span></b><small>New trip · number given when you press Create</small></span>
                        <button type="button" wire:click="cycleTruck({{ $t['i'] }})" @class(['ds-pt__truck', 'is-free' => $t['truck'] && $t['truck']['state'] === 'free', 'is-busy' => $t['truck'] && $t['truck']['state'] === 'busy'])>🚚 {{ $t['truck'] ? $t['truck']['plate'] : 'No truck yet' }}@if ($t['truck'] && $t['truck']['state'] === 'busy') · after {{ $t['truck']['on'] }}@endif <span>▾</span></button>
                    </span>
                    <span class="ds-pt__stops">
                        @foreach ($t['cities'] as $n => $c)
                            <span class="ds-pt__stop"><span class="ds-pt__dot"></span><small><b>{{ $c['city'] }}</b></small><small class="ds-pt__muted">{{ $c['boxes'] }} {{ Str::plural('box', $c['boxes']) }}</small></span>
                            @if (! $loop->last)<span class="ds-pt__line"></span>@endif
                        @endforeach
                    </span>
                    <span class="ds-pt__fillrow">
                        <span class="ds-pt__fill"><i style="width: {{ $t['pct'] }}%" @class(['is-full' => $t['pct'] >= 100])></i><span>About {{ $t['load'] }} of {{ $t['cap'] }} space{{ $t['pct'] >= 100 ? ' · full' : '' }}</span></span>
                        <span @class(['ds-pt__age', 'is-old' => $t['days'] >= 4, 'is-mid' => $t['days'] === 3])>{{ $t['days'] ? 'Oldest '.$t['days'].' '.Str::plural('day', $t['days']) : 'Today' }}</span>
                    </span>
                    <span class="ds-pt__why"><span aria-hidden="true">✦</span><span>{{ $t['why'] }}</span></span>
                    @if ($tops[$t['i']] ?? [])
                        @php($pick = $t['topPick'] ?? $tops[$t['i']][0]['key'])
                        <span class="ds-pt__top">
                            <b><span aria-hidden="true">✦</span> Room for {{ $t['cap'] - $t['load'] }} more · top up with</b>
                            @foreach ($tops[$t['i']] as $o)
                                <button type="button" wire:click="pickTop({{ $t['i'] }}, @js($o['key']))" @class(['ds-pt__topopt', 'is-on' => $pick === $o['key']])><i class="ds-te__radio"></i><span><b>{{ $o['city'] }}, {{ $o['province'] }}</b><small>{{ $o['same'] ? 'Same province' : 'Next province' }} · {{ $o['days'] ? $o['days'].' '.Str::plural('day', $o['days']).' old' : 'today' }}</small></span><span class="ds-cb__pill">{{ $o['boxes'] }} {{ Str::plural('box', $o['boxes']) }}</span></button>
                            @endforeach
                            <span class="ds-pt__topbtns"><button type="button" class="ds-te__btn is-main" wire:click="addTop({{ $t['i'] }})">Add to this trip</button><button type="button" class="ds-te__btn ds-wc__ghost" wire:click="skipTop({{ $t['i'] }})">No thanks</button></span>
                        </span>
                    @endif
                    @if (! empty($t['topped']))<small class="ds-pt__ok">✓ {{ $t['topped'] }}</small>@elseif (! empty($t['noTop']))<small class="ds-pt__muted">No top-up · {{ $t['cap'] - $t['load'] }} space stays free</small>@endif
                    @if ($t['on'])
                        <button type="button" wire:click="toggleSms({{ $t['i'] }})" @disabled(! $smsOn) @class(['ds-pt__sms', 'is-on' => $smsOn && ($t['sms'] ?? true)])><i>{{ $smsOn && ($t['sms'] ?? true) ? '✓' : '' }}</i>Send SMS for this trip <small>· {{ ! $smsOn ? 'off for all trips in SMS settings' : (($t['sms'] ?? true) ? 'receivers get a text when it is locked' : 'no text for this trip only') }}</small></button>
                    @endif
                    @if ($sets[$t['i']] ?? [])
                        <span class="ds-pt__sets">
                            <span class="ds-pt__lhead"><b>Kept together on this trip</b><small>customers with 2+ boxes</small></span>
                            @foreach ($sets[$t['i']] as $st)
                                <span class="ds-pt__set"><span><b>{{ $st['name'] }}</b> · {{ $st['city'] }}</span><span @class(['ds-cb__pill', 'is-own' => ! $st['missing'], 'is-warn' => $st['missing']])>{{ $st['missing'] ? $st['n'].' here · '.$st['missing'].' not unloaded yet' : $st['n'].' of '.$st['n'].' together' }}</span></span>
                            @endforeach
                        </span>
                    @endif
                </article>
            @empty
                <p class="ds-cb__card ds-cb__muted">Nothing to plan: every waiting city is already on a trip, or no boxes are waiting.</p>
            @endforelse
            <span class="ds-pt__sum">
                <span><b>{{ $onTrips->count() }} {{ Str::plural('trip', $onTrips->count()) }} · about {{ $onTrips->sum('load') }} boxes</b><small>{{ $atHub ? 'Trip numbers with your hub code · the boxes go on the trip when you press Create' : 'Trip numbers and their boxes now (combos together)' }} · @if ($smsOn)SMS to receivers when the trip is locked{{ ($noSms = $onTrips->filter(fn ($t) => ! ($t['sms'] ?? true))->count()) ? ', except '.$noSms.' '.Str::plural('trip', $noSms) : '' }}@else No SMS (off in @if ($smsUrl)<a href="{{ $smsUrl }}" class="ds-pt__smslink">SMS settings ›</a>@else SMS settings @endif)@endif</small></span>
                @if ($changedAny && $needPlan === 'reason')
                    <select wire:model="planReason" class="ds-wc__sel" aria-label="Why did you change the AI plan?"><option value="">Why did you change the plan?</option>@foreach ($reasons as $r)<option value="{{ $r }}">{{ $r }}</option>@endforeach</select>
                @endif
                <button type="button" wire:click="create" wire:loading.attr="disabled" @disabled(! $onTrips->count())>{{ $made && ! $onTrips->count() ? '✓ Created' : 'Create '.$onTrips->count().' '.Str::plural('trip', $onTrips->count()) }}</button>
            </span>
        </section>

        <aside class="ds-pt__side">
            <section class="ds-cb__card ds-pt__card">
                <b class="ds-pt__h3">Trucks</b>
                @forelse ($trucks as $k)
                    @php($st = $k['id'] === $kept ? 'kept' : $k['state'])
                    <span class="ds-pt__trk"><i class="is-{{ $st }}"></i><span><b>{{ $k['plate'] }}</b><small>{{ $st === 'kept' ? 'Kept free today' : $k['sub'] }}</small></span><small class="is-{{ $st }}">{{ $st === 'kept' ? 'Kept' : $k['label'] }}</small></span>
                @empty
                    <p class="ds-cb__muted">No trucks in this hub yet.</p>
                @endforelse
            </section>
            <section class="ds-pt__free">
                @if ($given)
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>{{ $given }}</b></span>
                    <span>Crew copied from the truck team. Load from the sections of its cities, oldest first.</span>
                @elseif ($freeTruck && $waitingTrips->isNotEmpty())
                    @php($w = $waitingTrips->first())
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>{{ $freeTruck['plate'] }} is free</b></span>
                    <span>Best next trip: {{ $w['province'] }} ({{ $w['trip']->trip_number }} · {{ $w['cities'] }}). {{ $w['days'] ? 'Its boxes are the oldest ('.$w['days'].' '.Str::plural('day', $w['days']).').' : '' }}</span>
                    <button type="button" class="ds-te__btn is-main" wire:click="give({{ $w['trip']->id }}, {{ $freeTruck['id'] }})">Give {{ $w['province'] }} to {{ $freeTruck['plate'] }}</button>
                @elseif ($waitingTrips->isNotEmpty())
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>{{ $waitingTrips->count() }} {{ Str::plural('trip', $waitingTrips->count()) }} wait for a truck</b></span>
                    <span>When a truck is free, it shows here with the most urgent trip to give it.</span>
                @elseif ($freeTruck)
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>{{ $freeTruck['plate'] }} is free</b></span>
                    <span>Create the trips: the most urgent one gets this truck.</span>
                @else
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>No free truck right now</b></span>
                    <span>Trips without a truck wait; the next free truck gets the most urgent one.</span>
                @endif
            </section>
            <section class="ds-cb__card ds-pt__card">
                <b class="ds-pt__h3">How the top-up is picked</b>
                @foreach (['Same province first, then the next province.', 'Only cities that fit the room left.', 'Oldest and priority boxes first; whole customers only.', 'Never over the truck space; the reserve stays free.'] as $n => $h)
                    <span class="ds-pt__how"><b>{{ $n + 1 }}</b><span>{{ $h }}</span></span>
                @endforeach
            </section>
            @if (! $atHub)
            <section class="ds-cb__card ds-pt__card">
                <span class="ds-pt__lhead"><b class="ds-pt__h3">Unloading now</b><small>{{ $unload['container'] ?? 'Nothing today' }}</small></span>
                @foreach ($unload['rows'] as [$a, $b, $here])
                    <span class="ds-pt__un"><span>{{ $a }}</span><b @class(['is-here' => $here])>{{ $b }}</b></span>
                @endforeach
                <small class="ds-pt__muted">Boxes for a truck that is here go straight on it. The rest wait in their section.</small>
            </section>
            @endif
        </aside>
    </div>
    @endif
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_18

# ---------------------------------------------------------------- resources/views/filament/trips/trip.blade.php
mkdir -p 'resources/views/filament/trips'
cat > 'resources/views/filament/trips/trip.blade.php' <<'DISPATCH_FILE_END_19'
<x-filament-panels::page>
<div class="ds-tp">
    <section class="ds-tp__steps" aria-label="Trip steps">
        @foreach ($steps as $s)
            <span @class(['ds-tp__step', 'is-'.$s['state']])><b>{{ $s['n'] }} {{ $s['label'] }}</b><small>{{ $s['who'] }}</small></span>
        @endforeach
    </section>

    <section class="ds-board__panel ds-tp__card">
        <header class="ds-tp__head">
            <strong>{{ $trip->trip_number }}{{ $trip->destination ? ' → '.$trip->destination->hub_name : '' }}</strong>
            <span class="ds-cb__pill is-{{ $stage }}">{{ $stageInfo[0] }}</span>
        </header>
        @if (\App\Support\Trips\CityTrips::ready() && ($tc = $trip->cities()->get())->isNotEmpty())
            <p class="ds-tp__cities">📍 {{ $tc->first()->province }} › {{ $tc->pluck('city')->join(', ') }} · {{ $trip->is_lock ? 'locked: no more boxes join' : 'new boxes of these cities can still join (New boxes)' }}@if ($trip->plan_why)<small>✦ {{ $trip->plan_why }}</small>@endif</p>
        @endif

        <div class="ds-tp__tiles">
            <span><small>Truck</small><b>{{ $trip->truck?->plate_no ?? 'No truck yet' }}</b><small>{{ $rental ? 'Rental · '.($rental['company'] ?? '—').' · ' : '' }}{{ $truckState === 'Free' && $rental ? 'Returned' : $truckState }}</small></span>
            <span><small>Boxes</small><b>{{ $boxes }}</b></span>
            @if ($rental)
                <span><small>Rental cost</small><b>{{ $rental['cost'] !== null ? '₱'.number_format($rental['cost']).' · '.(\App\Support\Rentals::RATES[$rental['rate']] ?? '') : '—' }}</b><small>{{ $rental['perBox'] ? 'about ₱'.number_format($rental['perBox']).' per box' : 'not known yet' }}</small></span>
            @endif
            <span><small>Leadman took the trip</small><b>{{ $took ?? '—' }}</b></span>
        </div>

        <div class="ds-tp__crewhead"><b>Crew on this trip</b><small>Copied from the truck team · change it for this trip only with Crew on this trip (top right)</small></div>
        @forelse ($crew as $c)
            <span @class(['ds-tp__person', 'is-swap' => $c->replaces_user_id])>
                <i>{{ collect(explode(' ', (string) $c->user?->full_name))->map(fn ($w) => mb_substr($w, 0, 1))->take(2)->join('') }}</i>
                <span><b>{{ $c->user?->full_name }}</b><small>{{ $c->role ?? $c->user?->workposition?->position_description }}@if ($c->replaces_user_id) · this trip only, instead of {{ $c->replaces?->full_name }}{{ $c->reason ? ' ('.(\App\Support\TripFlow::SWAP_REASONS[$c->reason] ?? $c->reason).')' : '' }}@endif</small></span>
            </span>
        @empty
            <p class="ds-cb__none">{{ $trip->truck_id ? 'No crew on this trip. Click Crew on this trip (top right) to choose who goes.' : 'No truck and no crew yet. Pick the truck in Boxes & edit (top right): its team is copied here. Or click Crew on this trip to choose people now.' }}</p>
        @endforelse

        @if ($rental)
            <span class="ds-tp__person"><i>R</i><span><b>{{ $rental['driver'] ?: 'Rental driver' }}</b><small>Rental driver · written on the trip for the records · our leadman rides along with the driver app</small></span></span>
        @endif
        @if ($lockChecks)
            @php($allOk = collect($lockChecks)->every('ok'))
            <div @class(['ds-tp__lock', 'is-ok' => $allOk])>
                <span class="ds-tp__lockhead"><b>🔒 Lock the trip</b><small>Only here, on the Trip page · the button at the top right</small></span>
                @foreach ($lockChecks as $c)
                    <span @class(['ds-tp__check', 'is-ok' => $c['ok']])><i>{{ $c['ok'] ? '✓' : '!' }}</i><span><b>{{ $c['title'] }}</b><small>{{ $c['sub'] }}</small></span></span>
                @endforeach
                <small>{{ $allOk ? 'All green: lock it now.' : 'Not ready yet.' }}{{ $autoLock ? ' It also locks by itself when the lead man takes the trip with every check green.' : '' }}</small>
            </div>
        @endif
        @foreach ($warnings as $w)
            <p @class(['ds-tp__warn', 'is-'.$w['tone']])>{{ $w['text'] }}</p>
        @endforeach

        @if ($next)
            <div class="ds-tp__next">
                <span><b>Next trip waiting for {{ $trip->truck?->plate_no }}</b><small>{{ $next->trip_number }}{{ $next->destination ? ' → '.$next->destination->hub_name : '' }} · {{ $nextBoxes }} boxes{{ $next->departure_date ? ' · '.$next->departure_date->format('M j') : '' }}</small></span>
                <a href="{{ static::getUrl(['trip' => $next->id]) }}" class="ds-cb__pill">Waits for {{ $trip->trip_number }} to close ›</a>
            </div>
        @endif
        <small class="ds-board__muted">Release truck now is a backup only. Normally the truck releases itself when every box is delivered or returned.</small>
    </section>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_19

# ---------------------------------------------------------------- tests/Feature/CityTripsTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/CityTripsTest.php' <<'DISPATCH_FILE_END_20'
<?php

use App\Filament\Pages\PlanTrips;
use App\Filament\Pages\Scanload;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\TripOverride;
use App\Models\Truck;
use App\Models\User;
use App\Support\Sms\SmsEvents;
use App\Support\Trips\CityTrips;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    // only our sample boxes wait
    Invoice::query()->update(['is_assigned' => true]);
    Truck::query()->update(['is_assigned' => false, 'capacity' => 20]);
    $this->free = Truck::where('logistichub_id', $this->admin->logistichub_id)->where('is_active', true)->orderBy('plate_no')->get();
    $base = Invoice::firstOrFail();
    $this->box = function (string $prov, string $city, int $days, string $no) use ($base) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => $no, 'receiver_province' => $prov, 'receiver_city' => $city, 'receiver_barangay' => 'X', 'is_verified' => true, 'is_assigned' => false,
            'is_delivered' => false, 'verified_at' => now()->subDays($days), 'receiver_mobile_no' => '09'.random_int(100000000, 999999999), 'set_key' => null])->save();

        return $i;
    };
    foreach (range(1, 8) as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 4, 'TAR'.$n);
    }
    foreach (range(1, 6) as $n) {
        ($this->box)('Tarlac', 'Capas', 3, 'CAP'.$n);
    }
    foreach (range(1, 9) as $n) {
        ($this->box)('Bulacan', 'Malolos', 2, 'MAL'.$n);
    }
});

it('plans trips by city: oldest province first, nearby cities fill one truck', function () {
    $plan = (new CityTrips($this->admin))->plan();
    expect($plan['trips'][0]['province'])->toBe('Tarlac')
        ->and(collect($plan['trips'][0]['cities'])->pluck('city')->all())->toBe(['Tarlac City', 'Capas'])
        ->and($plan['trips'][0]['load'])->toBe(14)
        ->and($plan['trips'][0]['truck_id'])->toBe($this->free[0]->id)
        ->and($plan['trips'][1]['province'])->toBe('Bulacan');

    $first = (new CityTrips($this->admin))->plan(['first' => 'Bulacan']);
    expect($first['trips'][0]['province'])->toBe('Bulacan');
});

it('creates trips with their boxes (not loaded); scanning onto the truck marks them loaded', function () {
    $page = Livewire::test(PlanTrips::class)->assertSee('Plan trips')->assertSee('Tarlac City')->assertSee('Waiting, by city')->call('create');
    $trip = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->firstOrFail();
    // board 45: the boxes go on the trip at Create, as "Not loaded"
    $on = Tripinvoice::where('deliverylog_id', $trip->id);
    expect((clone $on)->count())->toBeGreaterThan(0)
        ->and((clone $on)->where('is_loaded', true)->count())->toBe(0)
        ->and((clone $on)->where('invoice', 'TAR1')->exists())->toBeTrue()
        ->and(TripCity::where('deliverylog_id', $trip->id)->sum('planned_boxes'))->toBe((clone $on)->count())
        ->and($trip->truck_id)->toBe($this->free[0]->id)
        ->and($this->free[0]->fresh()->is_assigned)->toBeTrue();
    $page->assertSee('created:')->assertSee($trip->trip_number);

    // the planned cities are covered now
    expect(collect((new CityTrips($this->admin))->plan()['trips'])->pluck('province')->all())->not->toContain('Tarlac');

    $load = Livewire::test(Scanload::class)->set('data.deliverylog_id', $trip->id)
        ->call('scan', 'TAR1')->assertSet('lastStatus', 'success');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->where('invoice', 'TAR1')->value('is_loaded'))->toBeTrue()
        ->and(Invoice::where('invoice', 'TAR1')->value('is_assigned'))->toBeTrue();

    // a box of another city: asked first, then added when the office says so
    $load->call('scan', 'MAL1')->assertSet('lastStatus', 'warning')->assertSee('Other city');
    expect(Tripinvoice::where('invoice', 'MAL1')->exists())->toBeFalse();
    $load->call('loadAnyway')->assertSee('Why?')->call('bypassWith', 'Customer called');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->where('invoice', 'MAL1')->value('is_loaded'))->toBeTrue();

    // locked: no more boxes join, and the SMS waits for the lock
    $trip->update(['is_lock' => true]);
    $late = Invoice::where('invoice', 'TAR1')->firstOrFail()->replicate();
    $late->forceFill(['invoice' => 'TARLATE', 'is_assigned' => false, 'set_key' => null])->save();
    $load->call('scan', 'TARLATE')->assertSet('lastStatus', 'danger');
    expect(Tripinvoice::where('invoice', 'TARLATE')->exists())->toBeFalse();
});

it('keeps a trip for the next free truck, then Give hands it over', function () {
    Truck::where('id', '!=', $this->free[0]->id)->update(['is_active' => false]);
    $page = Livewire::test(PlanTrips::class)->call('cycleTruck', 0); // free → no truck yet
    expect($page->get('trips')[0]['truck_id'])->toBeNull();
    $page->call('create');
    expect(Deliverylog::whereHas('cities')->count())->toBe(0); // changed the AI plan: a reason first
    $page->assertSee('Why did you change the plan?')->set('planReason', 'Truck problem')->call('create');
    expect(TripOverride::where('rule', 'change_plan')->value('reason'))->toBe('Truck problem');
    $trip = Deliverylog::whereHas('cities')->whereNull('truck_id')->firstOrFail();

    Livewire::test(PlanTrips::class)->assertSee('is free')->assertSee('Give')->call('give', $trip->id, $this->free[0]->id)->assertSee('is on '.$trip->trip_number);
    expect($trip->fresh()->truck_id)->toBe($this->free[0]->id);
});

it('does not text receivers of a city trip before it is locked', function () {
    (new CityTrips($this->admin))->create((new CityTrips($this->admin))->plan()['trips'], today());
    $trip = Deliverylog::whereHas('cities')->firstOrFail();
    Livewire::test(Scanload::class)->set('data.deliverylog_id', $trip->id)->call('scan', 'TAR1');
    expect(SmsEvents::outForDelivery($trip->fresh()))->toBe(0);
});
DISPATCH_FILE_END_20

# ---------------------------------------------------------------- tests/Feature/HubAreasTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/HubAreasTest.php' <<'DISPATCH_FILE_END_21'
<?php

use App\Filament\Company\Pages\MyArea;
use App\Filament\Company\Pages\PlanTrips as HubPlanTrips;
use App\Filament\Pages\Ai\AiTrips;
use App\Filament\Pages\HubAreas as HubAreasSettings;
use App\Filament\Pages\HubSetup;
use App\Filament\Pages\PlanTrips;
use App\Models\AppSetting;
use App\Models\Deliverylog;
use App\Models\Hubs\HubAreaRequest;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\TripOverride;
use App\Models\Truck;
use App\Models\User;
use App\Support\Ai\AiFeatures;
use App\Support\Hubs\HubAreas;
use App\Support\Sms\SmsEvents;
use App\Support\Sms\SmsSettings;
use App\Support\Trips\CityTrips;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Invoice::query()->update(['is_assigned' => true]);
    Truck::query()->update(['is_assigned' => false, 'capacity' => 20]);
    $mk = fn (string $name, string $code, string $prov) => tap(new Logistichub, fn ($h) => $h->forceFill(['hub_name' => $name, 'hub_code' => $code, 'is_company' => true, 'is_active' => true, 'trip_counter' => 0, 'province' => $prov, 'user_id' => $this->admin->id])->save());
    $this->baguio = $mk('Baguio Hub', 'BGO', 'Benguet');
    $this->vigan = $mk('Vigan Hub', 'VGN', 'Ilocos Sur');
    $base = Invoice::firstOrFail();
    $this->box = function (string $prov, string $city, string $brgy, string $no, int $days = 2) use ($base) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => $no, 'receiver_province' => $prov, 'receiver_city' => $city, 'receiver_barangay' => $brgy, 'is_verified' => true, 'is_assigned' => false,
            'is_delivered' => false, 'verified_at' => now()->subDays($days), 'receiver_mobile_no' => '09'.random_int(100000000, 999999999), 'set_key' => null, 'is_priority' => false])->save();

        return $i;
    };
});

it('finds the hub of a box: barangay, then city, then province; one owner per place', function () {
    HubAreas::add($this->baguio->id, 'Benguet', null, null, $this->admin);
    HubAreas::add($this->baguio->id, 'La Union', 'San Fernando', null, $this->admin);
    HubAreas::add($this->vigan->id, 'La Union', 'San Fernando', 'Sevilla', $this->admin);
    $conflict = HubAreas::add($this->vigan->id, 'benguet', null, null, $this->admin);
    expect($conflict['ok'])->toBeFalse()->and($conflict['conflict']->logistichub_id)->toBe($this->baguio->id);

    expect(HubAreas::hubOf(($this->box)('Benguet', 'La Trinidad', 'Pico', 'B1')))->toBe($this->baguio->id)
        ->and(HubAreas::hubOf(($this->box)('La Union', 'San Fernando City', 'Brgy. Sevilla', 'B2')))->toBe($this->vigan->id)
        ->and(HubAreas::hubOf(($this->box)('La Union', 'San Fernando', 'Poro', 'B3')))->toBe($this->baguio->id)
        ->and(HubAreas::hubOf(($this->box)('La Union', 'Agoo', 'X', 'B4')))->toBeNull()
        ->and(HubAreas::hubOf(($this->box)('Pampanga', 'San Fernando', 'Sevilla', 'B5')))->toBeNull(); // same city name, other province

    // a switched-off hub has no area: its boxes go direct
    $this->vigan->forceFill(['is_active' => false])->save();
    expect(HubAreas::hubOf(Invoice::where('invoice', 'B2')->first()))->toBe($this->baguio->id)
        ->and(HubAreas::orphans()->first()['hub'])->toBe('Vigan Hub');
});

it('lets the admin move a place and a hub ask for one; the office approves', function () {
    HubAreas::add($this->baguio->id, 'La Union', 'San Fernando', null, $this->admin);
    Livewire::test(HubAreasSettings::class)->assertSee('Which hub delivers each place')->assertSee('Baguio Hub')
        ->set('add.'.$this->vigan->id.'.province', 'La Union')->set('add.'.$this->vigan->id.'.city', 'San Fernando')
        ->call('addPlace', $this->vigan->id)->assertSee('already belongs to Baguio Hub')->call('moveIt');
    expect(HubAreas::owner('La Union', 'San Fernando')->logistichub_id)->toBe($this->vigan->id);

    $hubUser = User::factory()->create(['logistichub_id' => $this->baguio->id, 'is_admin' => false, 'first_name' => 'Liza']);
    $this->actingAs($hubUser);
    Filament::setCurrentPanel(Filament::getPanel('company'));
    Livewire::test(MyArea::class)->assertSee('My delivery area')
        ->set('ask.province', 'La Union')->set('ask.city', 'San Fernando')->set('ask.barangay', 'Catbangen')->set('ask.reason', '20 minutes from our hub')
        ->call('send')->assertSee('Sent: Brgy. Catbangen, San Fernando, La Union');
    $r = HubAreaRequest::firstOrFail();
    expect($r->status)->toBe('pending')->and(HubAreas::pendingCount())->toBe(1);

    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(HubAreasSettings::class)->assertSee('Baguio Hub asks for Brgy. Catbangen')->call('decide', $r->id, true);
    expect(HubAreas::hubOf(($this->box)('La Union', 'San Fernando', 'Catbangen', 'C1')))->toBe($this->baguio->id)
        ->and($r->fresh()->status)->toBe('approved');
});

it('suggests the area of a new hub: its province and the free provinces of its region', function () {
    HubAreas::add($this->vigan->id, 'Ilocos Sur', null, null, $this->admin);
    HubAreas::add($this->baguio->id, 'Pangasinan', 'Rosales', null, $this->admin);
    Livewire::test(HubSetup::class)->assertSee('Add a hub and its area')
        ->set('form.name', 'Dagupan Hub')->set('form.code', 'dgp')->set('form.province', 'Pangasinan')->set('form.city', 'Dagupan City')
        ->call('save')->assertSee('Suggested area')->assertSee('Whole province · the hub is here')->assertSee('Closer than its hub now')
        ->call('toggleLeave', 1) // leave Ilocos Norte or La Union out
        ->call('approve');
    $dgp = Logistichub::where('hub_code', 'DGP')->firstOrFail();
    expect(HubAreas::owner('Pangasinan')->logistichub_id)->toBe($dgp->id)
        ->and(HubAreas::owner('Ilocos Sur')->logistichub_id)->toBe($this->vigan->id) // never taken from another hub
        ->and(HubAreas::owner('Pangasinan', 'Rosales')->logistichub_id)->toBe($this->baguio->id); // "closer" moves only when you say so
});

it('plans one trip per hub, more when the boxes do not fit one truck, and keeps hub boxes off direct trips', function () {
    HubAreas::add($this->baguio->id, 'Benguet', null, null, $this->admin);
    foreach (range(1, 14) as $n) {
        ($this->box)('Benguet', 'La Trinidad', 'Pico', 'LT'.$n, 4);
    }
    foreach (range(1, 12) as $n) {
        ($this->box)('Benguet', 'Itogon', 'X', 'IT'.$n, 2);
    }
    foreach (range(1, 6) as $n) {
        ($this->box)('Tarlac', 'Capas', 'X', 'CAP'.$n, 3);
    }
    $c = new CityTrips($this->admin);
    expect($c->places()->pluck('city')->all())->toBe(['Capas']);
    $hubs = $c->planHubs();
    expect($hubs)->toHaveCount(1)->and($hubs[0]['name'])->toBe('Baguio Hub')->and($hubs[0]['boxes'])->toBe(26)
        ->and($hubs[0]['trips'])->toHaveCount(2)
        ->and(collect($hubs[0]['trips'][0]['cities'])->pluck('city')->all())->toBe(['La Trinidad']);

    $page = Livewire::test(PlanTrips::class)->assertSee('To hubs')->call('setTab', 'hubs')->assertSee('Baguio Hub')->assertSee('Suggested for today')
        ->call('makeHub', $this->baguio->id)->assertSee('to Baguio Hub');
    $trips = Deliverylog::where('assigned_to', $this->baguio->id)->get();
    expect($trips)->not->toBeEmpty()
        ->and(TripCity::whereIn('deliverylog_id', $trips->pluck('id'))->pluck('hub_id')->unique()->all())->toBe([$this->baguio->id]);

    // scanning: a Baguio box joins the Baguio trip; a Capas box does not, and a Baguio box does not join a direct trip
    $hubTrip = $trips->first();
    // board 45: the hub's boxes are on the trip from Create
    expect(Tripinvoice::where('deliverylog_id', $hubTrip->id)->where('invoice', 'LT1')->value('logistichub_id'))->toBe($this->baguio->id);
    expect(CityTrips::join($hubTrip, 'CAP1')[1])->toBe('hub:0');
    $page->call('setTab', 'direct')->call('create');
    $direct = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Capas'))->firstOrFail();
    $late = Invoice::where('invoice', 'LT2')->firstOrFail()->replicate();
    $late->forceFill(['invoice' => 'LT9', 'is_assigned' => false, 'set_key' => null])->save(); // came after Create
    expect(CityTrips::join($direct, 'LT9')[1])->toBe('hub:'.$this->baguio->id)
        ->and(CityTrips::join($direct, 'LT9', false, true)[0])->not->toBeNull(); // with a reason: delivered direct
});

it('delivers a hub city direct instead, with a reason saved in Overrides', function () {
    HubAreas::add($this->baguio->id, 'Benguet', null, null, $this->admin);
    foreach (range(1, 4) as $n) {
        ($this->box)('Benguet', 'Itogon', 'X', 'IT'.$n, 5);
    }
    Livewire::test(PlanTrips::class)->call('setTab', 'hubs')->call('askDirectCity', $this->baguio->id, 'benguet|itogon')->assertSee('Why?')
        ->call('directWith', 'Priority box')->call('setTab', 'direct')->assertSee('Itogon')->call('create');
    $trip = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Itogon'))->firstOrFail();
    expect(TripCity::where('deliverylog_id', $trip->id)->pluck('hub_id')->all())->toContain($this->baguio->id)
        ->and(Tripinvoice::where('deliverylog_id', $trip->id)->where('invoice', 'IT1')->exists())->toBeTrue()
        ->and(TripOverride::where('rule', 'direct_hub')->value('reason'))->toBe('Priority box');
});

it('lets a partner hub plan its own trips with its trucks and trip numbers', function () {
    HubAreas::add($this->baguio->id, 'Benguet', null, null, $this->admin);
    HubAreas::add($this->vigan->id, 'Ilocos Sur', null, null, $this->admin);
    $truck = Truck::firstOrFail()->replicate();
    $truck->forceFill(['plate_no' => 'BGO 001', 'logistichub_id' => $this->baguio->id, 'is_active' => true, 'is_assigned' => false, 'capacity' => 5])->save();
    $toHub = Deliverylog::create(['trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $this->baguio->id, 'user_id' => $this->admin->id]);
    foreach (['Benguet|La Trinidad|LT1', 'Benguet|La Trinidad|LT2', 'Benguet|Itogon|IT1', 'Ilocos Sur|Vigan|VG1'] as $row) {
        [$p, $c, $no] = explode('|', $row);
        $inv = ($this->box)($p, $c, 'X', $no);
        Tripinvoice::create(['deliverylog_id' => $toHub->id, 'logistichub_id' => $this->baguio->id, 'invoice' => $no, 'invoice_id' => $inv->id, 'is_loaded' => true]);
        $inv->update(['is_assigned' => true]);
    }
    $hubUser = User::factory()->create(['logistichub_id' => $this->baguio->id, 'is_admin' => false]);
    $this->actingAs($hubUser);
    Filament::setCurrentPanel(Filament::getPanel('company'));
    Livewire::test(HubPlanTrips::class)->assertSee('Arrived, by city')->assertSee('La Trinidad')->assertDontSee('To hubs')
        ->assertSee('1 box here belongs to another hub')->call('create');
    $own = Deliverylog::where('logistichub_id', $this->baguio->id)->firstOrFail();
    expect($own->trip_number)->toStartWith('BGO')->and($own->truck_id)->toBe($truck->id)
        ->and(Tripinvoice::where('deliveryloghub_id', $own->id)->count())->toBe(3)
        ->and(Tripinvoice::where('invoice', 'VG1')->value('deliveryloghub_id'))->toBeNull();
});

it('follows the SMS switches: hub texts have their own switch, one trip can skip the text', function () {
    expect(SmsSettings::KINDS)->toHaveKey('out_for_delivery_hub');
    $trip = Deliverylog::create(['trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $this->admin->logistichub_id, 'user_id' => $this->admin->id, 'no_sms' => true]);
    expect(SmsEvents::outForDelivery($trip))->toBe(0);
    AppSetting::put('sms.on.out_for_delivery', '0');
    ($this->box)('Tarlac', 'Capas', 'X', 'CAP1', 3);
    Livewire::test(PlanTrips::class)->assertSee('No SMS (off in');
    // the old AI trip helper is out of the menu
    expect(AiTrips::shouldRegisterNavigation())->toBeFalse()
        ->and(AiFeatures::ALL['trips'][0])->toBe('Trip helper');
});
DISPATCH_FILE_END_21

# ---------------------------------------------------------------- tests/Feature/TripFillTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/TripFillTest.php' <<'DISPATCH_FILE_END_22'
<?php

use App\Filament\Pages\NewBoxes;
use App\Filament\Pages\PlanTrips;
use App\Filament\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Filament\Tables\TripList;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\TripOverride;
use App\Models\Truck;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Trips\CityTrips;
use App\Support\Trips\TripFill;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Invoice::query()->update(['is_assigned' => true]);
    Truck::query()->update(['is_assigned' => false, 'capacity' => 20]);
    $base = Invoice::firstOrFail();
    $this->box = function (string $prov, string $city, string $no, ?string $phone = null, ?string $set = null) use ($base) {
        $i = $base->replicate();
        $i->forceFill(['invoice' => $no, 'receiver_province' => $prov, 'receiver_city' => $city, 'receiver_barangay' => 'X', 'is_verified' => true, 'is_assigned' => false,
            'is_delivered' => false, 'is_priority' => false, 'verified_at' => now()->subDays(3), 'receiver_name' => 'R '.$no,
            'receiver_mobile_no' => $phone ?? '09'.random_int(100000000, 999999999), 'set_key' => $set])->save();

        return $i;
    };
    foreach (range(1, 14) as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 'TAR'.$n);
    }
});

it('picks combos whole: urgent first, combos before single boxes, never split', function () {
    $c = fn ($key, $n) => ['key' => $key, 'ids' => range(1, $n), 'n' => $n, 'space' => (float) $n, 'prio' => 0, 'retry' => 0, 'name' => $key, 'barangay' => ''];
    [$picked, $rest] = TripFill::pick(collect([$c('s1', 1), $c('combo', 3), $c('s2', 1), $c('s3', 1)]), 4);
    expect($picked->pluck('key')->all())->toBe(['combo', 's1'])->and($rest->pluck('key')->all())->toBe(['s2', 's3']);
    [$picked] = TripFill::pick(collect([$c('combo', 3), $c('s1', 1), $c('s2', 1)]), 2);
    expect($picked->pluck('key')->all())->toBe(['s1', 's2']); // the combo does not fit: not split

    // a set (same name, phone and city) and one receiver with two names (same phone) are each one combo
    ($this->box)('Pampanga', 'Angeles', 'ANG1', '09170000001');
    ($this->box)('Pampanga', 'Angeles', 'ANG2', '09170000001');
    foreach (['ANG3', 'ANG4'] as $no) {
        ($this->box)('Pampanga', 'Angeles', $no, '09170000002')->update(['receiver_name' => 'Maria Santos']);
    }
    $units = (new CityTrips($this->admin))->waitingUnits()->where('city', 'Angeles');
    $combos = TripFill::combos($units);
    expect($combos)->toHaveCount(2)
        ->and($combos->pluck('kind')->sort()->values()->all())->toBe(['receiver', 'set'])
        ->and($combos->pluck('n')->all())->toBe([2, 2]);
});

it('puts the boxes on the trips at Create (not loaded), up to the truck space', function () {
    Truck::query()->update(['capacity' => 10]);
    ($this->box)('Tarlac', 'Tarlac City', 'COMBO1', '09171111111');
    ($this->box)('Tarlac', 'Tarlac City', 'COMBO2', '09171111111');
    Livewire::test(PlanTrips::class)->call('create');
    $trip = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->firstOrFail();
    $on = Tripinvoice::where('deliverylog_id', $trip->id);
    expect((clone $on)->count())->toBe(10)
        ->and((clone $on)->where('is_loaded', true)->count())->toBe(0)
        ->and((clone $on)->whereIn('invoice', ['COMBO1', 'COMBO2'])->count())->toBe(2) // the combo first, whole
        ->and(TripCity::where('deliverylog_id', $trip->id)->value('planned_boxes'))->toBe(10);
});

it('adds new boxes to a trip with room, then Add anyway with a reason, then a new trip', function () {
    Livewire::test(PlanTrips::class)->call('create');
    $trip = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->firstOrFail(); // 14 of 20
    // a new container: a receiver with 3 boxes and 5 single boxes for Tarlac City
    foreach ([1, 2, 3] as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 'NEWC'.$n, '09172222222');
    }
    foreach (range(1, 5) as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 'NEW'.$n);
    }
    $row = collect(TripFill::newBoxes($this->admin))->firstWhere('city', 'Tarlac City');
    expect($row['kind'])->toBe('open')->and($row['n'])->toBe(8)->and($row['trip']['number'])->toBe($trip->trip_number)
        ->and($row['newN'])->toBe(2); // room 6: the combo of 3 + 3 single boxes

    $page = Livewire::test(NewBoxes::class)->assertSee('New boxes since the trips were made')->assertSee('Add to '.$trip->trip_number)
        ->call('openPick', $row['key'])->assertSee('Combo · receiver')->assertSee('Pick what fits')->assertSee('Add 6 boxes')
        ->call('confirmPick');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->count())->toBe(20)
        ->and(Tripinvoice::where('deliverylog_id', $trip->id)->whereIn('invoice', ['NEWC1', 'NEWC2', 'NEWC3'])->count())->toBe(3);

    // full now: nothing is picked; one box is over the space → Add anyway needs a reason
    $row = collect(TripFill::newBoxes($this->admin))->firstWhere('city', 'Tarlac City');
    expect($row['kind'])->toBe('full')->and($row['n'])->toBe(2);
    $page->call('openPick', $row['key'], true)->assertSee('Pick boxes')->call('toggle', $row['combos'][0]['key'])->assertSee('Add anyway · 1 box')
        ->call('confirmPick');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->count())->toBe(20); // no reason yet
    $page->set('reason', 'It still fits (small box)')->call('confirmPick');
    expect(Tripinvoice::where('deliverylog_id', $trip->id)->count())->toBe(21)
        ->and(TripOverride::where('rule', 'truck_full')->where('trip_id', $trip->id)->value('reason'))->toBe('It still fits (small box)');

    // the last box: a new trip, made by the AI
    $row = collect(TripFill::newBoxes($this->admin))->firstWhere('city', 'Tarlac City');
    $page->call('newTrip', $row['key']);
    $new = Deliverylog::whereKeyNot($trip->id)->whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->latest('id')->firstOrFail();
    expect(Tripinvoice::where('deliverylog_id', $new->id)->count())->toBe(1)->and($new->made_by)->toBe('ai')
        ->and(TripFill::newBoxes($this->admin))->toBe([]);
});

it('applies all: boxes to the trip with room, the rest on a new trip, in the warehouse too', function () {
    $wh = User::where('email', 'warehouse@example.com')->firstOrFail();
    $this->actingAs($wh);
    Filament::setCurrentPanel(Filament::getPanel('warehouse'));
    Livewire::test(App\Filament\Warehouse\Pages\PlanTrips::class)->call('create');
    foreach (range(1, 8) as $n) {
        ($this->box)('Tarlac', 'Tarlac City', 'APP'.$n);
    }
    Livewire::test(App\Filament\Warehouse\Pages\NewBoxes::class)->assertSee('Apply')->call('applyAll');
    $trips = Deliverylog::whereHas('cities', fn ($q) => $q->where('city', 'Tarlac City'))->orderBy('id')->get();
    expect($trips)->toHaveCount(2)
        ->and(Tripinvoice::where('deliverylog_id', $trips[0]->id)->count())->toBe(20)
        ->and(Tripinvoice::where('deliverylog_id', $trips[1]->id)->count())->toBe(2)
        ->and(Invoice::where('invoice', 'like', 'APP%')->where('is_assigned', false)->count())->toBe(0);
});

it('puts a box on the partner hub trip at their unload scan: full → new hub trip, or Add anyway', function () {
    $hubUser = User::where('email', 'company@example.com')->firstOrFail();
    $hub = (int) $hubUser->logistichub_id;
    $truck = Truck::query()->firstOrFail();
    $t1 = $truck->replicate();
    $t1->forceFill(['logistichub_id' => $hub, 'plate_no' => 'HUB 1', 'capacity' => 2, 'is_assigned' => true, 'is_active' => true])->save();
    $t2 = $truck->replicate();
    $t2->forceFill(['logistichub_id' => $hub, 'plate_no' => 'HUB 2', 'capacity' => 2, 'is_assigned' => false, 'is_active' => true])->save();
    $hubTrip = Deliverylog::create(['truck_id' => $t1->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $hub, 'assigned_to' => $hub, 'user_id' => $hubUser->id]);
    TripCity::create(['deliverylog_id' => $hubTrip->id, 'province' => 'Benguet', 'city' => 'La Trinidad', 'city_key' => 'la trinidad', 'planned_boxes' => 0]);
    $fromManila = Deliverylog::create(['trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $this->admin->logistichub_id, 'assigned_to' => $hub, 'user_id' => $this->admin->id]);
    $row = function (string $no, ?string $phone = null) use ($fromManila, $hub) {
        $i = ($this->box)('Benguet', 'La Trinidad', $no, $phone);

        return Tripinvoice::create(['deliverylog_id' => $fromManila->id, 'logistichub_id' => $hub, 'invoice' => $no, 'invoice_id' => $i->id, 'is_loaded' => true]);
    };
    $a = $row('LT1');
    $b = $row('LT2');
    $c = $row('LT3', '09173333333');
    $d = $row('LT4', '09173333333'); // same receiver as LT3: a combo

    expect(TripFill::placeAtHub($a, $hub, $hubUser)['trip'])->toBe($hubTrip->trip_number)
        ->and(TripFill::placeAtHub($b, $hub, $hubUser)['trip'])->toBe($hubTrip->trip_number);
    $full = TripFill::placeAtHub($c, $hub, $hubUser); // 2 of 2: full → new hub trip with HUB 2
    expect($full['kind'])->toBe('new')->and($full['full']['number'])->toBe($hubTrip->trip_number);
    $new = Deliverylog::findOrFail($full['tripId']);
    expect($new->truck_id)->toBe($t2->id)->and($new->made_by)->toBe('ai');
    // the rest of the combo follows its first box
    expect(TripFill::placeAtHub($d, $hub, $hubUser)['tripId'])->toBe($new->id);

    // Add anyway: the combo moves to the full trip; the empty new trip goes away and its truck is free again
    $res = TripFill::hubAddAnyway($c->fresh(), $hubTrip->id, $hubUser, 'Small boxes');
    expect($res['ok'])->toBeTrue()
        ->and(Tripinvoice::where('deliveryloghub_id', $hubTrip->id)->count())->toBe(4)
        ->and(Deliverylog::find($new->id))->toBeNull()
        ->and((bool) $t2->fresh()->is_assigned)->toBeFalse()
        ->and(TripOverride::where('rule', 'truck_full')->where('trip_id', $hubTrip->id)->exists())->toBeTrue();
});

it('is done by itself when every box is delivered; returns wait until scanned back', function () {
    $truck = Truck::where('logistichub_id', $this->admin->logistichub_id)->firstOrFail();
    $trip = Deliverylog::create(['truck_id' => $truck->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'logistichub_id' => $this->admin->logistichub_id,
        'assigned_to' => $this->admin->logistichub_id, 'user_id' => $this->admin->id, 'taken_at' => now()->subHours(3)]);
    $rows = Invoice::whereIn('invoice', ['TAR1', 'TAR2'])->get()->map(fn ($i) => Tripinvoice::create(['deliverylog_id' => $trip->id, 'logistichub_id' => $trip->assigned_to,
        'invoice' => $i->invoice, 'invoice_id' => $i->id, 'is_loaded' => true]));
    $rows[0]->update(['is_delivered' => true]);
    $trip->forceFill(['back_at' => now()])->save();
    $st = TripList::status($trip->fresh());
    expect($st['label'])->toBe('Coming back')->and($st['when'])->toBe('1 return to scan at the office');

    Livewire::test(ListDeliverylogs::class)->assertSee('Still at work')->assertSee('Coming back')
        ->assertCanSeeTableRecords([$trip]);

    // the return is scanned back at the office: the trip is done by itself
    app(TripAssignment::class)->returnToInventory($rows[1]->fresh());
    $trip->refresh();
    expect($trip->is_active)->toBeFalsy()->and($trip->release_reason)->toBe('auto')
        ->and($trip->delivery_date?->toDateString())->toBe(today()->toDateString())
        ->and(TripList::status($trip)['label'])->toBe('Done');
    Livewire::test(ListDeliverylogs::class)->assertCanNotSeeTableRecords([$trip])
        ->set('activeTab', 'done')->assertCanSeeTableRecords([$trip]);
});
DISPATCH_FILE_END_22

# ---------------------------------------------------------------- tests/Feature/UndoDeliveryTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/UndoDeliveryTest.php' <<'DISPATCH_FILE_END_23'
<?php

use App\Enums\UndoDeliveryReason;
use App\Filament\Delivery\Pages\Dashboard;
use App\Filament\Delivery\Pages\Deliveryinv;
use App\Filament\Resources\Deliverylogs\Pages\EditDeliverylog;
use App\Filament\Resources\Deliverylogs\RelationManagers\TripinvoicesRelationManager;
use App\Filament\Tables\DeliveryAttemptColumns;
use App\Models\Deliverylog;
use App\Models\DeliveryReversal;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->firstOrFail();

    $this->deliver = fn () => app(TripAssignment::class)->markDelivered($this->box, ['deliveries/door.jpg'], $this->driver);
});

function driverPanel(): void
{
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    test()->actingAs(test()->driver);
}

it('records when and by whom a box was delivered', function () {
    ($this->deliver)();

    $box = $this->box->fresh();
    expect($box->is_delivered)->toBeTruthy()
        ->and($box->delivered_by)->toBe($this->driver->id)
        ->and($box->delivered_at)->not->toBeNull();
});

it('lets the driver undo from the toast right after delivering', function () {
    ($this->deliver)();
    driverPanel();

    Livewire::test(Deliveryinv::class)
        ->dispatch('undo-delivery', tripinvoiceId: $this->box->id)
        ->assertNotified('Delivery undone');

    $reversal = DeliveryReversal::firstOrFail();
    expect($this->box->fresh()->is_delivered)->toBeFalsy()
        ->and($reversal->reason)->toBe(UndoDeliveryReason::TappedByMistake)
        ->and($reversal->photos)->toBe(['deliveries/door.jpg'])
        ->and($reversal->by_office)->toBeFalse();
});

it('shows Undo on the dashboard for 30 minutes, then Office only', function () {
    $this->travelTo(today()->setTime(10, 0)); // not near midnight: the list is today's deliveries
    ($this->deliver)();
    driverPanel();

    $this->travelTo(now()->addMinutes(10));
    Livewire::test(Dashboard::class)->assertSee('20 min left')->assertDontSee('Office only');

    $this->travelTo(now()->addMinutes(25));
    Livewire::test(Dashboard::class)->assertSee('Office only')->assertDontSee('min left');
});

it('lets the driver undo from the dashboard with a reason', function () {
    ($this->deliver)();
    driverPanel();

    Livewire::test(Dashboard::class)
        ->callAction('undoDelivery', data: ['reason' => UndoDeliveryReason::Other->value], arguments: ['tripinvoice' => $this->box->id])
        ->assertHasActionErrors(['note' => 'required']);

    Livewire::test(Dashboard::class)
        ->callAction('undoDelivery', data: ['reason' => UndoDeliveryReason::WrongBox->value], arguments: ['tripinvoice' => $this->box->id])
        ->assertHasNoActionErrors()
        ->assertNotified('Delivery undone');

    expect($this->box->fresh()->is_delivered)->toBeFalsy()
        ->and(DeliveryReversal::first()->reason)->toBe(UndoDeliveryReason::WrongBox)
        ->and($this->trip->user->notifications()->count())->toBeGreaterThan(0);
});

it('refuses a driver undo after 30 minutes or for someone else\'s delivery', function () {
    ($this->deliver)();

    $this->travelTo(now()->addMinutes(31));
    expect(fn () => app(TripAssignment::class)->undoDelivery($this->box->fresh(), $this->driver, UndoDeliveryReason::WrongBox))
        ->toThrow(DomainException::class, 'too late');

    $this->travelBack();
    $other = User::where('email', '!=', $this->driver->email)->where('email', 'like', '%@example.com')->where('id', '!=', $this->admin->id)->firstOrFail();
    expect(fn () => app(TripAssignment::class)->undoDelivery($this->box->fresh(), $other, UndoDeliveryReason::WrongBox))
        ->toThrow(DomainException::class);

    expect($this->box->fresh()->is_delivered)->toBeTruthy();
});

it('lets the office mark a box as not delivered any time and tells the driver', function () {
    ($this->deliver)();
    $this->travelTo(now()->addDays(2));

    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);

    Livewire::test(TripinvoicesRelationManager::class, ['ownerRecord' => $this->trip, 'pageClass' => EditDeliverylog::class])
        ->callTableAction('undoDelivery', $this->box, data: ['reason' => UndoDeliveryReason::ReceiverDidNotGetIt->value, 'note' => 'Customer called'])
        ->assertHasNoTableActionErrors()
        ->assertNotified('Marked as not delivered');

    $reversal = DeliveryReversal::firstOrFail();
    expect($this->box->fresh()->is_delivered)->toBeFalsy()
        ->and($reversal->by_office)->toBeTrue()
        ->and($reversal->delivered_by)->toBe($this->driver->id)
        ->and($this->driver->notifications()->count())->toBe(1);

    $html = view('filament.delivery-attempts', ['attempts' => DeliveryAttemptColumns::history($this->box->fresh())])->render();
    expect($html)->toContain('Delivery undone')->toContain('Receiver says they did not get the box')->toContain('Customer called');
});
DISPATCH_FILE_END_23

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
