<?php

namespace App\Console\Commands;

use App\Support\Photos\PhotoShrinker;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Storage;

/**
 * Make big photos smaller on the server (longest side 1600 px, JPEG 80%, the right way up).
 * Every 10 minutes it checks the photos saved in the last 15 minutes (the safety net for
 * uploads the phone could not make smaller). Run once with --all for the photos already saved.
 */
class PhotosShrink extends Command
{
    protected $signature = 'photos:shrink
        {--all : Every photo already saved, not only the new ones}
        {--minutes=15 : Photos saved in the last N minutes}
        {--dry : Only count, change nothing}';

    protected $description = 'Make big photos (over 600 KB or 1600 px) smaller, in place';

    /** Folders on the public disk that are not photos people took. */
    protected const SKIP = ['livewire-tmp', 'filament-exports', 'filament-imports', 'exports', 'imports'];

    public function handle(): int
    {
        if (! PhotoShrinker::available()) {
            $this->error('PHP GD is not installed on this server: photos cannot be made smaller.');

            return self::FAILURE;
        }
        @ini_set('memory_limit', '512M');

        $disk = Storage::disk('public');
        $since = $this->option('all') ? 0 : now()->subMinutes((int) $this->option('minutes'))->getTimestamp();
        $dry = (bool) $this->option('dry');
        $seen = $changed = $before = $after = 0;

        foreach ($disk->allFiles() as $path) {
            $top = explode('/', $path)[0];
            if (in_array($top, static::SKIP, true) || str_starts_with(basename($path), '.')) {
                continue;
            }
            if (! in_array(strtolower(pathinfo($path, PATHINFO_EXTENSION)), PhotoShrinker::EXTENSIONS, true)) {
                continue;
            }
            if ($since && $disk->lastModified($path) < $since) {
                continue;
            }
            $size = $disk->size($path);
            $seen++;
            if ($dry) {
                if ($size >= PhotoShrinker::MIN_BYTES) {
                    $changed++;
                    $before += $size;
                }

                continue;
            }
            $res = PhotoShrinker::file('public', $path);
            if ($res) {
                $changed++;
                $before += $res['before'];
                $after += $res['after'];
            }
        }

        $mb = fn (int $b) => number_format($b / 1048576, 1).' MB';
        $this->info($dry
            ? "{$seen} photos checked · {$changed} are big ({$mb($before)}). Run without --dry to make them smaller."
            : "{$seen} photos checked · {$changed} made smaller · {$mb($before)} → {$mb($after)}");

        return self::SUCCESS;
    }
}
