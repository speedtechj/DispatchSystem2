<?php

namespace App\Filament\Pages;

use App\Models\AppSetting;
use App\Models\Photos\PhotoTask;
use App\Models\Photos\PhotoTaskItem;
use App\Support\Photos\Storage\OldSystem;
use App\Support\Photos\Storage\PhotoStore;
use App\Support\Photos\Storage\PhotoWork;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Contracts\Support\Htmlable;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\StreamedResponse;

/** Settings → Photo storage (board 66): buckets, moving photos, copying the old system's photos, workers. */
class PhotoStorage extends Page
{
    protected string $view = 'filament.photos.storage';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedCloudArrowUp;

    protected static ?string $title = 'Photo storage';

    protected static ?string $slug = 'photo-storage';

    public string $tab = 'old';

    public int $step = 1;

    public string $rt = 'wmsv2';

    public string $search = '';

    /** @var array<string, array<string, ?string>> */
    public array $form = [];

    /** @var array<string, bool> */
    public array $editing = ['tmp' => false, 'real' => false];

    public bool $autoOff = true;

    public bool $runHere = false;

    public bool $sureAgain = false;

    public string $oldFolder = '';

    /** @var array<string, string> */
    public array $msg = [];

    public static function canAccess(): bool
    {
        return PhotoStore::ready() && (bool) Auth::user()?->is_admin;
    }

    public function getHeading(): string|Htmlable
    {
        return '';
    }

