<?php

namespace App\Filament\Pages;

use App\Filament\Concerns\ResolvesOwnerTrip;
use App\Filament\Exports\RouteinvoiceExporter;
use App\Filament\Resources\Deliverylogs\DeliverylogResource;
use App\Filament\Tables\InvoicePickerTable;
use App\Models\Invoice;
use App\Services\TripAssignment;
use Filament\Actions\Action;
use Filament\Actions\BulkAction;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\ExportBulkAction;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Concerns\InteractsWithTable;
use Filament\Tables\Contracts\HasTable;
use Filament\Tables\Enums\RecordActionsPosition;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Collection;

/**
 * Pick unassigned invoices and put them on a delivery trip.
 * Opened from a trip's "Assign invoice" button (?ownerRecord={trip id}).
 */
class Routeinvoice extends Page implements HasTable
{
    use InteractsWithTable;
    use ResolvesOwnerTrip;

    protected string $view = 'filament.pages.routeinvoice';

    protected static bool $shouldRegisterNavigation = false;

    protected static ?string $title = 'Assign invoices';

    protected function ownerTripQuery(): Builder
    {
        return DeliverylogResource::getEloquentQuery();
    }

    public function table(Table $table): Table
    {
        return $table
            ->query(InvoicePickerTable::query()->where('is_assigned', false))
            ->defaultGroup('receiver_name')
            ->groups(InvoicePickerTable::groups())
            ->searchable(InvoicePickerTable::searchable())
            ->columns(InvoicePickerTable::columns())
            ->filters(InvoicePickerTable::filters(verifiedByDefault: true))
            ->deferFilters(false)
            ->striped()
            ->emptyStateIcon(Heroicon::OutlinedInboxStack)
            ->emptyStateHeading('No invoices waiting for a trip')
            ->emptyStateDescription('Every verified invoice is already assigned. Try clearing the filters.')
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
                    ->action(fn (Invoice $record) => $this->assignAndNotify(
                        fn () => app(TripAssignment::class)->addToDeliveryTrip($this->ownerTrip(), [$record]),
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
                            fn () => app(TripAssignment::class)->addToDeliveryTrip($this->ownerTrip(), $records),
                            $records->count(),
                        )),
                    ExportBulkAction::make()
                        ->label('Export')
                        ->color('success')
                        ->icon(Heroicon::CloudArrowDown)
                        ->exporter(RouteinvoiceExporter::class),
                ]),
            ]);
    }
}
