#!/usr/bin/env bash
#
# Dispatch System — Part 18 · inactive trucks and crew
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part18-inactive-crew.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 8 files"

# ---------------------------------------------------------------- app/Filament/Company/Resources/Trucks/RelationManagers/TruckcrewsRelationManager.php
mkdir -p 'app/Filament/Company/Resources/Trucks/RelationManagers'
cat > 'app/Filament/Company/Resources/Trucks/RelationManagers/TruckcrewsRelationManager.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Filament\Company\Resources\Trucks\RelationManagers;

use App\Models\User;
use Filament\Tables\Table;
use Filament\Schemas\Schema;
use Filament\Actions\EditAction;
use Filament\Actions\CreateAction;
use Filament\Actions\DeleteAction;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Filament\Actions\AssociateAction;
use Filament\Actions\BulkActionGroup;
use Filament\Forms\Components\Select;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\DissociateAction;
use Filament\Tables\Columns\TextColumn;
use Illuminate\Database\Eloquent\Model;
use Filament\Forms\Components\TextInput;
use Filament\Actions\DissociateBulkAction;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Resources\RelationManagers\RelationManager;

class TruckcrewsRelationManager extends RelationManager
{
    protected static string $relationship = 'truckcrews';

    public function form(Schema $schema): Schema
    {
        return $schema
            ->components([
                Select::make('crew')
                    ->options(User::All()
                    ->where('is_assigned', false)
                    ->where('is_crew', true)
                    ->where('is_active', true)
                    ->where('logistichub_id', Auth::user()->logistichub_id)
                    ->pluck('full_name', 'id'))
                    ->label('Crew')
                    ->hiddenOn('edit')
                    ->required(),
                MarkdownEditor::make('remarks'),
            ]);
    }

