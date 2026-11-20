#!/usr/bin/env bash
#
# Dispatch System — Part 22f: faster Delivery trips and the whole system
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part22f-faster-system.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 14 files"

# ---------------------------------------------------------------- app/Filament/Company/Resources/Deliverylogs/RelationManagers/TripinvoicesRelationManager.php
mkdir -p 'app/Filament/Company/Resources/Deliverylogs/RelationManagers'
cat > 'app/Filament/Company/Resources/Deliverylogs/RelationManagers/TripinvoicesRelationManager.php' <<'DISPATCH_FILE_END_0'
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
            ->modifyQueryUsing(fn (Builder $query) => $query->withCount(['deliveryAttempts', 'deliveryReversals'])->with([...DeliveryAttemptColumns::eagerLoad(), 'deliverylog', 'hubTrip', 'invdata.consolidator:id,code,company_name', 'invdata.routearea']))
            //  ->poll('5s')
            // speed: the group checkbox uses the boxes on this page (no query per receiver)
            ->selectCurrentPageOnly()
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
                        return $record->hubTrip?->trip_number; // eager-loaded (was one query per box)
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
                    ->label('Box Type'),
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
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Resources/Deliverylogs/RelationManagers/TripinvoicesRelationManager.php
mkdir -p 'app/Filament/Resources/Deliverylogs/RelationManagers'
cat > 'app/Filament/Resources/Deliverylogs/RelationManagers/TripinvoicesRelationManager.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Resources\Deliverylogs\RelationManagers;

use App\Filament\Actions\BulkPrintReceipts;
use App\Filament\Exports\TripinvoiceExporter;
use App\Filament\Pages\Routeinvoice;
use App\Filament\Tables\DeliveryAttemptColumns;
use App\Filament\Tables\TripBoxes;
use App\Filament\Tables\TruckSpotColumn;
use App\Models\Consolidator;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkAction;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\ExportAction;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Notifications\Notification;
use Filament\Resources\RelationManagers\RelationManager;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Filters\Filter;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Grouping\Group;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

class TripinvoicesRelationManager extends RelationManager
{
    protected static string $relationship = 'tripinvoices';

    protected static ?string $title = TripBoxes::TITLE;

