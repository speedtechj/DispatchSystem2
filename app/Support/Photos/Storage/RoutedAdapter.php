<?php

namespace App\Support\Photos\Storage;

use League\Flysystem\Config;
use League\Flysystem\FileAttributes;
use League\Flysystem\FilesystemAdapter as FlyAdapter;
use League\Flysystem\UnableToReadFile;
use League\Flysystem\UnableToRetrieveMetadata;
use League\Flysystem\UnableToWriteFile;

/**
 * The "public" and "box" disks: each file is on this server or in a bucket (Settings → Photo storage).
 * New files go where "New photos go to" points; reading looks up where the file is (photo_files).
 * When a bucket does not answer, the photo is saved on the server so nothing is lost.
 */
class RoutedAdapter implements FlyAdapter
{
    public function __construct(protected string $disk, protected array $config) {}

    protected function server()
    {
        return PhotoStore::server($this->disk);
    }

    /** [place, Laravel disk, key] for reading a file. */
    protected function at(string $path): array
    {
        $place = PhotoStore::placeOf($this->disk, $path);

        return $place === 'server' ? ['server', $this->server(), $path] : [$place, PhotoStore::fs($place), PhotoStore::key($this->disk, $path)];
    }

    public function fileExists(string $path): bool
    {
        [, $fs, $key] = $this->at($path);

        return $fs->exists($key);
    }

    public function directoryExists(string $path): bool
    {
        return $this->server()->directoryExists($path);
    }

    public function write(string $path, string $contents, Config $config): void
    {
        $this->save($path, $contents, $config);
    }

    public function writeStream(string $path, $contents, Config $config): void
    {
        $this->save($path, $contents, $config);
    }

    /** @param  string|resource  $contents */
    protected function save(string $path, $contents, Config $config): void
    {
        $place = PhotoStore::targetFor($this->disk, $path);
        $options = array_filter(['visibility' => $config->get('visibility')]);
        // new photos at most 200 KB (Settings → Photo storage), wherever they are saved
        $max = PhotoStore::ready() && ! PhotoStore::skip($this->disk, $path) ? PhotoFolders::maxKb() : 0;
        if ($max > 0 && in_array(strtolower(pathinfo($path, PATHINFO_EXTENSION)), ['jpg', 'jpeg', 'webp'], true)) {
            $contents = is_resource($contents) ? (string) stream_get_contents($contents) : $contents;
            $contents = PhotoWork::smaller($contents, $path, $max * 1024);
        }
        if ($place !== 'server') {
            $bytes = is_resource($contents) ? (string) stream_get_contents($contents) : $contents;
            try {
                PhotoStore::fs($place)->put(PhotoStore::key($this->disk, $path), $bytes);
                // a copy left on the server from before would be found by mistake later
                rescue(fn () => $this->server()->delete($path), null, false);
                PhotoStore::record($this->disk, $path, $place, strlen($bytes));

                return;
            } catch (\Throwable $e) {
                $this->server()->put($path, $bytes, $options) ?: throw UnableToWriteFile::atLocation($path, 'server');
                PhotoStore::record($this->disk, $path, 'server', strlen($bytes), 'Bucket did not answer: '.PhotoStore::why($e));
                report($e);

                return;
            }
        }
        $this->server()->put($path, $contents, $options) ?: throw UnableToWriteFile::atLocation($path, 'server');
        PhotoStore::forget($this->disk, $path);
    }

    public function read(string $path): string
    {
        [, $fs, $key] = $this->at($path);
        $out = $fs->get($key);

        return $out ?? throw UnableToReadFile::fromLocation($path);
    }

    public function readStream(string $path)
    {
        [, $fs, $key] = $this->at($path);

        return $fs->readStream($key) ?? throw UnableToReadFile::fromLocation($path);
    }

    public function delete(string $path): void
    {
        [$place, $fs, $key] = $this->at($path);
        $fs->delete($key);
        if ($place !== 'server') {
            PhotoStore::forget($this->disk, $path);
        }
    }

    public function deleteDirectory(string $path): void
    {
        $this->server()->deleteDirectory($path);
    }

    public function createDirectory(string $path, Config $config): void
    {
        $this->server()->makeDirectory($path);
    }

    public function setVisibility(string $path, string $visibility): void
    {
        if (PhotoStore::placeOf($this->disk, $path) === 'server') {
            $this->server()->setVisibility($path, $visibility);
        }
    }

    public function visibility(string $path): FileAttributes
    {
        [$place, $fs, $key] = $this->at($path);

        return new FileAttributes($path, null, $place === 'server' ? $fs->getVisibility($key) : 'private');
    }

    public function mimeType(string $path): FileAttributes
    {
        [, $fs, $key] = $this->at($path);
        $mime = $fs->mimeType($key) ?: throw UnableToRetrieveMetadata::mimeType($path);

        return new FileAttributes($path, null, null, null, $mime);
    }

    public function lastModified(string $path): FileAttributes
    {
        [, $fs, $key] = $this->at($path);

        return new FileAttributes($path, null, null, $fs->lastModified($key));
    }

    public function fileSize(string $path): FileAttributes
    {
        [, $fs, $key] = $this->at($path);

        return new FileAttributes($path, $fs->size($key));
    }

    /** Only the files on this server are listed (photos in a bucket are found through photo_files). */
    public function listContents(string $path, bool $deep): iterable
    {
        return $this->server()->getDriver()->listContents($path, $deep);
    }

    public function move(string $source, string $destination, Config $config): void
    {
        [$place, $fs, $key] = $this->at($source);
        if ($place === 'server') {
            $fs->move($key, $destination);

            return;
        }
        $fs->move($key, PhotoStore::key($this->disk, $destination));
        PhotoStore::forget($this->disk, $source);
        PhotoStore::record($this->disk, $destination, $place);
    }

    public function copy(string $source, string $destination, Config $config): void
    {
        [$place, $fs, $key] = $this->at($source);
        if ($place === 'server') {
            $fs->copy($key, $destination);

            return;
        }
        $fs->copy($key, PhotoStore::key($this->disk, $destination));
        PhotoStore::record($this->disk, $destination, $place);
    }

    /** Called by Storage::disk(...)->url(): the server link, or a temporary bucket link. */
    public function getUrl(string $path): string
    {
        $place = PhotoStore::placeOf($this->disk, $path);
        if ($place !== 'server') {
            return PhotoStore::link($place, PhotoStore::key($this->disk, $path));
        }
        $base = $this->config['url'] ?? null;

        return $base ? rtrim($base, '/').'/'.ltrim($path, '/') : url('/storage/'.ltrim($path, '/'));
    }

    public function getTemporaryUrl(string $path, $expiration, array $options = []): string
    {
        return $this->getUrl($path);
    }
}
