<?php

namespace App\Support;

use App\Models\BrandAsset;
use App\Models\Companyprofile;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Storage;
use Throwable;

/**
 * "Install as an app" (PWA): the Driver app (Delivery panel) and the Scan app (Scan panel).
 *
 * Its name and icon come from Company Info (Branding), so they follow the logo.
 * To make another panel installable later, add it to apps() and to the
 * render hooks in that panel's provider.
 */
class Pwa
{
    /** @return array<string, array<string, mixed>> */
    public static function apps(): array
    {
        return [
            'delivery' => [
                'label' => 'Driver', 'badge' => 'DRV', 'strip' => '#17895e', 'stripText' => '#ffffff',
                'scope' => '/delivery', 'start' => '/delivery',
                'shortcuts' => [
                    ['name' => 'Scan a box', 'url' => '/delivery?view=scan'],
                    ['name' => 'My deliveries', 'url' => '/delivery?view=list'],
                    ['name' => 'Today’s trip', 'url' => '/delivery'],
                ],
            ],
            'scan' => [
                'label' => 'Scan', 'badge' => 'SCN', 'strip' => '#f6be00', 'stripText' => '#0e2433',
                'scope' => '/scan', 'start' => '/scan',
                'shortcuts' => [
                    ['name' => 'Start scanning', 'url' => '/scan'],
                ],
            ],
        ];
    }

    public static function exists(string $panel): bool
    {
        return array_key_exists($panel, static::apps());
    }

    public static function app(string $panel): array
    {
        return static::apps()[$panel];
    }

    /** Name under the icon on the phone: set in Admin → App icon & favicon, else "Speedtech Driver". */
    public static function name(string $panel): string
    {
        return static::customLabel($panel) ?? static::shortCompany().' '.static::app($panel)['label'];
    }

    /** Short name (shown when space is tight): the custom name, else "Driver" / "Scan". */
    public static function shortName(string $panel): string
    {
        return static::customLabel($panel) ?? static::app($panel)['label'];
    }

    public static function customLabel(string $panel): ?string
    {
        $field = BrandAsset::LABEL_FIELDS[$panel] ?? null;
        $label = $field ? trim((string) BrandAsset::current()?->{$field}) : '';

        return $label !== '' ? $label : null;
    }

    /** First word of the company name, so the label fits under a home screen icon. */
    public static function shortCompany(): string
    {
        return strtok(Branding::companyName(), ' ') ?: 'Dispatch';
    }

    /** The Company Info record (looked up once per request), or null. */
    public static function profile(): ?Companyprofile
    {
        return once(function (): ?Companyprofile {
            try {
                return Schema::hasTable('companyprofiles') ? Companyprofile::query()->first() : null;
            } catch (Throwable) {
                return null;
            }
        });
    }

    /**
     * Browser tab icon, for every panel: the one uploaded in Admin → App icon & favicon,
     * else the Company Info favicon, else the built-in one.
     */
    public static function faviconUrl(): string
    {
        return BrandAsset::fileUrl(BrandAsset::current()?->favicon)
            ?? BrandAsset::fileUrl(static::profile()?->favicon ?? null)
            ?? asset(is_file(public_path('favicon.svg')) ? 'favicon.svg' : 'favicon.ico');
    }

    /** Version string for the favicon link, so browsers fetch a new upload straight away. */
    public static function faviconVersion(): string
    {
        $asset = BrandAsset::current();

        return substr(md5(static::faviconUrl().'|'.$asset?->updated_at), 0, 8);
    }

    /**
     * Changes when the app icon, logo or company name changes. It is part of the icon
     * links in the manifest, so Android sees a new icon and offers the update.
     */
    public static function version(): string
    {
        $profile = static::profile();
        $asset = BrandAsset::current();

        return substr(md5(Branding::companyName().'|'.json_encode($profile?->company_logo).'|'.$profile?->updated_at
            .'|'.$asset?->app_icon.'|'.$asset?->scan_icon.'|'.$asset?->driver_label.'|'.$asset?->scan_label), 0, 10);
    }

