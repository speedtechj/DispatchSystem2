<?php

namespace App\Filament\Shared\Trips;

use App\Models\Deliverylog;
use App\Models\User;
use App\Support\TripFlow;
use Filament\Actions\Action;
use Filament\Forms\Components\CheckboxList;
use Filament\Forms\Components\Select;
use Filament\Notifications\Notification;
use Filament\Schemas\Components\Text;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Illuminate\Support\Facades\Auth;

/** Trip steps on the trip lists: the step column, "Crew on this trip" and "Release truck now". */
class TripActions
{
    public static function stageColumn(): TextColumn
    {
        return TextColumn::make('trip_stage')
            ->label('Step')
            ->badge()
            ->visible(fn () => TripFlow::ready())
            ->getStateUsing(fn (Deliverylog $record) => TripFlow::label($record))
            ->color(fn (Deliverylog $record) => TripFlow::STAGES[TripFlow::stage($record)][2] ?? 'gray')
            ->description(fn (Deliverylog $record) => match (TripFlow::stage($record)) {
                'road' => $record->taken_at ? 'Taken '.$record->taken_at->format('g:i A').($record->taken_boxes !== null ? ' · '.$record->taken_boxes.' boxes' : '') : null,
                'back' => TripFlow::left($record).' to return',
                'closed' => $record->closed_at ? ($record->release_reason === 'auto' ? 'Released by itself ' : 'Released ').$record->closed_at->format('M j g:i A') : null,
                default => null,
            });
    }

    /** Crew people that can be put on a trip (of this hub when the person works at a partner hub). */
    protected static function crewOptions(Deliverylog $trip): array
    {
        $hub = Auth::user()?->logistichub_id;

        return User::with('workposition')->where('is_crew', true)->where('is_active', true)
            ->when(\Filament\Facades\Filament::getCurrentPanel()?->getId() === 'company' && $hub, fn ($q) => $q->where('logistichub_id', $hub))
            ->orderBy('first_name')->get()
            ->mapWithKeys(fn (User $u) => [$u->id => $u->full_name.($u->workposition ? ' · '.$u->workposition->position_description : '')])->all();
    }

    public static function crew(): Action
    {
        return Action::make('tripCrew')
            ->label('Crew on this trip')
            ->icon(Heroicon::UserGroup)
            ->color('gray')
            ->visible(fn (Deliverylog $record) => TripFlow::ready() && $record->is_active)
            ->modalHeading(fn (Deliverylog $record) => 'Crew on trip '.$record->trip_number)
            ->modalDescription('Copied from the truck team. Change it for this trip only: the truck team stays the same.')
            ->fillForm(fn (Deliverylog $record) => ['crew' => TripFlow::crew($record)->pluck('user_id')->all()])
            ->schema(fn (Deliverylog $record) => [
                CheckboxList::make('crew')->label('On this trip')->options(static::crewOptions($record))->columns(2)->required()->searchable(),
                Select::make('reason')->label('Why someone else today (if you change the team)')->options(TripFlow::SWAP_REASONS),
            ])
            ->action(function (Deliverylog $record, array $data): void {
                TripFlow::setCrew($record, $data['crew'] ?? [], $data['reason'] ?? null);
                Notification::make()->title('Crew saved for trip '.$record->trip_number)->body(TripFlow::crew($record)->map(fn ($c) => $c->user?->full_name)->join(', '))->success()->send();
            });
    }

    /** Backup: release the truck by hand, with a reason. Normally the trip closes by itself. */
    public static function release(): Action
    {
        return Action::make('releasetruct')
            ->label('Release truck now')
            ->icon(Heroicon::Truck)
            ->color('info')
            ->visible(fn (Deliverylog $record) => $record->is_active && $record->truck_id)
            ->modalHeading(fn (Deliverylog $record) => 'Release the truck of trip '.$record->trip_number.'?')
            ->schema(fn (Deliverylog $record) => array_filter([
                ($left = TripFlow::ready() ? TripFlow::left($record) : 0) ? Text::make($left.' '.str('box')->plural($left).' still on the trip (not delivered or returned). Normally the truck releases itself when they are done.') : null,
                Select::make('reason')->label('Why now')->options(TripFlow::RELEASE_REASONS)->default('done')->required(),
            ]))
            ->action(function (Deliverylog $record, array $data): void {
                TripFlow::release($record, $data['reason'] ?? 'done');
                Notification::make()->title('Truck released · trip '.$record->trip_number.' closed')->success()->send();
            });
    }
}
