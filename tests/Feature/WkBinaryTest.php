<?php

use App\Support\Pdf\WkBinary;

it('looks for the PDF program in this domain, the project and the usual places, safely', function () {
    $list = WkBinary::candidates();
    expect($list)->toContain(base_path('bin/wkhtmltopdf'), '/var/www/vhosts/icargoxpress.net/bin/wkhtmltopdf', '/usr/local/bin/wkhtmltopdf');
});

it('only looks at files PHP may open (open_basedir), and runs the others to check them', function () {
    $old = ini_get('open_basedir');
    // no open_basedir: everything allowed
    expect(WkBinary::allowed('/usr/local/bin/wkhtmltopdf'))->toBeTrue();

    $dir = sys_get_temp_dir().'/wk-'.uniqid();
    mkdir($dir);
    $fake = $dir.'/wkhtmltopdf';
    file_put_contents($fake, "#!/bin/sh\necho 'wkhtmltopdf 0.12.6 (with patched qt)'\n");
    chmod($fake, 0755);
    expect(WkBinary::works($fake))->toBeTrue()
        ->and(WkBinary::works($dir.'/nothing'))->toBeFalse();
    @unlink($fake);
    @rmdir($dir);
    expect($old)->toBe(ini_get('open_basedir'));
});

it('explains where it looked when the PDF program is missing', function () {
    config(['snappy.pdf.binary' => '/nowhere/wkhtmltopdf']);
    putenv('WKHTML_PDF_BINARY=/nowhere/wkhtmltopdf');
    WkBinary::forget();
    expect(WkBinary::candidates())->toContain('/nowhere/wkhtmltopdf');
});