    public static function manifest(string $panel): array
    {
        $app = static::app($panel);
        $v = static::version();
        $icon = fn (int $size, string $purpose) => [
            'src' => url("/pwa/{$panel}/icon-{$size}.png?v={$v}".($purpose === 'maskable' ? '&maskable=1' : '')),
            'sizes' => "{$size}x{$size}",
            'type' => 'image/png',
            'purpose' => $purpose,
        ];

        return array_filter([
            'id' => '/'.$panel.'-app',
            'name' => static::name($panel),
            'short_name' => static::shortName($panel),
            'description' => Branding::companyName().' · '.$app['label'],
            'start_url' => $app['start'],
            'scope' => $app['scope'],
            'display' => 'standalone',
            'orientation' => 'portrait',
            'background_color' => '#0e2433',
            'theme_color' => '#0e2433',
            'icons' => [$icon(192, 'any'), $icon(512, 'any'), $icon(512, 'maskable')],
            'shortcuts' => collect($app['shortcuts'] ?? [])->map(fn (array $s) => [
                'name' => $s['name'],
                'url' => $s['url'],
                'icons' => [['src' => url("/pwa/{$panel}/icon-192.png?v={$v}"), 'sizes' => '192x192', 'type' => 'image/png']],
            ])->all(),
        ]);
    }

    /**
     * The PNG icon: navy tile, the company logo (or initials) in a yellow square,
     * and a coloured strip naming the panel. Cached on disk until the logo changes.
     */
    public static function iconPath(string $panel, int $size, bool $maskable = false): ?string
    {
        if (! function_exists('imagecreatetruecolor')) {
            return null; // PHP GD extension missing
        }

        $name = $panel.($maskable ? '-maskable' : '').'-'.$size;
        $path = storage_path("app/pwa/{$name}-".static::version().'.png');

        if (! is_file($path)) {
            @mkdir(dirname($path), 0775, true);
            foreach (glob(storage_path("app/pwa/{$name}-*.png")) ?: [] as $old) {
                @unlink($old);
            }
            imagepng(static::drawIcon($panel, $size, $maskable), $path);
        }

        return $path;
    }

    protected static function drawIcon(string $panel, int $size, bool $maskable = false): \GdImage
    {
        if ($uploaded = static::uploadedIcon($panel)) {
            return static::fitUploadedIcon($uploaded, $size, $maskable);
        }

        $app = static::app($panel);
        $img = imagecreatetruecolor($size, $size);
        imagesavealpha($img, true);
        $color = fn (string $hex) => imagecolorallocate($img, ...sscanf($hex, '#%02x%02x%02x'));

        imagefill($img, 0, 0, $color('#0e2433'));

        // Keep everything inside the middle 80% so Android's round "maskable" crop never cuts it.
        $safe = (int) round($size * 0.1);
        $stripH = (int) round($size * 0.2);
        $stripTop = $size - $safe - $stripH;
        imagefilledrectangle($img, 0, $stripTop, $size, $size, $color($app['strip']));

        $tile = (int) round($size * 0.46);
        $tileX = (int) (($size - $tile) / 2);
        $tileY = (int) max($safe, ($stripTop - $tile) / 2 + $safe / 2);
        static::roundedRect($img, $tileX, $tileY, $tile, $tile, (int) ($tile * 0.22), $color('#f6be00'));

        $font = static::font();
        $logo = static::logoImage();

        if ($logo) {
            $pad = (int) ($tile * 0.14);
            $box = $tile - 2 * $pad;
            $w = imagesx($logo);
            $h = imagesy($logo);
            $scale = min($box / $w, $box / $h);
            $dw = (int) ($w * $scale);
            $dh = (int) ($h * $scale);
            imagecopyresampled($img, $logo, $tileX + (int) (($tile - $dw) / 2), $tileY + (int) (($tile - $dh) / 2), 0, 0, $dw, $dh, $w, $h);
        } elseif ($font) {
            static::centredText($img, $font, Branding::initials() ?: 'D', (int) ($tile * 0.36), $tileX, $tileY, $tile, $tile, $color('#0e2433'));
        } else {
            // No logo and no font: a simple box mark.
            $m = (int) ($tile * 0.28);
            imagesetthickness($img, max(2, (int) ($tile * 0.07)));
            imagerectangle($img, $tileX + $m, $tileY + $m, $tileX + $tile - $m, $tileY + $tile - $m, $color('#0e2433'));
            imageline($img, $tileX + $m, $tileY + (int) ($tile / 2), $tileX + $tile - $m, $tileY + (int) ($tile / 2), $color('#0e2433'));
        }

        if ($font) {
            static::centredText($img, $font, $app['badge'], (int) ($stripH * 0.42), 0, $stripTop, $size, $stripH, $color($app['stripText']));
        }

        return $img;
    }

