<?php

namespace App\Support\Pdf;

use Illuminate\Support\Facades\Cache;
use Symfony\Component\Process\Process;

/**
 * Finds the PDF program (wkhtmltopdf) on any computer or domain.
 *
 * Plesk keeps each domain in /var/www/vhosts/<domain>/ (open_basedir): PHP may not even look at a file
 * outside it, so a path from another computer's .env crashed the receipt. Here each place is tried
 * safely, in this order: WKHTML_PDF_BINARY in .env, <this domain>/bin, the project's bin folder,
 * the icargoxpress.net copy, then the usual system places. Places PHP may not look at are tried by
 * running "--version" instead. The answer is kept for a day.
 */
class WkBinary
{
    public static function find(): ?string
    {
        return Cache::remember('pdf.wk-binary.'.md5(base_path().'|'.env('WKHTML_PDF_BINARY').'|'.json_encode(config('snappy.pdf.search')).'|'.config('snappy.pdf.binary')), 86400, function (): ?string {
            foreach (static::candidates() as $path) {
                if (static::works($path)) {
                    return $path;
                }
            }

            return null;
        }) ?: null;
    }

    public static function forget(): void
    {
        Cache::forget('pdf.wk-binary.'.md5(base_path().'|'.env('WKHTML_PDF_BINARY').'|'.json_encode(config('snappy.pdf.search')).'|'.config('snappy.pdf.binary')));
    }

    /** @return list<string> */
    public static function candidates(): array
    {
        if (config('snappy.pdf.search') === false) {
            return array_values(array_filter([config('snappy.pdf.binary')], 'is_string')); // only the set path (tests)
        }
        $list = [env('WKHTML_PDF_BINARY'), config('snappy.pdf.binary')];
        if (preg_match('~^(/var/www/vhosts/[^/]+)~', base_path(), $m)) {
            $list[] = $m[1].'/bin/wkhtmltopdf'; // this domain
        }
        $list[] = base_path('bin/wkhtmltopdf');
        $list[] = dirname(base_path()).'/bin/wkhtmltopdf';
        $list[] = '/var/www/vhosts/icargoxpress.net/bin/wkhtmltopdf';
        array_push($list, '/usr/local/bin/wkhtmltopdf', '/usr/bin/wkhtmltopdf', '/opt/homebrew/bin/wkhtmltopdf', '/opt/wkhtmltopdf/bin/wkhtmltopdf');

        return array_values(array_unique(array_filter($list, fn ($p) => is_string($p) && $p !== '')));
    }

    /** May PHP look at this file (open_basedir)? */
    public static function allowed(string $path): bool
    {
        $base = (string) ini_get('open_basedir');
        if ($base === '') {
            return true;
        }
        foreach (explode(PATH_SEPARATOR, $base) as $dir) {
            $dir = rtrim($dir, '/');
            if ($dir !== '' && ($path === $dir || str_starts_with($path, $dir.'/'))) {
                return true;
            }
        }

        return false;
    }

    public static function works(string $path): bool
    {
        if (static::allowed($path)) {
            return @is_file($path) && @is_executable($path);
        }
        try {
            // outside open_basedir: PHP may still run it
            $p = new Process([$path, '--version']);
            $p->setTimeout(10);
            $p->run();

            return $p->isSuccessful() && str_contains(strtolower($p->getOutput().$p->getErrorOutput()), 'wkhtmltopdf');
        } catch (\Throwable) {
            return false;
        }
    }
}
