<?php

namespace App\Support\Photos\Storage;

use App\Models\AppSetting;
use App\Models\Photos\PhotoTask;
use App\Models\Photos\PhotoTaskItem;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Copy from the old system (wms.icargoxpress.net, the first version) to the bucket.
 * Same database as wmsv2: each photo path in the database keeps the same path in the bucket,
 * so it opens in wmsv2 right after. Another database: the files are copied under wms-v1/.
 * Nothing on the old site is ever changed or deleted from here.
 */
class OldSystem
{
    public const IMAGES = ['jpg', 'jpeg', 'png', 'webp', 'gif'];

    /** Tables that never hold photos people took. */
    protected const NOT = ['migrations', 'jobs', 'job_batches', 'failed_jobs', 'cache', 'cache_locks', 'sessions', 'password_reset_tokens',
        'photo_files', 'photo_tasks', 'photo_task_items', 'storage_buckets', 'app_settings', 'box_photos', 'help_guides', 'notifications', 'activity_log', 'telescope_entries'];

    public static function folder(): ?string
    {
        $set = AppSetting::get('photos.old_folder');
        if ($set) {
            return rtrim((string) $set, '/');
        }
        $guess = dirname(base_path()).'/wms.icargoxpress.net';

        return is_dir($guess) ? $guess : null;
    }

    public static function env(string $dir): array
    {
        $out = [];
        foreach (@file($dir.'/.env', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            if (preg_match('/^\s*([A-Z_]+)\s*=\s*(.*)$/', $line, $m) && in_array($m[1], ['APP_URL', 'DB_CONNECTION', 'DB_HOST', 'DB_PORT', 'DB_DATABASE'], true)) {
                $out[$m[1]] = trim($m[2], " \t\"'");
            }
        }

        return $out;
    }

    /** What the Find step shows. */
    public static function find(): array
    {
        $dir = static::folder();
        if (! $dir || ! is_dir($dir)) {
            return ['found' => false, 'dir' => $dir];
        }
        $env = static::env($dir);
        $c = config('database.connections.'.config('database.default'));
        $host = fn ($h) => in_array($h, ['localhost', '127.0.0.1', '::1', null, ''], true) ? 'local' : $h;
        $same = filled($env['DB_DATABASE'] ?? null) && ($env['DB_DATABASE'] ?? null) === ($c['database'] ?? null)
            && $host($env['DB_HOST'] ?? null) === $host($c['host'] ?? null);

        return [
            'found' => true, 'dir' => $dir, 'laravel' => is_file($dir.'/artisan'), 'same' => $same,
            'url' => rtrim($env['APP_URL'] ?? 'https://'.basename($dir), '/'),
            'storage' => is_dir($dir.'/storage/app/public') ? $dir.'/storage/app/public' : null,
            'uploads' => is_dir($dir.'/public/uploads') ? $dir.'/public/uploads' : null,
        ];
    }

    /** Columns in the database that hold photo paths (text ending in .jpg, .png …). */
    public static function columns(): Collection
    {
        $like = fn ($q, $col) => $q->where(function ($w) use ($col) {
            foreach (static::IMAGES as $e) {
                $w->orWhere($col, 'like', '%.'.$e.'%');
            }
        });
        $out = collect();
        foreach (Schema::getTables() as $t) {
            $table = $t['name'];
            if (in_array($table, static::NOT, true) || str_starts_with($table, 'sqlite_')) {
                continue;
            }
            foreach (Schema::getColumns($table) as $col) {
                if (! preg_match('/char|text|json|string/i', (string) ($col['type_name'] ?? $col['type'] ?? ''))) {
                    continue;
                }
                $name = $col['name'];
                $n = rescue(fn () => $like(DB::table($table), $name)->count(), 0, false);
                if ($n > 0) {
                    $ex = (string) $like(DB::table($table), $name)->value($name);
                    $out->push(['table' => $table, 'column' => $name, 'n' => $n, 'example' => Str::limit(static::paths($ex)[0] ?? $ex, 80)]);
                }
            }
        }

        return $out->sortByDesc('n')->values();
    }

    /** One value can hold several paths (a JSON list) or a full link. */
    public static function paths(?string $value): array
    {
        $value = trim((string) $value);
        if ($value === '') {
            return [];
        }
        $list = str_starts_with($value, '[') ? (json_decode($value, true) ?: []) : [$value];

        return collect($list)->flatten()->filter(fn ($p) => is_string($p) && in_array(strtolower(pathinfo(parse_url($p, PHP_URL_PATH) ?: $p, PATHINFO_EXTENSION)), static::IMAGES, true))
            ->map(function ($p) {
                $p = parse_url($p, PHP_URL_PATH) ?: $p;
                $p = ltrim($p, '/');

                return str_starts_with($p, 'storage/') ? substr($p, 8) : $p;
            })->unique()->values()->all();
    }

    /** Folders with photos in the old and new site: [path => [old => [n, bytes], new => [n, bytes]]]. */
    public static function folders(array $find): array
    {
        $out = [];
        $walk = function (?string $root, string $label, string $side) use (&$out) {
            if (! $root || ! is_dir($root)) {
                return;
            }
            $it = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($root, \FilesystemIterator::SKIP_DOTS));
            foreach ($it as $f) {
                if (! $f->isFile() || ! in_array(strtolower($f->getExtension()), static::IMAGES, true)) {
                    continue;
                }
                $rel = ltrim(substr($f->getPath(), strlen($root)), '/');
                $parts = array_slice(explode('/', $rel), 0, 2);
                $key = $label.($parts[0] !== '' ? '/'.implode('/', $parts) : '');
                $out[$key][$side][0] = ($out[$key][$side][0] ?? 0) + 1;
                $out[$key][$side][1] = ($out[$key][$side][1] ?? 0) + $f->getSize();
            }
        };
        $walk(storage_path('app/public'), 'storage/app/public', 'new');
        $walk($find['storage'] ?? null, 'storage/app/public', 'old');
        $walk($find['uploads'] ?? null, 'public/uploads', 'old');
        ksort($out);

        return $out;
    }

