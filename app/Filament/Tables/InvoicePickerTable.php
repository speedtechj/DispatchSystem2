<?php

namespace App\Filament\Tables;

use App\Models\Consolidator;
use App\Models\Invoice;
use Filament\Tables\Columns\Summarizers\Count;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\Filter;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Grouping\Group;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

/**
 * The "pick invoices for a trip" table shared by the admin, warehouse and hub
 * assignment screens. Relationship data is eager-loaded once per page instead
 * of being queried again for every row.
 */
class InvoicePickerTable
{
    /** Relations every column below needs. */
    public const EAGER_LOAD = ['consolidator:id,code,company_name', 'invoiceissue.boxissue', 'container', 'routearea', 'latestDeliveryAttempt'];

    public static function query(): Builder
    {
        return Invoice::query()->with(self::EAGER_LOAD);
    }

    /** @return array<int, Group|string> */
    public static function groups(): array
    {
        return [
            Group::make('receiver_name')->label('Receiver'),
            Group::make('receiver_barangay')->label('Barangay'),
            Group::make('receiver_city')->label('City'),
            Group::make('receiver_province')->label('Province'),
            Group::make('boxtype')->label('Box type'),
            Group::make('routearea.description')->label('Route area'),
            Group::make('container.batch_no')->label('Batch no.'),
        ];
    }

    /**
     * Searching for an invoice number also brings up every other box for the
     * same receiver, so a whole household can be added in one go.
     */
    public static function searchable(): array
    {
        return [
            'invoice',
            function (Builder $query, string $search): Builder {
                $receiver = Invoice::where('invoice', $search)->value('receiver_name');

                return filled($receiver)
                    ? $query->orWhere('receiver_name', 'like', '%'.$receiver.'%')
                    : $query;
            },
        ];
    }

    public static function columns(): array
    {
        return [
            TextColumn::make('invoice')
                ->label('Invoice')
                ->weight('bold')
                ->copyable()
                ->description(fn (Invoice $record) => $record->consolidator?->company_name),
            TextColumn::make('problem')
                ->label('Issue')
                ->badge()
                ->color('danger')
                ->icon('heroicon-m-exclamation-triangle')
                ->getStateUsing(fn (Invoice $record) => $record->invoiceissue
                    ->pluck('boxissue.issue_type')
                    ->filter()
                    ->unique()
                    ->join(', ') ?: null),
            TextColumn::make('flags')
                ->label('Status')
                ->badge()
                ->state(fn (Invoice $record) => array_values(array_filter([
                    $record->is_priority ? 'Priority' : null,
                    $record->is_returned ? 'Returned' : null,
                    $record->is_resolved ? 'Resolved' : null,
                ])))
                ->color(fn (string $state) => match ($state) {
                    'Priority' => 'warning',
                    'Returned' => 'info',
                    default => 'success',
                }),
            TextColumn::make('latestDeliveryAttempt.reason')
                ->label('Last delivery attempt')
                ->badge()
                ->formatStateUsing(fn ($state) => $state->getLabel())
                ->icon(fn ($state) => $state?->getIcon())
                ->color(fn ($state) => $state?->getColor() ?? 'gray')
                ->tooltip(fn (Invoice $record) => collect([
                    $record->latestDeliveryAttempt?->note,
                    $record->latestDeliveryAttempt?->created_at?->format('M j, g:i A'),
                ])->filter()->join(' — ') ?: null),
            TextColumn::make('batchno')
                ->label('Batch')
                ->sortable(query: fn (Builder $query, string $direction): Builder => $query
                    ->orderByRaw('CAST(batchno AS UNSIGNED) '.($direction === 'desc' ? 'desc' : 'asc'))),
            TextColumn::make('container.batch_year')
                ->label('Batch year')
                ->toggleable(isToggledHiddenByDefault: true),
            TextColumn::make('sender_name')->label('Sender')->searchable(),
            TextColumn::make('receiver_name')->label('Receiver')->searchable()->weight('medium'),
            TextColumn::make('receiver_address')->label('Address')->wrap()->limit(40),
            TextColumn::make('receiver_province')->label('Province')->toggleable(isToggledHiddenByDefault: true),
            TextColumn::make('receiver_city')->label('City / Municipality')->toggleable(isToggledHiddenByDefault: true),
            TextColumn::make('receiver_barangay')->label('Barangay')->toggleable(isToggledHiddenByDefault: true),
            TextColumn::make('boxtype')
                ->label('Box type')
                ->badge()
                ->color('gray')
                ->summarize(Count::make()->label('Boxes')),
            TextColumn::make('routearea.description')->label('Route area'),
        ];
    }

    public static function filters(bool $verifiedByDefault = false): array
    {
        return array_values(array_filter([
            $verifiedByDefault
                ? Filter::make('is_verified')
                    ->label('Verified only')
                    ->toggle()
                    ->query(fn (Builder $query): Builder => $query->where('is_verified', true))
                    ->default()
                : null,
            Filter::make('is_returned')
                ->label('Returned only')
                ->toggle()
                ->query(fn (Builder $query): Builder => $query->where('is_returned', true)),
            SelectFilter::make('container_id')
                ->label('Container')
                ->multiple()
                ->searchable()
                ->preload()
                ->relationship('container', 'container_no', fn (Builder $query) => $query->where('is_active', true))
                ->getOptionLabelFromRecordUsing(fn (Model $record) => trim("{$record->container_no} · batch {$record->batch_no} {$record->batch_year}")),
            SelectFilter::make('routearea_id')
                ->label('Route area')
                ->multiple()
                ->searchable()
                ->preload()
                ->relationship('routearea', 'description'),
            SelectFilter::make('receiver_province')
                ->label('Province')
                ->multiple()
                ->searchable()
                ->options(fn () => Invoice::query()
                    ->whereNotNull('receiver_province')
                    ->distinct()
                    ->orderBy('receiver_province')
                    ->pluck('receiver_province', 'receiver_province')),
            SelectFilter::make('location_code')
                ->label('Company')
                ->multiple()
                ->searchable()
                ->options(fn () => Consolidator::query()->orderBy('company_name')->pluck('company_name', 'code')),
        ]));
    }
}
