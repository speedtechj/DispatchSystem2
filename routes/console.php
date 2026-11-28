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

Artisan::command('photos:work {--seconds=50}', function () {
    \Illuminate\Support\Facades\Cache::put('photos.schedule.seen', time(), 3600);
    $n = \App\Support\Photos\Storage\PhotoWork::work((int) $this->option('seconds'));
    $n && $this->info($n.' photos moved or copied.');
})->purpose('Settings → Photo storage: go on with moves and copies (the scheduler runs it every minute)');

Artisan::command('connectors:send {--seconds=50}', function () {
    if (! \App\Support\Connectors\Recorder::ready()) {
        return;
    }
    \Illuminate\Support\Facades\Cache::put('connectors.schedule.seen', time(), 3600);
    $r = \App\Support\Connectors\Sender::run((int) $this->option('seconds'));
    ($r['sent'] || $r['released']) && $this->info("{$r['sent']} statuses sent ({$r['saved']} saved), {$r['released']} out of the hold.");
})->purpose('Settings → Consolidator connections: send the Outbox to the connectors (the scheduler runs it every minute)');

Schedule::command('photos:prune')->dailyAt('02:30');
Schedule::command('photos:work')->everyMinute()->withoutOverlapping(10);
Schedule::command('ai:work')->everyFifteenMinutes()->withoutOverlapping();
Schedule::command('aging:summary')->hourly()->withoutOverlapping();
Schedule::command('track:check')->everyFiveMinutes()->withoutOverlapping();
Schedule::command('sms:work')->everyFiveMinutes()->withoutOverlapping();
Schedule::command('track:summary')->dailyAt('18:00');
Schedule::command('photos:shrink')->everyTenMinutes()->withoutOverlapping();
Schedule::command('connectors:send')->everyMinute()->withoutOverlapping(10);