    /** All / Loaded / Not loaded / Delivered / Problems (board 44b). */
    public function getTabs(): array
    {
        return TripBoxes::tabs('is_loaded', fn () => $this->getRelationship()->getQuery());
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                TextInput::make('trip_number')
                    ->required()
                    ->maxLength(255),
            ]);
    }

    public function table(Table $table): Table
    {
        return $table
            ->modifyQueryUsing(fn (Builder $query) => $query->withCount(['deliveryAttempts', 'deliveryReversals'])->with([...DeliveryAttemptColumns::eagerLoad(), 'invdata.consolidator:id,code,company_name', 'invdata.routearea', 'invdata.container', 'invoiceissue.boxissue', 'deliverylog']))
            // speed: the group checkbox uses the boxes on this page (no query per receiver)
            ->selectCurrentPageOnly()
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
            ->collapsedGroupsByDefault()
            // ->poll('5s')
            ->deferLoading()
            ->recordTitleAttribute('id')
            ->columns([
                TruckSpotColumn::make(),
                TextColumn::make('invdata.consolidator.company_name')
                    ->label('Company'),
                TextColumn::make('deliverylog.trip_number')
                    ->label('Trip Number'),
                //  ->searchable(),
                TextColumn::make('invdata.invoice')
                    ->sortable()
                    ->searchable(isIndividual: true, isGlobal: false)
                    ->label('Invoice No.'),
                DeliveryAttemptColumns::column(),
                TextColumn::make('problem')
                    ->badge()
                    ->color('danger')
                    ->label('Problem')
                    ->getStateUsing(fn ($record) => $record->invoiceissue->pluck('boxissue.issue_type')->filter()->unique()->join(', ') ?: null),
                IconColumn::make('invdata.is_resolved')
                    ->label('Resolved')
                    ->icon(fn ($state) => $state ? 'heroicon-o-check-circle' : null)
                    ->color('success'),
                TextColumn::make('invdata.batchno')
                    ->label('Batch No')
                    ->sortable(),
                TextColumn::make('invdata.is_priority')
                    ->label('Priority')
                    // ->badge()
                    ->formatStateUsing(fn ($state) => $state ? 'PRIORITY' : null)
                    ->color(fn ($state) => $state ? 'success' : null),
                TextColumn::make('invdata.container.batch_year')
                    ->label('Batch Year')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('invdata.sender_name')
                    ->sortable()
                    ->label('Sender'),
                TextColumn::make('invdata.receiver_name')
                    ->sortable()
                    ->label('Receiver'),
                TextColumn::make('invdata.receiver_address')
                    ->label('Address'),
                TextColumn::make('invdata.receiver_province')
                    ->sortable()
                    //   ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Province'),
                TextColumn::make('invdata.receiver_city')
                    //     ->toggleable(isToggledHiddenByDefault: true)
                    ->label('City/Municipality'),
                TextColumn::make('invdata.receiver_barangay')
                    //        ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Barangay'),
                TextColumn::make('invdata.boxtype')
                    ->label('Box Type'),
                // TextColumn::make('invoice.routearea.description')
                //     ->label('Route Area'),
                IconColumn::make('is_loaded')
                    ->label('Loaded')
                    ->color(fn (bool $state) => $state ? 'success' : 'danger')
                    ->icon(fn (bool $state) => match ($state) {
                        true => 'heroicon-o-check-circle',
                        false => 'heroicon-o-x-circle',
                    }),

            ])->searchOnBlur()
            ->persistSearchInSession()
            ->persistColumnSearchesInSession()
            ->filters([

                Filter::make('is_loaded')
                    ->label('Not Loaded')
                    ->toggle()
                    ->query(fn (Builder $query): Builder => $query->where('is_loaded', false)),
                SelectFilter::make('company')
                    ->label('Company')
                    ->multiple()
                    //  ->searchable()
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
                    Action::make('Priority')
                        ->label('Mark as Priority')
                        ->color('warning')
                        ->icon(Heroicon::ExclamationTriangle)
                        ->action(function ($record) {
                            $record->invoice()->update([
                                'is_priority' => true,
                            ]);
                            Notification::make()
                                ->title('Invoice marked as priority')
                                ->success()
                                ->send();
                        }),
                    Action::make('Unpriority')
                        ->label('Mark as Unpriority')
                        ->color('danger')
                        ->icon(Heroicon::ExclamationTriangle)
                        ->action(function ($record) {
                            $record->invoice()->update([
                                'is_priority' => false,
                            ]);
                            Notification::make()
                                ->title('Invoice marked as unpriority')
                                ->success()
                                ->send();
                        }),
                    Action::make('Print')
                        ->label('Print')
                        ->color('primary')
                        ->icon('heroicon-o-printer')
                        ->url(fn (Model $record) => route('invoicepdf', $record->invoice_id))
                        ->openUrlInNewTab(),
                    Action::make('Delete')
                        ->label('Remove')
                        ->action(function (Tripinvoice $record): void {
                            try {
                                app(TripAssignment::class)->removeFromDeliveryTrip($record);
                            } catch (\DomainException $exception) {
                                Notification::make()->title($exception->getMessage())->danger()->send();

                                return;
                            }

                            Notification::make()->title('Invoice removed from the trip')->success()->send();
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
                            try {
                                foreach ($records as $record) {
                                    app(TripAssignment::class)->removeFromDeliveryTrip($record, returned: false);
                                }
                            } catch (\DomainException $exception) {
                                Notification::make()->title($exception->getMessage())->danger()->send();

                                return;
                            }

                            Notification::make()
                                ->title('Invoices removed from the trip')
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
                            try {
                                foreach ($records as $record) {
                                    app(TripAssignment::class)->removeFromDeliveryTrip($record, returned: true);
                                }
                            } catch (\DomainException $exception) {
                                Notification::make()->title($exception->getMessage())->danger()->send();

                                return;
                            }

                            Notification::make()
                                ->title('Invoices marked as returned')
                                ->success()
                                ->send();
                        })
                        ->requiresConfirmation()
                        ->color('warning'),
                    BulkAction::make('Move')
                        ->label('Move to Another Trip')
                        ->icon(Heroicon::ArrowRight)
                        ->color('info')
                        ->schema([
                            Select::make('deliverylog_id')
                                ->label('Select Target Trip')
                                ->searchable()
                                ->options(function () {
                                    return Deliverylog::where('is_active', true)
                                        ->where('logistichub_id', Auth::user()->logistichub_id)
                                        ->get()
                                        ->mapWithKeys(function ($record) {
                                            //    dd($record->logistichub->hub_name);
                                            $assignTo = $record->assigned_to ?? 'N/A';
                                            $going_to = Logistichub::where('id', $assignTo)->value('hub_name') ?? 'N/A';

                                            return [
                                                $record->id => "{$record->trip_number} | {$going_to}",
                                            ];
                                        });
                                })
                                ->required(),

                        ])
                        ->action(function (Collection $records, array $data) {

                            $deliverylogdata = Deliverylog::find($data['deliverylog_id']);
                            if ($this->ownerRecord->assigned_to == $deliverylogdata->assigned_to) {
                                foreach ($records as $record) {
                                    $record->update([
                                        'deliverylog_id' => $data['deliverylog_id'],
                                    ]);
                                }
                                Notification::make()
                                    ->title('Invoices moved successfully')
                                    ->success()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('Cannot move invoices to a trip assigned to a different Hub')
                                    ->danger()
                                    ->send();
                            }
                            //   $recordIds = $records->pluck('id')->toArray();

                            // Redirect to the move page with the selected record IDs
                            //  redirect()->route('filament.pages.movetripinvoice', ['recordIds' => implode(',', $recordIds)]);
                        }),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Resources/Deliverylogs/Tables/DeliverylogsTable.php
mkdir -p 'app/Filament/Resources/Deliverylogs/Tables'
cat > 'app/Filament/Resources/Deliverylogs/Tables/DeliverylogsTable.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Filament\Resources\Deliverylogs\Tables;

use App\Filament\Pages\TripStops;
use App\Filament\Pages\TripFuel;
use App\Filament\Tables\TripBoardColumns;
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
            // board 42: one clear row per trip; click a trip for its details on the side
            ->recordUrl(null)
            ->recordAction('details')
            ->defaultSort('created_at', 'desc')
            ->query(Deliverylog::query()->where('logistichub_id', '=', Auth::user()->logistichub_id))
            ->modifyQueryUsing(fn (Builder $query) => TripBoardColumns::withProgress($query, 'delivery'))
            ->columns([...\App\Filament\Tables\TripList::columns(), ...collect([
                \App\Filament\Shared\Trips\TripActions::stageColumn(),

                TripBoardColumns::status('delivery'),

                TripBoardColumns::progress('delivery'),

                // Partner hub by truck: "Received by Baguio · 2 missing" (Scan app · Receive truck).
                TextColumn::make('hub_received')
                    ->label('Hub received')
                    ->badge()
                    ->color(fn ($state) => str_contains((string) $state, 'missing') ? 'danger' : (str_contains((string) $state, 'Received') ? 'success' : 'warning'))
                    ->visible(fn () => \App\Support\Shipping\TruckReceive::ready())
                    ->getStateUsing(function ($record) {
                        $r = \App\Models\Shipping\TruckReceipt::with('hub:id,hub_name')->where('deliverylog_id', $record->id)->get();

                        return $r->isEmpty() ? null : $r->map(fn ($x) => $x->finished_at
                            ? 'Received by '.($x->hub?->hub_name ?? 'hub').($x->missing ? ' · '.$x->missing.' missing' : '')
                            : ($x->hub?->hub_name ?? 'Hub').' receiving…')->join(' / ');
                    }),

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
            ])->map(fn ($c) => $c->toggleable(isToggledHiddenByDefault: true))->all()])
            ->filters([
                ...\App\Filament\Tables\TripList::filters(),
                TripBoardColumns::filter('delivery'),
                SelectFilter::make('assigned_to')
                    ->label('Which hub')
                    ->options(Logistichub::query()->pluck('hub_name', 'id'))
                    ->searchable()
                    ->preload(),
            ])->deferFilters(false)
            ->filtersLayout(\Filament\Tables\Enums\FiltersLayout::AboveContent)->filtersFormColumns(5)
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
                    ->url(fn ($record): string => \App\Filament\Pages\SeaShipments::getUrl(['trip' => $record->id])),
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
                        // locking is on the Trip page (when ready); here a super admin can only unlock
                        ->hidden(function ($record) {
                            return ! $record->is_lock || ! Auth::user()->hasRole('super_admin');
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
                \App\Filament\Tables\TripList::details(),
            ], position: RecordActionsPosition::AfterColumns)
            ->toolbarActions([
                BulkActionGroup::make([
                    //    DeleteBulkAction::make(),

                ]),
            ]);
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Shared/Trips/ListsTrips.php
mkdir -p 'app/Filament/Shared/Trips'
cat > 'app/Filament/Shared/Trips/ListsTrips.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Shared\Trips;

use App\Filament\Tables\TripList;
use App\Models\Deliverylog;
use Filament\Actions\Action;
use Filament\Actions\CreateAction;
use Filament\Facades\Filament;
use Illuminate\Contracts\Pagination\CursorPaginator;
use Illuminate\Contracts\Pagination\Paginator;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/** Delivery trips list (board 42): title, Plan trips, New trip by hand and the stage tabs. All three panels. */
trait ListsTrips
{
    protected ?int $tripsPrimedFor = null;

    protected function getHeaderActions(): array
    {
        $plan = collect(Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => is_subclass_of($p, PlanTripsPage::class));

        return array_values(array_filter([
            $plan ? Action::make('plan')->label('✦ Plan trips')->url(fn () => $plan::getUrl()) : null,
            CreateAction::make()->label('+ New trip by hand')->color('gray'),
        ]));
    }

    public function getTitle(): string
    {
        return 'Delivery trips';
    }

    public function getSubheading(): ?string
    {
        return 'Every trip, who made it and how far it is. Click a trip for the details.';
    }

    public function getBreadcrumbs(): array
    {
        return [];
    }

    /** Speed: load cities, crew, truck and hub for the whole page at once. */
    public function getTableRecords(): Collection|Paginator|CursorPaginator
    {
        $records = parent::getTableRecords();
        if ($this->tripsPrimedFor !== spl_object_id($records)) { // again only when Filament reloads the rows
            $this->tripsPrimedFor = spl_object_id($records);
            TripList::prime($records instanceof Paginator || $records instanceof CursorPaginator ? $records->items() : $records);
        }

        return $records;
    }

    public function getTabs(): array
    {
        return TripList::tabs(Deliverylog::query()->where('deliverylogs.logistichub_id', Auth::user()->logistichub_id));
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Filament/Tables/TripList.php
mkdir -p 'app/Filament/Tables'
cat > 'app/Filament/Tables/TripList.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Filament\Tables;

use App\Models\Deliverylog;
use App\Models\TripCity;
use App\Models\TripCrew;
use App\Models\TripOverride;
use App\Support\Hubs\HubAreas;
use App\Support\TripFlow;
use App\Support\Trips\TripRules;
use Filament\Actions\Action;
use Filament\Forms\Components\ToggleButtons;
use Filament\Schemas\Components\Tabs\Tab;
use Filament\Tables\Columns\ViewColumn;
use Filament\Tables\Filters\Filter;
use Illuminate\Contracts\Pagination\Paginator;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Delivery trips list (board 42): one clear row per trip, who made it (✦ AI, ✦ Plan trips, changed, by hand),
 * where it goes, truck and crew, boxes, status; tabs, Made by and Going to filters, details on the side.
 */
class TripList
{
    public const MADE = [
        'ai' => ['✦ AI', 'ai'],
        'plan' => ['✦ Plan trips', 'plan'],
        'changed' => ['✦ Plan trips · changed', 'changed'],
        'manual' => ['✎ By hand', 'manual'],
    ];

    /** Rows loaded once for the whole page by prime(): trip id => cities, cities from boxes, crew. */
    protected static array $primed = ['app' => null, 'cities' => [], 'boxCities' => [], 'crew' => []];

    protected static function primed(string $kind, int $id)
    {
        return static::$primed['app'] === spl_object_id(app()) ? (static::$primed[$kind][$id] ?? null) : null;
    }

    /** Load what every row needs in a few queries instead of several per trip (speed). */
    public static function prime(iterable $trips): void
    {
        $trips = collect($trips instanceof Paginator ? $trips->items() : $trips)->filter(fn ($t) => $t instanceof Model);
        if ($trips->isEmpty()) {
            return;
        }
        (new Collection($trips->all()))->loadMissing(['truck', 'user', 'destination']);
        $ids = $trips->pluck('id')->all();
        TripFlow::known($trips);
        static::$primed = ['app' => spl_object_id(app()), 'cities' => [], 'boxCities' => [], 'crew' => []];
        $cities = TripCity::whereIn('deliverylog_id', $ids)->get()->groupBy('deliverylog_id');
        $crew = TripCrew::with('user.workposition')->whereIn('deliverylog_id', $ids)->get()->groupBy('deliverylog_id');
        $noCities = array_values(array_diff($ids, $cities->keys()->all()));
        $box = collect();
        if ($noCities) {
            $sel = fn (string $col) => DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                ->whereIn('tripinvoices.'.$col, $noCities)->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                ->select('tripinvoices.'.$col.' as trip', 'invoices.receiver_province as province', 'invoices.receiver_city as city')->distinct()->get();
            $box = $sel('deliverylog_id')->concat($sel('deliveryloghub_id'))->groupBy('trip');
        }
        foreach ($ids as $id) {
            static::$primed['cities'][$id] = $cities->get($id, collect());
            static::$primed['crew'][$id] = $crew->get($id, collect());
            static::$primed['boxCities'][$id] = $box->get($id, collect())->unique(fn ($r) => $r->province.'|'.$r->city)->take(6)->values();
        }
    }

    protected static function citiesOf(Model $trip)
    {
        return static::primed('cities', $trip->id) ?? TripCity::where('deliverylog_id', $trip->id)->get();
    }

    protected static function hasMade(): bool
    {
        static $has = null;

        return $has ??= Schema::hasColumn('deliverylogs', 'made_by');
    }

    /** How the trip was made. Old trips: Plan trips when they have cities, else by hand. */
    public static function madeKey(Model $trip): string
    {
        $m = static::hasMade() ? $trip->made_by : null;
        if ($m && isset(self::MADE[$m])) {
            return $m;
        }

        return static::citiesOf($trip)->isNotEmpty() ? 'plan' : 'manual';
    }

    public static function isHubTrip(Model $trip): bool
    {
        return $trip->assigned_to && (int) $trip->assigned_to !== (int) $trip->logistichub_id;
    }

    /** @return array{to: string, cities: string, dot: string} */
    public static function goes(Model $trip): array
    {
        $cities = static::citiesOf($trip);
        if ($cities->isEmpty()) {
            $rows = static::primed('boxCities', $trip->id) ?? DB::table('tripinvoices')->join('invoices', 'invoices.id', '=', 'tripinvoices.invoice_id')
                ->where(fn ($q) => $q->where('tripinvoices.deliverylog_id', $trip->id)->orWhere('tripinvoices.deliveryloghub_id', $trip->id))
                ->whereNotNull('invoices.receiver_city')->where('invoices.receiver_city', '!=', '')
                ->select('invoices.receiver_province as province', 'invoices.receiver_city as city')->distinct()->limit(6)->get();
            $prov = Str::title((string) ($rows->first()->province ?? ''));
            $list = $rows->pluck('city')->map(fn ($c) => Str::title($c))->unique();
        } else {
            $prov = (string) $cities->first()->province;
            $list = $cities->pluck('city')->unique();
        }
        $cityText = $list->isEmpty() ? 'No boxes yet' : $list->take(3)->join(', ').($list->count() > 3 ? ' +'.($list->count() - 3) : '');
        if (static::isHubTrip($trip)) {
            $color = class_exists(HubAreas::class) ? HubAreas::color((int) $trip->assigned_to) : '#1d6fb8';

            return ['to' => '→ '.($trip->destination?->hub_name ?? 'Hub'), 'cities' => $cityText, 'dot' => $color];
        }

        return ['to' => $prov ?: ($list->isEmpty() ? 'Not set yet' : 'Direct'), 'cities' => $cityText, 'dot' => '#17895e'];
    }

    public static function crew(Model $trip)
    {
        return (static::primed('crew', $trip->id) ?? TripCrew::with('user.workposition')->where('deliverylog_id', $trip->id)->get())->sortBy(fn ($c) => TripFlow::isLead($c) ? 0 : 1)->values();
    }

    /** @return array{label: string, tone: string, when: string} */
    public static function status(Model $trip): array
    {
        $stage = TripFlow::ready() ? TripFlow::stage($trip) : ($trip->is_active ? 'loading' : 'closed');
        $label = TripFlow::STAGES[$stage][0] ?? Str::title($stage);
        $when = match ($stage) {
            'road' => $trip->taken_at ? 'Left '.$trip->taken_at->format('g:i A') : 'On the road',
            'back' => $trip->back_at ? 'Back '.$trip->back_at->format('g:i A') : 'Back at the hub',
            'closed' => $trip->closed_at ? 'Done '.$trip->closed_at->format('M j g:i A') : 'Done',
            'ready' => $trip->ready_at ? 'Locked '.$trip->ready_at->format('g:i A') : 'Locked',
            'waiting' => 'Waits for the truck',
            default => $trip->departure_date ? 'Leaves '.Carbon::parse($trip->departure_date)->format('M j') : '',
        };

        return ['label' => $label, 'tone' => $stage, 'when' => $when];
    }

    /** "How this trip was made" lines for the details panel. */
    public static function how(Deliverylog $trip): array
    {
        $key = static::madeKey($trip);
        $note = static::hasMade() ? $trip->made_note : null;
        $lines = [];
        $lines[] = match ($key) {
            'ai' => ['✦', 'Plan trips with the AI'.($note ? ': “'.$note.'”' : '').'.'],
            'changed' => ['✎', 'Plan trips, changed before Create'.($note ? ': '.$note : '').'.'],
            'plan' => ['✦', ($note ?: (static::isHubTrip($trip) ? 'Plan trips › To hubs' : 'Plan trips')).' (system rules).'],
            default => ['✎', 'Made by hand in Delivery trips › New trip.'],
        };
        if ($trip->plan_why) {
            $lines[] = ['💬', 'Why: '.$trip->plan_why];
        }
        if (static::isHubTrip($trip)) {
            $lines[] = ['⌂', ($trip->destination?->hub_name ?? 'The hub').' delivers the boxes with its own trucks.'];
        }
        if (TripRules::ready()) {
            foreach (TripOverride::where('trip_id', $trip->id)->latest('id')->limit(4)->get() as $o) {
                $lines[] = ['⇄', (TripRules::RULES[$o->rule][0] ?? $o->rule).($o->box ? ' · '.$o->box : '').($o->reason ? ': '.$o->reason : '').' ('.$o->status.')'];
            }
        }

        return $lines;
    }

    /** @return list<ViewColumn> */
    public static function columns(): array
    {
        return [
            ViewColumn::make('trip_number')->label('Trip · made by')->view('filament.trips.list.trip')->searchable()->sortable(),
            ViewColumn::make('goes')->label('Going to')->view('filament.trips.list.goes'),
            ViewColumn::make('truck_view')->label('Truck · crew')->view('filament.trips.list.truck')
                ->searchable(query: fn (Builder $query, string $search) => $query->whereHas('truck', fn ($t) => $t->where('plate_no', 'like', "%{$search}%"))),
            ViewColumn::make('boxes_bar')->label('Boxes')->view('filament.trips.list.boxes'),
            ViewColumn::make('stage_view')->label('Status')->view('filament.trips.list.status'),
        ];
    }

    /** Made by and Going to, as chips above the list. */
    public static function filters(): array
    {
        return [
            Filter::make('made')
                ->schema([ToggleButtons::make('v')->label('Made by')->inline()->options(['all' => 'All', 'ai' => '✦ AI', 'plan' => '✦ Plan trips', 'manual' => '✎ By hand'])->default('all')])
                ->query(function (Builder $query, array $data) {
                    $q = $query;
                    $v = $data['v'] ?? 'all';
                    if ($v === 'all' || ! $v) {
                        return $q;
                    }
                    $hasCities = fn ($w) => $w->select(DB::raw(1))->from('trip_cities')->whereColumn('trip_cities.deliverylog_id', 'deliverylogs.id');
                    $made = static::hasMade();

                    return match ($v) {
                        'ai' => $made ? $q->where('deliverylogs.made_by', 'ai') : $q->whereRaw('1 = 0'),
                        'plan' => $q->where(fn ($w) => $made
                            ? $w->whereIn('deliverylogs.made_by', ['plan', 'changed'])->orWhere(fn ($n) => $n->whereNull('deliverylogs.made_by')->whereExists($hasCities))
                            : $w->whereExists($hasCities)),
                        'manual' => $q->where(fn ($w) => $made
                            ? $w->where('deliverylogs.made_by', 'manual')->orWhere(fn ($n) => $n->whereNull('deliverylogs.made_by')->whereNotExists($hasCities))
                            : $w->whereNotExists($hasCities)),
                        default => $q,
                    };
                })
                ->columnSpan(2)
                ->indicateUsing(fn (array $data) => ($data['v'] ?? 'all') !== 'all' ? 'Made by: '.(['ai' => 'AI', 'plan' => 'Plan trips', 'manual' => 'By hand'][$data['v']] ?? '') : null),
            Filter::make('going')
                ->schema([ToggleButtons::make('v')->label('Going to')->inline()->options(['all' => 'All', 'direct' => 'Direct', 'hub' => 'To hubs'])->default('all')])
                ->query(fn (Builder $query, array $data) => match ($data['v'] ?? 'all') {
                    'direct' => $query->whereColumn('deliverylogs.assigned_to', 'deliverylogs.logistichub_id'),
                    'hub' => $query->whereColumn('deliverylogs.assigned_to', '!=', 'deliverylogs.logistichub_id'),
                    default => $query,
                })
                ->indicateUsing(fn (array $data) => ($data['v'] ?? 'all') !== 'all' ? 'Going to: '.(['direct' => 'Direct', 'hub' => 'To hubs'][$data['v']] ?? '') : null),
        ];
    }

    /** Click a trip: its details on the side. */
    public static function details(): Action
    {
        return Action::make('details')
            ->label('Details')
            ->icon('heroicon-o-ellipsis-horizontal')
            ->iconButton()
            ->slideOver()
            ->modalWidth('lg')
            ->modalHeading(fn (Deliverylog $record) => 'Trip '.$record->trip_number)
            ->modalContent(fn (Deliverylog $record, $livewire) => view('filament.trips.list.details', ['trip' => $record,
                'editUrl' => method_exists($livewire, 'getResource') ? $livewire::getResource()::getUrl('edit', ['record' => $record]) : null]))
            ->modalSubmitAction(false)
            ->modalCancelActionLabel('Close');
    }

    /** All / Planned / Loading / On the road / Done. */
    public static function tabs(Builder $base): array
    {
        $loaded = fn ($w) => $w->select(DB::raw(1))->from('tripinvoices')->where('tripinvoices.is_loaded', true)
            ->where(fn ($x) => $x->whereColumn('tripinvoices.deliverylog_id', 'deliverylogs.id')->orWhereColumn('tripinvoices.deliveryloghub_id', 'deliverylogs.id'));
        $taken = Schema::hasColumn('deliverylogs', 'taken_at');
        $q = [
            'all' => fn (Builder $b) => $b,
            'planned' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNull('deliverylogs.taken_at'))->whereNotExists($loaded),
            'loading' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNull('deliverylogs.taken_at'))->whereExists($loaded),
            'road' => fn (Builder $b) => $b->where('deliverylogs.is_active', true)->when($taken, fn ($x) => $x->whereNotNull('deliverylogs.taken_at'), fn ($x) => $x->whereRaw('1 = 0')),
            'done' => fn (Builder $b) => $b->where('deliverylogs.is_active', false),
        ];
        $labels = ['all' => 'All', 'planned' => 'Planned', 'loading' => 'Loading', 'road' => 'On the road', 'done' => 'Done'];

        return collect($q)->mapWithKeys(fn ($fn, $k) => [$k => Tab::make($labels[$k])
            ->badge(fn () => $fn((clone $base))->count())
            ->modifyQueryUsing(fn (Builder $query) => $fn($query))])->all();
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Deliverylogs/RelationManagers/TripinvoicesRelationManager.php
mkdir -p 'app/Filament/Warehouse/Resources/Deliverylogs/RelationManagers'
cat > 'app/Filament/Warehouse/Resources/Deliverylogs/RelationManagers/TripinvoicesRelationManager.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Filament\Warehouse\Resources\Deliverylogs\RelationManagers;

use App\Filament\Actions\BulkPrintReceipts;
use App\Filament\Exports\TripinvoiceExporter;
use App\Filament\Tables\DeliveryAttemptColumns;
use App\Filament\Tables\TripBoxes;
use App\Filament\Tables\TruckSpotColumn;
use App\Filament\Warehouse\Pages\Hubroute;
use App\Models\Consolidator;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkAction;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\ExportAction;
use Filament\Forms\Components\Select;
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
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Auth;

class TripinvoicesRelationManager extends RelationManager
{
    protected static string $relationship = 'tripinvoices';

    protected static ?string $title = TripBoxes::TITLE;

    /** All / Loaded / Not loaded / Delivered / Problems (board 44b). */
    public function getTabs(): array
    {
        return TripBoxes::tabs('is_loaded', fn () => $this->getRelationship()->getQuery());
    }

    public function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                TextInput::make('trip_number')
                    ->required()
                    ->maxLength(255),
            ]);
    }

    public function table(Table $table): Table
    {
        return $table
            ->modifyQueryUsing(fn (Builder $query) => $query->withCount(['deliveryAttempts', 'deliveryReversals'])->with([...DeliveryAttemptColumns::eagerLoad(), 'invdata.consolidator:id,code,company_name', 'invdata.routearea', 'invdata.container', 'invoiceissue.boxissue', 'deliverylog']))
            // speed: the group checkbox uses the boxes on this page (no query per receiver)
            ->selectCurrentPageOnly()
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
            ->collapsedGroupsByDefault()
            // ->poll('5s')
            ->deferLoading()
            ->recordTitleAttribute('id')
            ->columns([
                TruckSpotColumn::make(),
                TextColumn::make('invdata.consolidator.company_name')
                    ->label('Company'),
                TextColumn::make('deliverylog.trip_number')
                    ->label('Trip Number'),
                //  ->searchable(),
                TextColumn::make('invdata.invoice')
                    ->sortable()
                    ->searchable(isIndividual: true, isGlobal: false)
                    ->label('Invoice No.'),
                DeliveryAttemptColumns::column(),
                TextColumn::make('problem')
                    ->badge()
                    ->color('danger')
                    ->label('Problem')
                    ->getStateUsing(fn ($record) => $record->invoiceissue->pluck('boxissue.issue_type')->filter()->unique()->join(', ') ?: null),
                IconColumn::make('invdata.is_resolved')
                    ->label('Resolved')
                    ->icon(fn ($state) => $state ? 'heroicon-o-check-circle' : null)
                    ->color('success'),
                TextColumn::make('invdata.batchno')
                    ->label('Batch No')
                    ->sortable(),
                TextColumn::make('invdata.is_priority')
                    ->label('Priority')
                    // ->badge()
                    ->formatStateUsing(fn ($state) => $state ? 'PRIORITY' : null)
                    ->color(fn ($state) => $state ? 'success' : null),
                TextColumn::make('invdata.container.batch_year')
                    ->label('Batch Year')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('invdata.sender_name')
                    ->sortable()
                    ->label('Sender'),
                TextColumn::make('invdata.receiver_name')
                    ->sortable()
                    ->label('Receiver'),
                TextColumn::make('invdata.receiver_address')
                    ->label('Address'),
                TextColumn::make('invdata.receiver_province')
                    ->sortable()
                    //   ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Province'),
                TextColumn::make('invdata.receiver_city')
                    //     ->toggleable(isToggledHiddenByDefault: true)
                    ->label('City/Municipality'),
                TextColumn::make('invdata.receiver_barangay')
                    //        ->toggleable(isToggledHiddenByDefault: true)
                    ->label('Barangay'),
                TextColumn::make('invdata.boxtype')
                    ->label('Box Type'),
                // TextColumn::make('invoice.routearea.description')
                //     ->label('Route Area'),
                IconColumn::make('is_loaded')
                    ->label('Loaded')
                    ->color(fn (bool $state) => $state ? 'success' : 'danger')
                    ->icon(fn (bool $state) => match ($state) {
                        true => 'heroicon-o-check-circle',
                        false => 'heroicon-o-x-circle',
                    }),

            ])->searchOnBlur()
            ->persistSearchInSession()
            ->persistColumnSearchesInSession()
            ->filters([

                Filter::make('is_loaded')
                    ->label('Not Loaded')
                    ->toggle()
                    ->query(fn (Builder $query): Builder => $query->where('is_loaded', false)),
                SelectFilter::make('company')
                    ->label('Company')
                    ->multiple()
                    //  ->searchable()
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
                    ->url(fn ($livewire) => Hubroute::getUrl(['ownerRecord' => $livewire->ownerRecord->getKey()])),
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
                    Action::make('Priority')
                        ->label('Mark as Priority')
                        ->color('warning')
                        ->icon(Heroicon::ExclamationTriangle)
                        ->action(function ($record) {
                            $record->invoice()->update([
                                'is_priority' => true,
                            ]);
                            Notification::make()
                                ->title('Invoice marked as priority')
                                ->success()
                                ->send();
                        }),
                    Action::make('Unpriority')
                        ->label('Mark as Unpriority')
                        ->color('danger')
                        ->icon(Heroicon::ExclamationTriangle)
                        ->action(function ($record) {
                            $record->invoice()->update([
                                'is_priority' => false,
                            ]);
                            Notification::make()
                                ->title('Invoice marked as unpriority')
                                ->success()
                                ->send();
                        }),
                    Action::make('Print')
                        ->label('Print')
                        ->color('primary')
                        ->icon('heroicon-o-printer')
                        ->url(fn (Model $record) => route('invoicepdf', $record->invoice_id))
                        ->openUrlInNewTab(),
                    Action::make('Delete')
                        ->label('Remove')
                        ->action(function (Tripinvoice $record): void {
                            try {
                                app(TripAssignment::class)->removeFromDeliveryTrip($record);
                            } catch (\DomainException $exception) {
                                Notification::make()->title($exception->getMessage())->danger()->send();

                                return;
                            }

                            Notification::make()->title('Invoice removed from the trip')->success()->send();
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
                    // BulkAction::make('update_status')
                    //     ->label('Update Status')
                    //                         ->icon(Heroicon::DocumentArrowDown)
                    //                         ->action(function (Collection $records): void {
                    //                             // Transform records to array (only needed fields)
                    //                            // dd($records);
                    //                             $data = $records->map(function ($record) {
                    //                                 return [
                    //                                     'invoice' => $record->invoice,
                    //                                 ];
                    //                             })->toArray();

                    //                             // Send DELETE request
                    //                             // $response = Http::delete('https://apiconnector.test/api/status', [
                    //                             //     'records' => $data
                    //                             // ]);
                    //                             $response = Http::send('DELETE', 'https://apiconnector.test/api/status', [
                    //     'json' => [
                    //         'records' => $data
                    //     ]
                    // ]);
                    //                 //            dump($data);
                    //                             // Debug response if needed
                    //                             if ($response->failed()) {
                    //                                 dd($response->body());
                    //                             }

                    //                             // Optional success feedback
                    //                             Notification::make()
                    //                                 ->title('Status updated successfully')
                    //                                 ->success()
                    //                                 ->send();
                    //                         }),
                    BulkAction::make('delete')
                        ->label('Remove ')
                        ->action(function ($records) {
                            try {
                                foreach ($records as $record) {
                                    app(TripAssignment::class)->removeFromDeliveryTrip($record, returned: false);
                                }
                            } catch (\DomainException $exception) {
                                Notification::make()->title($exception->getMessage())->danger()->send();

                                return;
                            }

                            Notification::make()
                                ->title('Invoices removed from the trip')
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
                            try {
                                foreach ($records as $record) {
                                    app(TripAssignment::class)->removeFromDeliveryTrip($record, returned: true);
                                }
                            } catch (\DomainException $exception) {
                                Notification::make()->title($exception->getMessage())->danger()->send();

                                return;
                            }

                            Notification::make()
                                ->title('Invoices marked as returned')
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

                    BulkAction::make('Move')
                        ->label('Move to Another Trip')
                        ->icon(Heroicon::ArrowRight)
                        ->color('info')
                        ->schema([
                            Select::make('deliverylog_id')
                                ->label('Select Target Trip')
                                ->searchable()
                                ->options(function () {
                                    return Deliverylog::where('is_active', true)
                                        ->where('logistichub_id', Auth::user()->logistichub_id)
                                        ->get()
                                        ->mapWithKeys(function ($record) {
                                            //    dd($record->logistichub->hub_name);
                                            $assignTo = $record->assigned_to ?? 'N/A';
                                            $going_to = Logistichub::where('id', $assignTo)->value('hub_name') ?? 'N/A';

                                            return [
                                                $record->id => "{$record->trip_number} | {$going_to}",
                                            ];
                                        });
                                })
                                ->required(),

                        ])
                        ->action(function (Collection $records, array $data) {

                            $deliverylogdata = Deliverylog::find($data['deliverylog_id']);
                            if ($this->ownerRecord->assigned_to == $deliverylogdata->assigned_to) {
                                foreach ($records as $record) {
                                    $record->update([
                                        'deliverylog_id' => $data['deliverylog_id'],
                                    ]);
                                }
                                Notification::make()
                                    ->title('Invoices moved successfully')
                                    ->success()
                                    ->send();
                            } else {
                                Notification::make()
                                    ->title('Cannot move invoices to a trip assigned to a different Hub')
                                    ->danger()
                                    ->send();
                            }
                            //   $recordIds = $records->pluck('id')->toArray();

                            // Redirect to the move page with the selected record IDs
                            //  redirect()->route('filament.pages.movetripinvoice', ['recordIds' => implode(',', $recordIds)]);
                        }),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Deliverylogs/Tables/DeliverylogsTable.php
mkdir -p 'app/Filament/Warehouse/Resources/Deliverylogs/Tables'
cat > 'app/Filament/Warehouse/Resources/Deliverylogs/Tables/DeliverylogsTable.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Filament\Warehouse\Resources\Deliverylogs\Tables;

use App\Filament\Shared\Trips\TripActions;
use App\Filament\Tables\TripBoardColumns;
use App\Filament\Tables\TripList;
use App\Filament\Warehouse\Pages\SeaShipments;
use App\Filament\Warehouse\Pages\TripFuel;
use App\Filament\Warehouse\Pages\TripStops;
use App\Models\Deliverylog;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\TruckReceipt;
use App\Support\Fuel\Fuel;
use App\Support\Shipping\Islands;
use App\Support\Shipping\Shipments;
use App\Support\Shipping\TruckReceive;
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
use Filament\Tables\Enums\FiltersLayout;
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
            // board 42: one clear row per trip; click a trip for its details on the side
            ->recordUrl(null)
            ->recordAction('details')
            ->defaultSort('created_at', 'desc')
            ->query(Deliverylog::query()->where('logistichub_id', '=', Auth::user()->logistichub_id))
            ->modifyQueryUsing(fn (Builder $query) => TripBoardColumns::withProgress($query, 'delivery'))
            ->columns([...TripList::columns(), ...collect([
                TripActions::stageColumn(),

                TripBoardColumns::status('delivery'),

                TripBoardColumns::progress('delivery'),

                // Partner hub by truck: "Received by Baguio · 2 missing" (Scan app · Receive truck).
                TextColumn::make('hub_received')
                    ->label('Hub received')
                    ->badge()
                    ->color(fn ($state) => str_contains((string) $state, 'missing') ? 'danger' : (str_contains((string) $state, 'Received') ? 'success' : 'warning'))
                    ->visible(fn () => TruckReceive::ready())
                    ->getStateUsing(function ($record) {
                        $r = TruckReceipt::with('hub:id,hub_name')->where('deliverylog_id', $record->id)->get();

                        return $r->isEmpty() ? null : $r->map(fn ($x) => $x->finished_at
                            ? 'Received by '.($x->hub?->hub_name ?? 'hub').($x->missing ? ' · '.$x->missing.' missing' : '')
                            : ($x->hub?->hub_name ?? 'Hub').' receiving…')->join(' / ');
                    }),

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
            ])->map(fn ($c) => $c->toggleable(isToggledHiddenByDefault: true))->all()])
            ->filters([
                ...TripList::filters(),
                TripBoardColumns::filter('delivery'),
                SelectFilter::make('assigned_to')
                    ->label('Which hub')
                    ->options(Logistichub::query()->pluck('hub_name', 'id'))
                    ->searchable()
                    ->preload(),
            ])->deferFilters(false)
            ->filtersLayout(FiltersLayout::AboveContent)->filtersFormColumns(5)
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
                    ->visible(fn ($record): bool => Shipments::ready() && $record->is_active && $record->destination?->is_company
                        && Islands::bySea($record->destination) && ! SeaShipment::where('deliverylog_id', $record->id)->exists())
                    ->url(fn ($record): string => SeaShipments::getUrl(['trip' => $record->id])),
                Action::make('fuel')
                    ->label('Fuel')
                    ->icon('heroicon-o-beaker')
                    ->button()
                    ->color('gray')
                    ->visible(fn (): bool => Fuel::ready())
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
                        // locking is on the Trip page (when ready); here a super admin can only unlock
                        ->hidden(function ($record) {
                            return ! $record->is_lock || ! Auth::user()->is_admin;
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
                    TripActions::release(),
                    TripActions::crew(),
                    EditAction::make()
                        ->label('Edit')
                        ->icon(Heroicon::PencilSquare)
                        ->hidden(function ($record) {
                            return $record->is_lock;
                        }),

                ]),
                TripList::details(),
            ], position: RecordActionsPosition::AfterColumns)
            ->toolbarActions([
                BulkActionGroup::make([
                    //    DeleteBulkAction::make(),

                ]),
            ]);
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Providers/AppServiceProvider.php
mkdir -p 'app/Providers'
cat > 'app/Providers/AppServiceProvider.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Providers;

use App\Models\Consolidator;
use App\Support\Navigation\DispatchNavigationManager;
use App\Support\Photos\PhotoShrinker;
use App\Support\SchemaMemo;
use Filament\Actions\DeleteAction;
use Filament\Forms\Components\FileUpload;
use Filament\Navigation\NavigationManager;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Section;
use Filament\Support\Assets\Css;
use Filament\Support\Assets\Js;
use Filament\Support\Facades\FilamentAsset;
use Filament\Tables\Table;
use Illuminate\Console\Events\CommandFinished;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Events\MigrationEnded;
use Illuminate\Database\Events\MigrationsEnded;
use Illuminate\Database\Events\SchemaLoaded;
use Illuminate\Database\QueryException;
use Illuminate\Database\Schema\Builder;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        // Speed: Schema::hasTable / hasColumn answers are remembered (App\Support\SchemaMemo); forgotten when migrations run.
        $this->app->extend('db.schema', fn ($schema) => $schema instanceof Builder ? new SchemaMemo($schema) : $schema);
    }

    public function boot(): void
    {
        // Side menus: groups in the order of the work, clear names, numbers on what waits (App\Support\Navigation\Menu).
        $this->app->scoped(NavigationManager::class, fn () => new DispatchNavigationManager);

        // Forms are built with Filament schemas, which only pass the fields they render.
        Model::unguard();

        Section::configureUsing(fn (Section $section) => $section->columnSpanFull());

        // Photos are made smaller on the phone before upload (longest side 1600 px), like the
        // Scan app and the Driver app. A 3 MB phone photo becomes a few hundred KB.
        // Non-photo files are not touched; small pictures (logos) are never made bigger.
        FileUpload::configureUsing(fn (FileUpload $upload) => $upload
            ->automaticallyResizeImagesMode('contain')
            ->automaticallyResizeImagesToWidth((string) PhotoShrinker::MAX_SIDE)
            ->automaticallyResizeImagesToHeight((string) PhotoShrinker::MAX_SIDE)
            ->imageResizeUpscale(false));

        // Consistent, roomier tables in every panel.
        Table::configureUsing(fn (Table $table) => $table
            ->paginationPageOptions([10, 25, 50, 100])
            ->defaultPaginationPageOption(25)
            ->striped());

        // Deleting something that is still in use (e.g. a truck that has trips) used to end in a
        // database error page. Show a clear message instead.
        DeleteAction::configureUsing(fn (DeleteAction $action) => $action->using(
            function (Model $record, DeleteAction $action): bool {
                try {
                    return (bool) $record->delete();
                } catch (QueryException $exception) {
                    if (! in_array($exception->getCode(), ['23000', '23503'], true)) {
                        throw $exception;
                    }

                    Notification::make()
                        ->title('Cannot delete this record')
                        ->body('It is still used by other records (for example trips or invoices). Remove those first.')
                        ->danger()
                        ->persistent()
                        ->send();

                    $action->halt();

                    return false;
                }
            },
        ));

        // Queue workers live for hours; start every job with fresh lookups.
        Queue::looping(function () {
            Consolidator::flushNameCache();
            SchemaMemo::reset();
        });

        // Tables changed: forget the remembered Schema answers.
        Event::listen([MigrationsEnded::class, MigrationEnded::class, SchemaLoaded::class], fn () => SchemaMemo::flush());
        Event::listen(CommandFinished::class, function ($e) {
            if (in_array($e->command, ['optimize:clear', 'cache:clear', 'migrate', 'migrate:fresh', 'migrate:rollback', 'migrate:refresh', 'migrate:reset', 'db:wipe'], true)) {
                SchemaMemo::flush();
            }
        });

        FilamentAsset::register([
            Js::make('barcode-scanner', resource_path('js/barcode-scanner.js')),
            Js::make('driver-offline', resource_path('js/driver-offline.js')),
            // Maps & routes: the stops map (Leaflet 1.9.4 + OpenStreetMap), only on the pages that show it.
            // Kept in resources/vendor so the server does not need node_modules (composer runs
            // filament:upgrade, which publishes these files, before any npm step).
            Js::make('leaflet', resource_path('vendor/leaflet/leaflet.js'))->loadedOnRequest(),
            Css::make('leaflet', resource_path('vendor/leaflet/leaflet.css'))->loadedOnRequest(),
            Js::make('trip-map', resource_path('js/trip-map.js'))->loadedOnRequest(),
            Js::make('truck-map', resource_path('js/truck-map.js'))->loadedOnRequest(),
        ]);
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Support/SchemaMemo.php
mkdir -p 'app/Support'
cat > 'app/Support/SchemaMemo.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Support;

use Illuminate\Database\Schema\Builder;

/**
 * Speed: remembers Schema::hasTable / hasColumn / hasColumns answers.
 *
 * Many screens check "is this feature's table there yet?" for every row. On MySQL each check is an
 * information_schema query. The answers are kept for the request and in bootstrap/cache/schema-memo.php,
 * and forgotten whenever migrations run, a table is created, changed or dropped, or on optimize:clear.
 * Every other Schema call goes straight to Laravel.
 */
class SchemaMemo
{
    /** @var array<string, bool> */
    protected static array $memo = [];

    protected static ?int $app = null;

    protected static bool $loaded = false;

    protected static bool $dirty = false;

    public function __construct(protected Builder $schema) {}

    public static function file(): string
    {
        return app()->bootstrapPath('cache/schema-memo.php');
    }

    protected static function useFile(): bool
    {
        return ! app()->runningUnitTests();
    }

    protected function connectionKey(): string
    {
        $c = $this->schema->getConnection();

        return $c->getName().':'.$c->getDatabaseName();
    }

    protected function remember(string $key, \Closure $ask): bool
    {
        if (static::$app !== spl_object_id(app())) {
            static::$app = spl_object_id(app());
            static::$memo = [];
            static::$loaded = false;
        }
        if (! static::$loaded) {
            static::$loaded = true;
            if (static::useFile() && is_file(static::file())) {
                $saved = @include static::file();
                static::$memo = is_array($saved) ? $saved + static::$memo : static::$memo;
            }
        }
        $key = $this->connectionKey().'|'.$key;
        if (! array_key_exists($key, static::$memo)) {
            static::$memo[$key] = (bool) $ask();
            if (static::useFile() && ! static::$dirty) {
                static::$dirty = true;
                app()->terminating(fn () => static::save());
            }
        }

        return static::$memo[$key];
    }

    public static function save(): void
    {
        if (! static::$dirty) {
            return;
        }
        static::$dirty = false;
        $tmp = static::file().'.'.getmypid();
        if (@file_put_contents($tmp, '<?php return '.var_export(static::$memo, true).';', LOCK_EX) !== false) {
            @rename($tmp, static::file());
            if (function_exists('opcache_invalidate')) {
                @opcache_invalidate(static::file(), true);
            }
        }
    }

    /** Read the saved answers again on the next check (long-running queue workers). */
    public static function reset(): void
    {
        static::$memo = [];
        static::$loaded = false;
    }

    /** Forget every answer (migrations ran, a table changed, optimize:clear). */
    public static function flush(): void
    {
        static::$memo = [];
        static::$loaded = true;
        static::$dirty = false;
        if (is_file(static::file())) {
            @unlink(static::file());
            if (function_exists('opcache_invalidate')) {
                @opcache_invalidate(static::file(), true);
            }
        }
    }

    public function hasTable($table)
    {
        return $this->remember('t:'.$table, fn () => $this->schema->hasTable($table));
    }

    public function hasColumn($table, $column)
    {
        return $this->remember('c:'.$table.'.'.strtolower($column), fn () => $this->schema->hasColumn($table, $column));
    }

    public function hasColumns($table, array $columns)
    {
        foreach ($columns as $column) {
            if (! $this->hasColumn($table, $column)) {
                return false;
            }
        }

        return true;
    }

    public function __call($method, $args)
    {
        // anything that can change tables (create, table, drop, rename, ...) forgets the answers
        if (! preg_match('/^(has|get|whenTableHas|whenTableDoesntHave|connection|getConnection)/', $method)) {
            static::flush();
        }

        return $this->schema->{$method}(...$args);
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Support/Shipping/Islands.php
mkdir -p 'app/Support/Shipping'
cat > 'app/Support/Shipping/Islands.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Support\Shipping;

use App\Models\Boxes\WhSection;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Support\Boxes\Sections;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Where a hub is (Luzon, Visayas, Mindanao) and whether boxes go there by sea. Set in
 * Settings → Hubs · island & sea; until then suggested from the provinces of the hub's
 * warehouse section, or from the hub's name.
 */
class Islands
{
    public const ISLANDS = ['luzon' => 'Luzon', 'visayas' => 'Visayas', 'mindanao' => 'Mindanao'];

    public const VISAYAS = ['aklan', 'antique', 'capiz', 'guimaras', 'iloilo', 'negros occidental', 'bohol', 'cebu', 'negros oriental', 'siquijor',
        'biliran', 'eastern samar', 'leyte', 'northern samar', 'samar', 'western samar', 'southern leyte'];

    public const MINDANAO = ['zamboanga del norte', 'zamboanga del sur', 'zamboanga sibugay', 'bukidnon', 'camiguin', 'lanao del norte', 'misamis occidental',
        'misamis oriental', 'davao de oro', 'compostela valley', 'davao del norte', 'davao del sur', 'davao occidental', 'davao oriental', 'cotabato', 'north cotabato',
        'sarangani', 'south cotabato', 'sultan kudarat', 'agusan del norte', 'agusan del sur', 'dinagat islands', 'surigao del norte', 'surigao del sur',
        'basilan', 'lanao del sur', 'maguindanao', 'maguindanao del norte', 'maguindanao del sur', 'sulu', 'tawi-tawi', 'tawi tawi'];

    /** Words in a hub's name, for a first guess. */
    protected const NAMES = [
        'visayas' => ['cebu', 'mandaue', 'lapu', 'iloilo', 'bacolod', 'tacloban', 'dumaguete', 'tagbilaran', 'bohol', 'roxas', 'kalibo', 'ormoc', 'catbalogan', 'leyte', 'samar', 'negros', 'visayas'],
        'mindanao' => ['davao', 'cdo', 'cagayan de oro', 'general santos', 'gensan', 'zamboanga', 'butuan', 'iligan', 'cotabato', 'surigao', 'koronadal', 'ozamiz', 'dipolog', 'pagadian', 'malaybalay', 'valencia', 'mindanao'],
    ];

    public static function ready(): bool
    {
        return Schema::hasColumn('logistichubs', 'by_sea');
    }

    public static function ofProvince(?string $province): string
    {
        $p = Sections::clean($province);

        return in_array($p, self::VISAYAS, true) ? 'visayas' : (in_array($p, self::MINDANAO, true) ? 'mindanao' : 'luzon');
    }

    /** @return array{island: string, from: string} */
    public static function suggest(Logistichub $hub): array
    {
        // speed: asked for every trip row; one answer per hub per request
        static $memo = [null, []];
        if ($memo[0] !== spl_object_id(app())) {
            $memo = [spl_object_id(app()), []];
        }

        return $memo[1][$hub->id.'|'.$hub->hub_name] ??= static::suggestNow($hub);
    }

    protected static function suggestNow(Logistichub $hub): array
    {
        if (Sections::ready()) {
            $prov = WhSection::where('logistichub_id', $hub->id)->get()->flatMap(fn ($s) => (array) $s->provinces)->filter();
            if ($prov->isNotEmpty()) {
                $island = $prov->map(fn ($p) => static::ofProvince($p))->countBy()->sortDesc()->keys()->first();
                $codes = WhSection::where('logistichub_id', $hub->id)->pluck('code')->join(', ');

                return ['island' => $island, 'from' => 'section '.$codes.' · '.$prov->take(3)->join(', ')];
            }
        }
        $name = Str::lower($hub->hub_name.' '.$hub->hub_code);
        foreach (self::NAMES as $island => $words) {
            foreach ($words as $w) {
                if (str_contains($name, $w)) {
                    return ['island' => $island, 'from' => 'the name "'.$hub->hub_name.'"'];
                }
            }
        }

        return ['island' => 'luzon', 'from' => 'nothing found: Luzon'];
    }

    public static function islandOf(Logistichub $hub): string
    {
        return static::ready() && $hub->island ? $hub->island : static::suggest($hub)['island'];
    }

    /** Boxes for this hub go by sea (or RoRo): set by hand, else Visayas and Mindanao. */
    public static function bySea(Logistichub $hub): bool
    {
        if (static::ready() && $hub->by_sea !== null) {
            return (bool) $hub->by_sea;
        }

        return static::islandOf($hub) !== 'luzon';
    }

    /** The usual arrival port: set on the hub, else the port of its last shipment. */
    public static function port(Logistichub $hub): ?string
    {
        if (static::ready() && $hub->port) {
            return $hub->port;
        }

        return Shipments::ready() ? SeaShipment::where('logistichub_id', $hub->id)->whereNotNull('port_to')->latest('id')->value('port_to') : null;
    }

    /** Ids of the hubs reached by sea. */
    public static function seaHubIds(): array
    {
        return Logistichub::where('is_company', true)->get()->filter(fn ($h) => static::bySea($h))->pluck('id')->all();
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Support/TripFlow.php
mkdir -p 'app/Support'
cat > 'app/Support/TripFlow.php' <<'DISPATCH_FILE_END_10'
<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\TripCrew;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * A trip from plan to closed: Planned → Loading → Ready → On the road → Back → Closed.
 * Each trip keeps its own crew (copied from the truck team). The trip closes and the truck is
 * released by itself when every box is delivered or returned.
 */
class TripFlow
{
    /** key => [label, who moves it on, colour] */
    public const STAGES = [
        'waiting' => ['Next trip · waits for the truck', 'Automatic', 'gray'],
        'planned' => ['Planned', 'Office', 'info'],
        'loading' => ['Loading', 'Warehouse', 'warning'],
        'ready' => ['Ready', 'Office locked it', 'primary'],
        'road' => ['On the road', 'Driver', 'success'],
        'back' => ['Back', 'Driver', 'warning'],
        'closed' => ['Closed', 'Automatic', 'gray'],
    ];

    public const RELEASE_REASONS = [
        'done' => 'Trip done',
        'hub' => 'Boxes handed to the partner hub',
        'broke_down' => 'Truck broke down',
        'cancelled' => 'Trip cancelled',
        'other' => 'Other',
    ];

    public const SWAP_REASONS = ['sick' => 'Sick', 'day_off' => 'Day off', 'other_truck' => 'On another truck', 'other' => 'Other'];

    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Schema::hasTable('trip_crews') && Schema::hasColumn('deliverylogs', 'taken_at');
    }

    public static function queueReady(): bool
    {
        static $ready;

        return $ready ??= Schema::hasColumn('deliverylogs', 'waits_for');
    }

    // ------------------------------------------------------------------ next trip waiting

    /** Trips not waiting for another trip that still runs (the trip they waited for may be closed by hand). */
    public static function notWaiting($q)
    {
        return $q->where(fn ($q) => $q->whereNull('waits_for')
            ->orWhereIn('waits_for', Deliverylog::query()->select('id')->where('is_active', false)));
    }

    /** The trip that still runs on this truck (another one than $except). */
    public static function runningOn(?int $truckId, ?int $except = null): ?Deliverylog
    {
        return $truckId ? Deliverylog::where('truck_id', $truckId)->where('is_active', true)
            ->when($except, fn ($q) => $q->whereKeyNot($except))
            ->when(static::queueReady(), fn ($q) => static::notWaiting($q))->oldest('id')->first() : null;
    }

    /** Trips loaded once for a whole list (speed): [app id, id => trip]. Set by known(). */
    protected static array $known = [null, [], []];

    /** Remember these trips' "waits for" trips for this request, so stage() needs no query per row. */
    public static function known(iterable $trips): void
    {
        $ids = collect($trips)->pluck('waits_for')->filter()->unique()->values()->all();
        $tripIds = collect($trips)->pluck('id')->all();
        static::$known = [spl_object_id(app()), $ids && static::queueReady() ? Deliverylog::whereIn('id', $ids)->get()->keyBy('id')->all() : [],
            // trip id => has a loaded box (for stage(): loading)
            array_fill_keys(Tripinvoice::whereIn('deliverylog_id', $tripIds)->where('is_loaded', true)->distinct()->pluck('deliverylog_id')->all(), true) + array_fill_keys($tripIds, false)];
    }

    /** This trip waits for the truck's current trip to close. */
    public static function waitsFor(Deliverylog $trip): ?Deliverylog
    {
        if (! static::queueReady() || ! $trip->waits_for) {
            return null;
        }
        $before = static::$known[0] === spl_object_id(app()) && isset(static::$known[1][$trip->waits_for])
            ? static::$known[1][$trip->waits_for] : Deliverylog::find($trip->waits_for);

        return $before && $before->is_active ? $before : null;
    }

    /** The next trip planned for the same truck, waiting for this one. */
    public static function nextAfter(Deliverylog $trip): ?Deliverylog
    {
        return static::queueReady() ? Deliverylog::where('waits_for', $trip->id)->where('is_active', true)->oldest('id')->first() : null;
    }

    /** Truck list for a trip: free trucks, and trucks still out (the trip then waits for them). */
    public static function truckOptions(?int $hubId, ?int $tripId = null): array
    {
        // Own trucks, and rental trucks booked today (own first).
        $trucks = Rentals::usable(Truck::query()->where('is_active', 1)->when($hubId, fn ($q) => $q->where('logistichub_id', $hubId)))
            ->get()->sortBy(fn ($t) => [$t->isRental() ? 1 : 0, $t->plate_no])->values();

        return $trucks->mapWithKeys(function ($t) use ($tripId) {
            $on = $t->is_assigned ? static::runningOn($t->id, $tripId) : null;
            if ($t->is_assigned && ! $on && ! static::queueReady()) {
                return [];
            }

            return [$t->id => $t->plate_no.($t->isRental() ? ' · rental, '.(Rentals::rateText($t) ?: 'booked today') : '').($on ? ' · on '.$on->trip_number.' (this trip waits for it)' : '')];
        })->all();
    }

    // ------------------------------------------------------------------ steps

    public static function stage(Deliverylog $trip): string
    {
        if (! $trip->is_active) {
            return 'closed';
        }
        if (static::waitsFor($trip)) {
            return 'waiting';
        }
        if (static::ready() && $trip->back_at) {
            return 'back';
        }
        if (static::ready() && $trip->taken_at) {
            return 'road';
        }
        if ($trip->is_lock) {
            return 'ready';
        }
        $known = static::$known[0] === spl_object_id(app()) && array_key_exists($trip->id, static::$known[2]) ? static::$known[2][$trip->id] : null;
        if ($trip->is_current || ($known ?? Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->exists())) {
            return 'loading';
        }

        return 'planned';
    }

    public static function label(Deliverylog $trip): string
    {
        return static::STAGES[static::stage($trip)][0];
    }

    /** The leadman (or anyone on the crew) takes the trip: it is on the road, with the box count confirmed. */
    public static function take(Deliverylog $trip, ?User $by = null): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        $by ??= Auth::user();
        $trip->forceFill(['taken_at' => now(), 'taken_by' => $by?->id, 'taken_boxes' => static::boxes($trip)->count(), 'is_current' => true])->save();
    }

    /** The driver is back at the hub; boxes not delivered are scanned back with Return boxes. */
    public static function back(Deliverylog $trip): void
    {
        if (! static::ready() || $trip->back_at) {
            return;
        }
        $trip->forceFill(['back_at' => now(), 'taken_at' => $trip->taken_at ?? now()])->save();
        static::maybeClose($trip->fresh());
    }

    /** Boxes the trip still carries (main trip or a partner hub's own trip). */
    public static function boxes(Deliverylog $trip)
    {
        return Tripinvoice::query()->where(fn ($q) => $q->where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id));
    }

    /** Boxes still to deliver or return. Boxes a partner hub received off this truck count as done. */
    public static function left(Deliverylog $trip): int
    {
        $handed = TruckReceiptReady::finishedHubs($trip->id);

        return static::boxes($trip)->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->when($handed, fn ($q) => $q->where(fn ($q) => $q->whereNull('logistichub_id')->orWhereNotIn('logistichub_id', $handed)->orWhere('deliveryloghub_id', $trip->id)))
            ->count();
    }

    /** Close the trip and free the truck when nothing is left: every box delivered, returned or received by the hub. */
    public static function maybeClose(?Deliverylog $trip): bool
    {
        if (! $trip || ! static::ready() || ! $trip->is_active || ! $trip->truck_id) {
            return false;
        }
        // Every box delivered, returned (taken off the trip) or received by the partner hub.
        $total = static::boxes($trip)->count();
        if ($total === 0 ? ! $trip->back_at : static::left($trip) > 0) {
            return false;
        }
        static::release($trip, 'done', auto: true);

        return true;
    }

    /** Free the truck and close the trip (by itself, or by the office with a reason). */
    public static function release(Deliverylog $trip, string $reason = 'done', bool $auto = false): void
    {
        app(TripAssignment::class)->releaseTruck($trip);
        if (static::ready()) {
            $trip->forceFill(['closed_at' => now(), 'release_reason' => $auto ? 'auto' : $reason])->saveQuietly();
        }
        // The next trip waiting for this truck starts now: the crew sees it right away.
        if ($next = static::nextAfter($trip)) {
            $next->forceFill(['waits_for' => null])->saveQuietly();
            // More trips planned for this truck: they now wait for the one that just started, in order.
            Deliverylog::where('waits_for', $trip->id)->where('is_active', true)->whereKeyNot($next->id)->update(['waits_for' => $next->id]);
            $trip->truck?->update(['is_assigned' => true]);
        }
    }

    // ------------------------------------------------------------------ crew of the trip

    /** Copy the truck team onto the trip, when it has no crew yet. */
    public static function copyCrew(Deliverylog $trip): void
    {
        if (! static::ready() || ! $trip->truck_id || TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            return;
        }
        // Only active people: someone made inactive stays off new trips.
        $users = User::with('workposition')->where('is_active', true)->whereIn('id', Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew'))->get();
        foreach ($users as $u) {
            TripCrew::firstOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $u->id], ['role' => $u->workposition?->position_description]);
        }
    }

    /** The truck changed before the trip left: take the new truck's team. */
    public static function truckChanged(Deliverylog $trip, ?int $oldTruckId = null): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        // The old truck's team leaves the trip; people the office picked by hand stay.
        $oldTeam = $oldTruckId ? Truckcrew::where('truck_id', $oldTruckId)->pluck('crew') : collect();
        TripCrew::where('deliverylog_id', $trip->id)->whereNull('replaces_user_id')->whereIn('user_id', $oldTeam)->delete();
        if (! TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            static::copyCrew($trip);
        }
    }

    /** Someone joined or left the truck team: update the trips of the truck that did not leave yet. */
    public static function teamChanged(int $truckId, int $userId, bool $joined): void
    {
        if (! static::ready() || ! $truckId || ! $userId || ($joined && ! User::whereKey($userId)->where('is_active', true)->exists())) {
            return;
        }
        $trips = Deliverylog::where('truck_id', $truckId)->where('is_active', true)->whereNull('taken_at')->pluck('id');
        foreach ($trips as $tripId) {
            if ($joined) {
                if (! TripCrew::where('deliverylog_id', $tripId)->where('replaces_user_id', $userId)->exists()) {
                    TripCrew::firstOrCreate(['deliverylog_id' => $tripId, 'user_id' => $userId], ['role' => User::find($userId)?->workposition?->position_description]);
                }
            } else {
                TripCrew::where('deliverylog_id', $tripId)->where('user_id', $userId)->whereNull('replaces_user_id')->delete();
            }
        }
    }

    /** @return Collection<int, TripCrew> */
    public static function crew(Deliverylog $trip): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        static::copyCrew($trip);

        return TripCrew::with('user.workposition', 'replaces')->where('deliverylog_id', $trip->id)->orderBy('id')->get()
            ->sortBy(fn ($c) => static::isLead($c) ? 0 : 1)->values();
    }

    public static function isLead(TripCrew $c): bool
    {
        return Str::contains(Str::lower((string) ($c->role ?? $c->user?->workposition?->position_description)), 'lead');
    }

    /** Who may tap "I take the trip": the leadman; anyone on the crew when there is no leadman. */
    public static function canTake(Deliverylog $trip, User $user): bool
    {
        $crew = static::crew($trip);
        $leads = $crew->filter(fn ($c) => static::isLead($c));

        return ($leads->isNotEmpty() ? $leads : $crew)->contains(fn ($c) => (int) $c->user_id === (int) $user->id);
    }

    /**
     * Set the crew for this trip only. People not in the truck team are marked as replacing
     * the team members left out.
     *
     * @param  list<int>  $userIds
     */
    public static function setCrew(Deliverylog $trip, array $userIds, ?string $reason = null): void
    {
        $userIds = array_values(array_unique(array_map('intval', $userIds)));
        $team = Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew')->map(fn ($i) => (int) $i)->unique()->values()->all();
        $out = array_values(array_diff($team, $userIds));
        TripCrew::where('deliverylog_id', $trip->id)->whereNotIn('user_id', $userIds)->delete();
        $users = User::with('workposition')->whereIn('id', $userIds)->get()->keyBy('id');
        foreach ($userIds as $i => $id) {
            $isNew = ! in_array($id, $team, true);
            TripCrew::updateOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $id], [
                'role' => $users[$id]?->workposition?->position_description,
                'replaces_user_id' => $isNew ? ($out[$i] ?? $out[0] ?? null) : null,
                'reason' => $isNew ? $reason : null,
            ]);
        }
    }

    /** The trip a crew member works on now: newest active trip with them on its crew (or their truck's). */
    public static function tripFor(User $user): ?Deliverylog
    {
        if (static::ready()) {
            $trip = Deliverylog::with('truck')->where('is_active', true)
                ->when(static::queueReady(), fn ($q) => static::notWaiting($q))
                ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('id')->first();
            if ($trip) {
                return $trip;
            }
        }
        $truckId = Truckcrew::where('crew', $user->getKey())->latest('id')->value('truck_id');
        if (! $truckId) {
            return null;
        }
        $trip = Deliverylog::with('truck')->where('truck_id', $truckId)->where('is_active', true)
            ->when(static::queueReady(), fn ($q) => static::notWaiting($q))->latest('id')->first();
        // Someone replaced this person on that trip: it is not theirs.
        if ($trip && static::ready() && TripCrew::where('deliverylog_id', $trip->id)->exists()
            && ! TripCrew::where('deliverylog_id', $trip->id)->where('user_id', $user->id)->exists()) {
            return null;
        }

        return $trip;
    }

    /** The trip that closed in the last 12 hours, for the "Trip done" screen. */
    public static function justClosedFor(User $user): ?Deliverylog
    {
        if (! static::ready()) {
            return null;
        }

        return Deliverylog::with('truck')->where('is_active', false)->where('closed_at', '>=', now()->subHours(12))
            ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('closed_at')->first();
    }

    // ------------------------------------------------------------------ warnings (crew board)

    /** Crew people of the hub (null = all hubs). */
    public static function crewPeople(int|false|null $hub): Collection
    {
        return User::with('workposition')->where('is_crew', true)->where('is_active', true)
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))
            ->when($hub === false, fn ($q) => $q->whereRaw('1 = 0'))
            ->orderBy('first_name')->get();
    }

    /**
     * What needs a look now: trips ready but not taken, trucks back with boxes not returned,
     * trucks out very long, crew without a truck, trucks on a trip without crew.
     *
     * @return list<array{tone: string, text: string}>
     */
    public static function warnings(int|false|null $hub): array
    {
        if (! static::ready() || $hub === false) {
            return [];
        }
        $out = [];
        $trips = Deliverylog::with('truck:id,plate_no')->where('is_active', true)->whereNotNull('truck_id')
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->get();
        foreach ($trips as $t) {
            $stage = static::stage($t);
            if ($stage === 'ready' && $t->ready_at && $t->ready_at->lt(now()->subMinutes(30))) {
                $out[] = ['kind' => 'ready', 'trip' => $t, 'tone' => 'warn', 'text' => 'Trip '.$t->trip_number.' is ready since '.$t->ready_at->format('g:i A').' · nobody took it yet.'];
            }
            if ($stage === 'back' && $t->back_at?->lt(now()->subHours(2)) && ($left = static::left($t)) > 0) {
                $out[] = ['kind' => 'back', 'trip' => $t, 'tone' => 'warn', 'text' => 'Truck '.$t->truck?->plate_no.' is back since '.$t->back_at->format('g:i A').' · '.$left.' '.str('box')->plural($left).' not returned yet (Return boxes).'];
            }
            if ($stage === 'road' && $t->taken_at?->lt(now()->subHours(14))) {
                $out[] = ['kind' => 'road', 'trip' => $t, 'tone' => 'warn', 'text' => 'Truck '.$t->truck?->plate_no.' is on trip '.$t->trip_number.' since '.$t->taken_at->format('M j g:i A').'. Still out?'];
            }
            if (in_array($stage, ['ready', 'road'], true) && ! TripCrew::where('deliverylog_id', $t->id)->exists()) {
                $out[] = ['kind' => 'nocrew', 'trip' => $t, 'tone' => 'bad', 'text' => 'Trip '.$t->trip_number.' has no crew.'];
            }
        }
        foreach (Truckcrew::with('member', 'truck')->whereHas('member', fn ($q) => $q->where('is_active', false))->get() as $c) {
            if ($hub === null || (int) $c->truck?->logistichub_id === $hub) {
                $out[] = ['kind' => 'inactive', 'truck_id' => $c->truck_id, 'user_id' => $c->crew, 'tone' => 'warn', 'text' => ($c->member?->full_name ?? 'Someone').' is inactive but still on the team of '.($c->truck?->plate_no ?? 'a truck').'.'];
            }
        }
        // On the team of an active truck (a truck made inactive does not count).
        $onTruck = Truckcrew::whereHas('truck', fn ($q) => $q->where('is_active', true))->pluck('crew')->map(fn ($i) => (int) $i)->all();
        foreach (static::crewPeople($hub)->reject(fn ($u) => in_array((int) $u->id, $onTruck, true)) as $u) {
            $out[] = ['kind' => 'notruck', 'tone' => 'info', 'text' => $u->full_name.' has no truck.'];
        }

        return $out;
    }
}
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- app/Support/Trips/CityTrips.php
mkdir -p 'app/Support/Trips'
cat > 'app/Support/Trips/CityTrips.php' <<'DISPATCH_FILE_END_11'
<?php

namespace App\Support\Trips;

use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\TripCity;
use App\Models\Tripinvoice;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Ai\Ai;
use App\Support\Ai\AiUnavailable;
use App\Support\Ai\TripPlanner;
use App\Support\Hubs\HubAreas;
use App\Support\Maps\Barangays;
use App\Support\Rentals;
use App\Support\TripFlow;
use App\Support\TruckSpace;
use App\Support\Warehouses\Coverage;
use Filament\Facades\Filament;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Trips by city: nearby cities of one province fill one truck. A trip keeps its cities;
 * waiting boxes of those cities join when they are scanned onto the truck.
 */
class CityTrips
{
    public const DEFAULT_CAPACITY = 50;

    /** $atHub: a partner hub plans its own trips (boxes that arrived at the hub; added at Create). */
    public function __construct(public readonly User $user, public readonly bool $atHub = false) {}

    public static function ready(): bool
    {
        static $ready = null;

        return $ready ??= Schema::hasTable('trip_cities');
    }

    public static function isCityTrip(?Deliverylog $trip): bool
    {
        return $trip && static::ready() && TripCity::where('deliverylog_id', $trip->id)->exists();
    }

    /** Kept for this request: Plan trips asks for the same lists many times in one click. */
    protected ?TripPlanner $plannerMemo = null;

    protected ?Collection $placesMemo = null;

    protected ?array $coveredMemo = null;

    protected ?Collection $trucksMemo = null;

    protected function planner(): TripPlanner
    {
        return $this->plannerMemo ??= new TripPlanner($this->user, $this->atHub ? 'hub' : 'delivery');
    }

    /**
     * Waiting boxes by city: [key, province, city, boxes, space, receivers, biggest, days, prio, retry].
     */
    public function places(): Collection
    {
        return $this->placesMemo ??= $this->freshPlaces();
    }

    /** How these trips are made (Delivery trips › Made by): ['ai' => bool, 'instruction' => what was typed, 'reason' => why the plan was changed]. */
    public array $made = [];

    /** made_by / made_note of one planned trip. */
    protected function madeFields(array $t, string $default = 'plan'): array
    {
        if (! Schema::hasColumn('deliverylogs', 'made_by')) {
            return [];
        }
        if (! empty($t['changed'])) {
            return ['made_by' => 'changed', 'made_note' => Str::limit(trim(($t['changedNote'] ?? 'changed').(! empty($this->made['reason']) ? '. Reason: '.$this->made['reason'] : '')), 295, '')];
        }
        if (! empty($this->made['ai']) && filled($this->made['instruction'] ?? null)) {
            return ['made_by' => 'ai', 'made_note' => Str::limit((string) $this->made['instruction'], 295, '')];
        }

        return ['made_by' => $default, 'made_note' => null];
    }

    /** Cities of a hub's area delivered direct instead (keys "hubId|province|city"), set by Plan trips. */
    public array $direct = [];

    protected function isDirect(array $u): bool
    {
        if ($this->atHub) {
            // at a hub: only the boxes of its own area (a box of another hub came by mistake)
            return ! $u['hub'] || (int) $u['hub'] === (int) $this->user->logistichub_id;
        }

        return ! $u['hub'] || in_array($u['hub'].'|'.Str::lower($u['province']).'|'.Barangays::cityKey($u['city']), $this->direct, true);
    }

    /** Days a box has waited, per box id. */
    protected ?Collection $sinceMemo = null;

    protected function daysOf(array $u): int
    {
        if (! $this->sinceMemo) {
            $ids = $this->planner()->units()->flatMap(fn ($x) => $x['ids']);
            $this->sinceMemo = $ids->isEmpty() ? collect() : ($this->atHub
                ? Tripinvoice::whereIn('id', $ids)->get(['id', 'created_at'])->mapWithKeys(fn ($t) => [$t->id => $t->created_at])
                : Invoice::whereIn('id', $ids)->get(['id', 'verified_at', 'created_at'])->mapWithKeys(fn ($i) => [$i->id => $i->verified_at ?? $i->created_at]));
        }

        return (int) (collect($u['ids'])->map(fn ($id) => $this->sinceMemo[$id] ?? null)->filter()->map(fn ($d) => (int) floor(Carbon::parse($d)->diffInHours(now()) / 24))->max() ?? 0);
    }

    protected function freshPlaces(): Collection
    {
        // only the boxes the warehouse delivers direct; a hub's boxes are planned in "To hubs"
        $units = $this->planner()->units()->map(fn ($u) => $u + ['hub' => null])->filter(fn ($u) => $this->isDirect($u));
        $days = fn ($u) => $this->daysOf($u);

        return $units->groupBy(fn ($u) => Str::lower($u['province']).'|'.Barangays::cityKey($u['city']))->map(fn ($g, $k) => [
            'key' => $k, 'province' => $g->first()['province'], 'city' => $g->first()['city'],
            'boxes' => $g->sum('n'), 'space' => (int) ceil($g->sum('space')), 'receivers' => $g->count(), 'biggest' => (int) ceil($g->max('space')),
            'days' => (int) $g->map($days)->max(), 'prio' => $g->sum('prio'), 'retry' => $g->sum('retry'),
            'unclear' => $g->first()['city'] === 'No city',
            'via' => $this->atHub ? [] : $g->pluck('hub')->filter()->unique()->values()->all(),
        ])->values();
    }

    /**
     * Boxes a partner hub delivers, by hub and city.
     *
     * @return Collection<int, array{hub: int, name: string, boxes: int, space: int, days: int, prio: int, cities: Collection}>
     */
    public function hubPlaces(): Collection
    {
        if ($this->atHub) {
            return collect();
        }
        $units = $this->planner()->units()->map(fn ($u) => $u + ['hub' => null])->reject(fn ($u) => $this->isDirect($u));
        $names = Logistichub::whereIn('id', $units->pluck('hub')->unique())->pluck('hub_name', 'id');

        return $units->groupBy('hub')->map(function ($g, $hub) use ($names) {
            $cities = $g->groupBy(fn ($u) => Str::lower($u['province']).'|'.Barangays::cityKey($u['city']))->map(fn ($c, $k) => [
                'key' => $k, 'province' => $c->first()['province'], 'city' => $c->first()['city'], 'boxes' => $c->sum('n'),
                'space' => (int) ceil($c->sum('space')), 'days' => (int) $c->map(fn ($u) => $this->daysOf($u))->max(), 'prio' => $c->sum('prio') + $c->sum('retry'),
            ])->sortBy(fn ($c) => [-$c['prio'], -$c['days'], -$c['boxes']])->values();

            return ['hub' => (int) $hub, 'name' => (string) ($names[$hub] ?? 'Hub #'.$hub), 'boxes' => $cities->sum('boxes'), 'space' => $cities->sum('space'),
                'days' => (int) $cities->max('days'), 'prio' => $cities->sum('prio'), 'cities' => $cities];
        })->sortBy(fn ($h) => [-$h['prio'], -$h['days'], -$h['boxes']])->values();
    }

    /** Boxes for a hub still on the way (in containers not unloaded yet), for "wait for the next container". */
    public function comingFor(int $hubId): int
    {
        $map = HubAreas::map();
        if (! in_array($hubId, $map, true)) {
            return 0;
        }

        return Invoice::query()->where('is_verified', false)->where('is_delivered', false)->where('created_at', '>=', now()->subDays(60))->limit(3000)->get()
            ->filter(fn ($i) => HubAreas::hubOf($i, $map) === $hubId)->count();
    }

    /**
     * Trips to the hubs: one trip per hub, or more when the boxes do not fit one truck.
     * Whole cities go together (a city bigger than a truck goes on two trips: the truck-full check stops each truck).
     *
     * @param  array<int>  $usedTrucks  trucks already in the direct plan
     * @return list<array>
     */
    public function planHubs(array $usedTrucks = []): array
    {
        $trucks = $this->trucks();
        $free = $trucks->where('state', 'free')->reject(fn ($t) => in_array($t['id'], $usedTrucks, true))->values();
        $busy = $trucks->where('state', 'busy')->values();
        $fi = 0;
        $out = [];
        $open = $this->hubTripsOpen();
        foreach ($this->hubPlaces() as $h) {
            if (isset($open[$h['hub']])) {
                // a trip to this hub is open: its boxes join it when scanned
                $out[] = $h + ['trips' => [], 'coming' => 0, 'tip' => 'On '.implode(', ', $open[$h['hub']]).': boxes join when scanned onto the truck.', 'wait' => false, 'open' => $open[$h['hub']]];

                continue;
            }
            $slot = $free[$fi] ?? null;
            $cap = $slot['capacity'] ?? self::DEFAULT_CAPACITY;
            // first fit: each city (most urgent first) goes on the first trip with room, so trucks fill up;
            // a city bigger than a truck goes on more trips (the truck-full check stops each truck)
            $parts = [];
            foreach ($h['cities'] as $c) {
                $left = $c['space'];
                while ($left > 0) {
                    $fit = null;
                    foreach ($parts as $pi => $pt) {
                        if ($cap - $pt['load'] >= min($left, $cap)) {
                            $fit = $pi;
                            break;
                        }
                    }
                    if ($fit === null) {
                        $parts[] = ['cities' => [], 'load' => 0];
                        $fit = array_key_last($parts);
                    }
                    $take = min($left, $cap - $parts[$fit]['load']);
                    $parts[$fit]['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'province' => $c['province'],
                        'boxes' => $take === $c['space'] ? $c['boxes'] : (int) round($c['boxes'] * $take / max(1, $c['space'])), 'space' => $take];
                    $parts[$fit]['load'] += $take;
                    $left -= $take;
                }
            }
            $trips = [];
            foreach ($parts as $n => $pt) {
                $t = $free[$fi] ?? null;
                if ($t) {
                    $fi++;
                }
                $trips[] = ['cities' => $pt['cities'], 'load' => $pt['load'], 'cap' => $t['capacity'] ?? $cap, 'truck_id' => $t['id'] ?? null, 'plate' => $t['plate'] ?? null,
                    'when' => $t ? 'now' : 'later'];
            }
            $coming = $this->comingFor($h['hub']);
            $small = $h['space'] < $cap * 0.3;
            $tip = match (true) {
                $small && $coming > 0 && $h['prio'] === 0 => 'Wait: only '.$h['boxes'].' boxes; '.$coming.' more are on the way. One trip instead of two.',
                $small && $h['prio'] === 0 && $h['days'] < 3 => 'Small: only '.$h['boxes'].' boxes. Wait for more, or send if the hub needs them.',
                count($trips) > 1 && collect($trips)->contains('when', 'later') => 'Not enough free trucks: Trip 1 now with the priority and oldest boxes, the rest '.($coming ? 'with the next container' : 'when a truck is free').'.',
                count($trips) > 1 => count($trips).' trips: '.$h['boxes'].' boxes do not fit one truck. Priority and oldest on Trip 1.',
                $h['prio'] > 0 => 'Send today: '.$h['prio'].' priority or tried-before '.Str::plural('box', $h['prio']).', oldest '.$h['days'].' '.Str::plural('day', $h['days']).'.',
                default => 'Send: '.$h['boxes'].' boxes, oldest '.$h['days'].' '.Str::plural('day', $h['days']).'.',
            };
            if (! $free->count() && $busy->isNotEmpty()) {
                $tip .= ' No free truck now: '.$busy->first()['plate'].' comes back'.($busy->first()['on'] ? ' from '.$busy->first()['on'] : '').'.';
            }
            $out[] = $h + ['trips' => $trips, 'coming' => $coming, 'tip' => $tip, 'wait' => $small && $h['prio'] === 0, 'open' => []];
        }

        return $out;
    }

    /**
     * Make trips to a hub. Boxes join when scanned onto the truck (only boxes of this hub's cities).
     *
     * @return list<array{id: int, number: string, truck: ?string}>
     */
    public function createHub(int $hubId, array $trips, Carbon $date, ?string $why = null): array
    {
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['cities'])) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date, $hubId, $why) {
                $truck = ! empty($t['truck_id']) ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $hubId, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) $why, 295), 'plan_space' => (int) $t['load'],
                ] + $this->madeFields([]));
                foreach (collect($t['cities'])->unique('key') as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $c['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'),
                        'planned_boxes' => (int) $c['boxes'], 'hub_id' => $hubId]);
                }
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }

        return $made;
    }

    /**
     * Customers with 2+ boxes in these cities: kept together on the trip.
     *
     * @return list<array{name: string, city: string, n: int, missing: int}>
     */
    public function sets(array $cityKeys): array
    {
        $keys = array_flip($cityKeys);
        $units = $this->planner()->units()->filter(fn ($u) => isset($keys[Str::lower($u['province']).'|'.Barangays::cityKey($u['city'])]) && $u['n'] >= 2);
        $out = [];
        foreach ($units as $u) {
            $invIds = $this->atHub ? Tripinvoice::whereIn('id', $u['ids'])->pluck('invoice_id') : $u['ids'];
            $setKeys = Invoice::whereIn('id', $invIds)->pluck('set_key')->filter()->unique();
            $missing = $setKeys->isEmpty() ? 0 : Invoice::whereIn('set_key', $setKeys)->where('is_verified', false)->where('is_delivered', false)->count();
            $out[] = ['name' => $u['name'], 'city' => $u['city'], 'n' => $u['n'], 'missing' => $missing];
        }

        return collect($out)->sortBy(fn ($x) => [$x['missing'] ? 0 : 1, -$x['n']])->take(4)->values()->all();
    }

    /** Cities already on an open trip (planned or loading, not locked): city key => trip number. */
    public function covered(): array
    {
        return $this->coveredMemo ??= $this->freshCovered();
    }

    /** At a hub: boxes of another hub's area that came here by mistake. */
    public function notMine(): int
    {
        return $this->atHub ? $this->planner()->units()->filter(fn ($u) => ($u['hub'] ?? null) && (int) $u['hub'] !== (int) $this->user->logistichub_id)->sum('n') : 0;
    }

    protected function freshCovered(): array
    {
        if (! static::ready() || $this->atHub) {
            return [];
        }

        return TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->where('d.logistichub_id', $this->user->logistichub_id)
            ->when(Schema::hasColumn('trip_cities', 'hub_id'), fn ($q) => $q->whereNull('trip_cities.hub_id'))
            ->get(['trip_cities.province', 'trip_cities.city_key', 'd.trip_number'])
            ->mapWithKeys(fn ($r) => [Str::lower((string) $r->province).'|'.$r->city_key => $r->trip_number])->all();
    }

    /**
     * Open trips to each hub (not locked yet): hub id => trip numbers.
     *
     * @return array<int, list<string>>
     */
    public function hubTripsOpen(): array
    {
        if (! static::ready() || ! Schema::hasColumn('trip_cities', 'hub_id')) {
            return [];
        }

        return TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->where('d.logistichub_id', $this->user->logistichub_id)->whereNotNull('trip_cities.hub_id')->whereColumn('d.assigned_to', 'trip_cities.hub_id')
            ->get(['trip_cities.hub_id', 'd.trip_number'])->groupBy('hub_id')->map(fn ($g) => $g->pluck('trip_number')->unique()->values()->all())->all();
    }

    /** Trucks of the hub: free, out on a trip, kept, or off. */
    public function trucks(): Collection
    {
        return $this->trucksMemo ??= $this->freshTrucks();
    }

    protected function freshTrucks(): Collection
    {
        $all = Truck::where('logistichub_id', $this->user->logistichub_id)->orderBy('plate_no')->get();
        $usable = Rentals::usable(Truck::where('logistichub_id', $this->user->logistichub_id)->where('is_active', true))->pluck('id')->flip();
        // speed: every truck's crew in one query
        $crews = Truckcrew::with('member')->whereIn('truck_id', $all->pluck('id'))->get()->groupBy('truck_id');

        return $all->map(function (Truck $t) use ($usable, $crews) {
            $on = $t->is_assigned ? TripFlow::runningOn($t->id) : null;
            $state = match (true) {
                ! $t->is_active => 'off',
                ! isset($usable[$t->id]) => 'off',
                $on !== null => 'busy',
                (bool) $t->is_assigned => 'busy',
                default => 'free',
            };
            $sub = match ($state) {
                'free' => collect($crews->get($t->id, []))->map(fn ($c) => $c->member?->first_name)->filter()->join(' · ') ?: 'No crew yet',
                'busy' => $on ? 'On '.$on->trip_number.' · '.TripFlow::label($on) : 'On a trip',
                default => $t->is_active ? 'Rental, not booked today' : 'Inactive',
            };

            $stage = $on ? TripFlow::stage($on) : null;

            return ['id' => $t->id, 'plate' => $t->plate_no, 'state' => $state, 'sub' => $sub,
                'label' => match (true) {
                    $state === 'free' => 'Free now', $state === 'off' => 'Off', $stage === 'road' => 'Out', $stage === 'back' => 'Coming back', default => 'On a trip'
                }, 'on' => $on?->trip_number, 'onId' => $on?->id,
                'capacity' => TruckSpace::usable($t, self::DEFAULT_CAPACITY), 'rental' => $t->isRental()];
        })->sortBy(fn ($t) => [['free' => 0, 'busy' => 1, 'off' => 2][$t['state']], $t['rental'] ? 1 : 0, $t['plate']])->values();
    }

    /**
     * The draft: trips by province and city.
     *
     * @param  array{order?: string, first?: ?string, keep?: bool, full?: bool, instruction?: string}  $opt
     * @return array{trips: list<array>, kept: ?int, note: string, ai: bool}
     */
    public function plan(array $opt = []): array
    {
        $covered = $this->covered();
        $places = $this->places()->reject(fn ($p) => $p['unclear'] || isset($covered[$p['key']]));
        $trucks = $this->trucks();
        $free = $trucks->where('state', 'free')->values();
        $kept = ! empty($opt['keep']) && $free->count() > 1 ? $free->last()['id'] : null;
        $slots = $free->reject(fn ($t) => $t['id'] === $kept)->values()
            ->merge($trucks->where('state', 'busy')->values())
            ->push(null)->push(null)->values();

        $note = '';
        $ai = false;
        $why = [];
        $provinceOrder = null;
        if (filled($opt['instruction'] ?? null) && Ai::enabled('trips')) {
            try {
                $out = Ai::json('trips',
                    'You help plan delivery trips by city for a Philippine balikbayan box company. Read what the staff asked and answer the order of provinces to plan first, '
                    .'which truck ids to keep free, and one short reason per province. Answer as {"order":["Province",...],"keep_truck_ids":[id,...],"why":{"Province":"..."},"note":"one short sentence"}.',
                    json_encode(['asked' => $opt['instruction'], 'provinces' => $places->groupBy('province')->map(fn ($g, $p) => ['province' => $p, 'boxes' => $g->sum('boxes'), 'oldest_days' => $g->max('days'), 'cities' => $g->pluck('city')])->values(),
                        'trucks' => $trucks->where('state', '!=', 'off')->map(fn ($t) => ['id' => $t['id'], 'plate' => $t['plate'], 'state' => $t['state']])->values()], JSON_UNESCAPED_UNICODE),
                    'fast', 1200);
                $provinceOrder = array_values(array_filter((array) ($out['order'] ?? []), 'is_string'));
                $keepIds = array_map('intval', (array) ($out['keep_truck_ids'] ?? []));
                if ($keepIds) {
                    $slots = $slots->reject(fn ($t) => $t && in_array($t['id'], $keepIds, true))->values();
                    $kept = $keepIds[0];
                }
                $why = array_change_key_case((array) ($out['why'] ?? []));
                $note = Str::limit((string) ($out['note'] ?? ''), 200);
                $ai = true;
            } catch (AiUnavailable $e) {
                $note = 'Planned without AI ('.$e->getMessage().').';
            }
        }

        // provinces: oldest boxes first (or the one asked first), then the most boxes
        $byProv = $places->groupBy('province')->map(fn ($g, $p) => ['province' => $p, 'days' => $g->max('days'), 'boxes' => $g->sum('boxes'), 'urgent' => $g->sum('prio') + $g->sum('retry'), 'cities' => $g]);
        $rank = fn ($p) => [
            $provinceOrder ? (array_search(Str::lower($p['province']), array_map('strtolower', $provinceOrder), true) === false ? 99 : array_search(Str::lower($p['province']), array_map('strtolower', $provinceOrder), true)) : 0,
            ! empty($opt['first']) && Str::lower($p['province']) === Str::lower($opt['first']) ? 0 : 1,
            $p['urgent'] > 0 ? 0 : 1, -$p['days'], -$p['boxes'],
        ];
        $provs = $byProv->sortBy($rank)->values();

        $trips = [];
        $si = 0;
        foreach ($provs as $prov) {
            $cities = $prov['cities']->sortBy(fn ($c) => [-($c['prio'] + $c['retry']), -$c['days'], -$c['boxes']])->values();
            while ($cities->isNotEmpty() && $si < $slots->count()) {
                $slot = $slots[$si];
                $cap = $slot['capacity'] ?? self::DEFAULT_CAPACITY;
                $trip = ['province' => $prov['province'], 'cities' => [], 'load' => 0, 'cap' => $cap, 'days' => 0, 'truck_id' => $slot['id'] ?? null, 'on' => true, 'left' => []];
                $rest = collect();
                foreach ($cities as $c) {
                    if (! $trip['cities'] && $c['space'] > $cap) {
                        $trip['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space'], 'via' => $c['via'] ?? []];
                        $trip['load'] = $cap;
                        $trip['left'][] = $c['city'].' has '.$c['boxes'].' boxes: about '.max(0, $c['space'] - $cap).' wait for the next '.$prov['province'].' trip';
                        $trip['days'] = max($trip['days'], $c['days']);

                        continue;
                    }
                    if ($cap >= $trip['load'] + $c['space']) {
                        $trip['cities'][] = ['city' => $c['city'], 'key' => $c['key'], 'boxes' => $c['boxes'], 'space' => $c['space'], 'via' => $c['via'] ?? []];
                        $trip['load'] += $c['space'];
                        $trip['days'] = max($trip['days'], $c['days']);
                    } else {
                        $rest->push($c);
                    }
                }
                if (! $trip['cities']) {
                    break;
                }
                $trip['why'] = $this->why($trip, $prov, $rest, $slot, $why[Str::lower($prov['province'])] ?? null);
                $trips[] = $trip;
                $si++;
                $cities = $rest->values();
                // a city left over goes on the next trip of the same province only if it would be a real truckload
                if ($cities->sum('space') < ($slots[$si]['capacity'] ?? self::DEFAULT_CAPACITY) * 0.5) {
                    break;
                }
            }
        }

        foreach ($trips as &$t) {
            if (! empty($opt['full'])) {
                $t['on'] = $t['load'] >= $t['cap'] * 0.9;
            } elseif ($t['load'] < $t['cap'] * 0.3 && $t['days'] < 3) {
                // a small trip waits for more boxes (switch it on to send it anyway)
                $t['on'] = false;
                $t['why'] = 'Small trip: waits for more boxes. Switch it on to send it anyway. '.$t['why'];
            }
        }
        unset($t);
        if ($note === '') {
            $planned = collect($trips)->flatMap(fn ($t) => collect($t['cities'])->pluck('key'))->flip();
            $waitCities = $places->reject(fn ($p) => isset($planned[$p['key']]))->count();
            $note = $places->isEmpty() ? 'No boxes are waiting for a trip.' : count($trips).' '.Str::plural('trip', count($trips)).' · '.($waitCities ? $waitCities.' '.Str::plural('city', $waitCities).' wait' : 'every city planned');
        }

        return ['trips' => $trips, 'kept' => $kept, 'note' => $note, 'ai' => $ai];
    }

    protected function why(array $trip, array $prov, Collection $rest, ?array $slot, ?string $ai): string
    {
        $parts = [];
        if ($ai) {
            $parts[] = Str::finish(Str::limit($ai, 140), '.');
        } else {
            $urgent = collect($prov['cities'])->whereIn('key', collect($trip['cities'])->pluck('key'))->sum(fn ($c) => $c['prio'] + $c['retry']);
            $parts[] = ($trip['days'] >= 3 ? 'Oldest boxes ('.$trip['days'].' days)' : ($trip['days'] ? 'Boxes '.$trip['days'].' '.Str::plural('day', $trip['days']).' old' : 'New today'))
                .($urgent ? ', '.$urgent.' priority or tried before' : '').'.';
        }
        if ($rest->isNotEmpty()) {
            $parts[] = ($trip['load'] >= $trip['cap'] * 0.85 ? 'Full truck: ' : 'No room: ').$rest->map(fn ($c) => $c['city'].' ('.$c['boxes'].')')->join(', ').' '.($rest->count() > 1 ? 'wait' : 'waits').' for the next '.$prov['province'].' trip.';
        }
        $parts = array_merge($parts, $trip['left']);
        if ($slot && $slot['state'] === 'busy') {
            $parts[] = 'Waits for '.$slot['plate'].($slot['on'] ? ' ('.$slot['on'].')' : '').' to come back.';
        } elseif (! $slot) {
            $parts[] = 'No truck yet: give it to the next free truck.';
        }

        return implode(' ', $parts);
    }

    /**
     * Make the trips. Trip numbers come now; boxes join when scanned onto the truck.
     *
     * @return list<array{id: int, number: string, truck: ?string}>
     */
    public function create(array $trips, Carbon $date): array
    {
        if ($this->atHub) {
            return $this->createAtHub($trips, $date);
        }
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['on']) || empty($t['cities'])) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date) {
                $truck = $t['truck_id'] ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $this->user->logistichub_id, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) ($t['why'] ?? ''), 295), 'plan_space' => (int) $t['load'],
                ] + (Schema::hasColumn('deliverylogs', 'no_sms') ? ['no_sms' => array_key_exists('sms', $t) && ! $t['sms']] : []) + $this->madeFields($t));
                foreach ($t['cities'] as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => (int) $c['boxes']]);
                    // a hub's boxes of this city delivered direct instead
                    foreach ($c['via'] ?? [] as $hub) {
                        TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => 0, 'hub_id' => (int) $hub]);
                    }
                }
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }

        return $made;
    }

    /** A hub's own trips: the boxes of the trip's cities that are at the hub go on it now. */
    protected function createAtHub(array $trips, Carbon $date): array
    {
        $units = $this->planner()->units()->filter(fn ($u) => $this->isDirect($u));
        $made = [];
        foreach ($trips as $t) {
            if (empty($t['on']) || empty($t['cities'])) {
                continue;
            }
            $keys = collect($t['cities'])->pluck('key')->flip();
            $ids = $units->filter(fn ($u) => isset($keys[Str::lower($u['province']).'|'.Barangays::cityKey($u['city'])]))->flatMap(fn ($u) => $u['ids'])->values();
            if ($ids->isEmpty()) {
                continue;
            }
            $made[] = DB::transaction(function () use ($t, $date, $ids) {
                $truck = $t['truck_id'] ? Truck::whereKey($t['truck_id'])->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->lockForUpdate()->first() : null;
                $trip = Deliverylog::create([
                    'truck_id' => $truck?->id, 'trip_day' => 1, 'eta' => $date->toDateString(), 'departure_date' => $date->toDateString(),
                    'logistichub_id' => $this->user->logistichub_id, 'assigned_to' => $this->user->logistichub_id, 'user_id' => $this->user->id,
                    'plan_why' => Str::limit((string) ($t['why'] ?? ''), 295), 'plan_space' => (int) $t['load'],
                ] + (Schema::hasColumn('deliverylogs', 'no_sms') ? ['no_sms' => array_key_exists('sms', $t) && ! $t['sms']] : []) + $this->madeFields($t));
                foreach ($t['cities'] as $c) {
                    TripCity::create(['deliverylog_id' => $trip->id, 'province' => $t['province'], 'city' => $c['city'], 'city_key' => Str::after($c['key'], '|'), 'planned_boxes' => (int) $c['boxes']]);
                }
                app(TripAssignment::class)->addToHubTrip($trip, Tripinvoice::whereKey($ids)->get());
                if ($truck && ! $truck->is_assigned) {
                    $truck->update(['is_assigned' => true]);
                }

                return ['id' => $trip->id, 'number' => (string) $trip->trip_number, 'truck' => $truck?->plate_no];
            });
        }
        $this->plannerMemo = null;
        $this->placesMemo = null;

        return $made;
    }

    /** City trips that still wait for a truck, most urgent first. */
    public function waitingForTruck(): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        $places = $this->places()->keyBy('key');

        return Deliverylog::with('cities')->whereNull('truck_id')->where('is_active', true)->where('logistichub_id', $this->user->logistichub_id)
            ->whereHas('cities')->get()
            ->map(fn ($trip) => ['trip' => $trip, 'province' => $trip->cities->first()?->province, 'cities' => $trip->cities->pluck('city')->join(', '),
                'days' => (int) $trip->cities->map(fn ($c) => $places[Str::lower((string) $c->province).'|'.$c->city_key]['days'] ?? 0)->max()])
            ->sortByDesc('days')->values();
    }

    /** "Give": a free truck takes a trip that waits for a truck. */
    public function give(Deliverylog $trip, int $truckId): Truck
    {
        return DB::transaction(function () use ($trip, $truckId) {
            $truck = Truck::whereKey($truckId)->where('logistichub_id', $this->user->logistichub_id)->where('is_active', true)->where('is_assigned', false)->lockForUpdate()->firstOrFail();
            $trip->update(['truck_id' => $truck->id]);
            $truck->update(['is_assigned' => true]);
            TripFlow::copyCrew($trip->fresh());

            return $truck;
        });
    }

    /**
     * Load truck: a waiting box of one of the trip's cities joins the trip.
     *
     * @return array{0: ?Tripinvoice, 1: ?string} the box on the trip now, or why not
     */
    public static function join(Deliverylog $trip, string $code, bool $force = false, bool $forceHub = false): array
    {
        if (! static::ready()) {
            return [null, null];
        }
        $cities = TripCity::where('deliverylog_id', $trip->id)->get();
        if ($cities->isEmpty()) {
            return [null, null];
        }
        $inv = Invoice::where('invoice', $code)->where('is_delivered', false)->latest('id')->first();
        if (! $inv) {
            return [null, null];
        }
        if ($inv->is_assigned || Tripinvoice::where('invoice_id', $inv->id)->where('is_delivered', false)->whereHas('deliverylog', fn ($q) => $q->where('is_active', true))->exists()) {
            return [null, null];
        }
        if ($trip->is_lock) {
            return [null, 'Trip '.$trip->trip_number.' is locked: no more boxes join. Unlock it to add '.$code.'.'];
        }
        if (! $inv->is_verified) {
            return [null, $code.' is not unloaded yet (not scanned at Unload container).'];
        }
        $key = Barangays::cityKey($inv->receiver_city);
        // same city name in two provinces: the province must match too (a city saved without a province takes only boxes without one)
        $sameCity = $cities->filter(fn ($c) => $c->city_key === $key && Str::lower(Str::squish((string) $c->province)) === Str::lower(Str::squish((string) $inv->receiver_province)));
        $hasHub = Schema::hasColumn('trip_cities', 'hub_id');
        $boxHub = $hasHub ? HubAreas::hubOf($inv) : null;
        $match = $hasHub ? $sameCity->first(fn ($c) => (int) $c->hub_id === (int) $boxHub) : $sameCity->first();
        if (! $match && $hasHub && ! $forceHub) {
            $toHubTrip = $cities->every(fn ($c) => $c->hub_id && $trip->assigned_to && (int) $trip->assigned_to !== (int) $trip->logistichub_id);
            // a hub's box on our own trip, our box on a trip to a hub, or a box of another hub
            if ($sameCity->isNotEmpty() || $boxHub || $toHubTrip) {
                return [null, 'hub:'.(int) $boxHub];
            }
        }
        if (! $match && ! $force && ! $forceHub) {
            return [null, 'other-city'];
        }
        $added = app(TripAssignment::class)->addToDeliveryTrip($trip, collect([$inv]));
        if (! $added) {
            return [null, $code.' could not be added to '.$trip->trip_number.'.'];
        }

        return [Tripinvoice::with('invdata')->where('deliverylog_id', $trip->id)->where('invoice_id', $inv->id)->latest('id')->first(), null];
    }

    /** Unloading now: today's unloaded boxes by province, and where they go. */
    public function unloadingNow(): array
    {
        if ($this->atHub) {
            return ['container' => null, 'rows' => []];
        }
        $wh = $this->user->warehouse_id;
        $rows = Invoice::where('is_assigned', false)->where('is_delivered', false)->where('verified_at', '>=', today())
            ->when($wh && Filament::getCurrentPanel()?->getId() === 'warehouse', fn ($q) => $q->where('warehouse_id', $wh))
            ->with('container:id,container_no')->get(['id', 'container_id', 'receiver_province', 'receiver_city', 'wh_section_id', 'warehouse_id']);
        if ($rows->isEmpty()) {
            return ['container' => null, 'rows' => []];
        }
        $loading = static::ready() ? TripCity::query()->join('deliverylogs as d', 'd.id', '=', 'trip_cities.deliverylog_id')
            ->where('d.is_active', true)->whereNotNull('d.truck_id')->whereNull('d.waits_for')->where(fn ($q) => $q->where('d.is_lock', false)->orWhereNull('d.is_lock'))
            ->leftJoin('trucks as t', 't.id', '=', 'd.truck_id')->get(['trip_cities.province', 'trip_cities.city_key', 't.plate_no'])
            ->mapWithKeys(fn ($r) => [Str::lower((string) $r->province).'|'.$r->city_key => $r->plate_no]) : collect();
        $byProv = $rows->groupBy(fn ($r) => Str::title(Str::squish((string) $r->receiver_province)) ?: 'No province')->sortByDesc(fn ($g) => $g->count());
        $out = [];
        $here = $this->user->warehouse_id;
        foreach ($byProv->take(2) as $prov => $g) {
            $plate = $g->map(fn ($r) => $loading[Str::lower(Str::squish((string) $r->receiver_province)).'|'.Barangays::cityKey($r->receiver_city)] ?? null)->filter()->first();
            $to = $here ? Coverage::transferTo($g->first(), $here) : null;
            $out[] = [$prov.' · '.$g->count().' '.Str::plural('box', $g->count()), $to ? 'Transfer → '.Coverage::name($to) : ($plate ? $plate.' is here → straight on' : 'Sections'), (bool) $plate];
        }
        if ($byProv->count() > 2) {
            $n = $byProv->slice(2)->sum(fn ($g) => $g->count());
            $out[] = ['Others · '.$n.' '.Str::plural('box', $n), 'Sections', false];
        }

        return ['container' => $rows->sortByDesc('id')->first()->container?->container_no, 'rows' => $out];
    }
}
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- database/migrations/2026_11_20_000044_add_speed_indexes.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_20_000044_add_speed_indexes.php' <<'DISPATCH_FILE_END_12'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/** Speed: indexes the Delivery trips page and its cards use. Safe to run again: skips what exists. */
return new class extends Migration
{
    /** table => [index name => columns] */
    protected array $indexes = [
        'delivery_attempts' => ['delivery_attempts_trip_created_idx' => ['deliverylog_id', 'created_at']],
        'delivery_reversals' => ['delivery_reversals_trip_created_idx' => ['deliverylog_id', 'created_at']],
        'truckcrews' => ['truckcrews_truck_idx' => ['truck_id']],
    ];

    public function up(): void
    {
        foreach ($this->indexes as $table => $list) {
            if (! Schema::hasTable($table)) {
                continue;
            }
            foreach ($list as $name => $cols) {
                if (! Schema::hasColumns($table, $cols) || Schema::hasIndex($table, $name) || Schema::hasIndex($table, $cols)) {
                    continue;
                }
                Schema::table($table, fn (Blueprint $t) => $t->index($cols, $name));
            }
        }
    }

    public function down(): void
    {
        foreach ($this->indexes as $table => $list) {
            foreach ($list as $name => $cols) {
                if (Schema::hasTable($table) && Schema::hasIndex($table, $name)) {
                    Schema::table($table, fn (Blueprint $t) => $t->dropIndex($name));
                }
            }
        }
    }
};
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- tests/Feature/SpeedTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/SpeedTest.php' <<'DISPATCH_FILE_END_13'
<?php

