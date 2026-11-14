<?php

namespace App\Filament\Resources\Boxsummaries\Tables;

use App\Models\Consolidator;
use App\Models\Invoice;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Tables\Columns\Summarizers\Count;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Grouping\Group;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

class BoxsummariesTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->defaultGroup('boxtype')
            ->groups([
                Group::make('receiver_name')
                    ->label('Receiver Name')
                    ->collapsible(),
                Group::make('boxtype')
                    ->label('Box Type')
                    ->collapsible(),
                Group::make('receiver_barangay')
                    ->label('Barangay')
                    ->collapsible(),
                Group::make('receiver_city')
                    ->label('City/Municipality')
                    ->collapsible(),
                Group::make('receiver_province')
                    ->label('Province')
                    ->collapsible(),

            ])
            ->columns([
                TextColumn::make('company')
                    ->label('Company')
                    ->getStateUsing(function ($record) {
                        return Consolidator::nameForCode($record->location_code);
                    }),
                TextColumn::make('invoice')
                    ->label('Invoice'),
                TextColumn::make('batchno')
                    ->label('Batch No')
             //       ->sortable(),
                    ->sortable(query: function (Builder $query, string $direction): Builder {
                        return $query->orderByRaw('CAST(batchno AS UNSIGNED) '.$direction);
                    }),
                TextColumn::make('container.batch_year')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Batch Year'),
                TextColumn::make('sender_name')
                    ->label('Sender'),
                TextColumn::make('receiver_name')
                    ->label('Receiver'),
                TextColumn::make('receiver_address')
                    ->label('Address'),
                TextColumn::make('receiver_province')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Province'),
                TextColumn::make('receiver_city')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('City/Municipality'),
                TextColumn::make('receiver_barangay')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Barangay'),
                TextColumn::make('boxtype')
                    ->label('Box Type')
                    ->summarize(Count::make()->label('Total')),
                TextColumn::make('routearea.description')
                    ->label('Route Area'),
            ])
            ->filters([
                                SelectFilter::make('container_id')
                                    ->label('Container')
                                    ->multiple()
                                    ->searchable()
                                    ->preload()
                                    ->relationship('container', 'id', fn (Builder $query) => $query->where('is_unloaded', '1'))
                                    ->getOptionLabelFromRecordUsing(function (Model $record) {
                                        return "{$record->container_no} {$record->batch_no} {$record->batch_year}";
                                    }),
                                SelectFilter::make('receiver_province')
                                    ->label('Province')
                                    ->multiple()
                                    ->searchable()
                                    ->options(
                                        Invoice::query()
                                            ->select('receiver_province')
                                            ->distinct()
                                            ->orderBy('receiver_province')
                                            ->pluck('receiver_province', 'receiver_province')
                                    ),
                                SelectFilter::make('location_code')
                                    ->label('Company')
                                    ->multiple()
                                    ->searchable()
                                    ->options(
                                        Consolidator::query()
                                            ->select('code', 'company_name')
                                            ->orderBy('company_name')
                                            ->pluck('company_name', 'code')
                                    ),
                            ])->deferFilters(false)
            ->recordActions([
                                    //   EditAction::make(),
            ])
            ->toolbarActions([
                                    BulkActionGroup::make([
                                        //         DeleteBulkAction::make(),
                                    ]),
            ]);
    }
}
