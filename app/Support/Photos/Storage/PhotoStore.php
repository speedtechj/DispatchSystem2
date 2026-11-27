<?php

namespace App\Support\Photos\Storage;

use App\Models\AppSetting;
use App\Models\Photos\PhotoFile;
use App\Models\Photos\StorageBucket;
use Illuminate\Contracts\Filesystem\Filesystem;
use Illuminate\Filesystem\FilesystemAdapter;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Settings → Photo storage. Every photo of every app (scan app, driver app, panels) is saved
 * where "New photos go to" points: this server, the Temporary bucket or the Real bucket.
 * Each photo that is not on the server has a row in photo_files saying where it is, so old
 * photos keep opening after a switch. Links to bucket photos are made when a page shows them
 * (temporary links, the buckets stay private).
 */
class PhotoStore
{
    public const PLACES = ['server' => 'This server', 'tmp' => 'Temporary bucket', 'real' => 'Real bucket'];

    public const PROVIDERS = ['r2' => 'Cloudflare R2', 's3' => 'Amazon S3', 'other' => 'Other S3-compatible'];

    /** Folders on the public disk that always stay on the server (logos and icons used in PDFs and the app). */
    public const SKIP = ['livewire-tmp', 'filament-exports', 'filament-imports', 'exports', 'imports', 'brand', 'favicon', 'logo',
        'consolidatorlogo', 'help', 'icons', 'pwa', 'invoiceissue-attachments', 'email-attachments'];

    /** Tests: buckets are folders on the disk instead of R2. */
    public static bool $fake = false;

    protected static array $memo = [];

    protected static ?int $memoApp = null;

    protected static function memo(): array
    {
        if (static::$memoApp !== spl_object_id(app())) {
            static::$memoApp = spl_object_id(app());
            static::$memo = [];
        }

        return static::$memo;
    }

    public static function forgetMemo(): void
    {
        static::$memo = [];
        Cache::forget('photo_files.any');
    }

    public static function ready(): bool
    {
        static::memo();

        return static::$memo['ready'] ??= Schema::hasTable('photo_files') && Schema::hasTable('storage_buckets');
    }

    /** The S3 driver (composer require league/flysystem-aws-s3-v3). */
    public static function driverReady(): bool
    {
        return static::$fake || class_exists(\League\Flysystem\AwsS3V3\AwsS3V3Adapter::class);
    }

    public static function target(): string
    {
        $t = (string) AppSetting::get('photos.target', 'server');

        return isset(static::PLACES[$t]) ? $t : 'server';
    }

    public static function setTarget(string $place): void
    {
        AppSetting::put('photos.target', $place);
    }

    public static function bucket(string $slot): StorageBucket
    {
        static::memo();
        if (! static::ready()) {
            return new StorageBucket(['slot' => $slot, 'provider' => 'r2']);
        }

        return static::$memo['bucket'][$slot] ??= StorageBucket::firstOrNew(['slot' => $slot], ['provider' => 'r2']);
    }

    /** A bucket new photos can go to: set, tested, not turned off, and the driver is there. */
    public static function usable(string $slot): bool
    {
        if ($slot === 'server') {
            return true;
        }
        $b = static::bucket($slot);

        return static::driverReady() && $b->exists && $b->isSet() && $b->test_ok && ! $b->is_off;
    }

    /** A bucket photos can be read from (turned off still reads, so nothing breaks). */
    public static function readable(string $slot): bool
    {
        $b = static::bucket($slot);

        return static::driverReady() && $b->exists && $b->isSet();
    }

    public static function config(StorageBucket $b): array
    {
        if (static::$fake) {
            return ['driver' => 'local', 'root' => storage_path('framework/testing/buckets/'.$b->slot.'-'.($b->bucket ?: 'x')), 'throw' => true];
        }

        return array_filter([
            'driver' => 's3',
            'key' => trim((string) $b->access_key),
            'secret' => trim((string) $b->secret),
            'region' => $b->provider === 'r2' ? 'auto' : (trim((string) $b->region) ?: 'us-east-1'),
            'bucket' => trim((string) $b->bucket),
            'endpoint' => $b->endpointUrl(),
            'use_path_style_endpoint' => $b->provider !== 's3',
            'visibility' => 'private',
            'throw' => true,
            // R2 and other S3-compatible stores: only the checksums they need.
            'request_checksum_calculation' => 'when_required',
            'response_checksum_validation' => 'when_required',
        ], fn ($v) => $v !== null && $v !== '');
    }

