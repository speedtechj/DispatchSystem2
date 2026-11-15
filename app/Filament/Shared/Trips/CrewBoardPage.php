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
        $teams = Truckcrew::with('user.workposition')->get()->groupBy('truck_id');
        $trucks = Truck::where('is_active', 1)->when(is_int($hub), fn ($q) => $q->where('logistichub_id', $hub))->orderBy('plate_no')->get();
        $onTruck = $teams->flatten()->pluck('crew')->map(fn ($i) => (int) $i)->all();

        $tripPage = str_replace('CrewBoard', 'Trip', static::class);

        return [
            'tripUrl' => fn ($t) => class_exists($tripPage) ? $tripPage::urlFor($t) : null,
            'warnings' => TripFlow::warnings($hub),
            'rows' => $trucks->map(function (Truck $t) use ($teams, $people) {
                $trip = TripFlow::runningOn($t->id);
                $team = ($teams[$t->id] ?? collect())->filter(fn ($c) => $c->user)->values();
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
