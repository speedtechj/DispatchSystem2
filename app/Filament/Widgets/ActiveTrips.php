<?php

namespace App\Filament\Widgets;

use App\Filament\Resources\Deliverylogs\DeliverylogResource;
use App\Models\Deliverylog;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Columns\ViewColumn;
use Filament\Tables\Table;
use Filament\Widgets\TableWidget;
use Illuminate\Support\Facades\Auth;

class ActiveTrips extends TableWidget
{
    protected static ?int $sort = 2;

    protected int|string|array $columnSpan = 'full';

    protected static ?string $heading = 'Trips on the road';

    public function table(Table $table): Table
    {
        return $table
            ->query(Deliverylog::query()
                ->with(['truck:id,plate_no,description', 'destination:id,hub_name'])
                ->withCount([
                    'tripinvoices as boxes_count',
                    'tripinvoices as loaded_count' => fn ($q) => $q->where('is_loaded', true),
                    'tripinvoices as delivered_count' => fn ($q) => $q->where('is_delivered', true),
                ])
                ->where('logistichub_id', Auth::user()->logistichub_id)
                ->where('is_active', true)
                ->latest('departure_date'))
            ->paginated([5, 10, 25])
            ->defaultPaginationPageOption(5)
            ->emptyStateIcon('heroicon-o-truck')
            ->emptyStateHeading('No active trips')
            ->emptyStateDescription('Create a trip and assign invoices to see it here.')
            ->recordUrl(fn (Deliverylog $record) => DeliverylogResource::getUrl('edit', ['record' => $record]))
            ->columns([
                TextColumn::make('trip_number')->label('Trip')->weight('bold')->searchable(),
                TextColumn::make('destination.hub_name')->label('Going to'),
                TextColumn::make('truck.plate_no')->label('Truck')->description(fn (Deliverylog $record) => $record->truck?->description),
                TextColumn::make('departure_date')->label('Departs')->date('M j'),
                TextColumn::make('eta')->label('ETA')->date('M j'),
                ViewColumn::make('progress')->label('Loaded / delivered')->view('filament.widgets.trip-progress'),
            ]);
    }
}
