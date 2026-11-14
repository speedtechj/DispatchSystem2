<?php

namespace App\Filament\Shared\Tracking;

use App\Models\Deliverylog;
use App\Models\Maps\TripStop;
use App\Models\Tracking\TruckAlert;
use App\Support\Maps\MapSettings;
use App\Support\Maps\TripSorter;
use App\Support\Tracking\Tracker;
use App\Support\Tracking\TrackSettings;
use Filament\Facades\Filament;
use Illuminate\Support\Facades\Auth;

/** Shared by the Truck tracking page and the one-truck page. */
trait TracksTrucks
{
    protected function hub(): int|false|null
    {
        return Tracker::hubFor(Auth::user(), Filament::getCurrentPanel()?->getId());
    }

    /** The trip's stops (done or not), the route driven and where it started, for the map. */
    protected function tripMap(?Deliverylog $trip, bool $withPath = true): array
    {
        if (! $trip) {
            return [];
        }
        TripSorter::ensure($trip, 0);
        $left = Tracker::stopsLeft($trip)->pluck('id')->flip();
        $start = MapSettings::startFor($trip->user?->warehouse_id, $trip->logistichub_id);
        $done = $withPath ? array_map(fn ($p) => [$p[0], $p[1]], Tracker::path($trip->truck_id, $trip->id)) : [];

        return [
            'start' => $start ? ['lat' => $start[0], 'lng' => $start[1], 'name' => $start['name']] : null,
            'done' => $done,
            'from' => $done ? end($done) : null,
            'stops' => TripSorter::stops($trip)->filter->hasPin()->map(fn (TripStop $s) => [
                'no' => $s->stop_no, 'name' => $s->name, 'lat' => $s->lat, 'lng' => $s->lng, 'done' => ! isset($left[$s->id]),
            ])->values()->all(),
            'marks' => TruckAlert::where('deliverylog_id', $trip->id)->where('kind', 'stopped')->whereNotNull('lat')->get()
                ->map(fn ($a) => ['lat' => $a->lat, 'lng' => $a->lng, 'label' => $a->title.' · '.$a->started_at->format('g:i A')])->all(),
        ];
    }

    protected function googleKey(): ?string
    {
        return TrackSettings::mapKey();
    }
}
