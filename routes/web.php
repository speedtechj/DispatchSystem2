<?php

use App\Http\Controllers\AiChatController;
use App\Http\Controllers\BoxPhotoController;
use App\Http\Controllers\DriverOfflineController;
use App\Http\Controllers\FuelController;
use App\Http\Controllers\InstallQrController;
use App\Http\Controllers\InvoiceController;
use App\Http\Controllers\LoadingListController;
use App\Http\Controllers\PwaController;
use App\Http\Controllers\TrackController;
use Illuminate\Foundation\Http\Middleware\ValidateCsrfToken;
use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken;
use Illuminate\Support\Facades\Route;

// Printable delivery receipt. Only signed-in users (any panel) may print.
Route::get('/tripinv/{invoice}/printpdf', [InvoiceController::class, 'tripinvoice'])
    ->middleware('auth')
    ->whereNumber('invoice')
    ->name('invoicepdf');

// Several receipts at once (at most 15), one per page: /tripinv/print?ids=1,2,3
Route::get('/tripinv/print', [InvoiceController::class, 'bulk'])
    ->middleware('auth')
    ->name('invoicepdf.bulk');

// Install the Delivery panel as an app (PWA): manifest, icons, service worker and offline page.
Route::controller(PwaController::class)->group(function () {
    Route::get('/sw.js', 'serviceWorker')->name('pwa.sw');
    Route::get('/pwa/offline', 'offline')->name('pwa.offline');
    Route::get('/pwa/{panel}/manifest.webmanifest', 'manifest')->whereIn('panel', ['delivery', 'scan'])->name('pwa.manifest');
    Route::get('/pwa/{panel}/icon-{size}.png', 'icon')->whereIn('panel', ['delivery', 'scan'])->whereNumber('size')->name('pwa.icon');
    // Same files without a file ending: Plesk's nginx serves .js / .png / .webmanifest from disk
    // and never asks Laravel, so phones get a 404 and Android does not offer to install.
    Route::get('/pwa/sw', 'serviceWorker')->name('pwa.sw.plain');
    Route::get('/pwa/{panel}/manifest', 'manifest')->whereIn('panel', ['delivery', 'scan'])->name('pwa.manifest.plain');
    Route::get('/pwa/{panel}/icon/{size}', 'icon')->whereIn('panel', ['delivery', 'scan'])->whereNumber('size')->name('pwa.icon.plain');
});

Route::middleware('web')->group(function () {
    Route::get('/box-photos/{photo}.jpg', [BoxPhotoController::class, 'show'])->whereNumber('photo')->name('box-photos.show');
    Route::get('/box-photos/{photo}/download', [BoxPhotoController::class, 'download'])->whereNumber('photo')->name('box-photos.download');
});

// Driver app without signal: today's boxes for the phone, sending what was saved offline, and the offline page.
Route::middleware('web')->group(function () {
    Route::get('/delivery-offline/trip', [DriverOfflineController::class, 'trip'])->name('driver-offline.trip');
    Route::post('/delivery-offline/sync', [DriverOfflineController::class, 'sync'])->name('driver-offline.sync');
    Route::get('/delivery-offline', [DriverOfflineController::class, 'shell'])->name('driver-offline.shell');
});

// Customer chat: receivers ask about their own box (only while "Customer chat" is on in Admin → Settings → AI).
Route::middleware(['web', 'throttle:30,60'])->controller(AiChatController::class)->group(function () {
    Route::get('/ask-box', 'show')->name('ai-chat.show');
    Route::post('/ask-box', 'start')->name('ai-chat.start');
    Route::get('/ask-box/{token}', 'chat')->name('ai-chat.chat');
    Route::post('/ask-box/{token}', 'ask')->name('ai-chat.ask');
});

// Install QR codes for the phone apps (signed-in staff only): download, poster, stickers.
Route::middleware(['web', 'auth'])->controller(InstallQrController::class)->group(function () {
    Route::get('/install-qr/{app}.png', 'png')->whereIn('app', ['scan', 'driver'])->name('install-qr.png');
    Route::get('/install-qr/{app}/poster', 'poster')->whereIn('app', ['scan', 'driver'])->name('install-qr.poster');
    Route::get('/install-qr/{app}/stickers', 'stickers')->whereIn('app', ['scan', 'driver'])->name('install-qr.stickers');
});

// Maps & routes: printed loading list of a trip (FRONT → MIDDLE → BACK).
Route::middleware(['web', 'auth'])->get('/trip-loading/{trip}', [LoadingListController::class, 'show'])
    ->whereNumber('trip')->name('trip.loading-list');

// Truck tracking: the Driver app sends locations during a trip; GPS trackers send to a secret link.
Route::middleware(['web', 'auth', 'throttle:120,1'])->post('/delivery-track', [TrackController::class, 'driver'])->name('track.driver');
Route::middleware(['throttle:600,1'])->match(['get', 'post'], '/track/in/{token}', [TrackController::class, 'tracker'])
    ->withoutMiddleware([ValidateCsrfToken::class, VerifyCsrfToken::class, 'Illuminate\Foundation\Http\Middleware\PreventRequestForgery'])
    ->name('track.tracker');

// Fuel › VAT: the month's fuel receipts for the accountant (signed-in staff, their own hub).
Route::get('/fuel/vat-export', [FuelController::class, 'vatExport'])->middleware(['web', 'auth'])->name('fuel.vat-export');

// Printable QR labels for the warehouse sections.
Route::get('/sections/labels', App\Http\Controllers\SectionLabelsController::class)->middleware(['web', 'auth'])->name('sections.labels');