    public function mount(): void
    {
        foreach (['tmp', 'real'] as $slot) {
            $b = PhotoStore::bucket($slot);
            $this->form[$slot] = ['provider' => $b->provider ?: 'r2', 'account_id' => $b->account_id, 'endpoint' => $b->endpoint, 'region' => $b->region,
                'bucket' => $b->bucket, 'access_key' => $b->access_key, 'secret' => ''];
            $this->editing[$slot] = ! $b->exists;
        }
        $this->oldFolder = (string) (OldSystem::folder() ?? dirname(base_path()).'/wms.icargoxpress.net');
        $task = OldSystem::task();
        $this->step = ! $task ? 1 : ($task->status === 'done' ? 6 : ($task->done || $task->status === 'running' ? 5 : 2));
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['old', 'bucket', 'work'], true) ? $tab : 'old';
    }

    public function setStep(int $n): void
    {
        $this->step = max(1, min(8, $n));
    }

    // ── Bucket tab ──────────────────────────────────────────────

    public function setProvider(string $slot, string $p): void
    {
        if (isset(PhotoStore::PROVIDERS[$p]) && isset($this->form[$slot])) {
            $this->form[$slot]['provider'] = $p;
            $this->editing[$slot] = true;
        }
    }

    public function editBucket(string $slot): void
    {
        $this->editing[$slot] = true;
    }

    public function saveBucket(string $slot): void
    {
        $f = array_map(fn ($v) => is_string($v) ? trim($v) : $v, $this->form[$slot] ?? []);
        $b = PhotoStore::bucket($slot);
        if ($b->exists && $slot === 'tmp' && PhotoStore::target() === 'tmp' && $b->bucket && $f['bucket'] !== $b->bucket && PhotoStore::countIn('tmp')) {
            $this->msg[$slot] = 'Photos are in this bucket: switch to Real and move them before you change it.';

            return;
        }
        $b->fill(['provider' => $f['provider'] ?? 'r2', 'account_id' => $f['account_id'] ?: null, 'endpoint' => $f['endpoint'] ?: null, 'region' => $f['region'] ?: null,
            'bucket' => $f['bucket'] ?: null, 'access_key' => $f['access_key'] ?: null]);
        if (filled($f['secret'] ?? null)) {
            $b->secret = $f['secret'];
        }
        $b->forceFill(['test_ok' => false, 'test_message' => null]);
        $b->slot = $slot;
        $b->save();
        PhotoStore::forgetMemo();
        $this->form[$slot]['secret'] = '';
        $this->editing[$slot] = false;
        $this->testBucket($slot);
    }

    public function testBucket(string $slot): void
    {
        [$ok, $msg] = PhotoStore::test($slot);
        PhotoStore::forgetMemo();
        $this->msg[$slot] = ($ok ? '✓ ' : '✗ ').$msg;
    }

    public function setTarget(string $place): void
    {
        if (! isset(PhotoStore::PLACES[$place]) || ! PhotoStore::usable($place)) {
            Notification::make()->title('Put and test that bucket first')->warning()->send();

            return;
        }
        PhotoStore::setTarget($place);
        Notification::make()->title('New photos go to: '.PhotoStore::PLACES[$place])->success()->send();
    }

    public function turnOff(string $slot): void
    {
        if ($slot !== 'tmp') {
            return;
        }
        $b = PhotoStore::bucket('tmp');
        if (PhotoStore::target() === 'tmp') {
            $this->msg['tmp'] = 'Not yet: new photos still go here. Choose Real bucket first.';
        } elseif (($n = PhotoStore::countIn('tmp')) > 0) {
            $this->msg['tmp'] = 'Not yet: '.number_format($n).' photos are still here. Move Temporary → Real first.';
        } else {
            $b->update(['is_off' => true]);
            $this->msg['tmp'] = 'Turned off: nothing is saved or read here. The files stay in Cloudflare as a backup.';
        }
        PhotoStore::forgetMemo();
    }

    public function turnOn(string $slot): void
    {
        PhotoStore::bucket($slot)->update(['is_off' => false]);
        $this->msg[$slot] = '';
        PhotoStore::forgetMemo();
    }

    public function startMove(): void
    {
        $to = PhotoStore::target();
        if ($to === 'server' || PhotoWork::active()) {
            Notification::make()->title($to === 'server' ? 'Choose a bucket for new photos first' : 'Another move is running')->warning()->send();

            return;
        }
        $t = PhotoWork::startMove($to);
        Cache::forget('photos.server.count');
        Notification::make()->title(number_format($t->total).' photos will move to the '.strtolower(PhotoStore::PLACES[$to]))->success()->send();
    }

    public function startSwitch(): void
    {
        if (! PhotoStore::usable('real') || PhotoWork::active()) {
            Notification::make()->title(PhotoWork::active() ? 'Another move is running' : 'Put and test the real bucket first')->warning()->send();

            return;
        }
        PhotoWork::startSwitch($this->autoOff);
        Notification::make()->title('Switching to the real bucket')->success()->send();
    }

    public function pause(int $id): void
    {
        PhotoTask::whereKey($id)->whereIn('status', ['running', 'checking'])->update(['status' => 'paused']);
    }

    public function resume(int $id): void
    {
        PhotoTask::whereKey($id)->where('status', 'paused')->update(['status' => 'running']);
        PhotoWork::kick();
    }

    // ── Workers tab ─────────────────────────────────────────────

    public function toggleRunHere(): void
    {
        $this->runHere = ! $this->runHere;
    }

    /** "Run here": the page itself goes on while it is open (wire:poll). */
    public function tick(): void
    {
        if ($this->runHere) {
            PhotoWork::work(8);
            PhotoStore::forgetMemo();
        }
    }

    // ── Copy from the old system ────────────────────────────────

    public function saveFolder(): void
    {
        $dir = rtrim(trim($this->oldFolder), '/');
        AppSetting::put('photos.old_folder', $dir ?: null);
        Cache::forget('photos.old.columns');
        $f = OldSystem::find();
        Notification::make()->title($f['found'] ? 'Found the old system' : 'No folder there')->{$f['found'] ? 'success' : 'warning'}()->send();
    }

    public function scan(): void
    {
        $task = OldSystem::scan();
        $task->forceFill(['options' => array_merge($task->options ?? [], ['folders' => OldSystem::folders(OldSystem::find())])])->save();
        Cache::forget('photos.old.columns');
        $this->step = 2;
        Notification::make()->title('Scanned: '.number_format($task->items()->count()).' photo paths')->success()->send();
    }

    public function setOpt(string $key): void
    {
        $task = OldSystem::task();
        if ($task && in_array($key, ['small', 'keep'], true)) {
            $task->update(['options' => array_merge($task->options ?? [], [$key => ! $task->opt($key, $key === 'small')])]);
        }
    }

    public function tryFifty(): void
    {
        $task = OldSystem::task();
        if (! $task) {
            return;
        }
        if (! PhotoStore::usable(PhotoStore::target() !== 'server' ? PhotoStore::target() : 'tmp')) {
            Notification::make()->title('Put and test the bucket first (Bucket tab)')->warning()->send();

            return;
        }
        $n = OldSystem::tryFifty($task)->count();
        Notification::make()->title($n.' photos tried')->success()->send();
    }

    public function copyNew(): void
    {
        $task = OldSystem::task();
        if (! $task) {
            return;
        }
        $task->update(['status' => 'running', 'started_at' => $task->started_at ?? now(), 'options' => array_merge($task->options ?? [], ['again' => false])]);
        $task->items()->where('status', 'failed')->update(['status' => 'pending']);
        PhotoWork::kick();
        $this->sureAgain = false;
    }

    public function checkBucket(): void
    {
        $task = OldSystem::task();
        if ($task) {
            $task->items()->where('status', 'done')->update(['checked' => false]);
            $task->update(['status' => 'checking']);
            PhotoWork::kick();
        }
    }

    public function copyAgain(): void
    {
        if (! $this->sureAgain) {
            $this->sureAgain = true;

            return;
        }
        $task = OldSystem::task();
        if ($task) {
            $task->items()->whereIn('status', ['done', 'skipped', 'failed'])->update(['status' => 'pending', 'checked' => false]);
            $task->update(['status' => 'running', 'options' => array_merge($task->options ?? [], ['again' => true])]);
            PhotoWork::kick();
        }
        $this->sureAgain = false;
    }

    public function pick(int $id): void
    {
        $item = PhotoTaskItem::find($id);
        $item && OldSystem::pick($item);
    }

    public function markBackup(): void
    {
        AppSetting::put('photos.old_backup', AppSetting::get('photos.old_backup') ? null : now()->toDateString());
    }

    public function csv(string $kind): StreamedResponse
    {
        $task = OldSystem::task();
        $find = OldSystem::find();
        if ($kind === 'list') {
            AppSetting::put('photos.old_csv', now()->toDateString());
        }

        return response()->streamDownload(function () use ($task, $kind, $find) {
            $out = fopen('php://output', 'w');
            fputcsv($out, $kind === 'list' ? ['old link', 'new path in the bucket', 'status', 'size before', 'size after', 'found in', 'database'] : ['path', 'found in', 'status', 'file', 'database', 'note']);
            $task?->items()->orderBy('id')->chunk(1000, function ($items) use ($out, $kind, $find) {
                foreach ($items as $i) {
                    fputcsv($out, $kind === 'list'
                        ? [OldSystem::oldLink($i, $find), $i->path, $i->status, $i->size_before, $i->size_after, $i->found, $i->ref]
                        : [$i->path, $i->found, $i->status, $i->source, $i->ref, $i->note]);
                }
            });
            fclose($out);
        }, ($kind === 'list' ? 'old-to-new-links' : 'photo-scan-report').'-'.now()->format('Ymd-Hi').'.csv', ['Content-Type' => 'text/csv']);
    }

    protected function getViewData(): array
    {
        $target = PhotoStore::target();
        $tmp = PhotoStore::bucket('tmp');
        $real = PhotoStore::bucket('real');
        $task = OldSystem::task();
        $find = $this->tab === 'old' ? OldSystem::find() : ['found' => (bool) OldSystem::folder()];
        $active = PhotoWork::active();
        $serverCount = $this->tab === 'bucket' ? Cache::remember('photos.server.count', 600, function () {
            $n = 0;
            foreach (['public', 'box'] as $d) {
                foreach (rescue(fn () => $d === 'box' ? PhotoStore::server($d)->allFiles('box-photos') : PhotoStore::server($d)->allFiles(), [], false) as $p) {
                    $n += PhotoStore::skip($d, $p) || str_starts_with(basename($p), '.') ? 0 : 1;
                }
            }

            return $n;
        }) : 0;

        $items = fn () => $task ? $task->items() : PhotoTaskItem::whereRaw('1 = 0');
        $groups = $task ? $task->items()->selectRaw('found, count(*) as n')->groupBy('found')->pluck('n', 'found') : collect();

        return [
            'target' => $target, 'tmp' => $tmp, 'real' => $real, 'stats' => PhotoStore::stats(), 'driver' => PhotoStore::driverReady(),
            'usable' => ['server' => true, 'tmp' => PhotoStore::usable('tmp'), 'real' => PhotoStore::usable('real')],
            'inTmp' => PhotoStore::countIn('tmp'), 'serverCount' => $serverCount,
            'moves' => PhotoTask::whereIn('kind', ['move', 'switch'])->latest('id')->limit(3)->get(),
            'active' => $active, 'switch' => PhotoTask::where('kind', 'switch')->latest('id')->first(),
            'worker' => PhotoStore::workerOn(), 'scheduler' => PhotoStore::schedulerOn(), 'queueSeen' => PhotoStore::queueSeen(), 'scheduleSeen' => PhotoStore::scheduleSeen(),
            'find' => $find, 'task' => $task,
            'columns' => $this->tab === 'old' && $this->step === 1 && ($find['found'] ?? false) ? Cache::remember('photos.old.columns', 600, fn () => OldSystem::columns()->all()) : [],
            'groups' => $groups,
            'rows' => $this->tab === 'old' && $this->step === 3 ? $items()->where('found', $this->rt)
                ->when($this->search !== '', fn ($q) => $q->where(fn ($w) => $w->where('path', 'like', '%'.$this->search.'%')->orWhere('ref', 'like', '%'.$this->search.'%')))
                ->orderBy('id')->limit(40)->get() : collect(),
            'tried' => $this->step === 4 ? $items()->where('tried', true)->whereIn('status', ['done', 'skipped'])->orderByDesc('size_before')->limit(6)->get() : collect(),
            'triedSum' => $task ? $task->items()->where('tried', true)->where('status', 'done')->selectRaw('count(*) n, sum(size_before) b, sum(size_after) a')->first() : null,
            'last' => $this->step === 5 && $task ? $task->items()->whereIn('status', ['done', 'skipped', 'failed'])->latest('updated_at')->limit(6)->get() : collect(),
            'checkedN' => $task ? $task->items()->where('checked', true)->count() : 0,
            'missingN' => (int) ($groups['missing'] ?? 0),
            'backup' => AppSetting::get('photos.old_backup'), 'csvAt' => AppSetting::get('photos.old_csv'),
            'mb' => fn ($b) => $b >= 1073741824 ? number_format($b / 1073741824, 1).' GB' : ($b >= 1048576 ? number_format($b / 1048576, 1).' MB' : number_format($b / 1024).' KB'),
            'openUrl' => fn (PhotoTaskItem $i) => route('photo-storage.open', $i->id),
            'oldUrl' => fn (PhotoTaskItem $i) => OldSystem::oldLink($i, $find),
        ];
    }
}
