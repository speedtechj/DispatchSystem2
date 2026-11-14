<?php

namespace App\Console\Commands;

use App\Support\Aging\AgingNotifier;
use Illuminate\Console\Command;

class AgingTick extends Command
{
    protected $signature = 'aging:summary {--now : send the morning summary now}';

    protected $description = 'Box aging: send the morning summary at the chosen hour, and the monthly limits check';

    public function handle(): int
    {
        $n = AgingNotifier::tick((bool) $this->option('now'));
        $this->info("Summaries sent: {$n}");

        return self::SUCCESS;
    }
}
