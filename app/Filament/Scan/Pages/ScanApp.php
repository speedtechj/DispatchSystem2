<?php

namespace App\Filament\Scan\Pages;

use App\Models\Ai\AiPhotoCheck;
use App\Models\BoxPhoto;
use App\Models\Invoice;
use App\Models\PhotoSetting;
use App\Models\Unmanifested;
use App\Support\Ai\Ai;
use App\Support\Ai\PhotoCheck;
use App\Support\Photos\BoxPhotos;
use App\Support\ScanModes;
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

    /** Load truck: the box is for another hub. */
    #[Locked]
    public ?array $wrongHub = null;

    /** Unload: the list of trucks to pick from is open. */
    public bool $truckPicker = false;

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
        $this->reset('status', 'message', 'invoiceId', 'missing', 'condition', 'note', 'boxPhoto', 'early', 'spot', 'route', 'setInfo', 'wrongHub');
    }

    /** Called by the camera or the typed box number. */
    public function scan(string $code): void
    {
        $this->runScan($code);
    }

    /** After "too early": load that box anyway. */
    public function loadAnyway(): void
    {
        if ($code = $this->early['code'] ?? $this->wrongHub['code'] ?? null) {
            $this->runScan($code, true);
        }
    }

    // ------------------------------------------------------------------ sections, truck waiting, sets

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

    public function openTruckPicker(bool $open = true): void
    {
        $this->truckPicker = $open && $this->mode === 'unload';
    }

    public function truckStart(int $tripId): void
    {
        $station = $this->station();
        if ($this->mode === 'unload' && $station && method_exists($station, 'startTruck') && $station->startTruck($tripId)) {
            $this->truckPicker = false;
            Notification::make()->title('Truck waiting: its boxes now go straight onto it')->success()->send();
        }
    }

    public function truckPause(bool $paused): void
    {
        if ($this->mode === 'unload' && ($station = $this->station()) && method_exists($station, 'pauseTruck')) {
            $station->pauseTruck($paused);
        }
    }

    public function truckStop(): void
    {
        if ($this->mode === 'unload' && ($station = $this->station()) && method_exists($station, 'stopTruck')) {
            $station->stopTruck();
        }
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
        $truck = null;
        $trucks = collect();
        $openSets = [];
        if (in_array($this->screen, ['scan', 'done'], true) && $mode && $this->choice) {
            $station = $this->station();
            $progress = $station->progress();
            $target = $station->appChoices()->firstWhere('id', $this->choice);
            $loadNext = $this->screen === 'scan' && method_exists($station, 'loadNext') ? $station->loadNext() : null;
            $team = method_exists($station, 'team') ? $station->team() : [];
            $truck = method_exists($station, 'truckStatus') ? $station->truckStatus() : null;
            $trucks = $this->truckPicker && method_exists($station, 'truckChoices') ? $station->truckChoices() : collect();
            $openSets = $this->screen === 'done' && method_exists($station, 'openSets') ? $station->openSets() : [];
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
            'truck' => $truck,
            'trucks' => $trucks,
            'openSets' => $openSets,
            'splitReasons' => \App\Models\Boxes\SetSplit::REASONS,
            'box' => $this->invoiceId ? Invoice::find($this->invoiceId) : null,
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
