<?php

namespace App\Filament\Concerns;

use App\Models\Tripinvoice;
use App\Support\Trips\TripFill;
use Filament\Notifications\Notification;
use Illuminate\Support\Facades\Auth;

/**
 * Partner hub unload scans (Receive truck, Receive container): each box goes on the hub's open trip
 * of its city; full → a new hub trip, with Add anyway (board 45d).
 */
trait PlacesOnHubTrips
{
    /** Where the last box went. */
    public ?array $hubTrip = null;

    protected function placeOnHubTrip(Tripinvoice $row): ?array
    {
        $placed = TripFill::placeAtHub($row->fresh('invdata'), (int) Auth::user()?->logistichub_id, Auth::user());
        $this->hubTrip = $placed ? $placed + ['row' => $row->id] : null;

        return $placed;
    }

    /** Add anyway: the box (and its combo) goes on the full trip instead of the new one. */
    public function hubAnyway(): void
    {
        if (! $this->hubTrip || empty($this->hubTrip['full'])) {
            return;
        }
        $row = Tripinvoice::find($this->hubTrip['row']);
        if (! $row) {
            return;
        }
        $res = TripFill::hubAddAnyway($row, (int) $this->hubTrip['full']['id'], Auth::user());
        if ($res['ok']) {
            $this->hubTrip = ['trip' => $this->hubTrip['full']['number'], 'tripId' => $this->hubTrip['full']['id'], 'kind' => 'anyway',
                'why' => 'Added anyway: over the estimate · saved with your name. '.$res['msg'], 'row' => $row->id];
        }
        Notification::make()->title($res['msg'])->{$res['ok'] ? 'success' : 'warning'}()->send();
    }
}
