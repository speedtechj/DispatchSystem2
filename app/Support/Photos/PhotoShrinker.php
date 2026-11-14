<?php

namespace App\Support\Photos;

use Illuminate\Support\Facades\Storage;

/**
 * The server's safety net for photos: anything still big when it arrives (the phone could
 * not make it smaller) is made smaller here: longest side 1600 px, JPEG 80%, the right way
 * up. Without GD, or for a photo too big for the server's memory, the file is left as it is.
 */
class PhotoShrinker
{
    public const MAX_SIDE = 1600;

    /** Files smaller than this are left alone, unless they are larger than MAX_SIDE. */
    public const MIN_BYTES = 600 * 1024;

    public const QUALITY = 80;

    public const EXTENSIONS = ['jpg', 'jpeg', 'png', 'webp'];

    public static function available(): bool
    {
        return function_exists('imagecreatefromstring') && function_exists('imagejpeg');
    }

    /**
     * Make a stored photo smaller, in place (same path and format).
     *
     * @return array{before: int, after: int}|null null when nothing was changed
     */
    public static function file(string $disk, string $path): ?array
    {
        $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
        if (! static::available() || ! in_array($ext, static::EXTENSIONS, true)) {
            return null;
        }
        $store = Storage::disk($disk);
        if (! $store->exists($path)) {
            return null;
        }
        $bytes = (string) $store->get($path);
        $out = static::bytes($bytes, $ext);
        if ($out === null) {
            return null;
        }
        $store->put($path, $out);

        return ['before' => strlen($bytes), 'after' => strlen($out)];
    }

    /**
     * The smaller photo, or null when it is already small or cannot be read.
     * $format: jpg / jpeg / png / webp (the photo keeps its format so its name stays right).
     */
    public static function bytes(string $bytes, string $format = 'jpg'): ?string
    {
        if (! static::available()) {
            return null;
        }
        $info = @getimagesizefromstring($bytes);
        if (! $info) {
            return null;
        }
        [$w, $h] = $info;
        $big = max($w, $h) > static::MAX_SIDE;
        if (! $big && strlen($bytes) < static::MIN_BYTES) {
            return null;
        }
        if (! static::fitsInMemory($w, $h)) {
            return null;
        }

        $src = @imagecreatefromstring($bytes);
        if (! $src) {
            return null;
        }
        $src = static::upright($src, static::orientation($bytes));

        $w = imagesx($src);
        $h = imagesy($src);
        $scale = min(1, static::MAX_SIDE / max($w, $h));
        $nw = max(1, (int) round($w * $scale));
        $nh = max(1, (int) round($h * $scale));
        $img = imagecreatetruecolor($nw, $nh);
        $format = strtolower($format);
        if ($format === 'png' || $format === 'webp') {
            imagealphablending($img, false);
            imagesavealpha($img, true);
        }
        imagecopyresampled($img, $src, 0, 0, 0, 0, $nw, $nh, $w, $h);
        imagedestroy($src);

        ob_start();
        match ($format) {
            'png' => imagepng($img, null, 9),
            'webp' => function_exists('imagewebp') ? imagewebp($img, null, static::QUALITY) : imagepng($img, null, 9),
            default => imagejpeg($img, null, static::QUALITY),
        };
        imagedestroy($img);
        $out = (string) ob_get_clean();

        // Keep it when it had to fit MAX_SIDE, or is clearly smaller (a photo made smaller
        // before is not saved again and again, which would only lower its quality).
        return $out !== '' && ($big || strlen($out) < strlen($bytes) * 0.8) ? $out : null;
    }

