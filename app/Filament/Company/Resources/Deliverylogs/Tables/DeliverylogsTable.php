<?php

namespace App\Filament\Company\Resources\Deliverylogs\Tables;

use App\Filament\Company\Pages\TripFuel;
use App\Filament\Company\Pages\TripStops;
use App\Filament\Shared\Trips\TripActions;
use App\Filament\Tables\TripBoardColumns;
use App\Filament\Tables\TripList;
use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Support\Fuel\Fuel;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Enums\FiltersLayout;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;

class DeliverylogsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            // board 42: one clear row per trip; click a trip for its details on the side
            ->recordUrl(null)
            ->recordAction('details')
            ->defaultSort('created_at', 'desc')
            ->query(Deliverylog::query()->where('logistichub_id', '=', Auth::user()->logistichub_id))
            ->modifyQueryUsing(fn (Builder $query) => TripBoardColumns::withProgress($query, 'hub'))
            ->columns([...TripList::columns(), ...collect([
                TripActions::stageColumn(),
                TripBoardColumns::status('hub'),
                TripBoardColumns::progress('hub'),
                TextColumn::make('truck.plate_no')
                    ->sortable(),
                TextColumn::make('trip_day')
                    ->numeric()
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),
                TextColumn::make('Total Invoices')
                    ->badge()
                    ->color('success')
                    ->label('Total Invoices')
                    ->getStateUsing(function ($record) {

                        return Tripinvoice::where('deliveryloghub_id', $record->id)->count();
                    }),
                TextColumn::make('Total Loaded')
                    ->badge()
                    ->color('success')
                    ->label('Total Loaded')
                    ->getStateUsing(function ($record) {

                        return Tripinvoice::where('deliveryloghub_id', $record->id)->where('is_loaded_hub', 1)->count();
                    }),

                TextColumn::make('eta')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('departure_date')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('delivery_date')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('waybill_number')
                    ->searchable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('user.full_name')
                    ->label('Created By')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])->map(fn ($c) => $c->toggleable(isToggledHiddenByDefault: true))->all()])
            ->filters([
                // a partner hub's own trips always go direct, so only Made by
                TripList::filters()[0],
                TripBoardColumns::filter('hub'),
            ])->deferFilters(false)
            ->filtersLayout(FiltersLayout::AboveContent)->filtersFormColumns(4)
            ->recordActions([
                Action::make('stops')
                    ->label('Stops & loading')
                    ->icon('heroicon-o-map')
                    ->button()
                    ->color('gray')
                    ->url(fn ($record): string => TripStops::getUrl(['trip' => $record->id])),
                Action::make('fuel')
                    ->label('Fuel')
                    ->icon('heroicon-o-beaker')
                    ->button()
                    ->color('gray')
                    ->visible(fn (): bool => Fuel::ready())
                    ->url(fn ($record): string => TripFuel::getUrl(['trip' => $record->id])),
                ActionGroup::make([
                    TripActions::release(),
                    TripActions::crew(),
                    EditAction::make()->label('Edit')->icon(Heroicon::PencilSquare)->hidden(fn ($record) => (bool) $record->is_lock),
                ]),
                TripList::details(),
            ], position: RecordActionsPosition::AfterColumns)
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }
}