    /** The bucket as a Laravel disk. */
    public static function fs(string $slot): FilesystemAdapter
    {
        static::memo();
        $b = static::bucket($slot);
        $key = $slot.':'.($b->updated_at?->timestamp ?? 0);

        return static::$memo['fs'][$key] ??= Storage::build(static::config($b));
    }

    /** The disk on this server behind a routed disk (public or box). */
    public static function server(string $disk): Filesystem
    {
        static::memo();

        return static::$memo['server'][$disk] ??= Storage::build(config('filesystems.disks.'.$disk.'.inner') + ['throw' => true]);
    }

    /** The key in the bucket: the same path (old box photos, box-photos/…, under private/). */
    public static function key(string $disk, string $path): string
    {
        $path = ltrim($path, '/');

        return ($disk === 'box' && str_starts_with($path, 'box-photos/') ? 'private/' : '').$path;
    }

    public static function skip(string $disk, string $path): bool
    {
        return $disk === 'public' && in_array(explode('/', ltrim($path, '/'))[0], static::SKIP, true);
    }

    /** Any photo off the server at all? (Before anything moved, nothing is looked up.) */
    public static function any(): bool
    {
        static::memo();

        return static::$memo['any'] ??= static::ready() && Cache::rememberForever('photo_files.any', fn () => PhotoFile::query()->exists());
    }

    public static function placeOf(string $disk, string $path): string
    {
        if (! static::any()) {
            return 'server';
        }
        static::memo();
        $k = $disk.'|'.$path;
        if (! array_key_exists($k, static::$memo['place'] ?? [])) {
            if (count(static::$memo['place'] ?? []) > 5000) {
                static::$memo['place'] = [];
            }
            static::$memo['place'][$k] = PhotoFile::where('disk', $disk)->where('path', $path)->value('place') ?? 'server';
        }
        $place = static::$memo['place'][$k];

        return $place === 'server' || ! static::readable($place) ? 'server' : $place;
    }

    /**
     * Part 46: look up where many photos are with one query (a page of photos asked one by one was slow).
     * Also keeps their size, so nobody asks the bucket for it.
     */
    public static function preload(string $disk, array $paths): void
    {
        $paths = array_values(array_unique(array_filter($paths)));
        if ($paths === [] || ! static::any()) {
            return;
        }
        static::memo();
        foreach (array_chunk($paths, 500) as $chunk) {
            $rows = PhotoFile::where('disk', $disk)->whereIn('path', $chunk)->get(['path', 'place', 'size'])->keyBy('path');
            foreach ($chunk as $path) {
                static::$memo['place'][$disk.'|'.$path] = $rows[$path]->place ?? 'server';
                static::$memo['size'][$disk.'|'.$path] = $rows[$path]->size ?? null;
            }
        }
    }

    /** The size kept in photo_files (null when not known). */
    public static function knownSize(string $disk, string $path): ?int
    {
        static::memo();
        if (! array_key_exists($disk.'|'.$path, static::$memo['size'] ?? [])) {
            static::preload($disk, [$path]);
        }
        $v = static::$memo['size'][$disk.'|'.$path] ?? null;

        return $v === null ? null : (int) $v;
    }

    /** Where a new photo goes. */
    public static function targetFor(string $disk, string $path): string
    {
        if (! static::ready() || static::skip($disk, $path)) {
            return 'server';
        }
        $t = static::target();

        return $t !== 'server' && static::usable($t) ? $t : 'server';
    }

    public static function record(string $disk, string $path, string $place, ?int $size = null, ?string $note = null): void
    {
        if (! static::ready()) {
            return;
        }
        static::memo();
        if ($place === 'server' && ! $note) {
            PhotoFile::where('disk', $disk)->where('path', $path)->delete();
        } else {
            PhotoFile::updateOrCreate(['disk' => $disk, 'path' => $path], ['place' => $place, 'size' => $size, 'note' => $note ? Str::limit($note, 150, '') : null]);
            if (! (static::$memo['any'] ?? false)) {
                Cache::forever('photo_files.any', true);
                static::$memo['any'] = true;
            }
        }
        static::$memo['place'][$disk.'|'.$path] = $place;
    }

