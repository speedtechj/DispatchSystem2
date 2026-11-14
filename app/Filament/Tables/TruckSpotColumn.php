<?php

namespace App\Filament\Tables;

use App\Models\Maps\TripStop;
use App\Support\Maps\TripSorter;
use Filament\Tables\Columns\TextColumn;

/** "Truck spot" on a trip's boxes: FRONT / MIDDLE / BACK and the stop number (Maps & routes). */
class TruckSpotColumn
{
    public static function make(): TextColumn
    {
        return TextColumn::make('truck_spot')
            ->label('Truck spot')
            ->badge()
            ->state(function ($record, $livewire): ?string {
                $trip = method_exists($livewire, 'getOwnerRecord') ? $livewire->getOwnerRecord() : null;
                $spot = $trip ? (TripSorter::zoneMap($trip)[$record->id] ?? null) : null;

                return $spot ? (TripStop::ZONES[$spot['zone']] ?? '').' · stop '.$spot['stop'] : null;
            })
            ->color(fn (?string $state): string => match (strtok((string) $state, ' ')) {
                'FRONT' => 'info', 'MIDDLE' => 'primary', 'BACK' => 'warning', default => 'gray',
            })
            ->placeholder('—')
            ->tooltip('FRONT is loaded first (next to the cab), BACK last (at the door)');
    }
}
