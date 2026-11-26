<?php

namespace App\Support\Photos\Storage;

use App\Jobs\RunPhotoTasks;
use App\Models\Photos\PhotoFile;
use App\Models\Photos\PhotoTask;
use App\Models\Photos\PhotoTaskItem;
use App\Support\Photos\PhotoShrinker;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Str;

/**
 * Moving photos in small batches: by the queue worker (Supervisor or Plesk), by the scheduler
 * (every minute), or by the Photo storage page itself while it is open ("Run here").
 * Each photo is copied, checked (same size in the bucket), and only then the old copy is deleted.
 */
class PhotoWork
{
    /** Server → a bucket: every photo still on the server (not the logos and icons). */
    public static function startMove(string $to, bool $tidy = true): PhotoTask
    {
        @set_time_limit(600);
        $task = PhotoTask::create(['kind' => 'move', 'from_place' => 'server', 'to_place' => $to, 'status' => 'running', 'user_id' => Auth::id(), 'started_at' => now(),
            'options' => ['tidy' => $tidy]]);
        $refs = $tidy ? PhotoFolders::refs() : [];
        $rows = [];
        foreach (['public', 'box'] as $disk) {
            $server = PhotoStore::server($disk);
            $files = $disk === 'box' ? $server->allFiles('box-photos') : $server->allFiles();
            foreach ($files as $path) {
                if (PhotoStore::skip($disk, $path) || str_starts_with(basename($path), '.')) {
                    continue;
                }
                $r = $refs[$disk.'|'.$path] ?? null;
                $rows[] = ['photo_task_id' => $task->id, 'disk' => $disk, 'path' => $path, 'status' => 'pending', 'created_at' => now(), 'updated_at' => now(),
                    'new_path' => $r[2] ?? null, 'tbl' => $r[0] ?? null, 'col' => $r[1] ?? null];
                if (count($rows) >= 500) {
                    PhotoTaskItem::insert($rows);
                    $rows = [];
                }
            }
        }
        $rows && PhotoTaskItem::insert($rows);
        $task->update(['total' => $task->items()->count()]);
        static::kick();

        return $task;
    }

    /** Switch to the real bucket: new photos go there now, the Temporary photos move, then Temporary turns off (if asked). */
    public static function startSwitch(bool $autoOff = true): PhotoTask
    {
        PhotoStore::setTarget('real');
        $task = PhotoTask::create(['kind' => 'switch', 'from_place' => 'tmp', 'to_place' => 'real', 'status' => 'running', 'user_id' => Auth::id(),
            'started_at' => now(), 'options' => ['auto_off' => $autoOff]]);
        PhotoFile::where('place', 'tmp')->where('disk', '!=', 'old')->select(['disk', 'path'])->orderBy('id')
            ->chunk(500, fn ($c) => PhotoTaskItem::insert($c->map(fn ($f) => ['photo_task_id' => $task->id, 'disk' => $f->disk, 'path' => $f->path,
                'status' => 'pending', 'created_at' => now(), 'updated_at' => now()])->all()));
        $task->update(['total' => $task->items()->count()]);
        static::kick();

        return $task;
    }

    /** Let the queue worker go on (if one runs; otherwise the scheduler or the page does it). */
    public static function kick(): void
    {
        rescue(fn () => RunPhotoTasks::dispatch(), null, false);
    }

    public static function active(): ?PhotoTask
    {
        return PhotoStore::ready() ? PhotoTask::whereIn('status', ['running', 'checking'])->orderBy('id')->first() : null;
    }

    /** Work for up to $seconds. Returns how many photos were done. */
    public static function work(int $seconds = 20): int
    {
        if (! PhotoStore::ready()) {
            return 0;
        }
        $lock = Cache::lock('photos.work', $seconds + 60);
        if (! $lock->get()) {
            return 0;
        }
        @ini_set('memory_limit', '512M');
        $until = microtime(true) + $seconds;
        $n = 0;
        try {
            while (microtime(true) < $until && ($task = static::active())) {
                $items = $task->items()->where('status', $task->status === 'checking' ? 'done' : 'pending')
                    ->when($task->status === 'checking', fn ($q) => $q->where('checked', false))->orderBy('id')->limit(25)->get();
                if ($items->isEmpty()) {
                    static::finish($task);

                    continue;
                }
                foreach ($items as $item) {
                    if (microtime(true) >= $until) {
                        break;
                    }
                    $task->status === 'checking' ? static::check($task, $item) : static::one($task, $item);
                    $n++;
                }
                static::count($task);
            }
        } finally {
            $lock->release();
        }

        return $n;
    }

    protected static function finish(PhotoTask $task): void
    {
        $task = $task->fresh();
        if ($task->kind === 'copy_old' && $task->status === 'checking' && $task->items()->where('status', 'pending')->exists()) {
            $task->update(['status' => 'running']); // missing in the bucket: copied again, then checked again

            return;
        }
        if ($task->kind === 'copy_old' && $task->status === 'running') {
            $task->update(['status' => 'checking']);

            return;
        }
        $task->update(['status' => 'done', 'finished_at' => $task->finished_at ?? now(), 'checked_at' => $task->status === 'checking' ? now() : $task->checked_at]);
        if ($task->kind === 'switch' && $task->opt('auto_off') && PhotoStore::countIn('tmp') === 0) {
            $b = PhotoStore::bucket('tmp');
            $b->exists && $b->update(['is_off' => true]);
        }
        PhotoStore::forgetMemo();
    }

