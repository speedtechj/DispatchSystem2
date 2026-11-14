<?php

use App\Support\Photos\BoxPhotos;
use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

Artisan::command('photos:prune', function () {
    $this->info(BoxPhotos::prune().' old box photos deleted.');
})->purpose('Delete box photos older than the keep time in Settings → Box photos');

Schedule::command('photos:prune')->dailyAt('02:30');
Schedule::command('ai:work')->everyFifteenMinutes()->withoutOverlapping();
Schedule::command('aging:summary')->hourly()->withoutOverlapping();
Schedule::command('track:check')->everyFiveMinutes()->withoutOverlapping();
Schedule::command('sms:work')->everyFiveMinutes()->withoutOverlapping();
Schedule::command('track:summary')->dailyAt('18:00');
Schedule::command('photos:shrink')->everyTenMinutes()->withoutOverlapping();
