<?php

namespace App\Filament\Warehouse\Resources\Inventories\Tables;

use App\Filament\Warehouse\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Inventory;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Support\Facades\Auth;

class InventoriesTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->query(
                Inventory::onFloor(Auth::user()->warehouse_id)->with(['currentTrip.deliverylog:id,trip_number', 'warehouse:id,name'])
            )
            ->columns([
                TextColumn::make('currentTrip.deliverylog.trip_number')
                    ->label('Trip Number')
                    ->placeholder('Not assigned')
                    ->url(fn (Inventory $record) => $record->currentTrip
                        ? DeliverylogResource::getUrl('edit', ['record' => $record->currentTrip->deliverylog_id])
                        : null)
                    ->color('primary'),
                TextColumn::make('invoice')
                    ->searchable(),
                TextColumn::make('batchno')
                    ->searchable(),
                TextColumn::make('sender_name')
                    ->searchable(),
                TextColumn::make('receiver_name')
                    ->searchable(),
                TextColumn::make('receiver_address')
                    ->searchable(),
                TextColumn::make('receiver_province')
                    ->searchable(),
                TextColumn::make('receiver_city')
                    ->searchable(),
                TextColumn::make('receiver_barangay')
                    ->searchable(),
                TextColumn::make('boxtype')
                    ->searchable(),
                TextColumn::make('warehouse.name')
                    ->searchable(),
            ])
            ->filters([
                SelectFilter::make('receiver_province')
                    ->label('Receiver Province')
                    ->options(
                        fn () => Inventory::query()
                            ->whereNotNull('receiver_province')
                            ->where('receiver_province', '!=', '')
                            ->distinct()
                            ->orderBy('receiver_province')
                            ->pluck('receiver_province', 'receiver_province')
                            ->toArray()
                    )
                    ->searchable()
                    ->multiple(), //
            ])->deferFilters(false)
            ->recordActions([
                //       EditAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    //           DeleteBulkAction::make(),
                ]),
            ]);
    }
}