    /** The icon uploaded for this app in Admin → App icon & favicon, as a GD image, or null. */
    protected static function uploadedIcon(string $panel): ?\GdImage
    {
        $field = BrandAsset::ICON_FIELDS[$panel] ?? null;
        $path = $field ? BrandAsset::current()?->{$field} : null;

        if (blank($path) || ! Storage::disk('public')->exists($path)) {
            return null;
        }

        try {
            return @imagecreatefromstring(Storage::disk('public')->get($path)) ?: null;
        } catch (Throwable) {
            return null;
        }
    }

    /**
     * Square-crop the uploaded icon to $size. For Android's round "maskable" icon,
     * shrink it into the middle 80% on a navy background so nothing is cut off.
     */
    protected static function fitUploadedIcon(\GdImage $source, int $size, bool $maskable): \GdImage
    {
        $img = imagecreatetruecolor($size, $size);
        imagesavealpha($img, true);
        imagefill($img, 0, 0, $maskable
            ? imagecolorallocate($img, 0x0E, 0x24, 0x33)
            : imagecolorallocatealpha($img, 0, 0, 0, 127));

        $w = imagesx($source);
        $h = imagesy($source);
        $side = min($w, $h);
        $target = $maskable ? (int) round($size * 0.8) : $size;
        $offset = (int) (($size - $target) / 2);

        imagecopyresampled($img, $source, $offset, $offset, (int) (($w - $side) / 2), (int) (($h - $side) / 2), $target, $target, $side, $side);

        return $img;
    }

    protected static function roundedRect(\GdImage $img, int $x, int $y, int $w, int $h, int $r, int $color): void
    {
        imagefilledrectangle($img, $x + $r, $y, $x + $w - $r, $y + $h, $color);
        imagefilledrectangle($img, $x, $y + $r, $x + $w, $y + $h - $r, $color);
        foreach ([[$x + $r, $y + $r], [$x + $w - $r, $y + $r], [$x + $r, $y + $h - $r], [$x + $w - $r, $y + $h - $r]] as [$cx, $cy]) {
            imagefilledellipse($img, $cx, $cy, 2 * $r, 2 * $r, $color);
        }
    }

    protected static function centredText(\GdImage $img, string $font, string $text, int $pt, int $x, int $y, int $w, int $h, int $color): void
    {
        $box = imagettfbbox($pt, 0, $font, $text);
        $tw = $box[2] - $box[0];
        $th = $box[1] - $box[7];
        imagettftext($img, $pt, 0, $x + (int) (($w - $tw) / 2) - $box[0], $y + (int) (($h + $th) / 2) - $box[1], $color, $font, $text);
    }

    /** A bold TrueType font for the letters on the icon. To choose one, copy it to resources/fonts/icon.ttf. */
    protected static function font(): ?string
    {
        if (! function_exists('imagettftext')) {
            return null;
        }

        $candidates = array_filter([
            resource_path('fonts/icon.ttf'),
            '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
            '/Library/Fonts/Arial Bold.ttf',
            '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
            '/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf',
            '/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf',
            '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf',
            '/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf',
            'C:\\Windows\\Fonts\\arialbd.ttf',
        ]);

        foreach ($candidates as $font) {
            if (@is_file($font)) {
                return $font;
            }
        }

        return null;
    }

    /** The uploaded logo as a GD image (PNG, JPG, WebP or GIF), or null. */
    protected static function logoImage(): ?\GdImage
    {
        $logo = static::profile()?->company_logo;
        $path = is_array($logo) ? (array_values($logo)[0] ?? null) : $logo;

        if (blank($path) || ! Storage::disk('public')->exists($path)) {
            return null;
        }

        try {
            $image = @imagecreatefromstring(Storage::disk('public')->get($path));

            return $image ?: null; // SVG and other formats are not supported by GD
        } catch (Throwable) {
            return null;
        }
    }
}
