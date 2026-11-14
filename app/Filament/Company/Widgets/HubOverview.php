<?php

namespace App\Filament\Company\Widgets;

use App\Filament\Company\Pages\IncomingBoxes;
use App\Filament\Company\Pages\TrackBox;
use App\Models\Truck;
use App\Support\HubBoxes;
use Filament\Widgets\Widget;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Auth;

/**
 * Partner hub dashboard: this hub's boxes as steps
 * (handed to you → loading → out for delivery → delivered today),
 * and a warning when boxes wait too long for a trip.
 */
class HubOverview extends Widget
{
    protected static ?int $sort = 1;

    protected string $view = 'filament.company.widgets.hub-overview';

    protected int|string|array $columnSpan = 'full';

    protected static bool $isLazy = false;

    public const WAIT_DAYS = 2;

    protected function getViewData(): array
    {
        $hubId = (int) Auth::user()->logistichub_id;
        $hub = HubBoxes::forHub($hubId);
        $late = HubBoxes::waitingTooLong($hubId, self::WAIT_DAYS);

        return [
            'steps' => [
                ['Handed to you', (int) $hub?->boxes_waiting, 'Waiting for a hub trip', 'wait'],
                ['Loading', (int) $hub?->boxes_loading, 'On a hub trip, not loaded', 'load'],
                ['Out for delivery', (int) $hub?->boxes_out, 'On your trucks', 'out'],
                ['Delivered today', (int) $hub?->boxes_today, number_format((int) $hub?->boxes_month).' this month', 'done'],
            ],
            'waiting' => (int) $hub?->boxes_waiting,
            'late' => $late,
            'lateSince' => $late['since'] ? Carbon::parse($late['since'])->format('M j') : null,
            'failed' => (int) $hub?->failed_today,
            'planUrl' => IncomingBoxes::getUrl(),
            'trackUrl' => TrackBox::getUrl(),
            'greeting' => match (true) {
                now()->hour < 12 => 'Good morning', now()->hour < 18 => 'Good afternoon', default => 'Good evening'
            },
            'name' => Auth::user()->first_name,
            'hubName' => $hub?->hub_name,
            'trucks' => Truck::where('logistichub_id', $hubId)->where('is_active', true)->get(['is_assigned']),
        ];
    }
}
