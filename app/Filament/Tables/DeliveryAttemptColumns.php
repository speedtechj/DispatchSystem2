<?php

namespace App\Filament\Tables;

use App\Enums\UndoDeliveryReason;
use App\Models\Tripinvoice;
use App\Services\TripAssignment;
use Filament\Actions\Action;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Utilities\Get;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;

/**
 * "Not delivered" badge and history window for the trip invoice lists that
 * dispatchers use (Admin, Warehouse and Partner hub panels).
 */
class DeliveryAttemptColumns
{
    public static function column(): TextColumn
    {
        return TextColumn::make('latestDeliveryAttempt.reason')
            ->label('Delivery')
            ->badge()
            ->formatStateUsing(fn ($state, Tripinvoice $record) => $state->getLabel()
                .($record->delivery_attempts_count > 1 ? " · {$record->delivery_attempts_count} tries" : ''))
            ->icon(fn ($state) => $state?->getIcon())
            ->color(fn ($state) => $state?->getColor() ?? 'gray')
            ->tooltip(fn (Tripinvoice $record) => collect([
                $record->latestDeliveryAttempt?->note,
                $record->latestDeliveryAttempt?->created_at?->format('M j, g:i A'),
            ])->filter()->join(' — ') ?: null)
            ->placeholder(fn (Tripinvoice $record) => $record->is_delivered ? 'Delivered' : null);
    }

    public static function action(): Action
    {
        return Action::make('deliveryAttempts')
            ->label('Delivery attempts')
            ->icon(Heroicon::OutlinedClipboardDocumentList)
            ->color('gray')
            ->visible(fn (Tripinvoice $record) => ($record->delivery_attempts_count ?? 0) + ($record->delivery_reversals_count ?? 0) > 0)
            ->modalHeading(fn (Tripinvoice $record) => "Delivery history for {$record->invoice}")
            ->modalWidth('xl')
            ->modalSubmitAction(false)
            ->modalCancelActionLabel('Close')
            ->modalContent(fn (Tripinvoice $record) => view('filament.delivery-attempts', [
                'attempts' => static::history($record),
            ]));
    }

    /** Failed attempts and undone deliveries for one box, newest first. */
    public static function history(Tripinvoice $record): Collection
    {
        return $record->deliveryAttempts()->with(['user', 'deliverylog:id,trip_number'])->get()
            ->concat($record->deliveryReversals()->with(['user', 'deliverer', 'deliverylog:id,trip_number'])->get())
            ->sortByDesc('created_at')
            ->values();
    }

    /** Office correction: put a delivered box back to "not delivered", any time, with a reason. */
    public static function undoAction(): Action
    {
        return Action::make('undoDelivery')
            ->label('Mark as not delivered')
            ->icon(Heroicon::OutlinedArrowUturnLeft)
            ->color('warning')
            ->visible(fn (Tripinvoice $record) => (bool) $record->is_delivered)
            ->modalHeading(fn (Tripinvoice $record) => "Mark {$record->invoice} as not delivered?")
            ->modalDescription(fn (Tripinvoice $record) => collect([
                'Delivered '.($record->delivered_at ?? $record->updated_at)?->format('M j, g:i A'),
                $record->deliverer?->full_name ? 'by '.$record->deliverer->full_name : null,
                count($record->delivery_picture ?? []).' photo(s) kept in the history',
            ])->filter()->join(' · ').'. The box goes back on the driver\'s list and the driver is told.')
            ->modalIcon(Heroicon::OutlinedArrowUturnLeft)
            ->modalIconColor('warning')
            ->modalSubmitActionLabel('Mark as not delivered')
            ->modalWidth('md')
            ->schema([
                Select::make('reason')
                    ->label('Reason')
                    ->options(UndoDeliveryReason::officeOptions())
                    ->required()
                    ->native(false)
                    ->live(),
                Textarea::make('note')
                    ->label('Note')
                    ->rows(2)
                    ->maxLength(500)
                    ->required(fn (Get $get) => $get('reason') === UndoDeliveryReason::Other->value),
            ])
            ->action(function (Tripinvoice $record, array $data): void {
                try {
                    app(TripAssignment::class)->undoDelivery($record, Auth::user(), UndoDeliveryReason::from($data['reason']), $data['note'] ?? null, byOffice: true);
                } catch (\DomainException $exception) {
                    Notification::make()->title($exception->getMessage())->danger()->send();

                    return;
                }

                Notification::make()->title('Marked as not delivered')->body("{$record->invoice} is back on the driver's list.")->success()->send();
            });
    }

    /** Relations the column needs, to avoid a query per row. */
    public static function eagerLoad(): array
    {
        return ['latestDeliveryAttempt', 'deliverer:id,first_name,last_name'];
    }
}
