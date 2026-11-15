<?php

namespace App\Filament\Warehouse\Resources\Deliverylogs\Tables;

use App\Filament\Tables\TripBoardColumns;
use App\Filament\Warehouse\Pages\TripStops;
use App\Filament\Warehouse\Pages\TripFuel;
use App\Models\Deliverylog;
use App\Models\Logistichub;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\EditAction;
use Filament\Notifications\Notification;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Columns\ToggleColumn;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;

class DeliverylogsTable
{
    public static function configure(Table $table): Table
    {
        return $table
            ->recordUrl(null)
            ->query(Deliverylog::query()->where('logistichub_id', '=', Auth::user()->logistichub_id))
            ->modifyQueryUsing(fn (Builder $query) => TripBoardColumns::withProgress($query, 'delivery'))
            ->columns([
                \App\Filament\Shared\Trips\TripActions::stageColumn(),
                TextColumn::make('trip_number')
                    ->searchable(),

                TripBoardColumns::status('delivery'),

                TripBoardColumns::progress('delivery'),

                TextColumn::make('truck_id')
                    ->label('Truck')
                    ->searchable(query: function ($query, $search) {
                        return $query->whereHas('truck', function ($q) use ($search) {
                            $q->where('plate_no', 'like', "%{$search}%");
                        });
                    })
                    ->sortable()
                    ->getStateUsing(function ($record) {
                        return $record->truck ? $record->truck->plate_no : 'Truck not assigned';
                    }),
                TextColumn::make('vicheletype')
                    ->label('Vichele Type/Size')
                    ->getStateUsing(function ($record) {
                        return $record->truck ? $record->truck->category : ' ';
                    }),
                TextColumn::make('trip_day')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->numeric()
                    ->sortable(),
                TextColumn::make('logistichub.hub_name')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Logistic Hub/Location'),
                TextColumn::make('Total Invoices')
                    ->label('Total Invoices')
                    ->badge()
                    ->color('danger')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->count();
                    }),
                TextColumn::make('Total Loaded')
                    ->badge()
                    ->color('success')
                    ->label('Total Loaded')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->whereHas('invoice', function ($query) {
                            $query->where('is_loaded', 1);
                        })->count();
                    }),
                TextColumn::make('Verified Invoices')
                    ->label('Invoices Verified')
                    ->badge()
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->color('info')
                    ->getStateUsing(function ($record) {
                        return $record->tripinvoices()->whereHas('invoice', function ($query) {
                            $query->where('is_verified', 1);
                        })->count();
                        // return $record->tripinvoices->invoices->where('is_verified', 1)->count();
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
                        return DB::table('tripinvoices')
                            ->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                            ->where('tripinvoices.deliverylog_id', $record->id)
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
                        return DB::table('tripinvoices')
                            ->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                            ->where('tripinvoices.deliverylog_id', $record->id)
                            ->whereNotNull('invoices.receiver_province')->where('invoices.receiver_province', '!=', '')
                            ->distinct()->orderBy('invoices.receiver_province')->pluck('invoices.receiver_province');
                        //   ->implode(" , ");
                    }),
                IconColumn::make('is_lock')
                    ->label('Lock Status')
                    ->boolean()
                    ->trueIcon(Heroicon::LockClosed)
                    ->falseIcon(Heroicon::LockOpen)
                    ->sortable()
                    ->color(function ($state) {
                        return $state ? 'danger' : 'success';
                    }),

                TextColumn::make('waybill_number')
                    ->label('Waybill No. / Container No.')
                    ->searchable()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),
                TextColumn::make('eta')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->label('ETA')
                    ->date()
                    ->sortable(),
                TextColumn::make('departure_date')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->date()
                    ->sortable(),
                TextColumn::make('assigned_to')
                    ->sortable()
                    ->getStateUsing(function ($record) {
                        return Logistichub::where('id', $record->assigned_to)->first()->hub_name;
                    }),
                TextColumn::make('user.full_name')
                    ->label('Created By')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),

                ToggleColumn::make('is_active')
                    ->label('Is Active')
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
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
                TripBoardColumns::filter('delivery'),
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
                SelectFilter::make('assigned_to')
                    ->label('Going To')
                    ->options(Logistichub::query()->pluck('hub_name', 'id'))
                    ->searchable()
                    ->preload(),
            ])->deferFilters(false)
            ->recordActions([
                Action::make('stops')
                    ->label('Stops & loading')
                    ->icon('heroicon-o-map')
                    ->button()
                    ->color('gray')
                    ->url(fn ($record): string => TripStops::getUrl(['trip' => $record->id])),
                Action::make('seaShipment')
                    ->label('Make it a sea shipment')
                    ->icon('heroicon-o-globe-asia-australia')
                    ->button()
                    ->color('info')
                    ->tooltip(fn ($record) => ($record->destination?->hub_name ?? 'This hub').' is reached by sea')
                    ->visible(fn ($record): bool => \App\Support\Shipping\Shipments::ready() && $record->is_active && $record->destination?->is_company
                        && \App\Support\Shipping\Islands::bySea($record->destination) && ! \App\Models\Shipping\SeaShipment::where('deliverylog_id', $record->id)->exists())
                    ->url(fn ($record): string => \App\Filament\Warehouse\Pages\SeaShipments::getUrl(['trip' => $record->id])),
                Action::make('fuel')
                    ->label('Fuel')
                    ->icon('heroicon-o-beaker')
                    ->button()
                    ->color('gray')
                    ->visible(fn (): bool => \App\Support\Fuel\Fuel::ready())
                    ->url(fn ($record): string => TripFuel::getUrl(['trip' => $record->id])),
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
                            //  dd(Auth::user()->is_admin);
                            return Auth::user()->is_admin ? false : true;
                        })
                        ->action(function ($record) {
                            $record->update([
                                'is_lock' => ! $record->is_lock,
                            ]);

                            Notification::make()
                                ->title($record->is_lock ? 'Trip Locked Successfully' : 'Trip Unlocked Successfully')
                                ->success()
                                ->send();
                        }),
                    \App\Filament\Shared\Trips\TripActions::release(),
                    \App\Filament\Shared\Trips\TripActions::crew(),
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
                    //    DeleteBulkAction::make(),

                ]),
            ]);

    }
}
