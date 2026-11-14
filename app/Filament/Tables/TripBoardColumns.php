<?php

namespace App\Filament\Tables;

use App\Support\TripBoard;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Auth;

/** "Progress" and "Status" columns and the Status filter for the trip lists. */
class TripBoardColumns
{
    public static function board(string $kind): TripBoard
    {
        $user = Auth::user();

        return TripBoard::make($kind, (int) ($kind === 'warehouse' ? $user?->warehouse_id : $user?->logistichub_id));
    }

    /** Use in ->modifyQueryUsing() so each trip row carries its box counts. */
    public static function withProgress(Builder $query, string $kind): Builder
    {
        return static::board($kind)->withProgress($query);
    }

    public static function progress(string $kind): TextColumn
    {
        $word = static::board($kind)->doneWord();

        return TextColumn::make('boxes_done')
            ->label('Progress')
            ->state(fn (Model $record) => "{$record->boxes_done} of {$record->boxes_total} {$word}")
            ->description(fn (Model $record) => $record->boxes_loaded < $record->boxes_total
                ? "{$record->boxes_loaded} of {$record->boxes_total} loaded"
                : null);
    }

    public static function status(string $kind): TextColumn
    {
        return TextColumn::make('trip_status')
            ->label('Status')
            ->badge()
            ->state(fn (Model $record) => static::board($kind)->statusOf($record))
            ->formatStateUsing(fn (string $state) => TripBoard::STATUSES[$state] ?? $state)
            ->color(fn (string $state) => TripBoard::statusColor($state));
    }

    public static function filter(string $kind): SelectFilter
    {
        $board = static::board($kind);
        $options = TripBoard::STATUSES + ['today' => ucfirst($board->doneWord()).' today'];

        if ($kind === 'warehouse') {
            $options['done'] = 'Received';
        } else {
            $options['problems'] = 'Problems today';
        }

        return SelectFilter::make('board')
            ->label('Status')
            ->options($options)
            ->query(fn (Builder $query, array $data) => filled($data['value'] ?? null)
                ? static::board($kind)->whereStatus($query, $data['value'])
                : $query);
    }
}
