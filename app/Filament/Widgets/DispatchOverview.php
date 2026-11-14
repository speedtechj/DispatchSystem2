<?php

namespace App\Filament\Widgets;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Invoiceissue;
use App\Models\Tripinvoice;
use Filament\Support\Icons\Heroicon;
use Filament\Widgets\StatsOverviewWidget;
use Filament\Widgets\StatsOverviewWidget\Stat;
use Illuminate\Support\Facades\Auth;

class DispatchOverview extends StatsOverviewWidget
{
    protected static ?int $sort = 1;

    protected ?string $pollingInterval = '60s';

    protected function getStats(): array
    {
        $hubId = (int) Auth::user()->logistichub_id;
        // kept 60 seconds: the dashboard opens at once even with many boxes
        [$waiting, $onTrucks, $activeTrips, $openIssues, $perDay] = cache()->store('file')->remember('dash.overview.'.$hubId, 60, function () use ($hubId) {
            $hubTrips = Deliverylog::where('logistichub_id', $hubId)->select('id');
            $from = today()->subDays(6);
            $byDay = Tripinvoice::whereIn('deliverylog_id', $hubTrips)->where('is_delivered', true)
                ->where(fn ($q) => $q->where('delivered_at', '>=', $from)->orWhere(fn ($q) => $q->whereNull('delivered_at')->where('updated_at', '>=', $from)))
                ->selectRaw('date(coalesce(delivered_at, updated_at)) as d, count(*) as n')->groupBy('d')->pluck('n', 'd');

            return [
                Invoice::where('is_verified', true)->where('is_assigned', false)->count(),
                Tripinvoice::whereIn('deliverylog_id', $hubTrips)->where('is_loaded', true)->where('is_delivered', false)->count(),
                Deliverylog::where('logistichub_id', $hubId)->where('is_active', true)->count(),
                Invoiceissue::whereHas('invdata', fn ($q) => $q->where('is_resolved', false))->count(),
                collect(range(6, 0))->map(fn (int $ago) => (int) ($byDay[today()->subDays($ago)->toDateString()] ?? 0))->all(),
            ];
        });
        $deliveredPerDay = collect($perDay);

        return [
            Stat::make('Waiting for a trip', number_format($waiting))
                ->description('Verified boxes not yet assigned')
                ->icon(Heroicon::OutlinedInboxStack)
                ->color($waiting > 0 ? 'warning' : 'success'),
            Stat::make('On trucks now', number_format($onTrucks))
                ->description(trans_choice('{1} :count active trip|[0,*] :count active trips', $activeTrips, ['count' => $activeTrips]))
                ->icon(Heroicon::OutlinedTruck)
                ->color('info'),
            Stat::make('Delivered this week', number_format($deliveredPerDay->sum()))
                ->description(number_format($deliveredPerDay->last()).' today')
                ->chart($deliveredPerDay->all())
                ->icon(Heroicon::OutlinedCheckBadge)
                ->color('success'),
            Stat::make('Open box problems', number_format($openIssues))
                ->description($openIssues ? 'Need follow-up with the consolidator' : 'Nothing to follow up')
                ->icon(Heroicon::OutlinedExclamationTriangle)
                ->color($openIssues ? 'danger' : 'gray'),
        ];
    }
}
