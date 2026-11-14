<?php

namespace App\Console\Commands;

use App\Support\Tracking\AlertChecker;
use Illuminate\Console\Command;

/** Every 5 minutes: truck alerts (stopped, no location, off the route, back with boxes) and old locations removed. */
class TrackCheck extends Command
{
    protected $signature = 'track:check';

    protected $description = 'Truck tracking: raise and close truck alerts, remove old locations';

    public function handle(): int
    {
        $this->info('New truck alerts: '.AlertChecker::run());

        return self::SUCCESS;
    }
}
