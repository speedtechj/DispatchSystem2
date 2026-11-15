<?php

namespace App\Filament\Warehouse\Resources\Whdeliverylogs;

use App\Models\Whdeliverylog;
use App\Support\Boxes\Crossdock;
use App\Support\Boxes\TruckSets;
use Filament\Actions\Action;
use Filament\Notifications\Notification;

/**
 * "🚚 The truck is here now": while on, boxes for this trip's warehouse go straight onto the
 * truck when containers are unloaded (Scan app or Unload container). Scanners pick nothing.
 * Turns off by itself when the trip is locked or closed.
 */
class TruckHereAction
{
    public static function make(string $name = 'truckHere'): Action
    {
        return Action::make($name)
            ->label(fn (Whdeliverylog $record) => $record->truck_here ? 'Truck left: switch off' : '🚚 The truck is here now')
            ->color(fn (Whdeliverylog $record) => $record->truck_here ? 'gray' : 'warning')
            ->visible(fn (Whdeliverylog $record) => Crossdock::ready() && $record->is_active && ! $record->is_lock)
            ->requiresConfirmation()
            ->modalHeading(fn (Whdeliverylog $record) => $record->truck_here ? 'Switch off: the truck left?' : 'The truck to '.($record->warehouse?->name ?? 'the other warehouse').' is here now?')
            ->modalDescription(fn (Whdeliverylog $record) => $record->truck_here
                ? 'Boxes for '.($record->warehouse?->name ?? 'this warehouse').' go to their section again. The boxes already on the truck stay on this trip.'
                : 'While unloading any container here, boxes for '.($record->warehouse?->name ?? 'this warehouse').' go straight onto this truck. Scanners scan as always. It turns off by itself when you lock the trip.')
            ->schema(fn (Whdeliverylog $record) => $record->truck_here ? TruckSets::reasonFields($record) : [])
            ->modalWidth(fn (Whdeliverylog $record) => $record->truck_here && TruckSets::open($record) ? '3xl' : 'md')
            ->action(function (Whdeliverylog $record, array $data): void {
                if ($record->truck_here) {
                    TruckSets::saveReasons($record, $data['why'] ?? []);
                    Crossdock::switchOff($record);
                    Notification::make()->title('Switched off. Boxes for '.($record->warehouse?->name ?? 'that warehouse').' go to their section.')->success()->send();

                    return;
                }
                $section = Crossdock::sectionFor($record);
                if (! $section) {
                    Notification::make()->title('No section goes to '.($record->warehouse?->name ?? 'that warehouse').' yet')
                        ->body('Ask the admin to add one: Settings · places & routes → Warehouse sections (Goes to: '.($record->warehouse?->name ?? 'that warehouse').'). Then switch this on.')
                        ->warning()->persistent()->send();

                    return;
                }
                Crossdock::switchOn($record);
                Notification::make()->title('🚚 Truck here: boxes of section '.$section->code.' now go straight onto trip '.$record->trip_number)->success()->send();
            });
    }
}
