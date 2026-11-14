<?php

namespace App\Console\Commands;

use App\Models\AppSetting;
use App\Models\Logistichub;
use App\Support\Tracking\DaySummary;
use Illuminate\Console\Command;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Mail;

/** Every day at 6 PM: the end-of-day truck summary for Admin and each hub, and the optional email. */
class TrackSummary extends Command
{
    protected $signature = 'track:summary {--day= : YYYY-MM-DD, default today}';

    protected $description = 'Truck tracking: write the end-of-day summary (and email it when set)';

    public function handle(): int
    {
        $day = $this->option('day') ? Carbon::parse($this->option('day')) : today();
        $all = DaySummary::build($day, null);
        foreach (Logistichub::where('is_active', true)->pluck('id') as $hub) {
            DaySummary::build($day, (int) $hub);
        }
        $to = collect(preg_split('/[\s,;]+/', (string) AppSetting::get('track.summary_emails', '')))->filter(fn ($e) => filter_var($e, FILTER_VALIDATE_EMAIL))->values();
        if ($to->isNotEmpty() && $all && count($all->data['trucks'] ?? [])) {
            Mail::send('mail.truck-day', ['s' => $all, 'day' => $day], fn ($m) => $m->to($to->all())->subject('Trucks today · '.$day->format('M j')));
        }
        $this->info('Summary written for '.$day->toDateString().' ('.count($all?->data['trucks'] ?? []).' trucks)');

        return self::SUCCESS;
    }
}
