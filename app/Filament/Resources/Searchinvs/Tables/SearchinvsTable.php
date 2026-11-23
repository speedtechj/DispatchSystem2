<?php

namespace App\Filament\Resources\Searchinvs\Tables;

use App\Filament\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Consolidator;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\Whtripinvoice;
use App\Support\Photos\BoxAlbum;
use Carbon\Carbon;
use Filament\Actions\Action;
use Filament\Actions\ActionGroup;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\DeleteBulkAction;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Columns\ToggleColumn;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;

class SearchinvsTable
{
    /** Looked up once per box per page, not once per column. */
    private static array $memo = [];

    private static function tripOf(int $invoiceId): ?Tripinvoice
    {
        return self::remember('t'.$invoiceId, fn () => Tripinvoice::where('invoice_id', $invoiceId)->first());
    }

    private static function whTripOf(int $invoiceId): ?Whtripinvoice
    {
        return self::remember('w'.$invoiceId, fn () => Whtripinvoice::where('invoice_id', $invoiceId)->first());
    }

    private static function consolidatorOf(?string $code): ?Consolidator
    {
        return self::remember('c'.$code, fn () => Consolidator::where('code', $code)->first());
    }

    private static function remember(string $key, \Closure $find): mixed
    {
        if (! array_key_exists($key, self::$memo)) {
            if (count(self::$memo) > 2000) {
                self::$memo = [];
            }
            self::$memo[$key] = $find();
        }

        return self::$memo[$key];
    }

    public static function configure(Table $table): Table
    {
        return $table
            // delivered boxes greyed (board 57)
            ->recordClasses(fn ($record) => $record->is_delivered || self::tripOf((int) $record->id)?->is_delivered ? 'ds-row-delivered' : null)
            ->modifyQueryUsing(fn ($query) => $query->with('container:id,container_no,batch_no'))
            ->columns([
                // TextColumn::make( 'container.container_no' )
                // ->label('Container No')
                // ->sortable(),
                TextColumn::make('company')
                    ->label('Company')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->getStateUsing(function ($record) {
                        $company = self::consolidatorOf($record->location_code);

                        return $company?->company_name;
                    }),
                TextColumn::make('tripno')
                    ->label('Trip Number')
                    ->getStateUsing(function ($record) {
                        $tripinvoice = self::tripOf((int) $record->id);

                        return $tripinvoice->deliverylog->trip_number ?? 'Not Assigned';
                    })
                    ->url(function ($record) {
                        $tripinvoice = self::tripOf((int) $record->id);
                        if ($tripinvoice !== null) {
                            return DeliverylogResource::getUrl('edit', ['record' => $tripinvoice->deliverylog->id]) ?? 'not assigned';
                        }
                    })
                    ->color('primary'),
                //         TextColumn::make( 'Departure Date' )
                //         ->label('Departure Date')
                //         ->getStateUsing(function($record){
                //             $tripinvoice = Tripinvoice::where('invoice_id',$record->id)->first();
                //             return Carbon::parse($tripinvoice->deliverylog->departure_date)
                // ->format('F j, Y') ?? '';
                //         }),
                TextColumn::make('invoice')
                    ->label('Invoice')
                    ->searchable(isIndividual: true, isGlobal: false)
                    // two boxes can share a number (board 57): say so under the number
                    ->description(fn ($record) => ($n = \App\Support\Boxes\SameNumber::count((string) $record->invoice)) > 1 ? "⚠ {$n} share this number" : null)
                    ->extraAttributes(fn ($record) => \App\Support\Boxes\SameNumber::count((string) $record->invoice) > 1 ? ['class' => 'ds-same-no'] : []),
                TextColumn::make('container_batch')
                    ->label('Container · batch')
                    ->getStateUsing(fn ($record) => trim(($record->container?->container_no ?? '—').(($b = $record->container?->batch_no ?: $record->batchno) ? ' · '.$b : '')))
                    ->color('gray'),
                TextColumn::make('problem')
                    ->badge()
                    ->color('danger')
                    ->label('Problem')
                    ->getStateUsing(function ($record) {

                        return $record->invoiceissue()
                            ->with('boxissue')
                            ->get()
                            ->pluck('boxissue.issue_type')  // ✅ get all issue types
                            ->filter()
                            ->join(', ');
                    }),
                IconColumn::make('is_resolved')
                    ->label('Resolved')
                    ->icon(fn ($state) => $state ? 'heroicon-o-check-circle' : null)
                    ->color('success'),
                IconColumn::make('delivered')
                    ->label('Delivered')
                    ->boolean()
                    ->getStateUsing(function ($record) {
                        $isdelivered = self::tripOf((int) $record->id);

                        return $isdelivered->is_delivered ?? false;

                    }),
                IconColumn::make('loadedtruck')
                    ->label('Loaded')
                    ->boolean()
                    ->getStateUsing(function ($record) {
                        $isloaded = self::tripOf((int) $record->id);

                        return $isloaded->is_loaded ?? false;

                    }),
                ToggleColumn::make('is_priority')
                    ->label('Priority'),
                TextColumn::make('batchno')
                    ->label('Batch No')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('sender_name')
                    ->label('Sender Name')
                    ->searchable(isIndividual: true, isGlobal: false),
                TextColumn::make('receiver_name')
                    ->label('Receiver Name')
                    ->searchable(isIndividual: true, isGlobal: false),
                TextColumn::make('receiver_address')
                    ->label('Receiver Address')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('receiver_province')
                    ->label('Receiver Province')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('receiver_city')
                    ->label('Receiver City')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('receiver_barangay')
                    ->label('Receiver Barangay')
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('receiver_mobile_no')
                    ->label('Receiver Mobile No')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable(isIndividual: true, isGlobal: false),
                TextColumn::make('receiver_home_no')
                    ->label('Receiver Home No')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->searchable(isIndividual: true, isGlobal: false),
                TextColumn::make('boxtype')
                    ->label('Box Type'),
                TextColumn::make('routearea.description')
                    ->label('Route Area')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->sortable(),
                IconColumn::make('is_verified')
                    ->label('Verified')
                    ->toggleable(isToggledHiddenByDefault: true)
                    ->boolean(),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])->searchOnBlur()
            ->persistSearchInSession()
            ->persistColumnSearchesInSession()
            ->filters([
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
            ])->deferFilters(false)
            ->recordActions([
                Action::make('photos')
                    ->label('Photos')
                    ->icon('heroicon-o-photo')
                    ->color('gray')
                    ->modalHeading(fn ($record) => 'Photos · '.$record->invoice)
                    ->modalWidth('4xl')
                    ->modalSubmitAction(false)
                    ->modalCancelActionLabel('Close')
                    ->modalContent(fn ($record) => view('filament.partials.invoice-photos', [
                        'items' => (new BoxAlbum(auth()->user()))->forInvoice($record->id),
                    ])),
                //            ActionGroup::make([
                //     Action::make('view'),
                //     Action::make('edit'),
                //     Action::make('delete'),
                // ])
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    DeleteBulkAction::make(),
                ]),
            ]);
    }
}
