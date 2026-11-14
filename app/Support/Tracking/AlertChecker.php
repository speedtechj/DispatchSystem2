<?php

namespace App\Support\Tracking;

use App\Models\Deliverylog;
use App\Models\Tracking\TruckAlert;
use App\Models\Tracking\TruckPosition;
use App\Models\User;
use App\Support\Maps\MapSettings;
use App\Support\Maps\TripSorter;
use Filament\Actions\Action;
use Filament\Notifications\Notification;

/**
 * Every 5 minutes: opens an alert when a truck on a trip is stopped too long away
 * from a stop, has sent no location, is far off its stops, or is back at the
 * warehouse with boxes left. Closes it when that is over. Sends it to the bell.
 */
class AlertChecker
{
    public static function run(): int
    {
        $opened = 0;
        foreach (Tracker::activeTrips(null) as $trip) {
            if (! $trip->truck) {
                continue;
            }
            $now = Tracker::now($trip->truck, $trip);
            $hasLocation = $now['lat'] !== null;
            $last = $hasLocation ? [$now['lat'], $now['lng']] : null;

            $opened += static::toggle($trip, 'stopped', $hasLocation && $now['kind'] === 'warn' && ! $now['atStop'],
                'Stopped '.Tracker::dur($now['stoppedMin']).', not at a stop', $hasLocation ? Tracker::nearPlace($trip, $now['lat'], $now['lng']) : null, $last);

            $everSent = TruckPosition::where('deliverylog_id', $trip->id)->exists();
            $opened += static::toggle($trip, 'no_signal', $everSent && $now['kind'] === 'bad',
                'No location for '.($now['seen'] ? Tracker::dur((int) $now['seen']->diffInMinutes(now())) : 'a while'),
                'The Driver app may be closed or the phone has no signal.', $last);

            $left = Tracker::stopsLeft($trip)->filter->hasPin();
            $off = false;
            $offKm = 0;
            if ($hasLocation && $left->isNotEmpty() && $now['kind'] === 'ok') {
                $offKm = $left->map(fn ($s) => Tracker::km($last, [$s->lat, $s->lng]))->min();
                $start = MapSettings::startFor($trip->user?->warehouse_id, $trip->logistichub_id);
                $fromStart = $start ? Tracker::km($last, [$start[0], $start[1]]) : INF;
                $off = $offKm > TrackSettings::int('off_route') && $fromStart > TrackSettings::int('off_route');
            }
            $opened += static::toggle($trip, 'off_route', $off, 'Far off the route ('.round($offKm, 1).' km from the nearest stop)', null, $last);

            $back = false;
            if (TrackSettings::int('back') && $hasLocation && Tracker::stopsLeft($trip)->isNotEmpty()
                && ($start ??= MapSettings::startFor($trip->user?->warehouse_id, $trip->logistichub_id))) {
                $wentOut = TruckPosition::where('deliverylog_id', $trip->id)->get(['lat', 'lng'])->contains(fn ($p) => Tracker::km([$p->lat, $p->lng], [$start[0], $start[1]]) > 1);
                $back = $wentOut && Tracker::km($last, [$start[0], $start[1]]) < 0.3;
            }
            $left = TripSorter::boxes($trip)->where('is_delivered', false)->count();
            $opened += static::toggle($trip, 'back_with_boxes', $back, 'Back at the warehouse with '.$left.' '.str('box')->plural($left).' left', null, $last);
            unset($start);
        }

        // finished trips: close what is still open
        TruckAlert::whereNull('ended_at')->whereHas('trip', fn ($q) => $q->where('is_active', false))->update(['ended_at' => now()]);

        // keep the history only as long as set
        TruckPosition::where('recorded_at', '<', now()->subDays(max(7, TrackSettings::int('keep_days'))))->limit(20000)->delete();

        return $opened;
    }

    protected static function toggle(Deliverylog $trip, string $kind, bool $on, string $title, ?string $text, ?array $at): int
    {
        $open = TruckAlert::where('truck_id', $trip->truck_id)->where('kind', $kind)->whereNull('ended_at')->first();
        if (! $on) {
            $open?->update(['ended_at' => now()]);

            return 0;
        }
        if ($open) {
            $open->update(['title' => $title]);

            return 0;
        }
        $alert = TruckAlert::create([
            'truck_id' => $trip->truck_id, 'deliverylog_id' => $trip->id, 'kind' => $kind, 'title' => $title, 'text' => $text,
            'lat' => $at[0] ?? null, 'lng' => $at[1] ?? null, 'started_at' => now(),
        ]);
        AlertExplainer::explain($alert);
        static::notify($trip, $alert->fresh());

        return 1;
    }

    protected static function notify(Deliverylog $trip, TruckAlert $alert): void
    {
        $users = User::with('panelcategory')->where('is_active', true)->get()
            ->filter(fn (User $u) => in_array($u->panelcategory?->code, ['adm', 'whse', 'co'], true))
            ->filter(fn (User $u) => (int) $u->logistichub_id === (int) $trip->logistichub_id || ($u->panelcategory?->code === 'adm' && $u->hasRole('super_admin')));

        foreach ($users as $u) {
            $panel = ['adm' => '', 'whse' => '/warehouse', 'co' => '/company'][$u->panelcategory->code];
            Notification::make()
                ->title('🚚 '.$trip->truck?->plate_no.': '.$alert->title)
                ->body($alert->ai_note ? '✨ '.$alert->ai_note : trim('Trip '.$trip->trip_number.'. '.$alert->text))
                ->icon('heroicon-o-truck')->color($alert->kind === 'no_signal' ? 'danger' : 'warning')
                ->actions([Action::make('open')->label('Open the truck')->url(url($panel.'/truck-tracking/truck?truck='.$trip->truck_id.'&tab=alerts'))])
                ->sendToDatabase($u);
        }
    }
}
