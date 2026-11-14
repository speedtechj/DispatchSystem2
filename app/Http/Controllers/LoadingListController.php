<?php

namespace App\Http\Controllers;

use App\Models\Deliverylog;
use App\Models\Tripinvoice;
use App\Support\Maps\TripSorter;
use Illuminate\Http\Request;
use Illuminate\Http\Response;

class LoadingListController extends Controller
{
    /** Printed loading list: grouped FRONT → MIDDLE → BACK, load from the top. */
    public function show(Request $request, int $trip): Response
    {
        $trip = Deliverylog::with('truck')->findOrFail($trip);
        abort_unless(TripSorter::canSee($request->user(), $trip), 404);
        TripSorter::ensure($trip);

        $stops = TripSorter::stops($trip)->sortByDesc('stop_no')->values();
        $codes = Tripinvoice::whereIn('id', $stops->flatMap(fn ($s) => $s->box_ids ?? []))->pluck('invoice', 'id');

        return response()->view('maps.loading-list', [
            'trip' => $trip,
            'groups' => collect(['front', 'middle', 'back'])->mapWithKeys(fn ($z) => [$z => $stops->where('zone', $z)->values()])->filter->isNotEmpty(),
            'codes' => $codes,
            'boxes' => (int) $stops->sum('boxes'),
            'count' => $stops->count(),
        ]);
    }
}
