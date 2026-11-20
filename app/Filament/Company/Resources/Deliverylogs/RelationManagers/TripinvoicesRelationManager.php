<?php

namespace App\Filament\Company\Resources\Deliverylogs\RelationManagers;

use App\Filament\Actions\BulkPrintReceipts;
use App\Filament\Company\Pages\Routeinvoice;
use App\Filament\Exports\TripinvoiceExporter;
use App\Filament\Tables\DeliveryAttemptColumns;
use App\Filament\Tables\TripBoxes;
use App\Filament\Tables\TruckSpotColumn;
use App\Models\Consolidator;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkAction;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\ExportAction;
use Filament\Forms\Components\TextInput;
use Filament\Notifications\Notification;
use Filament\Resources\RelationManagers\RelationManager;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\Summarizers\Count;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Filters\Filter;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Grouping\Group;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

class TripinvoicesRelationManager extends RelationManager
{
    protected static string $relationship = 'tripinvoices';

    protected static ?string $title = TripBoxes::TITLE;

    /** All / Loaded / Not loaded / Delivered / Problems (board 44b). */
    public function getTabs(): array
    {
        return TripBoxes::tabs('is_loaded_hub', fn () => Tripinvoice::query()->where('deliveryloghub_id', $this->ownerRecord->id));
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                TextInput::make('invoice')
                    ->required()
                    ->maxLength(255),
            ]);
    }

    public function table(Table $table): Table
    {
        return $table
            ->modifyQueryUsing(fn (Builder $query) => $query->withCount(['deliveryAttempts', 'deliveryReversals'])->with(DeliveryAttemptColumns::eagerLoad()))
            //  ->poll('5s')
            ->defaultGroup('invdata.receiver_name')
            ->groups([
                Group::make('invdata.receiver_name')
                    ->label('Receiver Name'),
                Group::make('invdata.boxtype')
                    ->label('Box Type'),
                Group::make('invdata.routearea.description')
                    ->label('Route Area'),
                Group::make('invdata.container.batch_no')
                    ->label('Batch No'),
                Group::make('invdata.receiver_barangay')
                    ->label('Barangay'),
                Group::make('invdata.receiver_city')
                    ->label('City'),
                Group::make('invdata.receiver_province')
                    ->label('Province'),
            ])
            ->recordTitleAttribute('id')
            ->deferLoading()
            ->query(
                Tripinvoice::query()
                    ->where('deliveryloghub_id', $this->ownerRecord->id)
                    ->with(['invdata', 'invoice', 'deliverylog', 'logistichub', 'route'])  // ✅ moved inside query()
            )
            ->paginated([10, 25, 50])        // ✅ v5 uses paginated() not paginationPageOptions()
            ->defaultPaginationPageOption(10) //

            ->columns([
                TruckSpotColumn::make(),
                TextColumn::make('company')
                    ->label('Company')
                    ->getStateUsing(function ($record) {
                        return Consolidator::nameForCode($record->invdata->location_code);
                        // return $record->invdata;
                    }),
                TextColumn::make('deliveryloghub_id')
                    ->label('Trip Number')
                    ->getStateUsing(function ($record) {
                        return Deliverylog::find($record->deliveryloghub_id)->trip_number;
                    })
                    ->searchable(),
                TextColumn::make('invdata.invoice')
                    ->sortable()
                    ->searchable(isIndividual: true)
                    ->label('Invoice No'),
                DeliveryAttemptColumns::column(),
                TextColumn::make('invdata.container.batch_no')
                    ->label('Batch No')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('invdata.container.batch_year')
                    ->label('Batch Year')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('invdata.receiver_name')
                    ->label('Receiver'),
                TextColumn::make('invdata.receiver_address')
                    ->label('Address'),
                TextColumn::make('invdata.receiver_province')
                    ->sortable()
                    ->label('Province'),
                TextColumn::make('invdata.receiver_city')
                    ->label('City/Municipality'),
                TextColumn::make('invdata.receiver_barangay')
                    ->label('Barangay'),
                TextColumn::make('invdata.boxtype')
                    ->label('Box Type')
                    ->summarize(Count::make()->label('Total')),
                TextColumn::make('invdata.routearea.description')
                    ->label('Route Area'),
                IconColumn::make('is_loaded_hub')
                    ->label('Loaded')
                    ->color(fn (bool $state) => $state ? 'success' : 'danger')
                    ->icon(fn (bool $state) => match ($state) {
                        true => 'heroicon-o-check-circle',
                        false => 'heroicon-o-x-circle',
                    }),

            ])
            ->filters([

                Filter::make('is_loaded')
                    ->label('Not Loaded')
                    ->toggle()
                    ->query(fn (Builder $query): Builder => $query->where('is_loaded', false)),
                SelectFilter::make('company')
                    ->label('Company')
                    ->multiple()
                    ->searchable()
                    ->options(
                        Consolidator::orderBy('company_name')
                            ->pluck('company_name', 'code')
                    )
                    ->query(function ($query, array $data) {
                        if (! $data['values']) {
                            return;
                        }

                        $query->whereHas('invoice', function ($q) use ($data) {
                            $q->whereIn('location_code', $data['values']);
                        });
                    }),

            ])->deferFilters(false)
            ->headerActions([
                Action::make('Assign Invoice')
                    ->label('+ Assign invoice')->color('warning')
                    ->url(fn ($livewire) => Routeinvoice::getUrl(['ownerRecord' => $livewire->ownerRecord->getKey()])),
                ExportAction::make()
                    ->label('Export')
                    ->exporter(TripinvoiceExporter::class)
                    ->color('info')
                    ->icon('heroicon-o-arrow-down-tray'),

            ])
            ->recordActions([
                ActionGroup::make([
                    DeliveryAttemptColumns::action(),
                    DeliveryAttemptColumns::undoAction(),
                    // Print Function
                    Action::make('Print')
                        ->label('Print')
                        ->color('primary')
                        ->icon('heroicon-o-printer')
                        ->url(fn (Model $record) => route('invoicepdf', $record->invoice_id))
                        ->openUrlInNewTab(),
                    // Export Function

                    // Action::make('Export')
                    // ->label('Export')
                    //  ->requiresConfirmation()

                    // Delete function
                    Action::make('Delete')
                        ->before(function ($record) {
                            //  dd($record);
                            $record->update([
                                'hub_assigned' => 0,
                                'deliveryloghub_id' => null,
                                'is_loaded_hub' => 0,
                            ]);
                        })
                        ->requiresConfirmation()
                        ->color('danger')
                        ->icon('heroicon-o-trash'),

                ]),

            ], position: RecordActionsPosition::BeforeColumns)
            ->toolbarActions([
                BulkPrintReceipts::make(),
                TripBoxes::priority(true),
                TripBoxes::priority(false),
                BulkActionGroup::make([
                    BulkAction::make('delete')
                        ->label('Remove ')
                        ->action(function ($records) {

                            // dump($records);
                            foreach ($records as $record) {
                                Tripinvoice::find($record->id)?->update([
                                    'hub_assigned' => 0,
                                    'deliveryloghub_id' => null,
                                    'is_loaded_hub' => 0,
                                ]);
                            }
                            Notification::make()
                                ->title('Invoice removed successfully')
                                ->success()
                                ->send();
                        })
                        ->requiresConfirmation()
                        ->color('danger')
                        ->icon('heroicon-o-trash'),
                    BulkAction::make('Return')
                        ->label('Return')
                        ->icon(Heroicon::Backward)
                        ->action(function ($records) {

                            foreach ($records as $record) {
                                Invoice::find($record->invoice_id)?->update([
                                    'is_returned' => 1,
                                    //     'is_assigned' => 0,
                                ]);
                                Tripinvoice::find($record->id)?->update([

                                    'hub_assigned' => 0,
                                    'deliveryloghub_id' => null,
                                    'is_loaded_hub' => 0,

                                ]);
                                //  $record->delete();
                            }
                            Notification::make()
                                ->title('Invoice returned successfully')
                                ->success()
                                ->send();
                        })
                        ->requiresConfirmation()
                        ->color('warning'),
                    // BulkAction::make('Loaded')
                    //     ->color('success')
                    //     ->label('Mark as Loaded')
                    //     ->icon(Heroicon::Truck)
                    //     ->action(function ($records) {
                    //         foreach ($records as $record) {
                    //             $record->update([
                    //                 'is_loaded' => 1,
                    //             ]);
                    //         }
                    //         Notification::make()
                    //             ->title('Invoice Loaded successfully')
                    //             ->success()
                    //             ->send();

                    //         $tripcount = Tripinvoice::where('deliverylog_id', $record->deliverylog_id)->count();
                    //         $totalloaded = Tripinvoice::where('deliverylog_id', $record->deliverylog_id)->where('is_loaded', true)->count();
                    //         if ($totalloaded > 0) {
                    //             if ($tripcount == $totalloaded) {
                    //                 $Deliverydata = Deliverylog::find($record->deliverylog_id);
                    //                 $Deliverydata->truck->update([
                    //                     'is_assigned' => true,
                    //                 ]);
                    //                 $Deliverydata->update([
                    //                     'is_current' => true,

                    //                 ]);
                    //             }
                    //         }
                    //     })

                ]),
            ]);
    }
}