    public static function count(PhotoTask $task): void
    {
        $by = $task->items()->selectRaw('status, count(*) as n, sum(coalesce(size_before, 0)) as b, sum(coalesce(size_after, 0)) as a')->groupBy('status')->get()->keyBy('status');
        $task->update([
            'done' => (int) ($by['done']->n ?? 0), 'skipped' => (int) ($by['skipped']->n ?? 0), 'failed' => (int) ($by['failed']->n ?? 0),
            'bytes_before' => (int) (($by['done']->b ?? 0) + ($by['skipped']->b ?? 0)), 'bytes_after' => (int) (($by['done']->a ?? 0) + ($by['skipped']->a ?? 0)),
        ]);
    }

    /** One photo of a move, a switch or a copy. */
    public static function one(PhotoTask $task, PhotoTaskItem $item): void
    {
        try {
            match ($task->kind) {
                'move', 'switch' => static::moveOne($task, $item),
                'copy_old' => OldSystem::copyOne($task, $item),
            };
        } catch (\Throwable $e) {
            $item->update(['status' => 'failed', 'note' => Str::limit(PhotoStore::why($e), 150, '')]);
            $task->update(['last_error' => Str::limit(PhotoStore::why($e), 250, '')]);
        }
    }

    protected static function moveOne(PhotoTask $task, PhotoTaskItem $item): void
    {
        $from = $task->from_place;
        $to = $task->to_place;
        $now = PhotoStore::placeOf($item->disk, $item->path);
        if ($now === $to) {
            $item->update(['status' => 'skipped', 'note' => 'Already there']);

            return;
        }
        $key = PhotoStore::key($item->disk, $item->path);
        $src = $from === 'server' ? PhotoStore::server($item->disk) : PhotoStore::fs($from);
        $srcKey = $from === 'server' ? $item->path : $key;
        if (! $src->exists($srcKey)) {
            $item->update(['status' => 'missing', 'note' => 'Not found']);

            return;
        }
        $bytes = (string) $src->get($srcKey);
        $dest = PhotoStore::fs($to);
        // put in the new folders (board 67): only photos of the server whose record is known
        $tidy = $from === 'server' && $task->opt('tidy') && $item->new_path && $item->tbl && $item->col;
        $path = $tidy ? $item->new_path : $item->path;
        $key = PhotoStore::key($item->disk, $path);
        $dest->put($key, $bytes);
        if ((int) $dest->size($key) !== strlen($bytes)) {
            throw new \RuntimeException('The copy in the bucket has a different size.');
        }
        PhotoStore::record($item->disk, $path, $to, strlen($bytes));
        if ($tidy) {
            PhotoFolders::rewrite($item->tbl, $item->col, $item->path, $path);
            PhotoStore::forget($item->disk, $item->path);
        }
        $src->delete($srcKey);
        $item->update(['status' => 'done', 'size_before' => strlen($bytes), 'size_after' => strlen($bytes), 'new_path' => $tidy ? $path : null]);
    }

    /** Check: the photo is in the bucket. A missing one is copied again. */
    protected static function check(PhotoTask $task, PhotoTaskItem $item): void
    {
        $key = $item->new_path ?: $item->path;
        $ok = $task->to_place && rescue(fn () => PhotoStore::fs($task->to_place)->exists($key), false, false);
        $item->update($ok ? ['checked' => true] : ['status' => 'pending', 'checked' => false, 'note' => 'Missing in the bucket: copied again']);
    }

    /** Make a photo at most $max bytes: 1600 px, JPEG quality 80 down to 60. Signatures (PNG) and other files stay. */
    public static function smaller(string $bytes, string $path, int $max = 200 * 1024): string
    {
        $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
        if (strlen($bytes) <= $max || ! PhotoShrinker::available() || ! in_array($ext, ['jpg', 'jpeg', 'webp'], true)) {
            return $bytes;
        }
        $info = @getimagesizefromstring($bytes);
        if (! $info) {
            return $bytes;
        }
        $src = @imagecreatefromstring($bytes);
        if (! $src) {
            return $bytes;
        }
        $src = PhotoShrinker::upright($src, PhotoShrinker::orientation($bytes));
        $w = imagesx($src);
        $h = imagesy($src);
        $out = $bytes;
        // 1600 px with quality 80 down to 60; still too big (a very busy photo): 1280 px, then 1024 px
        foreach ([PhotoShrinker::MAX_SIDE, 1280, 1024] as $side) {
            $scale = min(1, $side / max($w, $h));
            $img = imagecreatetruecolor(max(1, (int) round($w * $scale)), max(1, (int) round($h * $scale)));
            imagecopyresampled($img, $src, 0, 0, 0, 0, imagesx($img), imagesy($img), $w, $h);
            foreach ([80, 75, 70, 65, 60] as $q) {
                ob_start();
                $ext === 'webp' && function_exists('imagewebp') ? imagewebp($img, null, $q) : imagejpeg($img, null, $q);
                $out = (string) ob_get_clean();
                if (strlen($out) <= $max) {
                    break 2;
                }
            }
            imagedestroy($img);
            $img = null;
            if ($scale < 1 && $side === 1024) {
                break;
            }
        }
        $img && imagedestroy($img);
        imagedestroy($src);

        return $out !== '' && strlen($out) < strlen($bytes) ? $out : $bytes;
    }
}
