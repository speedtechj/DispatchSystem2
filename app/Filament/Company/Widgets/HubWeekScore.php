<?php

namespace App\Filament\Company\Widgets;

use App\Support\HubDesk;
use Filament\Widgets\Widget;
use Illuminate\Support\Facades\Auth;

/** Partner hub dashboard: delivered this week, and the hub score for the last 30 days. */
class HubWeekScore extends Widget
{
    protected string $view = 'filament.company.widgets.hub-week-score';

    protected static ?int $sort = 3;

    protected int|string|array $columnSpan = 'full';

    protected static bool $isLazy = true;

    protected function getViewData(): array
    {
        $desk = new HubDesk((int) Auth::user()->logistichub_id);
        $week = $desk->week();
        $best = $week->sortByDesc('boxes')->first();

        return [
            'week' => $week,
            'max' => max(1, $week->max('boxes')),
            'total' => $week->sum('boxes'),
            'best' => $best && $best['boxes'] ? $best['date']->format('D') : null,
            'score' => $desk->score(),
        ];
    }
}
