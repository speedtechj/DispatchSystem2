<?php

namespace App\Http\Controllers;

use App\Models\BrandAsset;
use App\Support\Branding;
use App\Support\Pwa;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Response;
use Symfony\Component\HttpFoundation\BinaryFileResponse;

/** Files that make the Delivery panel installable: manifest, icons, the service worker and the offline page. */
class PwaController extends Controller
{
    public function manifest(string $panel): JsonResponse
    {
        abort_unless(Pwa::exists($panel), 404);

        return response()
            ->json(Pwa::manifest($panel), options: JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)
            ->header('Content-Type', 'application/manifest+json')
            ->header('Cache-Control', 'no-cache');
    }

    public function icon(string $panel, int $size): BinaryFileResponse|RedirectResponse
    {
        abort_unless(Pwa::exists($panel) && in_array($size, [180, 192, 512], true), 404);

        $path = Pwa::iconPath($panel, $size, request()->boolean('maskable'));

        if (! $path) {
            return redirect(BrandAsset::fileUrl(BrandAsset::current()?->app_icon) ?? Branding::logoUrl() ?? Pwa::faviconUrl());
        }

        return response()->file($path, [
            'Content-Type' => 'image/png',
            'Cache-Control' => 'public, max-age=604800',
        ]);
    }

    public function serviceWorker(): Response
    {
        $path = fn (?string $url) => $url ? parse_url($url, PHP_URL_PATH) : null;

        return response(view('pwa.sw', [
            'version' => Pwa::version().'-'.DriverOfflineController::scriptVersion(),
            'driverScript' => '/js/app/driver-offline.js?v='.DriverOfflineController::scriptVersion(),
            'logoPath' => $path(Branding::logoUrl()),
            'faviconPath' => $path(Pwa::faviconUrl()),
        ])->render(), 200, [
            'Content-Type' => 'text/javascript; charset=utf-8',
            'Cache-Control' => 'no-cache',
        ]);
    }

    public function offline(): Response
    {
        return response(view('pwa.offline', [
            'company' => Branding::companyName(),
            'initials' => Branding::initials(),
            'logo' => Branding::logoUrl(),
        ])->render());
    }
}
