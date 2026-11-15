<?php

namespace App\Filament\Warehouse\Resources\Whdeliverylogs\Tables;

use App\Filament\Tables\TripBoardColumns;
use App\Filament\Warehouse\Resources\Whdeliverylogs\TruckHereAction;
use App\Support\Boxes\Crossdock;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Columns\ToggleColumn;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

class WhdeliverylogsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->modifyQueryUsing(fn (Builder $query) => TripBoardColumns::withProgress($query, 'warehouse'))
            ->columns([
                TextColumn::make('trip_number')
                    ->searchable(),
                TripBoardColumns::status('warehouse'),
                TripBoardColumns::progress('warehouse'),
                TextColumn::make('truck.plate_no')
                    ->numeric()
                    ->sortable(),
                TextColumn::make('warehouse.name')
                    ->label('Warehouse')
                    ->sortable(),
                TextColumn::make('truck_here')
                    ->label('Truck')
                    ->badge()->color('warning')
                    ->getStateUsing(fn ($record) => $record->truck_here ? '🚚 Here, loading' : null)
                    ->visible(fn () => Crossdock::ready()),
                TextColumn::make('Total Invoices')
                    ->label('Total Invoices')
                    ->badge()
                    ->color('danger')
                    ->getStateUsing(function ($record) {
                        return $record->whtripinvoices()->count();
                    }),
                TextColumn::make('Total Load')
                    ->label('Total Load')
                    ->badge()
                    ->color('danger')
                    ->getStateUsing(function ($record) {
                        return $record->whtripinvoices()
                            ->where('is_loaded', true)
                            ->count();
                    }),
                TextColumn::make('City')
                    ->label('City')
                    ->separator(',')
                    ->color('primary')
                    ->listWithLineBreaks()
                    ->limitList(3)
                    ->expandableLimitedList()
                    ->getStateUsing(function ($record) {
                        // only the distinct places, straight from the database (a trip can hold thousands of boxes)
                        return DB::table('whtripinvoices')
                            ->join('invoices', 'invoices.id', '=', 'whtripinvoices.invoice_id')
                            ->where('whtripinvoices.whdeliverylog_id', $record->id)
                            ->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                            ->distinct()->orderBy('invoices.receiver_city')->pluck('invoices.receiver_city');
                        //   ->implode(" , ");
                    }),
                TextColumn::make('Province')
                    ->label('Province')
                    ->separator(',')
                    ->color('primary')
                    ->listWithLineBreaks()
                    ->limitList(3)
                    ->expandableLimitedList()
                    ->getStateUsing(function ($record) {
                        // only the distinct places, straight from the database (a trip can hold thousands of boxes)
                        return DB::table('whtripinvoices')
                            ->join('invoices', 'invoices.id', '=', 'whtripinvoices.invoice_id')
                            ->where('whtripinvoices.whdeliverylog_id', $record->id)
                            ->whereNotNull('invoices.receiver_province')->where('invoices.receiver_province', '!=', '')
                            ->distinct()->orderBy('invoices.receiver_province')->pluck('invoices.receiver_province');
                        //   ->implode(" , ");
                    }),
                TextColumn::make('departure_date')
                    ->date()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('delivery_date')
                    ->date()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('user.full_name')
                    ->numeric()
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
                ToggleColumn::make('is_active')
                    ->label('Active')
                    ->onColor('success')
                    ->offColor('danger')
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                ToggleColumn::make('is_lock')
                    ->label('Lock')
                    ->onColor('success')
                    ->offColor('danger')
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),

            ])
            ->filters([
                TripBoardColumns::filter('warehouse'),
                SelectFilter::make('is_lock')
                    ->label('Is Locked')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ]),
                SelectFilter::make('is_active')
                    ->label('Is Active')
                    ->options([
                        1 => 'Yes',
                        0 => 'No',
                    ])->default(1),
            ])->deferFilters(false)
            ->recordActions([
                TruckHereAction::make(),
                ActionGroup::make([
                    Action::make('locktrip')
                        ->requiresConfirmation()
                        ->label(function ($record) {
                            return $record->is_lock ? 'Unlock Trip' : 'Lock Trip';
                        })
                        ->color('info')
                        ->icon(function ($record) {
                            return $record->is_lock ? Heroicon::LockOpen : Heroicon::LockClosed;
                        })
                        ->hidden(function ($record) {
                            //  dd(Auth::user()->hasRole('super_admin'));
                            return Auth::user()->is_admin ? false : true;
                        })
                        // Before the truck leaves: customers not complete on it, with a reason for each box left behind.
                        ->schema(fn ($record) => $record->is_lock ? [] : \App\Support\Boxes\TruckSets::reasonFields($record))
                        ->modalWidth(fn ($record) => ! $record->is_lock && \App\Support\Boxes\TruckSets::open($record) ? '3xl' : 'md')
                        ->action(function ($record, array $data) {
                            if (! $record->is_lock) {
                                \App\Support\Boxes\TruckSets::saveReasons($record, $data['why'] ?? []);
                            }
                            $record->update([
                                'is_lock' => ! $record->is_lock,
                            ]);

                            Notification::make()
                                ->title($record->is_lock ? 'Trip Locked Successfully' : 'Trip Unlocked Successfully')
                                ->success()
                                ->send();
                        }),
                    EditAction::make()
                        ->label('Edit')
                        ->icon(Heroicon::PencilSquare)
                        ->hidden(function ($record) {
                            return $record->is_lock;
                        }),
                ]),
            ], position: RecordActionsPosition::BeforeColumns)
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }
}