use App\Filament\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Models\Deliverylog;
use App\Models\User;
use App\Support\SchemaMemo;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Livewire\Livewire;

uses(RefreshDatabase::class);

it('remembers Schema answers and forgets them when a table changes', function () {
    expect(Schema::getFacadeRoot())->toBeInstanceOf(SchemaMemo::class);
    expect(Schema::hasTable('speed_probe'))->toBeFalse();

    Schema::hasTable('users');
    Schema::hasColumn('users', 'email');
    DB::flushQueryLog();
    DB::enableQueryLog();
    Schema::hasTable('speed_probe');
    Schema::hasTable('users');
    Schema::hasColumn('users', 'email');
    expect(DB::getQueryLog())->toBeEmpty(); // asked before: no query

    Schema::create('speed_probe', fn (Blueprint $t) => $t->id());
    expect(Schema::hasTable('speed_probe'))->toBeTrue()
        ->and(Schema::hasColumn('speed_probe', 'id'))->toBeTrue();
    Schema::table('speed_probe', fn (Blueprint $t) => $t->string('note')->nullable());
    expect(Schema::hasColumn('speed_probe', 'note'))->toBeTrue();
    Schema::drop('speed_probe');
    expect(Schema::hasTable('speed_probe'))->toBeFalse();
});

it('loads the Delivery trips list with the same number of queries for 5 or 30 trips', function () {
    $this->seed(DemoSeeder::class);
    $admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->actingAs($admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $base = Deliverylog::where('logistichub_id', $admin->logistichub_id)->firstOrFail();

    $count = function () {
        DB::flushQueryLog();
        DB::enableQueryLog();
        Livewire::test(ListDeliverylogs::class)->html();

        return count(DB::getQueryLog());
    };
    $few = $count();
    foreach (range(1, 25) as $n) {
        $t = $base->replicate();
        $t->trip_number = null;
        $t->save();
    }
    $many = $count();

    expect($many - $few)->toBeLessThan(10); // before: about 13 more queries for every trip
});
DISPATCH_FILE_END_13

echo "▶ Updating the database (keeps your data)"
php artisan migrate --force

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