    public static function forget(string $disk, string $path): void
    {
        if (static::any()) {
            PhotoFile::where('disk', $disk)->where('path', $path)->delete();
            static::$memo['place'][$disk.'|'.$path] = 'server';
        }
    }

    /** A link for a bucket photo: valid for some hours, made again each time a page shows it. */
    public static function link(string $slot, string $key, int $hours = 6): string
    {
        $fs = static::fs($slot);
        if (static::$fake) {
            return url('/photo-storage/fake/'.$slot.'/'.$key);
        }

        return $fs->temporaryUrl($key, now()->addHours($hours));
    }

    /** Upload, read back and delete a small file. */
    public static function test(string $slot): array
    {
        $b = static::bucket($slot);
        if (! static::driverReady()) {
            return [false, 'The S3 driver is not installed yet. On the server run: composer require league/flysystem-aws-s3-v3'];
        }
        if (! $b->isSet()) {
            return [false, 'Put the bucket details first.'];
        }
        static::$memo['fs'] = [];
        $key = 'wmsv2-test/'.Str::uuid().'.txt';
        $body = 'Photo storage test '.now()->toIso8601String();
        try {
            $fs = static::fs($slot);
            $fs->put($key, $body);
            $back = $fs->get($key);
            $fs->delete($key);
            $ok = $back === $body;
            $msg = $ok ? 'Uploaded, read and deleted a test file.' : 'The test file came back different.';
        } catch (\Throwable $e) {
            $ok = false;
            $msg = static::why($e);
        }
        $b->forceFill(['test_ok' => $ok, 'test_message' => Str::limit($msg, 250, ''), 'tested_at' => now()])->save();
        static::$memo['bucket'] = [];

        return [$ok, $msg];
    }

    /** A clear reason from an S3 error. */
    public static function why(\Throwable $e): string
    {
        $all = $e->getMessage().' '.($e->getPrevious()?->getMessage() ?? '');

        return match (true) {
            str_contains($all, 'InvalidAccessKeyId') => 'The Access key ID is wrong.',
            str_contains($all, 'SignatureDoesNotMatch') => 'The Secret access key is wrong.',
            str_contains($all, 'NoSuchBucket') => 'There is no bucket with this name.',
            str_contains($all, 'AccessDenied') || str_contains($all, '403') => 'Access denied: the API token needs Object Read & Write on this bucket.',
            str_contains($all, 'Could not resolve host') || str_contains($all, 'cURL error 6') => 'The Account ID or endpoint is wrong (the address cannot be found).',
            str_contains($all, 'timed out') || str_contains($all, 'cURL error 28') => 'No answer from the bucket (timed out). Try again.',
            default => 'Could not connect: '.Str::limit(trim(preg_replace('/\s+/', ' ', $all)), 160),
        };
    }

    /** Last 7 days: photos saved to a bucket, photos that stayed on the server because the bucket did not answer. */
    public static function stats(): array
    {
        if (! static::ready()) {
            return ['bucket' => 0, 'server' => 0];
        }
        $q = PhotoFile::where('created_at', '>=', now()->subDays(7));

        return ['bucket' => (clone $q)->whereIn('place', ['tmp', 'real'])->count(), 'server' => (clone $q)->where('place', 'server')->whereNotNull('note')->count()];
    }

    public static function countIn(string $place): int
    {
        return static::ready() ? PhotoFile::where('place', $place)->where('disk', '!=', 'old')->count() : 0;
    }

    public static function queueSeen(): ?int
    {
        return Cache::get('photos.queue.seen');
    }

    public static function scheduleSeen(): ?int
    {
        return Cache::get('photos.schedule.seen');
    }

    public static function workerOn(): bool
    {
        return (static::queueSeen() ?? 0) > now()->subMinutes(5)->timestamp;
    }

    public static function schedulerOn(): bool
    {
        return (static::scheduleSeen() ?? 0) > now()->subMinutes(3)->timestamp;
    }
}
