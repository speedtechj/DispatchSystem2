<?php

namespace App\Filament\Company\Pages;

use App\Filament\Company\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Concerns\ResolvesOwnerTrip;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Filament\Actions\Action;
use Filament\Actions\BulkAction;
use Filament\Actions\BulkActionGroup;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\Summarizers\Count;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Concerns\InteractsWithTable;
use Filament\Tables\Contracts\HasTable;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Grouping\Group;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * Partner hub: pick boxes that arrived at the hub and put them on one of the
 * hub's own delivery trips. Opened with ?ownerRecord={hub trip id}.
 */
class Routeinvoice extends Page implements HasTable
{
    use InteractsWithTable;
    use ResolvesOwnerTrip;

    protected static bool $shouldRegisterNavigation = false;

    protected string $view = 'filament.company.pages.routeinvoice';

    protected static ?string $title = 'Assign invoices';

    protected function ownerTripQuery(): Builder
    {
        return DeliverylogResource::getEloquentQuery();
    }

    public function table(Table $table): Table
    {
        return $table
            ->query(Tripinvoice::query()
                ->with(['invdata.consolidator:id,code,company_name', 'invdata.routearea', 'invdata.container'])
                ->where('is_loaded', true)
                ->where('logistichub_id', Auth::user()->logistichub_id)
                ->where('hub_assigned', false))
            ->defaultSort('created_at', 'desc')
            ->defaultGroup('invdata.receiver_name')
            ->groups([
                Group::make('invdata.receiver_name')->label('Receiver'),
                Group::make('invdata.boxtype')->label('Box type'),
                Group::make('invdata.routearea.description')->label('Route area'),
                Group::make('invdata.container.batch_no')->label('Batch no.'),
                Group::make('invdata.receiver_barangay')->label('Barangay'),
                Group::make('invdata.receiver_city')->label('City'),
                Group::make('invdata.receiver_province')->label('Province'),
            ])
            ->striped()
            ->emptyStateIcon(Heroicon::OutlinedInboxStack)
            ->emptyStateHeading('No boxes waiting at your hub')
            ->emptyStateDescription('Boxes appear here once they are loaded on a trip coming to your hub.')
            ->columns([
                TextColumn::make('invdata.invoice')
                    ->label('Invoice')
                    ->weight('bold')
                    ->searchable()
                    ->description(fn (Tripinvoice $record) => $record->invdata?->consolidator?->company_name),
                IconColumn::make('invdata.is_returned')->label('Returned')->boolean()->trueColor('warning')->alignCenter(),
                TextColumn::make('invdata.batchno')
                    ->label('Batch')
                    ->sortable(query: fn (Builder $query, string $direction): Builder => $query->orderBy(
                        Invoice::selectRaw('CAST(batchno AS UNSIGNED)')->whereColumn('invoices.id', 'tripinvoices.invoice_id'),
                        $direction === 'desc' ? 'desc' : 'asc',
                    )),
                TextColumn::make('invdata.sender_name')->label('Sender'),
                TextColumn::make('invdata.receiver_name')->label('Receiver')->weight('medium'),
                TextColumn::make('invdata.receiver_address')->label('Address')->wrap()->limit(40),
                TextColumn::make('invdata.receiver_province')->label('Province'),
                TextColumn::make('invdata.receiver_city')->label('City / Municipality'),
                TextColumn::make('invdata.receiver_barangay')->label('Barangay'),
                TextColumn::make('invdata.boxtype')
                    ->label('Box type')
                    ->badge()
                    ->color('gray')
                    ->summarize(Count::make()->label('Boxes')),
            ])
            ->filters([
                SelectFilter::make('is_returned')
                    ->label('Returned status')
                    ->options([1 => 'Returned', 0 => 'Not returned'])
                    ->query(fn (Builder $query, array $data) => filled($data['value'] ?? null)
                        ? $query->whereHas('invoice', fn (Builder $q) => $q->where('is_returned', $data['value']))
                        : $query),
                SelectFilter::make('receiver_province')
                    ->label('Province')
                    ->multiple()
                    ->searchable()
                    ->options(fn () => Invoice::query()
                        ->whereNotNull('receiver_province')
                        ->distinct()
                        ->orderBy('receiver_province')
                        ->pluck('receiver_province', 'receiver_province'))
                    ->query(fn (Builder $query, array $data) => filled($data['values'] ?? null)
                        ? $query->whereHas('invoice', fn (Builder $q) => $q->whereIn('receiver_province', $data['values']))
                        : $query),
            ])
            ->deferFilters(false)
            ->headerActions([
                Action::make('done')
                    ->label('Back to trip')
                    ->icon(Heroicon::ArrowUturnLeft)
                    ->color('gray')
                    ->url(fn () => DeliverylogResource::getUrl('edit', ['record' => $this->ownerRecord])),
            ])
            ->recordActions([
                Action::make('addinvoice')
                    ->label('Add')
                    ->button()
                    ->size('sm')
                    ->icon(Heroicon::Plus)
                    ->action(fn (Tripinvoice $record) => $this->assignAndNotify(
                        fn () => app(TripAssignment::class)->addToHubTrip($this->ownerTrip(), [$record]),
                        1,
                    )),
            ], position: RecordActionsPosition::BeforeColumns)
            ->toolbarActions([
                BulkActionGroup::make([
                    BulkAction::make('addSelected')
                        ->label('Add to trip')
                        ->icon(Heroicon::PlusCircle)
                        ->color('primary')
                        ->deselectRecordsAfterCompletion()
                        ->action(fn (Collection $records) => $this->assignAndNotify(
                            fn () => app(TripAssignment::class)->addToHubTrip($this->ownerTrip(), $records),
                            $records->count(),
                        )),
                ]),
            ]);
    }
}