    /** A decoded photo needs about 5 bytes a pixel; leave room for the rest of the request. */
    protected static function fitsInMemory(int $w, int $h): bool
    {
        $need = $w * $h * 5 + 16 * 1024 * 1024;
        $limit = static::memoryLimit();
        if ($limit < 0) {
            return true;
        }
        if ($limit - memory_get_usage() > $need) {
            return true;
        }
        // try to raise the limit for this request
        $want = memory_get_usage() + $need + 32 * 1024 * 1024;
        @ini_set('memory_limit', (string) $want);

        return static::memoryLimit() < 0 || static::memoryLimit() - memory_get_usage() > $need;
    }

    protected static function memoryLimit(): int
    {
        $v = trim((string) ini_get('memory_limit'));
        if ($v === '' || $v === '-1') {
            return -1;
        }
        $n = (int) $v;

        return match (strtolower(substr($v, -1))) {
            'g' => $n * 1024 ** 3,
            'm' => $n * 1024 ** 2,
            'k' => $n * 1024,
            default => $n,
        };
    }

    /** The EXIF orientation of a JPEG (1 = upright). Phones save photos sideways and set this. */
    public static function orientation(string $bytes): int
    {
        if (strncmp($bytes, "\xFF\xD8", 2) !== 0) {
            return 1;
        }
        if (function_exists('exif_read_data')) {
            $exif = @exif_read_data('data://image/jpeg;base64,'.base64_encode(substr($bytes, 0, 256 * 1024)));
            if (is_array($exif) && isset($exif['Orientation'])) {
                return (int) $exif['Orientation'];
            }
        }

        return static::orientationByHand($bytes);
    }

    /** Read the orientation tag straight from the JPEG (when the exif extension is missing). */
    protected static function orientationByHand(string $bytes): int
    {
        $len = min(strlen($bytes), 256 * 1024);
        $i = 2;
        while ($i + 4 < $len) {
            if (ord($bytes[$i]) !== 0xFF) {
                return 1;
            }
            $marker = ord($bytes[$i + 1]);
            $size = unpack('n', substr($bytes, $i + 2, 2))[1];
            if ($marker === 0xE1 && substr($bytes, $i + 4, 6) === "Exif\0\0") {
                $t = $i + 10; // TIFF header
                $le = substr($bytes, $t, 2) === 'II';
                $u16 = fn ($o) => unpack($le ? 'v' : 'n', substr($bytes, $o, 2))[1];
                $u32 = fn ($o) => unpack($le ? 'V' : 'N', substr($bytes, $o, 4))[1];
                $ifd = $t + $u32($t + 4);
                if ($ifd + 2 > $len) {
                    return 1;
                }
                $count = $u16($ifd);
                for ($k = 0; $k < $count; $k++) {
                    $e = $ifd + 2 + $k * 12;
                    if ($e + 12 > $len) {
                        break;
                    }
                    if ($u16($e) === 0x0112) {
                        $v = $u16($e + 8);

                        return $v >= 1 && $v <= 8 ? $v : 1;
                    }
                }

                return 1;
            }
            if ($marker === 0xDA) {
                return 1; // image data starts: no EXIF
            }
            $i += 2 + $size;
        }

        return 1;
    }

    /** Turn the picture the way the phone meant it. */
    public static function upright(\GdImage $img, int $orientation): \GdImage
    {
        $out = match ($orientation) {
            2 => static::flip($img, IMG_FLIP_HORIZONTAL),
            3 => imagerotate($img, 180, 0),
            4 => static::flip($img, IMG_FLIP_VERTICAL),
            5 => static::flip(imagerotate($img, -90, 0), IMG_FLIP_HORIZONTAL),
            6 => imagerotate($img, -90, 0),
            7 => static::flip(imagerotate($img, 90, 0), IMG_FLIP_HORIZONTAL),
            8 => imagerotate($img, 90, 0),
            default => $img,
        };
        if ($out !== $img && $out instanceof \GdImage) {
            imagedestroy($img);
        }

        return $out instanceof \GdImage ? $out : $img;
    }

    protected static function flip(\GdImage $img, int $mode): \GdImage
    {
        imageflip($img, $mode);

        return $img;
    }
}
