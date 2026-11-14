<?php

namespace App\Console\Commands;

use App\Models\Ai\AiPhotoCheck;
use App\Support\Aging\BoxAging;
use App\Support\Ai\Ai;
use App\Support\Ai\Alerts;
use App\Support\Ai\PhotoCheck;
use App\Support\Maps\Geocoder;
use Illuminate\Console\Command;

/** Every 15 minutes: alerts, and photo checks that could not run right away. */
class AiWork extends Command
{
    protected $signature = 'ai:work {--photos=150 : most photos to check in one run}';

    protected $description = 'AI helpers: look for alerts and check photos waiting for the AI';

    public function handle(): int
    {
        if (Ai::enabled('aging')) {
            // count Box aging for the office now, so the menu badge and the page open fast
            BoxAging::rows(null, null, true);
        }

        $alerts = Alerts::run();
        $this->info("Alerts raised or refreshed: {$alerts}");

        if (Ai::enabled('photo_check')) {
            $n = 0;
            AiPhotoCheck::whereNull('checked_at')->where('created_at', '>=', now()->subDays(7))
                ->oldest('id')->limit((int) $this->option('photos'))->get()
                ->each(function (AiPhotoCheck $c) use (&$n) {
                    PhotoCheck::run($c);
                    $n++;
                });
            $this->info("Photos checked: {$n}");
        }

        // Maps & routes: addresses still waiting to be found on the map
        $found = Geocoder::work(60);
        if ($found) {
            $this->info("Addresses looked up on the map: {$found}");
        }

        return self::SUCCESS;
    }
}