    /** The copy task (one at a time; Scan again refreshes it and keeps what was copied). */
    public static function task(): ?PhotoTask
    {
        return PhotoStore::ready() ? PhotoTask::where('kind', 'copy_old')->latest('id')->first() : null;
    }

    /** Scan: every photo path, where its file really is. */
    public static function scan(): PhotoTask
    {
        @set_time_limit(600);
        $find = static::find();
        $task = static::task() ?? PhotoTask::create(['kind' => 'copy_old', 'status' => 'ready', 'user_id' => Auth::id(), 'options' => ['small' => true, 'keep' => false]]);
        $known = $task->items()->get(['id', 'path', 'status', 'size_before', 'src_time', 'other'])->keyBy('path');
        $seen = [];
        $add = function (string $path, ?string $ref, ?string $src, ?string $other, string $found, array $tidy = []) use ($task, $known, &$seen) {
            if (isset($seen[$path])) {
                return;
            }
            $seen[$path] = true;
            $size = $src && is_file($src) ? filesize($src) : null;
            $time = $src && is_file($src) ? filemtime($src) : null;
            $old = $known[$path] ?? null;
            $data = ['source' => $src, 'other' => $other, 'found' => $found, 'ref' => $ref ? Str::limit($ref, 118, '') : null, 'size_before' => $size, 'src_time' => $time];
            if (! $old || $old->status !== 'done') {
                $data += ['new_path' => $tidy[0] ?? null, 'tbl' => $tidy[1] ?? null, 'col' => $tidy[2] ?? null];
            }
            if ($old) {
                // copied before and the file did not change: stays done; changed: copied again
                $changed = $old->status === 'done' && ($old->size_before !== $size || $old->src_time !== $time);
                $old->update($data + ($found === 'missing' ? ['status' => 'missing'] : ($changed || $old->status === 'missing' ? ['status' => 'pending', 'checked' => false] : [])));
            } else {
                PhotoTaskItem::create($data + ['photo_task_id' => $task->id, 'disk' => 'public', 'path' => $path, 'status' => $found === 'missing' ? 'missing' : 'pending']);
            }
        };

        if (($find['same'] ?? false) || ! ($find['found'] ?? false)) {
            foreach (static::columns() as $c) {
                $hasId = Schema::hasColumn($c['table'], 'id');
                $isKnown = isset(PhotoFolders::known()[$c['table'].'.'.$c['column']]);
                $q = DB::table($c['table'])->whereNotNull($c['column'])->select($isKnown ? ['*'] : array_filter([$hasId ? 'id' : null, $c['column']]));
                $hasId ? $q->orderBy('id') : $q->orderBy($c['column']);
                foreach ($q->cursor() as $row) {
                    foreach (static::paths($row->{$c['column']}) as $p) {
                        $new = storage_path('app/public/'.$p);
                        $olds = array_filter([($find['storage'] ?? null) ? $find['storage'].'/'.$p : null, ($find['found'] ?? false) ? $find['dir'].'/public/'.$p : null]);
                        $old = collect($olds)->first(fn ($f) => is_file($f));
                        $hasNew = is_file($new);
                        $ref = $c['table'].'.'.$c['column'].(isset($row->id) ? ' #'.$row->id : '');
                        $np = $isKnown ? PhotoFolders::newPath($c['table'], $c['column'], $row, $p) : null;
                        $tidy = $np ? [$np, $c['table'], $c['column']] : [];
                        if (PhotoStore::placeOf('public', $p) !== 'server') {
                            // already in a bucket (copied before, or moved): nothing to do
                            if (! isset($known[$p]) && ! isset($seen[$p])) {
                                PhotoTaskItem::create(['photo_task_id' => $task->id, 'disk' => 'public', 'path' => $p, 'found' => 'wmsv2', 'ref' => Str::limit($ref, 118, ''),
                                    'status' => 'skipped', 'note' => 'Already in the bucket']);
                            }
                            $seen[$p] = true;

                            continue;
                        }
                        match (true) {
                            $hasNew && $old && filesize($new) !== filesize($old) => $add($p, $ref, filemtime($new) >= filemtime($old) ? $new : $old, filemtime($new) >= filemtime($old) ? $old : $new, 'both', $tidy),
                            $hasNew => $add($p, $ref, $new, null, 'wmsv2', $tidy),
                            (bool) $old => $add($p, $ref, $old, null, 'wms', $tidy),
                            default => $add($p, $ref, null, null, 'missing'),
                        };
                    }
                }
            }
        } else {
            // another database: every picture file of the old site, under wms-v1/
            foreach (['storage' => $find['storage'] ?? null, 'public/uploads' => $find['uploads'] ?? null] as $label => $root) {
                if (! $root) {
                    continue;
                }
                $it = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($root, \FilesystemIterator::SKIP_DOTS));
                foreach ($it as $f) {
                    if ($f->isFile() && in_array(strtolower($f->getExtension()), static::IMAGES, true)) {
                        $add('wms-v1/'.$label.'/'.ltrim(substr($f->getPathname(), strlen($root)), '/'), null, $f->getPathname(), null, 'wms');
                    }
                }
            }
        }
        $task->items()->whereNotIn('path', array_keys($seen))->where('status', '!=', 'done')->delete();
        $task->update(['total' => $task->items()->where('status', '!=', 'missing')->count()]);
        $task->forceFill(['options' => array_merge($task->options, ['scanned_at' => now()->toDateTimeString(), 'same' => (bool) ($find['same'] ?? false)])])->save();
        PhotoWork::count($task);

