<?php

namespace App\Console\Commands;

use App\Support\Sms\SmsEvents;
use Illuminate\Console\Command;

/** Every 5 minutes: "out for delivery" and "driver is next" texts to receivers. */
class SmsWork extends Command
{
    protected $signature = 'sms:work';

    protected $description = 'SMS to receivers: out for delivery and driver is next';

    public function handle(): int
    {
        $this->info('Texts sent: '.SmsEvents::work());

        return self::SUCCESS;
    }
}
