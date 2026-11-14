<?php

namespace App\Support;

use App\Models\AppSetting;
use App\Models\Logistichub;
use App\Models\User;
use App\Models\Warehouse;
use Milon\Barcode\DNS2D;

/**
 * Install QR codes for the phone apps. The link follows the app's own address (APP_URL),
 * unless Admin types another one in Settings → App icon & favicon. Codes are drawn fresh each time.
 */
class InstallLinks
{
    public const APPS = [
        'scan' => ['path' => '/scan', 'panel' => 'scan', 'title' => 'Scan app', 'for' => 'Unload containers, load trucks, transfers and returns with the phone camera.'],
        'driver' => ['path' => '/delivery', 'panel' => 'delivery', 'title' => 'Driver app', 'for' => "Today's boxes, deliver with photos, works without signal."],
    ];

    public static function base(): string
    {
        $custom = trim((string) AppSetting::get('install.base_url', ''));
        $base = $custom !== '' ? $custom : (string) config('app.url');
        if ($base === '' || $base === 'http://localhost') {
            $base = request()->getSchemeAndHttpHost();
        }

        return rtrim($base, '/');
    }

    public static function isCustom(): bool
    {
        return trim((string) AppSetting::get('install.base_url', '')) !== '';
    }

    public static function url(string $app): string
    {
        return static::base().(self::APPS[$app]['path'] ?? '/');
    }

    public static function name(string $app): string
    {
        return Pwa::name(self::APPS[$app]['panel'] ?? $app);
    }

    /** ok, or why phones can't use this address. */
    public static function problem(?string $base = null): ?string
    {
        $base ??= static::base();
        $host = (string) parse_url($base, PHP_URL_HOST);
        if ($host === '' || $host === 'localhost' || str_starts_with($host, '127.') || $host === '0.0.0.0' || str_ends_with($host, '.local')) {
            return 'This address only works on this computer. Phones can\'t open it. Use your online address (https://…).';
        }
        if (str_ends_with($host, '.test')) {
            return 'A .test address only works on this computer (Herd). Phones can\'t open it, and installing needs a real https address.';
        }
        if (preg_match('/^(10|192\.168|172\.(1[6-9]|2\d|3[01]))\./', $host)) {
            return 'This is a local network address: phones on the same Wi-Fi can open it, but installing the app needs https.';
        }
        if (parse_url($base, PHP_URL_SCHEME) !== 'https') {
            return 'Installing the app on a phone needs https. Use https://… for this address.';
        }

        return null;
    }

    public static function svg(string $app, int $px = 180): string
    {
        $text = static::url($app);
        $modules = static::modules($text);
        $scale = max(2, (int) floor($px / max(1, $modules)));
        $svg = (new DNS2D)->getBarcodeSVG($text, 'QRCODE,M', $scale, $scale, '#0b1620');
        // drop the XML header so it can sit inside a page
        $svg = preg_replace('/^.*?(<svg)/s', '$1', $svg);

        return preg_replace('/<desc>.*?<\/desc>/s', '', $svg);
    }

    public static function png(string $app, int $scale = 12): string
    {
        $dns = new DNS2D;
        $dns->setStorPath(storage_path('framework/cache/'));

        $raw = base64_decode($dns->getBarcodePNG(static::url($app), 'QRCODE,M', $scale, $scale, [11, 22, 32]));
        // add the white border phones need to read the code
        $src = @imagecreatefromstring($raw);
        if (! $src) {
            return $raw;
        }
        $pad = $scale * 4;
        $out = imagecreatetruecolor(imagesx($src) + 2 * $pad, imagesy($src) + 2 * $pad);
        imagefill($out, 0, 0, imagecolorallocate($out, 255, 255, 255));
        imagecopy($out, $src, $pad, $pad, 0, 0, imagesx($src), imagesy($src));
        ob_start();
        imagepng($out);

        return (string) ob_get_clean();
    }

    protected static function modules(string $text): int
    {
        $svg = (new DNS2D)->getBarcodeSVG($text, 'QRCODE,M', 1, 1);

        return preg_match('/width="([\d.]+)"/', $svg, $m) ? (int) round((float) $m[1]) : 25;
    }

    /** The name printed on posters: the warehouse or partner hub of the person printing, else the company. */
    public static function placeFor(?User $user): string
    {
        if ($user?->logistichub_id && ($hub = Logistichub::find($user->logistichub_id)) && $hub->is_company) {
            return (string) $hub->hub_name;
        }
        if ($user?->warehouse_id && ! $user->hasRole('super_admin') && ($wh = Warehouse::find($user->warehouse_id))) {
            return (string) $wh->name;
        }

        return Branding::companyName();
    }

    public static function rememberPrint(): void
    {
        AppSetting::put('install.printed_base', static::base());
    }

    /** True when posters were printed for another address than the one in use now. */
    public static function printedForOtherAddress(): bool
    {
        $printed = (string) AppSetting::get('install.printed_base', '');

        return $printed !== '' && $printed !== static::base();
    }

    public static function hiddenFor(?User $user): bool
    {
        return $user && (bool) AppSetting::get('install.hidden.'.$user->getKey(), false);
    }

    public static function hideFor(User $user, bool $hide = true): void
    {
        AppSetting::put('install.hidden.'.$user->getKey(), $hide ? '1' : null);
    }
}