        return $task->fresh();
    }

    /** Copy one photo: made smaller if asked, the original kept if asked, then checked by size. */
    public static function copyOne(PhotoTask $task, PhotoTaskItem $item): void
    {
        $to = PhotoStore::target() !== 'server' ? PhotoStore::target() : 'tmp';
        if (! PhotoStore::usable($to)) {
            throw new \RuntimeException('The bucket is not ready: put it and press Test connection.');
        }
        if ($task->to_place !== $to) {
            $task->update(['to_place' => $to]);
        }
        $fs = PhotoStore::fs($to);
        $disk = str_starts_with($item->path, 'wms-v1/') ? 'old' : 'public';
        // put in the new folders (board 67): the path in the database is changed after the copy is checked
        $tidy = $task->opt('tidy', true) && $item->new_path && $item->tbl && $item->col && $disk === 'public';
        $key = $tidy ? $item->new_path : $item->path;
        if (! $task->opt('again') && PhotoStore::placeOf('public', $key) === $to && $disk === 'public') {
            $item->update(['status' => 'skipped', 'note' => 'Already in the bucket']);

            return;
        }
        if (! $item->source || ! is_file($item->source)) {
            $item->update(['status' => 'missing', 'note' => 'The file is gone']);

            return;
        }
        $bytes = (string) file_get_contents($item->source);
        $out = $task->opt('small', true) ? PhotoWork::smaller($bytes, $item->path) : $bytes;
        if ($task->opt('keep') && strlen($out) !== strlen($bytes)) {
            $fs->put('_original/'.$key, $bytes);
        }
        $fs->put($key, $out);
        if ((int) $fs->size($key) !== strlen($out)) {
            throw new \RuntimeException('The copy in the bucket has a different size.');
        }
        if ($item->found === 'both' && $item->other && is_file($item->other)) {
            $fs->put('_other/'.$key, (string) file_get_contents($item->other));
        }
        PhotoStore::record($disk, $key, $to, strlen($out));
        if ($tidy) {
            PhotoFolders::rewrite($item->tbl, $item->col, $item->path, $key);
        }
        $item->update(['status' => 'done', 'size_after' => strlen($out), 'size_before' => strlen($bytes), 'checked' => false, 'new_path' => $tidy ? $key : null]);
    }

    /** Try 50: copy 50 photos now, to look at them before copying all. */
    public static function tryFifty(PhotoTask $task): Collection
    {
        @set_time_limit(300);
        $items = $task->items()->where('status', 'pending')->orderByDesc('size_before')->limit(50)->get();
        foreach ($items as $i) {
            PhotoWork::one($task, $i);
            $i->update(['tried' => true]);
        }
        PhotoWork::count($task);

        return $items->map->fresh();
    }

    /** Pick which of the two files (both sites had one) is the photo; the other is kept under _other/. */
    public static function pick(PhotoTaskItem $item): void
    {
        if ($item->found !== 'both' || ! $item->other) {
            return;
        }
        $item->update(['source' => $item->other, 'other' => $item->source, 'status' => 'pending', 'checked' => false]);
    }

    /** Old link (as before) for a path. */
    public static function oldLink(PhotoTaskItem $item, array $find): ?string
    {
        if (! $item->source) {
            return null;
        }
        if (str_starts_with($item->source, storage_path('app/public'))) {
            return url('/storage/'.$item->path);
        }
        $dir = $find['dir'] ?? '';
        $rel = ltrim(substr($item->source, strlen($dir)), '/');

        return ($find['url'] ?? '').'/'.(str_starts_with($rel, 'storage/app/public/') ? 'storage/'.substr($rel, 19) : preg_replace('#^public/#', '', $rel));
    }
}
