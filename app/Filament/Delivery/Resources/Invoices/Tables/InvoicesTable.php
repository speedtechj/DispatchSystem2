<?php

namespace App\Filament\Delivery\Resources\Invoices\Tables;

use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\Auth;

class InvoicesTable
{
    public static function configure(Table $table): Table
    {
        return $table
            // Only NOT delivered invoices on this lead's current delivery trip
            ->modifyQueryUsing(function (Builder $query) {
                $deliveryId = static::currentDeliveryId();

                if (! $deliveryId) {
                    return $query->whereRaw('1 = 0'); // no active trip → show nothing
                }

                return $query
                    ->where('is_delivered', false)
                    ->whereIn('invoice', static::tripInvoiceNumbers($deliveryId));
            })
            ->emptyStateHeading('No undelivered invoices')
            ->emptyStateDescription('There are no invoices left to deliver on your current trip.')
            ->columns([
                TextColumn::make('container_id')
                    ->numeric()
                    ->sortable(),
                TextColumn::make('invoice')
                    ->searchable(),
                TextColumn::make('batchno')
                    ->searchable(),
                TextColumn::make('sender_name')
                    ->searchable(),
                TextColumn::make('receiver_name')
                    ->searchable(),
                TextColumn::make('receiver_address')
                    ->searchable(),
                TextColumn::make('receiver_province')
                    ->searchable(),
                TextColumn::make('receiver_city')
                    ->searchable(),
                TextColumn::make('receiver_barangay')
                    ->searchable(),
                TextColumn::make('receiver_mobile_no')
                    ->searchable(),
                TextColumn::make('receiver_home_no')
                    ->searchable(),
                TextColumn::make('boxtype')
                    ->searchable(),
                TextColumn::make('routearea_id')
                    ->numeric()
                    ->sortable(),
                IconColumn::make('is_verified')
                    ->boolean(),
                IconColumn::make('is_returned')
                    ->boolean(),
                IconColumn::make('is_delivered')
                    ->boolean(),
                IconColumn::make('is_assigned')
                    ->boolean(),
                TextColumn::make('user_id')
                    ->numeric()
                    ->sortable(),
                TextColumn::make('location_code')
                    ->searchable(),
                IconColumn::make('is_priority')
                    ->boolean(),
                TextColumn::make('problem_description')
                    ->searchable(),
                IconColumn::make('is_resolved')
                    ->boolean(),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('warehouse_id')
                    ->numeric()
                    ->sortable(),
                IconColumn::make('wh_is_assigned')
                    ->boolean(),
            ])
            ->filters([
                //
            ])
            ->recordActions([])
            ->toolbarActions([]);
    }

    /**
     * Current delivery trip of the logged-in lead's truck
     * (same logic as the Delivery Invoice page).
     */
    public static function currentDeliveryId(): ?int
    {
        return once(function () {
            $crew = Truckcrew::where('crew', Auth::id())->first();

            if (! $crew?->truck) {
                return null;
            }

            return Deliverylog::where('truck_id', $crew->truck->id)
                ->where('is_current', true)
                ->value('id');
        });
    }

    /**
     * Invoice numbers loaded on that trip and not yet delivered
     * (same rules as the Delivery Invoice page table).
     */
    public static function tripInvoiceNumbers(int $deliveryId)
    {
        return Tripinvoice::query()
            ->select('invoice')
            ->where('is_delivered', false)
            ->where(function ($query) use ($deliveryId) {
                $query
                    ->where(function ($q) use ($deliveryId) {
                        $q->where('deliveryloghub_id', $deliveryId)
                            ->where('is_loaded_hub', 1);
                    })
                    ->orWhere(function ($q) use ($deliveryId) {
                        $q->where('deliverylog_id', $deliveryId)
                            ->where('is_loaded', 1);
                    });
            });
    }
}
