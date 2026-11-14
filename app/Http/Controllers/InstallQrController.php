<?php

namespace App\Http\Controllers;

use App\Support\Branding;
use App\Support\InstallLinks;
use App\Support\Pwa;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Illuminate\View\View;
use Symfony\Component\HttpFoundation\Response;

/** Install QR codes: PNG download, a printable poster, and a sheet of 6 stickers. */
class InstallQrController extends Controller
{
    protected function app(string $app): string
    {
        abort_unless(isset(InstallLinks::APPS[$app]), 404);

        return $app;
    }

    public function png(string $app): Response
    {
        $app = $this->app($app);

        return response(InstallLinks::png($app), 200, [
            'Content-Type' => 'image/png',
            'Content-Disposition' => 'attachment; filename="'.Str::slug(InstallLinks::name($app)).'-install-qr.png"',
            'Cache-Control' => 'no-store',
        ]);
    }

    public function poster(Request $request, string $app): View
    {
        return $this->sheet($app, 'poster');
    }

    public function stickers(Request $request, string $app): View
    {
        return $this->sheet($app, 'stickers');
    }

    protected function sheet(string $app, string $kind): View
    {
        $app = $this->app($app);
        InstallLinks::rememberPrint();
        $place = InstallLinks::placeFor(Auth::user());

        return view('install.'.$kind, [
            'app' => $app,
            'name' => InstallLinks::name($app),
            'url' => InstallLinks::url($app),
            'qr' => InstallLinks::svg($app, $kind === 'poster' ? 320 : 150),
            'icon' => route('pwa.icon', ['panel' => InstallLinks::APPS[$app]['panel'], 'size' => 192]).'?v='.Pwa::version(),
            'company' => Branding::companyName(),
            'place' => $place,
            'isCompany' => $place === Branding::companyName(),
            'for' => InstallLinks::APPS[$app]['for'],
        ]);
    }
}
