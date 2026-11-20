<?php

namespace App\Filament\Tables;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use Filament\Actions\BulkAction;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Tabs\Tab;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;

/**
 * Boxes on this trip (board 44b): All / Loaded / Not loaded / Delivered / Problems tabs, bulk priority,
 * and the tiles at the top of Edit trip. Shared by the Admin, Warehouse and Partner hub panels.
 */
class TripBoxes
{
    public const TITLE = 'Boxes on this trip';

    /** @param  string  $loaded  is_loaded (warehouse trips) or is_loaded_hub (a partner hub's own trips) */
    public static function tabs(string $loaded = 'is_loaded', ?\Closure $base = null): array
    {
        $problem = fn (Builder $q) => $q->where(fn ($w) => $w->whereHas('invoiceissue')->orWhereHas('deliveryAttempts'));
        $q = [
            'all' => ['All', fn (Builder $b) => $b],
            'loaded' => ['Loaded', fn (Builder $b) => $b->where($loaded, true)],
            'not_loaded' => ['Not loaded', fn (Builder $b) => $b->where(fn ($w) => $w->where($loaded, false)->orWhereNull($loaded))],
            'delivered' => ['Delivered', fn (Builder $b) => $b->where('is_delivered', true)],
            'problems' => ['Problems', $problem],
        ];

        return collect($q)->mapWithKeys(fn ($v, $k) => [$k => Tab::make($v[0])
            ->badge($base ? fn () => $v[1]($base())->count() : null)
            ->badgeColor($k === 'problems' ? 'danger' : 'gray')
            ->modifyQueryUsing(fn (Builder $query) => $v[1]($query))])->all();
    }

    /** Mark the selected boxes as priority, or take priority off. */
    public static function priority(bool $on): BulkAction
    {
        return BulkAction::make($on ? 'bulkPriority' : 'bulkUnpriority')
            ->label($on ? 'Mark as priority' : 'Take off priority')
            ->icon($on ? 'heroicon-o-star' : 'heroicon-o-minus-circle')
            ->color($on ? 'warning' : 'gray')
            ->requiresConfirmation()
            ->modalHeading(fn (Collection $records) => ($on ? 'Mark ' : 'Take priority off ').$records->count().' box'.($records->count() === 1 ? '' : 'es').($on ? ' as priority?' : '?'))
            ->action(function (Collection $records) use ($on) {
                Invoice::whereIn('id', $records->pluck('invoice_id')->filter())->update(['is_priority' => $on]);
                Notification::make()->title($records->count().' box'.($records->count() === 1 ? '' : 'es').($on ? ' marked as priority' : ' taken off priority'))->success()->send();
            })
            ->deselectRecordsAfterCompletion();
    }

    /** @return list<array{l: string, v: int|string, tone: string}> */
    public static function tiles(Deliverylog $trip, bool $hub = false): array
    {
        $rows = $hub ? Tripinvoice::where('deliveryloghub_id', $trip->id) : Tripinvoice::where('deliverylog_id', $trip->id);
        $loadedCol = $hub ? 'is_loaded_hub' : 'is_loaded';
        $total = (clone $rows)->count();
        $loaded = (clone $rows)->where($loadedCol, true)->count();
        $done = (clone $rows)->where('is_delivered', true)->count();
        $tried = (clone $rows)->where(fn ($w) => $w->where('is_delivered', false)->orWhereNull('is_delivered'))->whereHas('deliveryAttempts')->count();
        $prio = Invoice::whereIn('id', (clone $rows)->select('invoice_id'))->where('is_priority', true)->count();

        return [
            ['l' => 'Boxes', 'v' => $total, 'tone' => 'ink'],
            ['l' => 'Loaded', 'v' => $loaded.($total ? ' / '.$total : ''), 'tone' => $total && $loaded === $total ? 'ok' : 'ink'],
            ['l' => 'Delivered', 'v' => $done, 'tone' => $done ? 'ok' : 'ink'],
            ['l' => 'Not delivered', 'v' => $tried, 'tone' => $tried ? 'bad' : 'ink'],
            ['l' => 'Priority', 'v' => $prio, 'tone' => $prio ? 'warn' : 'ink'],
        ];
    }
}
