<?php

namespace App\Filament\Widgets;

use App\Filament\Resources\Deliverylogs\DeliverylogResource;
use App\Support\HubBoxes;
use Filament\Widgets\Widget;

/** Admin dashboard: boxes waiting, loading, out and delivered for every hub. */
class HubBoxesWidget extends Widget
{
    protected string $view = 'filament.widgets.hub-boxes';

    protected static ?int $sort = 3;

    protected int|string|array $columnSpan = 'full';

    /** Loads right after the page shows, so signing in is not held up. */
    protected static bool $isLazy = true;

    /** now, today or name */
    public string $sortBy = 'now';

    public function sortBy(string $by): void
    {
        $this->sortBy = in_array($by, ['now', 'today', 'name'], true) ? $by : 'now';
    }

    public function tripsUrl(int $hubId, bool $isPartner): string
    {
        return DeliverylogResource::getUrl('index', $isPartner ? ['filters' => ['assigned_to' => ['value' => $hubId]]] : []);
    }

    protected function getViewData(): array
    {
        $hubs = HubBoxes::hubs()
            ->each(fn ($h) => $h->boxes_now = $h->boxes_waiting + $h->boxes_loading + $h->boxes_out);

        $hubs = match ($this->sortBy) {
            'today' => $hubs->sortByDesc('boxes_today'),
            'name' => $hubs->sortBy('hub_name', SORT_NATURAL | SORT_FLAG_CASE),
            default => $hubs->sortBy([['is_company', 'asc'], ['boxes_now', 'desc']]),
        };

        $total = fn (string $field) => $hubs->sum($field);

        return [
            'hubs' => $hubs->values(),
            'scale' => max(1, $hubs->max(fn ($h) => $h->boxes_now + $h->boxes_today)),
            'totals' => [
                'now' => $total('boxes_now'), 'waiting' => $total('boxes_waiting'), 'loading' => $total('boxes_loading'),
                'out' => $total('boxes_out'), 'today' => $total('boxes_today'), 'month' => $total('boxes_month'), 'failed' => $total('failed_today'),
            ],
        ];
    }
}
