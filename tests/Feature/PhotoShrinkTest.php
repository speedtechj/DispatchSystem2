<?php

use App\Support\Photos\BoxPhotos;
use App\Support\Photos\PhotoShrinker;
use Filament\Forms\Components\FileUpload;
use Illuminate\Support\Facades\Storage;

/** A phone-like JPEG: big, sideways, with the EXIF orientation tag the phone sets. */
function phoneJpeg(int $w = 2400, int $h = 1800, int $orientation = 1, int $quality = 95): string
{
    $img = imagecreatetruecolor($w, $h);
    mt_srand(7);
    for ($y = 0; $y < $h; $y += 6) {
        for ($x = 0; $x < $w; $x += 6) {
            imagefilledrectangle($img, $x, $y, $x + 5, $y + 5, imagecolorallocate($img, mt_rand(0, 255), mt_rand(0, 255), mt_rand(0, 255)));
        }
    }
    ob_start();
    imagejpeg($img, null, $quality);
    $jpg = (string) ob_get_clean();
    imagedestroy($img);
    if ($orientation === 1) {
        return $jpg;
    }
    $tiff = "MM\0\x2A".pack('N', 8).pack('n', 1).pack('nnN', 0x0112, 3, 1).pack('n', $orientation)."\0\0".pack('N', 0);
    $app1 = "Exif\0\0".$tiff;

    return substr($jpg, 0, 2)."\xFF\xE1".pack('n', strlen($app1) + 2).$app1.substr($jpg, 2);
}

it('makes a big phone photo smaller and turns it the right way up', function () {
    $big = phoneJpeg(2400, 1800, 6);
    expect(strlen($big))->toBeGreaterThan(1024 * 1024)
        ->and(PhotoShrinker::orientation($big))->toBe(6);

    $out = PhotoShrinker::bytes($big, 'jpg');
    [$w, $h] = getimagesizefromstring($out);
    expect([$w, $h])->toBe([1200, 1600])          // portrait: the phone was held upright
        ->and(strlen($out))->toBeLessThan(strlen($big) / 2);
});

it('reads the orientation without the exif extension too', function () {
    $big = phoneJpeg(64, 48, 8);
    $byHand = (new ReflectionMethod(PhotoShrinker::class, 'orientationByHand'))->invoke(null, $big);
    expect($byHand)->toBe(8)
        ->and((new ReflectionMethod(PhotoShrinker::class, 'orientationByHand'))->invoke(null, phoneJpeg(64, 48)))->toBe(1);
});

it('leaves small photos and other files alone', function () {
    expect(PhotoShrinker::bytes(phoneJpeg(800, 600, 1, 70), 'jpg'))->toBeNull()
        ->and(PhotoShrinker::bytes('not a picture', 'jpg'))->toBeNull();

    Storage::fake('public');
    Storage::disk('public')->put('docs/list.pdf', str_repeat('x', 900 * 1024));
    expect(PhotoShrinker::file('public', 'docs/list.pdf'))->toBeNull();
});

it('shrinks new big photos on the server every 10 minutes, and old ones with --all', function () {
    Storage::fake('public');
    $disk = Storage::disk('public');
    $disk->put('INV001/new.jpg', $orig = phoneJpeg());
    $disk->put('not-delivered/INV002/old.jpg', phoneJpeg());
    $disk->put('INV003/small.jpg', phoneJpeg(400, 300, 1, 70));
    touch($disk->path('not-delivered/INV002/old.jpg'), now()->subDays(3)->getTimestamp());

    $this->artisan('photos:shrink --dry')->expectsOutputToContain('2 photos checked · 1 are big')->assertSuccessful();
    expect($disk->size('INV001/new.jpg'))->toBeGreaterThan(1024 * 1024);

    $this->artisan('photos:shrink')->expectsOutputToContain('1 made smaller')->assertSuccessful();
    expect($disk->size('INV001/new.jpg'))->toBeLessThan(strlen($orig) / 2)
        ->and($disk->size('not-delivered/INV002/old.jpg'))->toBeGreaterThan(1024 * 1024);

    $this->artisan('photos:shrink --all')->expectsOutputToContain('1 made smaller')->assertSuccessful();
    expect($disk->size('not-delivered/INV002/old.jpg'))->toBeLessThan(strlen($orig) / 2);
    [$w] = getimagesizefromstring($disk->get('not-delivered/INV002/old.jpg'));
    expect($w)->toBe(1600);
});

it('keeps scan photos upright when the server makes them smaller', function () {
    $out = BoxPhotos::shrink(phoneJpeg(2400, 1800, 6), 'TEST | UNLOAD');
    [$w, $h] = getimagesizefromstring($out);
    expect($h)->toBeGreaterThan($w);
});

it('makes photos smaller on the phone in every upload box', function () {
    $f = FileUpload::make('delivery_picture')->image();
    expect($f->getImageResizeTargetWidth())->toBe('1600')
        ->and($f->getImageResizeTargetHeight())->toBe('1600')
        ->and($f->getImageResizeMode())->toBe('contain')
        ->and($f->getImageResizeUpscale())->toBeFalse();
});
