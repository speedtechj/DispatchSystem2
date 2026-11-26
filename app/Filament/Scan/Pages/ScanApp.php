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

    /** Start screen: the tiles show at once, the counts and Continue a moment later (board 54). */
    public bool $homeReady = false;

    /** Load next, space, "Room for more": loaded right after the scan screen shows (board 51). */
    public bool $extrasReady = false;

    /** Pick boxes: a number per scan, so the same message twice still shows again. */
    public int $pickSeq = 0;

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
        // for Continue on the start screen
        cache()->put('scan-app.last.'.Auth::id(), ['mode' => $this->mode, 'choice' => $id, 'name' => $target['name'] ?? ''], now()->addHours(16));
        $this->extrasReady = false;
        $this->choice = $id;
        $this->returned = 0;
        $this->screen = 'scan';
        $this->clearResult();
    }

    /** Called by the start screen once it shows. */
    public function loadHome(): void
    {
        $this->homeReady = true;
    }

    /** Continue: back to the job left unfinished. */
    public function continueLast(): void
    {
        $last = cache()->get('scan-app.last.'.Auth::id());
        if (! $last || ! isset($this->modes()[$last['mode']])) {
            return;
        }
        $this->open($last['mode']);
        if ($this->screen === 'pick') {
            $this->pick((int) $last['choice']);
        }
    }

    /** The unfinished job of this person for the Continue card, or null. */
    protected function resume(): ?array
    {
        $last = cache()->get('scan-app.last.'.Auth::id());
        $mode = $last ? ($this->modes()[$last['mode']] ?? null) : null;
        if (! $mode) {
            return null;
        }
        try {
            $p = $this->station((int) $last['choice'], $last['mode'])->progress();
        } catch (\Throwable) {
            return null;
        }
        $total = (int) ($p['total'] ?? 0);
        $done = (int) ($p['loaded'] ?? 0);
        if ($total <= 0 || $done >= $total) {
            return null;
        }

        return ['label' => $mode['label'], 'name' => $last['name'], 'done' => $done, 'total' => $total, 'pct' => (int) round($done / $total * 100)];
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
        $this->homeReady = false;
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
        $this->reset('status', 'message', 'invoiceId', 'missing', 'condition', 'note', 'boxPhoto', 'early', 'spot', 'route', 'setInfo', 'wrongHub', 'bypass', 'hubTrip', 'pickResult', 'which');
    }

    /** Board 58: two boxes with the scanned number still to do: ['code' => …, 'options' => [id, name, place, sender]]. */
    public ?array $which = null;

    /** Which one? → the receiver was tapped: scan that exact box. */
    public function chooseBox(int $id): void
    {
        $w = $this->which;
        if (! $w || ! collect($w['options'] ?? [])->contains('id', $id)) {
            return;
        }
        $this->runScan($w['code'], false, $id);
    }

    /** Which one? → Not this box. */
    public function skipBox(): void
    {
        $this->clearResult();
    }

    /** The box on the result card, when it has this number (two boxes can share one). */
    protected function boxShown(string $code): ?int
    {
        return $this->invoiceId && Invoice::whereKey($this->invoiceId)->value('invoice') === $code ? $this->invoiceId : null;
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
            'invoice_id' => $this->boxShown($code) ?? \App\Support\Boxes\SameNumber::best($code)?->id, 'box' => $code];
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

    protected function runScan(string $code, bool $force = false, ?int $pin = null): void
    {
        $station = $this->station();
        if (! $station || ! $this->choice || $this->screen !== 'scan') {
            return;
        }
        // load anyway after a pick: the same box again, not a new Which one?
        $pin ??= $force ? $this->boxShown(\App\Support\InvoiceLookup::normalize($code)) : null;

        if ($force && property_exists($station, 'forceLoad')) {
            $station->forceLoad = true;
        }
        $pin ? $station->scanPinned($code, $pin) : $station->scan($code);
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
        $this->which = $station->which ?? null;
        if ($this->which) {
            $this->status = 'which';
            $this->dispatch('scan-app-result', status: 'which');

            return;
        }
        if ($this->mode === 'pick') {
            $this->pickSeq++;
        }

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
                FileUpload::make('attachment_pic')->label('Photo')->image()->disk('public')->directory(fn () => \App\Support\Photos\Storage\PhotoFolders::dir('unmanifested'))->visibility('private')->required(),
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
            $hubCounts = $this->mode === 'load' && method_exists($station, 'hubCounts') ? $station->hubCounts() : null;
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
            'waiting' => $this->screen === 'home' && $this->homeReady ? $this->waitingCounts() : [],
            'resume' => $this->screen === 'home' && $this->homeReady ? $this->resume() : null,
            'homeReady' => $this->homeReady,
            'progress' => $progress,
            'target' => $target,
            'loadNext' => $loadNext,
            'team' => $team,
            'hubCounts' => $hubCounts ?? null,
            'trucks' => $trucks,
            'openSets' => $openSets,
            'countResult' => $countResult,
            'receiveResult' => $receiveResult,
            'topUp' => $topUp,
            'extrasReady' => $this->extrasReady || $this->screen !== 'scan',
            'paused' => $this->screen === 'scan' && $this->mode !== 'pick' && (($this->status !== null && ($this->status !== 'success' || $this->photosOn())) || $this->bypass !== null),
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
