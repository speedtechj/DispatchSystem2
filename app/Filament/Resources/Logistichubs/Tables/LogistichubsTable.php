<?php

namespace App\Filament\Resources\Logistichubs\Tables;

use App\Models\Logistichub;
use App\Support\HubBoxes;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;

class LogistichubsTable
{
    public static function configure(Table $table): Table
    {
        // Box counts come from HubBoxes::counts() (fast, kept 60 seconds), not from the SQL row.
        $sortBy = fn (string|array $keys) => fn (Builder $query, string $direction) => $query->orderByRaw(HubBoxes::orderSql($keys, $direction));
        $n = fn (string $key) => fn ($record) => HubBoxes::count((int) $record->id, $key);

        return $table
            ->query(Logistichub::query())
            ->columns([
                TextColumn::make('hub_code')
                    ->searchable(),
                TextColumn::make('hub_name')
                    ->searchable(),
                IconColumn::make('is_active')
                    ->label('Active')
                    ->boolean(),
                IconColumn::make('is_company')
                    ->label('Company Hub')
                    ->boolean(),
                TextColumn::make('boxes_waiting')
                    ->label('Waiting')
                    ->badge()
                    ->state(fn ($record) => $record->is_company ? HubBoxes::count((int) $record->id, 'boxes_waiting') : null)
                    ->placeholder('—')
                    ->color(fn ($state) => $state > HubBoxes::BUSY_WAITING ? 'danger' : 'info')
                    ->tooltip('Handed to this partner hub, not on a hub trip yet')
                    ->alignEnd()
                    ->sortable(query: $sortBy('boxes_waiting')),
                TextColumn::make('boxes_on_trucks')
                    ->label('On trucks')
                    ->state(fn ($record) => HubBoxes::count((int) $record->id, 'boxes_loading') + HubBoxes::count((int) $record->id, 'boxes_out'))
                    ->tooltip('On this hub\'s trips: loading or out for delivery')
                    ->numeric()
                    ->alignEnd()
                    ->sortable(query: $sortBy(['boxes_loading', 'boxes_out'])),
                TextColumn::make('boxes_today')
                    ->state($n('boxes_today'))
                    ->label('Delivered today')
                    ->numeric()
                    ->color('success')
                    ->weight('bold')
                    ->alignEnd()
                    ->sortable(query: $sortBy('boxes_today')),
                TextColumn::make('boxes_month')
                    ->state($n('boxes_month'))
                    ->label('This month')
                    ->numeric()
                    ->alignEnd()
                    ->sortable(query: $sortBy('boxes_month')),
                TextColumn::make('user.full_name')
                    ->numeric()
                    ->sortable(),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                //
            ])
            ->recordActions([
                EditAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    //   DeleteBulkAction::make(),
                ]),
            ]);
    }
}
