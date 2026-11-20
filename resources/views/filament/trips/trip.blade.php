<x-filament-panels::page>
<div class="ds-tp">
    <section class="ds-tp__steps" aria-label="Trip steps">
        @foreach ($steps as $s)
            <span @class(['ds-tp__step', 'is-'.$s['state']])><b>{{ $s['n'] }} {{ $s['label'] }}</b><small>{{ $s['who'] }}</small></span>
        @endforeach
    </section>

    <section class="ds-board__panel ds-tp__card">
        <header class="ds-tp__head">
            <strong>{{ $trip->trip_number }}{{ $trip->destination ? ' → '.$trip->destination->hub_name : '' }}</strong>
            <span class="ds-cb__pill is-{{ $stage }}">{{ $stageInfo[0] }}</span>
        </header>
        @if (\App\Support\Trips\CityTrips::ready() && ($tc = $trip->cities()->get())->isNotEmpty())
            <p class="ds-tp__cities">📍 {{ $tc->first()->province }} › {{ $tc->pluck('city')->join(', ') }} · {{ $trip->is_lock ? 'locked: no more boxes join' : 'boxes of these cities join when scanned onto the truck' }}@if ($trip->plan_why)<small>✦ {{ $trip->plan_why }}</small>@endif</p>
        @endif

        <div class="ds-tp__tiles">
            <span><small>Truck</small><b>{{ $trip->truck?->plate_no ?? 'No truck yet' }}</b><small>{{ $rental ? 'Rental · '.($rental['company'] ?? '—').' · ' : '' }}{{ $truckState === 'Free' && $rental ? 'Returned' : $truckState }}</small></span>
            <span><small>Boxes</small><b>{{ $boxes }}</b></span>
            @if ($rental)
                <span><small>Rental cost</small><b>{{ $rental['cost'] !== null ? '₱'.number_format($rental['cost']).' · '.(\App\Support\Rentals::RATES[$rental['rate']] ?? '') : '—' }}</b><small>{{ $rental['perBox'] ? 'about ₱'.number_format($rental['perBox']).' per box' : 'not known yet' }}</small></span>
            @endif
            <span><small>Leadman took the trip</small><b>{{ $took ?? '—' }}</b></span>
        </div>

        <div class="ds-tp__crewhead"><b>Crew on this trip</b><small>Copied from the truck team · change it for this trip only with Crew on this trip (top right)</small></div>
        @forelse ($crew as $c)
            <span @class(['ds-tp__person', 'is-swap' => $c->replaces_user_id])>
                <i>{{ collect(explode(' ', (string) $c->user?->full_name))->map(fn ($w) => mb_substr($w, 0, 1))->take(2)->join('') }}</i>
                <span><b>{{ $c->user?->full_name }}</b><small>{{ $c->role ?? $c->user?->workposition?->position_description }}@if ($c->replaces_user_id) · this trip only, instead of {{ $c->replaces?->full_name }}{{ $c->reason ? ' ('.(\App\Support\TripFlow::SWAP_REASONS[$c->reason] ?? $c->reason).')' : '' }}@endif</small></span>
            </span>
        @empty
            <p class="ds-cb__none">{{ $trip->truck_id ? 'No crew on this trip. Click Crew on this trip (top right) to choose who goes.' : 'No truck and no crew yet. Pick the truck in Boxes & edit (top right): its team is copied here. Or click Crew on this trip to choose people now.' }}</p>
        @endforelse

        @if ($rental)
            <span class="ds-tp__person"><i>R</i><span><b>{{ $rental['driver'] ?: 'Rental driver' }}</b><small>Rental driver · written on the trip for the records · our leadman rides along with the driver app</small></span></span>
        @endif
        @foreach ($warnings as $w)
            <p @class(['ds-tp__warn', 'is-'.$w['tone']])>{{ $w['text'] }}</p>
        @endforeach

        @if ($next)
            <div class="ds-tp__next">
                <span><b>Next trip waiting for {{ $trip->truck?->plate_no }}</b><small>{{ $next->trip_number }}{{ $next->destination ? ' → '.$next->destination->hub_name : '' }} · {{ $nextBoxes }} boxes{{ $next->departure_date ? ' · '.$next->departure_date->format('M j') : '' }}</small></span>
                <a href="{{ static::getUrl(['trip' => $next->id]) }}" class="ds-cb__pill">Waits for {{ $trip->trip_number }} to close ›</a>
            </div>
        @endif
        <small class="ds-board__muted">Release truck now is a backup only. Normally the truck releases itself when every box is delivered or returned.</small>
    </section>
</div>
</x-filament-panels::page>
