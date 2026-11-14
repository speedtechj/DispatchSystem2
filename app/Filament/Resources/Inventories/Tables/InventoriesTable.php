<?php

namespace App\Filament\Resources\Inventories\Tables;

use App\Filament\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Inventory;
use App\Services\TripAssignment;
use Filament\Actions\BulkAction;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\EditAction;
use Filament\Notifications\Notification;
use Filament\Tables\Columns\Summarizers\Count;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;

class InventoriesTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->query(
                Inventory::onFloor()->with(['currentTrip.deliverylog:id,trip_number', 'warehouse:id,name', 'container:id,container_no'])
            )
            ->defaultGroup('receiver_province')
            ->columns([
                TextColumn::make('currentTrip.deliverylog.trip_number')
                    ->label('Trip Number')
                    ->placeholder('Not assigned')
                    ->url(fn (Inventory $record) => $record->currentTrip
                        ? DeliverylogResource::getUrl('edit', ['record' => $record->currentTrip->deliverylog_id])
                        : null)
                    ->color('primary'),
                TextColumn::make('invoice')
                    ->label('Invoice')
                    ->searchable()
                    ->sortable(),
                TextColumn::make('sender_name')
                    ->label('Sender Name')
                    ->sortable(),
                TextColumn::make('receiver_name')
                    ->label('Receiver Name')
                    ->sortable(),
                TextColumn::make('receiver_address')
                    ->label('Receiver Address')
                    ->sortable(),
                TextColumn::make('receiver_barangay')
                    ->label('Receiver Barangay')
                    ->sortable(),
                TextColumn::make('receiver_city')
                    ->label('Receiver City')
                    ->sortable(),
                TextColumn::make('receiver_province')
                    ->label('Receiver Province')
                    ->sortable(),
                TextColumn::make('container.container_no')
                    ->label('Container No')
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('warehouse.name')
                    ->label('Warehouse')
                    ->sortable(),
                TextColumn::make('summary')
                    ->label('Summary')
                    ->state(fn ($record) => $record->receiver_province)
                    ->summarize(

                        Count::make()->query(fn ($query) => $query->select('invoices.id'))

                    ),
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
                    ->multiple(), // remove if you only want one province at a time

            ])->deferFilters(false)
            ->recordActions([
                //  EditAction::make(),
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    BulkAction::make('Mark as Loaded')
                        ->label('Mark as loaded')
                        ->icon('heroicon-o-truck')
                        ->color('success')
                        ->requiresConfirmation()
                        ->modalDescription('Only boxes already on a trip can be loaded. They leave the inventory.')
                        ->action(function ($records): void {
                            $loaded = 0;

                            foreach ($records as $record) {
                                if ($record->currentTrip) {
                                    app(TripAssignment::class)->markLoaded($record->currentTrip);
                                    $loaded++;
                                }
                            }

                            $skipped = count($records) - $loaded;

                            Notification::make()
                                ->title("{$loaded} box(es) marked as loaded")
                                ->body($skipped ? "{$skipped} box(es) are not on a trip yet and were skipped." : null)
                                ->success()
                                ->send();
                        }),

                ]),
            ]);
    }
}