    public function table(Table $table): Table
    {
        return $table
            ->recordTitleAttribute('id')
            ->columns([
                TextColumn::make('Crew')
                    ->label('Crew')
                    ->sortable()
                    ->getStateUsing(function (Model $records){
                       return User::where('id', $records->crew)->first()->full_name;
                    }),
                TextColumn::make('postion')
                    ->label('Postion')
                    ->sortable()
                     ->getStateUsing(function (Model $records){
                      
                       $crewdata =User::where('id', $records->crew)->first();
                       return $crewdata->workposition->position_description;
                    }),
                TextColumn::make('user.full_name')
                    ->label('Created By')
                    ->sortable(),
                TextColumn::make('remarks')
                    ->sortable(),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                //
            ])
            ->headerActions([
               CreateAction::make()
                ->modalHeading('Assign')
                ->modalIcon(Heroicon::UserPlus)
                ->icon(Heroicon::UserPlus)
                ->createAnother(false)
                ->successNotificationTitle('Assigned Successfully')
                 ->modalSubmitActionLabel('Assign')
                ->label('Assigned')
                    ->mutateDataUsing(function (array $data): array {
                      //  dd($livewire->getOwnerRecord());
                        $data['user_id'] = Auth::id();
                        return $data;
                    })
                    ->after(function(array $data){
                        $crew_data = User::where('id', $data['crew'])->first();
                        $crew_data->update([
                            'is_assigned' => true,
                        ]);
                    }),
            ])
            ->recordActions([
                EditAction::make(),
                DeleteAction::make()
                 ->modalHeading('Unassigned')
                ->modalIcon(Heroicon::UserMinus)
                 ->modalSubmitActionLabel('Unassigned')
                ->icon(Heroicon::UserMinus)
                ->label('Unassigned')
                ->successNotificationTitle('Unassigned Successfully')
                ->after(function( $record){      
                    $crew_data = User::where('id', $record->crew)->first();
                    $crew_data->update([
                        'is_assigned' => false,
                    ]);
                }) ,
            ])
            ->toolbarActions([
                BulkActionGroup::make([
                    // DissociateBulkAction::make(),
                    // DeleteBulkAction::make(),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Filament/Shared/Trips/CrewBoardPage.php
mkdir -p 'app/Filament/Shared/Trips'
cat > 'app/Filament/Shared/Trips/CrewBoardPage.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Filament\Shared\Trips;

use App\Models\Deliverylog;
use App\Models\Truck;
use App\Models\Truckcrew;
use App\Models\TripCrew;
use App\Models\User;
use App\Support\TripFlow;
use App\Support\Tracking\Tracker;
use Filament\Facades\Filament;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Support\Facades\Auth;

/** Today's crew board: every truck with its crew, its trip and the next trip; people without a truck; warnings. */
class CrewBoardPage extends Page
{
    protected string $view = 'filament.trips.crew-board';

    protected static ?string $navigationLabel = 'Crew board';

    protected static ?string $title = "Today's crew board";

    protected static string|\BackedEnum|null $navigationIcon = 'heroicon-o-user-group';

    public static function canAccess(): bool
    {
        return TripFlow::ready() && Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId()) !== false;
    }

    public static function getNavigationBadge(): ?string
    {
        try {
            $n = count(array_filter(TripFlow::warnings(Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId())), fn ($w) => $w['tone'] !== 'info'));
        } catch (\Throwable) {
            return null;
        }

        return $n ? (string) $n : null;
    }

    public static function getNavigationBadgeColor(): ?string
    {
        return 'warning';
    }

    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    protected function truck(int $id): ?Truck
    {
        $t = Truck::find($id);

        return $t && Tracker::canSeeTruck($this->hub(), $t) ? $t : null;
    }

    public function addCrew(int $truckId, $userId): void
    {
        $truck = $this->truck($truckId);
        $user = $userId ? TripFlow::crewPeople($this->hub())->firstWhere('id', (int) $userId) : null;
        if (! $truck || ! $user) {
            return;
        }
        // One truck a day: leaving the other truck's team.
        Truckcrew::where('crew', $user->id)->where('truck_id', '!=', $truck->id)->get()->each->delete();
        if (! Truckcrew::where('truck_id', $truck->id)->where('crew', $user->id)->exists()) {
            Truckcrew::create(['truck_id' => $truck->id, 'crew' => $user->id, 'user_id' => Auth::id()]);
        }
        Notification::make()->title($user->full_name.' is on '.$truck->plate_no)->success()->send();
    }

    public function removeCrew(int $truckId, int $userId): void
    {
        if ($truck = $this->truck($truckId)) {
            Truckcrew::where('truck_id', $truck->id)->where('crew', $userId)->get()->each->delete();
        }
    }

    /** A truck without crew today: the crew of its last trip. */
    public function sameAsLastTrip(int $truckId): void
    {
        $truck = $this->truck($truckId);
        $last = $truck ? Deliverylog::where('truck_id', $truck->id)->whereIn('id', TripCrew::select('deliverylog_id'))->latest('id')->first() : null;
        if (! $last) {
            return;
        }
        foreach (TripCrew::where('deliverylog_id', $last->id)->pluck('user_id') as $uid) {
            $this->addCrew($truck->id, $uid);
        }
    }

    protected function getViewData(): array
    {
        $hub = $this->hub();
        $people = TripFlow::crewPeople($hub);
        $teams = Truckcrew::with('member.workposition')->get()->groupBy('truck_id');
        $trucks = Truck::where('is_active', 1)->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->orderBy('plate_no')->get();
        $onTruck = $teams->toBase()->only($trucks->modelKeys())->flatten()->pluck('crew')->map(fn ($i) => (int) $i)->all();

        $tripPage = str_replace('CrewBoard', 'Trip', static::class);

        return [
            'tripUrl' => fn ($t) => class_exists($tripPage) ? $tripPage::urlFor($t) : null,
            'warnings' => TripFlow::warnings($hub),
            'rows' => $trucks->map(function (Truck $t) use ($teams, $people) {
                $trip = TripFlow::runningOn($t->id);
                $team = ($teams[$t->id] ?? collect())->filter(fn ($c) => $c->member)->values();
                $last = $team->isEmpty() ? Deliverylog::where('truck_id', $t->id)->whereIn('id', TripCrew::select('deliverylog_id'))->latest('id')->first() : null;

                return [
                    'truck' => $t, 'team' => $team, 'trip' => $trip, 'stage' => $trip ? TripFlow::stage($trip) : null,
                    'next' => $trip ? TripFlow::nextAfter($trip) : null,
                    'tripCrew' => $trip ? TripFlow::crew($trip) : collect(),
                    'last' => $last ? TripCrew::with('user')->where('deliverylog_id', $last->id)->get()->map(fn ($c) => $c->user?->first_name)->filter()->join(', ') : null,
                    'addable' => $people->reject(fn ($u) => $team->contains('crew', $u->id))->mapWithKeys(fn ($u) => [$u->id => $u->full_name])->all(),
                ];
            }),
            'free' => $people->reject(fn ($u) => in_array((int) $u->id, $onTruck, true))->values(),
            'truckList' => $trucks->pluck('plate_no', 'id')->all(),
        ];
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Filament/Shared/Trips/TripActions.php
mkdir -p 'app/Filament/Shared/Trips'
cat > 'app/Filament/Shared/Trips/TripActions.php' <<'DISPATCH_FILE_END_2'
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
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Filament/Warehouse/Resources/Trucks/RelationManagers/TruckcrewsRelationManager.php
mkdir -p 'app/Filament/Warehouse/Resources/Trucks/RelationManagers'
cat > 'app/Filament/Warehouse/Resources/Trucks/RelationManagers/TruckcrewsRelationManager.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Filament\Warehouse\Resources\Trucks\RelationManagers;

use App\Models\User;
use Filament\Actions\AssociateAction;
use Filament\Actions\BulkActionGroup;
use Filament\Actions\CreateAction;
use Filament\Actions\DeleteAction;
use Filament\Actions\DeleteBulkAction;
use Filament\Actions\DissociateAction;
use Filament\Actions\DissociateBulkAction;
use Filament\Actions\EditAction;
use Filament\Forms\Components\MarkdownEditor;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Resources\RelationManagers\RelationManager;
use Filament\Schemas\Schema;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Auth;

class TruckcrewsRelationManager extends RelationManager
{
    protected static string $relationship = 'truckcrews';

    public function form(Schema $schema): Schema
    {
        return $schema
            ->components([
               Select::make('crew')
                    ->options(User::All()
                    ->where('is_assigned', false)
                    ->where('is_crew', true)
                    ->where('is_active', true)
                    ->where('logistichub_id', Auth::user()->logistichub_id)
                    ->pluck('full_name', 'id'))
                    ->label('Crew')
                    ->hiddenOn('edit')
                    ->required(),
                MarkdownEditor::make('remarks'),
            ]);
    }

    public function table(Table $table): Table
    {
         return $table
            ->recordTitleAttribute('id')
            ->columns([
                TextColumn::make('Crew')
                    ->label('Crew')
                    ->sortable()
                    ->getStateUsing(function (Model $records){
                       return User::where('id', $records->crew)->first()->full_name;
                    }),
                TextColumn::make('postion')
                    ->label('Postion')
                    ->sortable()
                     ->getStateUsing(function (Model $records){

                       $crewdata =User::where('id', $records->crew)->first();
                       return $crewdata->workposition->position_description;
                    }),
                TextColumn::make('user.full_name')
                    ->label('Created By')
                    ->sortable(),
                TextColumn::make('remarks')
                    ->sortable(),
                TextColumn::make('created_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
                TextColumn::make('updated_at')
                    ->dateTime()
                    ->sortable()
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                //
            ])
            ->headerActions([
                CreateAction::make()
                ->modalHeading('Assign')
                ->modalIcon(Heroicon::UserPlus)
                ->icon(Heroicon::UserPlus)
                ->createAnother(false)
                ->successNotificationTitle('Assigned Successfully')
                 ->modalSubmitActionLabel('Assign')
                ->label('Assigned')
                    ->mutateDataUsing(function (array $data): array {
                      //  dd($livewire->getOwnerRecord());
                        $data['user_id'] = Auth::id();
                        return $data;
                    })
                    ->after(function(array $data){
                        $crew_data = User::where('id', $data['crew'])->first();
                        $crew_data->update([
                            'is_assigned' => true,
                        ]);
                    }),

            ])
            ->recordActions([
        //        EditAction::make(),
                DeleteAction::make()
                 ->modalHeading('Unassigned')
                ->modalIcon(Heroicon::UserMinus)
                 ->modalSubmitActionLabel('Unassigned')
                ->icon(Heroicon::UserMinus)
                ->label('Unassigned')
                ->successNotificationTitle('Unassigned Successfully')
                ->after(function( $record){
                    $crew_data = User::where('id', $record->crew)->first();
                    $crew_data->update([
                        'is_assigned' => false,
                    ]);
                }) ,
            ])
            ->toolbarActions([
                BulkActionGroup::make([
              //      DissociateBulkAction::make(),
              //      DeleteBulkAction::make(),
                ]),
            ]);
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Models/Truckcrew.php
mkdir -p 'app/Models'
cat > 'app/Models/Truckcrew.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Truckcrew extends Model
{
    /** The truck team changed: trips of this truck that did not leave yet follow it (swaps made for one trip stay). */
    protected static function booted(): void
    {
        static::created(fn (Truckcrew $c) => \App\Support\TripFlow::teamChanged((int) $c->truck_id, (int) $c->crew, true));
        static::deleted(fn (Truckcrew $c) => \App\Support\TripFlow::teamChanged((int) $c->truck_id, (int) $c->crew, false));
    }

    public function truck()
    {
        return $this->belongsTo(Truck::class);
    }
    /** Who added this person to the truck. */
    public function user() {
        return $this->belongsTo(User::class);
    }

    /** The crew member (leadman, driver or helper) on the truck. */
    public function member()
    {
        return $this->belongsTo(User::class, 'crew');
    }
    
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Support/TripFlow.php
mkdir -p 'app/Support'
cat > 'app/Support/TripFlow.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Support;

use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Models\TripCrew;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * A trip from plan to closed: Planned → Loading → Ready → On the road → Back → Closed.
 * Each trip keeps its own crew (copied from the truck team). The trip closes and the truck is
 * released by itself when every box is delivered or returned.
 */
class TripFlow
{
    /** key => [label, who moves it on, colour] */
    public const STAGES = [
        'waiting' => ['Next trip · waits for the truck', 'Automatic', 'gray'],
        'planned' => ['Planned', 'Office', 'info'],
        'loading' => ['Loading', 'Warehouse', 'warning'],
        'ready' => ['Ready', 'Office locked it', 'primary'],
        'road' => ['On the road', 'Driver', 'success'],
        'back' => ['Back', 'Driver', 'warning'],
        'closed' => ['Closed', 'Automatic', 'gray'],
    ];

    public const RELEASE_REASONS = [
        'done' => 'Trip done',
        'hub' => 'Boxes handed to the partner hub',
        'broke_down' => 'Truck broke down',
        'cancelled' => 'Trip cancelled',
        'other' => 'Other',
    ];

    public const SWAP_REASONS = ['sick' => 'Sick', 'day_off' => 'Day off', 'other_truck' => 'On another truck', 'other' => 'Other'];

    public static function ready(): bool
    {
        static $ready;

        return $ready ??= Schema::hasTable('trip_crews') && Schema::hasColumn('deliverylogs', 'taken_at');
    }

    public static function queueReady(): bool
    {
        static $ready;

        return $ready ??= Schema::hasColumn('deliverylogs', 'waits_for');
    }

    // ------------------------------------------------------------------ next trip waiting

    /** Trips not waiting for another trip that still runs (the trip they waited for may be closed by hand). */
    public static function notWaiting($q)
    {
        return $q->where(fn ($q) => $q->whereNull('waits_for')
            ->orWhereIn('waits_for', Deliverylog::query()->select('id')->where('is_active', false)));
    }

    /** The trip that still runs on this truck (another one than $except). */
    public static function runningOn(?int $truckId, ?int $except = null): ?Deliverylog
    {
        return $truckId ? Deliverylog::where('truck_id', $truckId)->where('is_active', true)
            ->when($except, fn ($q) => $q->whereKeyNot($except))
            ->when(static::queueReady(), fn ($q) => static::notWaiting($q))->oldest('id')->first() : null;
    }

    /** This trip waits for the truck's current trip to close. */
    public static function waitsFor(Deliverylog $trip): ?Deliverylog
    {
        if (! static::queueReady() || ! $trip->waits_for) {
            return null;
        }
        $before = Deliverylog::find($trip->waits_for);

        return $before && $before->is_active ? $before : null;
    }

    /** The next trip planned for the same truck, waiting for this one. */
    public static function nextAfter(Deliverylog $trip): ?Deliverylog
    {
        return static::queueReady() ? Deliverylog::where('waits_for', $trip->id)->where('is_active', true)->oldest('id')->first() : null;
    }

    /** Truck list for a trip: free trucks, and trucks still out (the trip then waits for them). */
    public static function truckOptions(?int $hubId, ?int $tripId = null): array
    {
        $trucks = \App\Models\Truck::query()->where('is_active', 1)->when($hubId, fn ($q) => $q->where('logistichub_id', $hubId))->orderBy('plate_no')->get();

        return $trucks->mapWithKeys(function ($t) use ($tripId) {
            $on = $t->is_assigned ? static::runningOn($t->id, $tripId) : null;
            if ($t->is_assigned && ! $on && ! static::queueReady()) {
                return [];
            }

            return [$t->id => $t->plate_no.($on ? ' · on '.$on->trip_number.' (this trip waits for it)' : '')];
        })->all();
    }

    // ------------------------------------------------------------------ steps

    public static function stage(Deliverylog $trip): string
    {
        if (! $trip->is_active) {
            return 'closed';
        }
        if (static::waitsFor($trip)) {
            return 'waiting';
        }
        if (static::ready() && $trip->back_at) {
            return 'back';
        }
        if (static::ready() && $trip->taken_at) {
            return 'road';
        }
        if ($trip->is_lock) {
            return 'ready';
        }
        if ($trip->is_current || Tripinvoice::where('deliverylog_id', $trip->id)->where('is_loaded', true)->exists()) {
            return 'loading';
        }

        return 'planned';
    }

    public static function label(Deliverylog $trip): string
    {
        return static::STAGES[static::stage($trip)][0];
    }

    /** The leadman (or anyone on the crew) takes the trip: it is on the road, with the box count confirmed. */
    public static function take(Deliverylog $trip, ?User $by = null): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        $by ??= Auth::user();
        $trip->forceFill(['taken_at' => now(), 'taken_by' => $by?->id, 'taken_boxes' => static::boxes($trip)->count(), 'is_current' => true])->save();
    }

    /** The driver is back at the hub; boxes not delivered are scanned back with Return boxes. */
    public static function back(Deliverylog $trip): void
    {
        if (! static::ready() || $trip->back_at) {
            return;
        }
        $trip->forceFill(['back_at' => now(), 'taken_at' => $trip->taken_at ?? now()])->save();
        static::maybeClose($trip->fresh());
    }

    /** Boxes the trip still carries (main trip or a partner hub's own trip). */
    public static function boxes(Deliverylog $trip)
    {
        return Tripinvoice::query()->where(fn ($q) => $q->where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id));
    }

    /** Boxes still to deliver or return. Boxes a partner hub received off this truck count as done. */
    public static function left(Deliverylog $trip): int
    {
        $handed = TruckReceiptReady::finishedHubs($trip->id);

        return static::boxes($trip)->where(fn ($q) => $q->where('is_delivered', false)->orWhereNull('is_delivered'))
            ->when($handed, fn ($q) => $q->where(fn ($q) => $q->whereNull('logistichub_id')->orWhereNotIn('logistichub_id', $handed)->orWhere('deliveryloghub_id', $trip->id)))
            ->count();
    }

    /** Close the trip and free the truck when nothing is left: every box delivered, returned or received by the hub. */
    public static function maybeClose(?Deliverylog $trip): bool
    {
        if (! $trip || ! static::ready() || ! $trip->is_active || ! $trip->truck_id) {
            return false;
        }
        // Every box delivered, returned (taken off the trip) or received by the partner hub.
        $total = static::boxes($trip)->count();
        if ($total === 0 ? ! $trip->back_at : static::left($trip) > 0) {
            return false;
        }
        static::release($trip, 'done', auto: true);

        return true;
    }

    /** Free the truck and close the trip (by itself, or by the office with a reason). */
    public static function release(Deliverylog $trip, string $reason = 'done', bool $auto = false): void
    {
        app(TripAssignment::class)->releaseTruck($trip);
        if (static::ready()) {
            $trip->forceFill(['closed_at' => now(), 'release_reason' => $auto ? 'auto' : $reason])->saveQuietly();
        }
        // The next trip waiting for this truck starts now: the crew sees it right away.
        if ($next = static::nextAfter($trip)) {
            $next->forceFill(['waits_for' => null])->saveQuietly();
            // More trips planned for this truck: they now wait for the one that just started, in order.
            Deliverylog::where('waits_for', $trip->id)->where('is_active', true)->whereKeyNot($next->id)->update(['waits_for' => $next->id]);
            $trip->truck?->update(['is_assigned' => true]);
        }
    }

    // ------------------------------------------------------------------ crew of the trip

    /** Copy the truck team onto the trip, when it has no crew yet. */
    public static function copyCrew(Deliverylog $trip): void
    {
        if (! static::ready() || ! $trip->truck_id || TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            return;
        }
        // Only active people: someone made inactive stays off new trips.
        $users = User::with('workposition')->where('is_active', true)->whereIn('id', Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew'))->get();
        foreach ($users as $u) {
            TripCrew::firstOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $u->id], ['role' => $u->workposition?->position_description]);
        }
    }

    /** The truck changed before the trip left: take the new truck's team. */
    public static function truckChanged(Deliverylog $trip, ?int $oldTruckId = null): void
    {
        if (! static::ready() || $trip->taken_at) {
            return;
        }
        // The old truck's team leaves the trip; people the office picked by hand stay.
        $oldTeam = $oldTruckId ? Truckcrew::where('truck_id', $oldTruckId)->pluck('crew') : collect();
        TripCrew::where('deliverylog_id', $trip->id)->whereNull('replaces_user_id')->whereIn('user_id', $oldTeam)->delete();
        if (! TripCrew::where('deliverylog_id', $trip->id)->exists()) {
            static::copyCrew($trip);
        }
    }

    /** Someone joined or left the truck team: update the trips of the truck that did not leave yet. */
    public static function teamChanged(int $truckId, int $userId, bool $joined): void
    {
        if (! static::ready() || ! $truckId || ! $userId || ($joined && ! User::whereKey($userId)->where('is_active', true)->exists())) {
            return;
        }
        $trips = Deliverylog::where('truck_id', $truckId)->where('is_active', true)->whereNull('taken_at')->pluck('id');
        foreach ($trips as $tripId) {
            if ($joined) {
                if (! TripCrew::where('deliverylog_id', $tripId)->where('replaces_user_id', $userId)->exists()) {
                    TripCrew::firstOrCreate(['deliverylog_id' => $tripId, 'user_id' => $userId], ['role' => User::find($userId)?->workposition?->position_description]);
                }
            } else {
                TripCrew::where('deliverylog_id', $tripId)->where('user_id', $userId)->whereNull('replaces_user_id')->delete();
            }
        }
    }

    /** @return Collection<int, TripCrew> */
    public static function crew(Deliverylog $trip): Collection
    {
        if (! static::ready()) {
            return collect();
        }
        static::copyCrew($trip);

        return TripCrew::with('user.workposition', 'replaces')->where('deliverylog_id', $trip->id)->orderBy('id')->get()
            ->sortBy(fn ($c) => static::isLead($c) ? 0 : 1)->values();
    }

    public static function isLead(TripCrew $c): bool
    {
        return Str::contains(Str::lower((string) ($c->role ?? $c->user?->workposition?->position_description)), 'lead');
    }

    /** Who may tap "I take the trip": the leadman; anyone on the crew when there is no leadman. */
    public static function canTake(Deliverylog $trip, User $user): bool
    {
        $crew = static::crew($trip);
        $leads = $crew->filter(fn ($c) => static::isLead($c));

        return ($leads->isNotEmpty() ? $leads : $crew)->contains(fn ($c) => (int) $c->user_id === (int) $user->id);
    }

    /**
     * Set the crew for this trip only. People not in the truck team are marked as replacing
     * the team members left out.
     *
     * @param  list<int>  $userIds
     */
    public static function setCrew(Deliverylog $trip, array $userIds, ?string $reason = null): void
    {
        $userIds = array_values(array_unique(array_map('intval', $userIds)));
        $team = Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew')->map(fn ($i) => (int) $i)->unique()->values()->all();
        $out = array_values(array_diff($team, $userIds));
        TripCrew::where('deliverylog_id', $trip->id)->whereNotIn('user_id', $userIds)->delete();
        $users = User::with('workposition')->whereIn('id', $userIds)->get()->keyBy('id');
        foreach ($userIds as $i => $id) {
            $isNew = ! in_array($id, $team, true);
            TripCrew::updateOrCreate(['deliverylog_id' => $trip->id, 'user_id' => $id], [
                'role' => $users[$id]?->workposition?->position_description,
                'replaces_user_id' => $isNew ? ($out[$i] ?? $out[0] ?? null) : null,
                'reason' => $isNew ? $reason : null,
            ]);
        }
    }

    /** The trip a crew member works on now: newest active trip with them on its crew (or their truck's). */
    public static function tripFor(User $user): ?Deliverylog
    {
        if (static::ready()) {
            $trip = Deliverylog::with('truck')->where('is_active', true)
                ->when(static::queueReady(), fn ($q) => static::notWaiting($q))
                ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('id')->first();
            if ($trip) {
                return $trip;
            }
        }
        $truckId = Truckcrew::where('crew', $user->getKey())->latest('id')->value('truck_id');
        if (! $truckId) {
            return null;
        }
        $trip = Deliverylog::with('truck')->where('truck_id', $truckId)->where('is_active', true)
            ->when(static::queueReady(), fn ($q) => static::notWaiting($q))->latest('id')->first();
        // Someone replaced this person on that trip: it is not theirs.
        if ($trip && static::ready() && TripCrew::where('deliverylog_id', $trip->id)->exists()
            && ! TripCrew::where('deliverylog_id', $trip->id)->where('user_id', $user->id)->exists()) {
            return null;
        }

        return $trip;
    }

    /** The trip that closed in the last 12 hours, for the "Trip done" screen. */
    public static function justClosedFor(User $user): ?Deliverylog
    {
        if (! static::ready()) {
            return null;
        }

        return Deliverylog::with('truck')->where('is_active', false)->where('closed_at', '>=', now()->subHours(12))
            ->whereIn('id', TripCrew::where('user_id', $user->id)->select('deliverylog_id'))->latest('closed_at')->first();
    }

    // ------------------------------------------------------------------ warnings (crew board)

    /** Crew people of the hub (null = all hubs). */
    public static function crewPeople(int|false|null $hub): Collection
    {
        return User::with('workposition')->where('is_crew', true)->where('is_active', true)
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))
            ->when($hub === false, fn ($q) => $q->whereRaw('1 = 0'))
            ->orderBy('first_name')->get();
    }

    /**
     * What needs a look now: trips ready but not taken, trucks back with boxes not returned,
     * trucks out very long, crew without a truck, trucks on a trip without crew.
     *
     * @return list<array{tone: string, text: string}>
     */
    public static function warnings(int|false|null $hub): array
    {
        if (! static::ready() || $hub === false) {
            return [];
        }
        $out = [];
        $trips = Deliverylog::with('truck:id,plate_no')->where('is_active', true)->whereNotNull('truck_id')
            ->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->get();
        foreach ($trips as $t) {
            $stage = static::stage($t);
            if ($stage === 'ready' && $t->ready_at && $t->ready_at->lt(now()->subMinutes(30))) {
                $out[] = ['tone' => 'warn', 'text' => 'Trip '.$t->trip_number.' is ready since '.$t->ready_at->format('g:i A').' · nobody took it yet.'];
            }
            if ($stage === 'back' && $t->back_at?->lt(now()->subHours(2)) && ($left = static::left($t)) > 0) {
                $out[] = ['tone' => 'warn', 'text' => 'Truck '.$t->truck?->plate_no.' is back since '.$t->back_at->format('g:i A').' · '.$left.' '.str('box')->plural($left).' not returned yet (Return boxes).'];
            }
            if ($stage === 'road' && $t->taken_at?->lt(now()->subHours(14))) {
                $out[] = ['tone' => 'warn', 'text' => 'Truck '.$t->truck?->plate_no.' is on trip '.$t->trip_number.' since '.$t->taken_at->format('M j g:i A').'. Still out?'];
            }
            if (in_array($stage, ['ready', 'road'], true) && ! TripCrew::where('deliverylog_id', $t->id)->exists()) {
                $out[] = ['tone' => 'bad', 'text' => 'Trip '.$t->trip_number.' has no crew. Crew on this trip in the trip list.'];
            }
        }
        foreach (Truckcrew::with('member', 'truck')->whereHas('member', fn ($q) => $q->where('is_active', false))->get() as $c) {
            if ($hub === null || (int) $c->truck?->logistichub_id === $hub) {
                $out[] = ['tone' => 'warn', 'text' => ($c->member?->full_name ?? 'Someone').' is inactive but still on the team of '.($c->truck?->plate_no ?? 'a truck').'. Take them off on the crew board.'];
            }
        }
        // On the team of an active truck (a truck made inactive does not count).
        $onTruck = Truckcrew::whereHas('truck', fn ($q) => $q->where('is_active', true))->pluck('crew')->map(fn ($i) => (int) $i)->all();
        foreach (static::crewPeople($hub)->reject(fn ($u) => in_array((int) $u->id, $onTruck, true)) as $u) {
            $out[] = ['tone' => 'info', 'text' => $u->full_name.' has no truck.'];
        }

        return $out;
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- resources/views/filament/trips/crew-board.blade.php
mkdir -p 'resources/views/filament/trips'
cat > 'resources/views/filament/trips/crew-board.blade.php' <<'DISPATCH_FILE_END_6'
<x-filament-panels::page>
<div class="ds-cb">
    @if ($warnings)
        <section class="ds-cb__warn">
            @foreach ($warnings as $w)
                <span @class(['is-'.$w['tone']])>{{ $w['tone'] === 'info' ? 'ℹ' : '⚠' }} {{ $w['text'] }}</span>
            @endforeach
        </section>
    @endif

    <div class="ds-cb__grid">
        @forelse ($rows as $r)
            <section class="ds-board__panel ds-cb__truck" wire:key="tr-{{ $r['truck']->id }}">
                <header>
                    <b>{{ $r['truck']->plate_no }}</b>
                    @if ($r['trip'])
                        <a href="{{ $tripUrl($r['trip']) }}" class="ds-cb__pill is-{{ $r['stage'] }}">{{ $r['trip']->trip_number }} · {{ \App\Support\TripFlow::STAGES[$r['stage']][0] ?? '' }} ›</a>
                    @else
                        <span class="ds-cb__pill is-free">Free</span>
                    @endif
                </header>

                <small class="ds-board__muted">Truck team</small>
                @forelse ($r['team'] as $c)
                    <span class="ds-cb__person" wire:key="p-{{ $r['truck']->id }}-{{ $c->crew }}">
                        <span><b>{{ $c->member->full_name }}</b><small>{{ $c->member->workposition?->position_description }}{{ $c->member->is_active ? '' : ' · inactive' }}</small></span>
                        <button type="button" class="ds-fu__link" wire:click="removeCrew({{ $r['truck']->id }}, {{ $c->crew }})" aria-label="Take {{ $c->member->full_name }} off {{ $r['truck']->plate_no }}">✕</button>
                    </span>
                @empty
                    <p class="ds-cb__none">No crew on this truck.</p>
                    @if ($r['last'])
                        <x-filament::button size="sm" color="gray" wire:click="sameAsLastTrip({{ $r['truck']->id }})">Same as last trip · {{ $r['last'] }}</x-filament::button>
                    @endif
                @endforelse
                @if ($r['addable'])
                    <select class="ds-cb__add" wire:change="addCrew({{ $r['truck']->id }}, $event.target.value)" aria-label="Add someone to {{ $r['truck']->plate_no }}">
                        <option value="">+ Add someone…</option>
                        @foreach ($r['addable'] as $uid => $name)<option value="{{ $uid }}">{{ $name }}</option>@endforeach
                    </select>
                @endif

                @if ($r['trip'] && $r['tripCrew']->pluck('user_id')->sort()->values()->all() !== $r['team']->pluck('crew')->map(fn ($i) => (int) $i)->sort()->values()->all())
                    <small class="ds-cb__note">On trip {{ $r['trip']->trip_number }}: {{ $r['tripCrew']->map(fn ($c) => $c->user?->first_name.($c->replaces_user_id ? ' (instead of '.$c->replaces?->first_name.')' : ''))->join(', ') ?: 'nobody' }}</small>
                @endif
                @if ($r['next'])
                    <small class="ds-cb__next">Next trip waiting: <a href="{{ $tripUrl($r['next']) }}"><b>{{ $r['next']->trip_number }}</b></a> · starts when {{ $r['trip']->trip_number }} closes</small>
                @endif
            </section>
        @empty
            <p class="ds-board__muted">No active trucks.</p>
        @endforelse
    </div>

    <section class="ds-board__panel ds-cb__free">
        <h3>Crew without a truck</h3>
        @forelse ($free as $u)
            <span class="ds-cb__person" wire:key="f-{{ $u->id }}">
                <span><b>{{ $u->full_name }}</b><small>{{ $u->workposition?->position_description }}</small></span>
                <select class="ds-cb__add" wire:change="addCrew($event.target.value, {{ $u->id }})" aria-label="Put {{ $u->full_name }} on a truck">
                    <option value="">Put on a truck…</option>
                    @foreach ($truckList as $tid => $plate)<option value="{{ $tid }}">{{ $plate }}</option>@endforeach
                </select>
            </span>
        @empty
            <p class="ds-board__muted">Everyone has a truck.</p>
        @endforelse
        <p class="ds-board__muted">The truck team is copied onto each new trip. To change one trip only, use Crew on this trip in the trip list.</p>
    </section>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- tests/Feature/TripStepsTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/TripStepsTest.php' <<'DISPATCH_FILE_END_7'
<?php

use App\Filament\Delivery\Pages\Dashboard as DriverDashboard;
use App\Filament\Resources\Deliverylogs\Pages\ListDeliverylogs;
use App\Models\Deliverylog;
use App\Models\TripCrew;
use App\Models\Tripinvoice;
use App\Models\Truckcrew;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\DriverTrip;
use App\Support\TripFlow;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->sub = $this->driver->replicate()->fill(['email' => 'mark@example.com', 'first_name' => 'Mark']);
    $this->sub->save();
});

it('copies the truck team onto a new trip, follows team changes until the trip leaves, and swaps for one trip only', function () {
    $trip = Deliverylog::create(['truck_id' => $this->trip->truck_id, 'logistichub_id' => $this->trip->logistichub_id, 'assigned_to' => $this->trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    // Truck A is still on the demo trip: the new trip is the next trip waiting.
    expect(TripFlow::crew($trip)->pluck('user_id')->all())->toBe([$this->driver->id])
        ->and(TripFlow::stage($trip))->toBe('waiting')
        ->and(TripFlow::nextAfter($this->trip)?->id)->toBe($trip->id);

    // Mark is sick-cover for this trip only: the truck team stays the same.
    TripFlow::setCrew($trip, [$this->sub->id], 'sick');
    $row = TripCrew::where('deliverylog_id', $trip->id)->sole();
    expect($row->user_id)->toBe($this->sub->id)->and($row->replaces_user_id)->toBe($this->driver->id)->and($row->reason)->toBe('sick')
        ->and(Truckcrew::where('truck_id', $trip->truck_id)->pluck('crew')->all())->toBe([$this->driver->id])
        ->and(TripFlow::tripFor($this->sub))->toBeNull()                    // waits for the truck
        ->and(TripFlow::tripFor($this->driver)?->id)->toBe($this->trip->id);

    // The demo trip closes: the next trip starts, Mark sees it.
    TripFlow::release($this->trip, 'done');
    expect(TripFlow::stage($trip->fresh()))->toBe('planned')
        ->and($trip->fresh()->truck->is_assigned)->toBeTrue()
        ->and(TripFlow::tripFor($this->sub)?->id)->toBe($trip->id)
        ->and(TripFlow::tripFor($this->driver))->toBeNull();
});

it('goes Ready → On the road → Back → Closed, and the truck releases itself', function () {
    $this->trip->truck->update(['is_assigned' => true]);
    Filament::setCurrentPanel(Filament::getPanel('delivery'));
    $this->actingAs($this->driver);

    expect(TripFlow::stage($this->trip))->toBe('loading');
    Livewire::test(DriverDashboard::class)->assertSee('Being loaded')->assertDontSee('I take the trip');

    $this->trip->update(['is_lock' => true]);
    Livewire::test(DriverDashboard::class)->assertSee('Trip ready')->assertSee('I take the trip · 6 boxes')->call('takeTrip');
    $trip = $this->trip->fresh();
    expect(TripFlow::stage($trip))->toBe('road')->and($trip->taken_by)->toBe($this->driver->id)->and($trip->taken_boxes)->toBe(6);

    $rows = Tripinvoice::where('deliverylog_id', $trip->id)->orderBy('id')->get();
    foreach ($rows->take(5) as $r) {
        app(TripAssignment::class)->markDelivered($r, ['p.jpg']);
    }
    expect($trip->fresh()->is_active)->toBeTrue();
    Livewire::test(DriverDashboard::class)->assertSee('Back at the hub')->call('backAtHub');
    expect(TripFlow::stage($trip->fresh()))->toBe('back');

    // The last box is scanned back at the hub: the trip closes by itself.
    app(TripAssignment::class)->returnToInventory($rows->last());
    $trip = $trip->fresh();
    expect($trip->is_active)->toBeFalse()->and($trip->release_reason)->toBe('auto')->and($trip->truck->fresh()->is_assigned)->toBeFalse();

    Livewire::test(DriverDashboard::class)->assertSee('done · truck released')->assertSee('All 5 boxes delivered');
});

it('closes the trip when the last box is delivered, even without Back at the hub', function () {
    foreach (Tripinvoice::where('deliverylog_id', $this->trip->id)->get() as $r) {
        app(TripAssignment::class)->markDelivered($r, ['p.jpg']);
    }
    expect($this->trip->fresh()->is_active)->toBeFalse()->and($this->trip->fresh()->closed_at)->not->toBeNull();
});

it('lets the office change the crew of a trip and release the truck with a reason', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    Livewire::test(ListDeliverylogs::class)->assertSee('Loading')
        ->callTableAction('tripCrew', $this->trip, data: ['crew' => [$this->sub->id], 'reason' => 'day_off'])->assertHasNoTableActionErrors();
    expect(TripFlow::crew($this->trip)->pluck('user_id')->all())->toBe([$this->sub->id])
        ->and(DriverTrip::currentTrip($this->sub)?->id)->toBe($this->trip->id)
        ->and(DriverTrip::currentTrip($this->driver))->toBeNull();

    Livewire::test(ListDeliverylogs::class)->callTableAction('releasetruct', $this->trip, data: ['reason' => 'broke_down'])->assertHasNoTableActionErrors();
    expect($this->trip->fresh()->is_active)->toBeFalse()->and($this->trip->fresh()->release_reason)->toBe('broke_down');
});

it('shows today\'s crew board with the warnings, and puts people on trucks', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->sub->update(['is_crew' => true]);
    $this->trip->update(['is_lock' => true]);
    $this->trip->forceFill(['ready_at' => now()->subHour()])->saveQuietly();

    Livewire::test(\App\Filament\Pages\CrewBoard::class)
        ->assertSee($this->trip->truck->plate_no)->assertSee($this->trip->trip_number.' · Ready')
        ->assertSee('nobody took it yet')->assertSee('Mark '.$this->sub->last_name.' has no truck')
        ->call('addCrew', $this->trip->truck_id, $this->sub->id)
        ->assertDontSee('has no truck');
    expect(Truckcrew::where('truck_id', $this->trip->truck_id)->pluck('crew')->sort()->values()->all())->toBe(collect([$this->driver->id, $this->sub->id])->sort()->values()->all())
        ->and(TripFlow::crew($this->trip)->pluck('user_id')->all())->toContain($this->sub->id); // the trip did not leave yet: it follows
});

it('plans more trips for one truck: they start one after the other', function () {
    $mk = fn () => Deliverylog::create(['truck_id' => $this->trip->truck_id, 'logistichub_id' => $this->trip->logistichub_id, 'assigned_to' => $this->trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    $second = $mk();
    $third = $mk();
    expect(TripFlow::stage($second))->toBe('waiting')->and(TripFlow::stage($third))->toBe('waiting')
        ->and(TripFlow::tripFor($this->driver)?->id)->toBe($this->trip->id);

    TripFlow::release($this->trip, 'done');
    expect(TripFlow::tripFor($this->driver)?->id)->toBe($second->id)
        ->and(TripFlow::stage($third->fresh()))->toBe('waiting')
        ->and(TripFlow::nextAfter($second->fresh())?->id)->toBe($third->id);

    TripFlow::release($second->fresh(), 'done');
    expect(TripFlow::tripFor($this->driver)?->id)->toBe($third->id)->and(TripFlow::stage($third->fresh()))->not->toBe('waiting');
});

it('shows one trip on one page: steps, crew, warnings, next trip, and the office buttons', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $next = Deliverylog::create(['truck_id' => $this->trip->truck_id, 'logistichub_id' => $this->trip->logistichub_id, 'assigned_to' => $this->trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);

    $this->get(\App\Filament\Pages\Trip::getUrl(['trip' => $this->trip->id]))->assertOk()
        ->assertSee('1 Planned')->assertSee('Leadman took the trip')->assertSee('Crew on this trip')
        ->assertSee($this->driver->full_name)->assertSee('Next trip waiting for')->assertSee($next->trip_number);
    $this->get(\App\Filament\Pages\Trip::getUrl(['trip' => $next->id]))->assertOk()
        ->assertSee('is still on trip '.$this->trip->trip_number)->assertSee('Next trip · waits for the truck');

    Livewire::withQueryParams(['trip' => $this->trip->id])->test(\App\Filament\Pages\Trip::class)
        ->callAction('lock')->callAction('tripCrew', data: ['crew' => [$this->sub->id], 'reason' => 'sick'])
        ->assertSee('instead of '.$this->driver->full_name);
    expect($this->trip->fresh()->is_lock)->toBeTrue()->and(TripFlow::stage($this->trip->fresh()))->toBe('ready');

    Livewire::withQueryParams(['trip' => $this->trip->id])->test(\App\Filament\Pages\Trip::class)
        ->callAction('releasetruct', data: ['reason' => 'cancelled']);
    expect($this->trip->fresh()->release_reason)->toBe('cancelled')->and(TripFlow::stage($next->fresh()))->toBe('planned');

    // The trip list opens the page.
    Livewire::test(ListDeliverylogs::class)->assertSee(\App\Filament\Pages\Trip::getUrl(['trip' => $next->id]), false);
});

it('lets the office pick the crew of a trip that has no truck yet, and keeps it when the truck is picked', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $trip = Deliverylog::create(['truck_id' => null, 'logistichub_id' => $this->trip->logistichub_id, 'assigned_to' => $this->trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);

    Livewire::withQueryParams(['trip' => $trip->id])->test(\App\Filament\Pages\Trip::class)
        ->assertSee('No truck and no crew yet')->assertActionVisible('tripCrew')
        ->callAction('tripCrew', data: ['crew' => [$this->sub->id]]);
    $trip->update(['truck_id' => \App\Models\Truck::where('id', '!=', $this->trip->truck_id)->value('id') ?? $this->trip->truck_id]);
    expect(TripFlow::crew($trip->fresh())->pluck('user_id')->all())->toContain($this->sub->id);
});

it('leaves inactive people off trips and crew lists, and shows the crew member (not who added them) on the crew board', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->sub->update(['is_crew' => true, 'is_active' => false]);
    Truckcrew::create(['truck_id' => $this->trip->truck_id, 'crew' => $this->sub->id, 'user_id' => $this->admin->id]);

    $trip = Deliverylog::create(['truck_id' => $this->trip->truck_id, 'logistichub_id' => $this->trip->logistichub_id, 'assigned_to' => $this->trip->assigned_to, 'user_id' => $this->admin->id, 'trip_day' => 1, 'eta' => today(), 'departure_date' => today(), 'is_active' => true]);
    expect(TripFlow::crew($trip)->pluck('user_id')->all())->toBe([$this->driver->id])
        ->and(TripFlow::crewPeople(null)->pluck('id')->all())->not->toContain($this->sub->id);

    Livewire::test(\App\Filament\Pages\CrewBoard::class)
        ->assertSee($this->driver->full_name)->assertSee('inactive but still on the team')
        ->call('removeCrew', $this->trip->truck_id, $this->sub->id)->assertDontSee('inactive but still on the team');
});

it('counts people on an inactive truck as without a truck', function () {
    $this->actingAs($this->admin);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->driver->update(['is_crew' => true]);
    $this->trip->truck->update(['is_active' => false]);

    Livewire::test(\App\Filament\Pages\CrewBoard::class)->assertSee($this->driver->full_name.' has no truck')
        ->assertDontSee($this->trip->truck->plate_no);
});
DISPATCH_FILE_END_7

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
