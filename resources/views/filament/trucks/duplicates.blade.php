<x-filament-panels::page>
<div class="ds-fl ds-dp">
    @if ($fleetUrl)<a href="{{ $fleetUrl }}" class="ds-tk__back">‹ All trucks</a>@endif

    @if ($m)
        <section class="ds-cb__card ds-dp__done">
            <span class="ds-dp__tick" aria-hidden="true">✓</span>
            <b class="ds-dp__done-title">{{ $m->undone_at ? 'Undone' : 'Merged into '.$m->kept?->plate_no }}</b>
            @php
                $trips = ($moved['deliverylogs'] ?? 0) + ($moved['whdeliverylogs'] ?? 0);
                $fuel = $moved['fuel_fills'] ?? 0;
                $other = $moved->except(['deliverylogs', 'whdeliverylogs', 'fuel_fills'])->sum();
            @endphp
            <span>{{ $trips }} {{ Str::plural('trip', $trips) }}, {{ $fuel }} fuel {{ Str::plural('fill', $fuel) }}@if ($other) and {{ $other }} other {{ Str::plural('record', $other) }} (crew, tracking, booked days)@endif now belong to {{ $m->kept?->plate_no }}. Reports and cost per box count them once.</span>
            <span class="ds-dp__soft">The copy ({{ $m->dropped?->plate_no }} · #{{ $m->dropped_id }}) is now inactive and hidden from trips, the AI and the crew board.</span>
            <span class="ds-dp__btns">
                @if ($canUndo)<button type="button" class="ds-te__btn" wire:click="undo" wire:confirm="Put everything back on {{ $m->dropped?->plate_no }}?">↶ Undo</button>@endif
                @if ($keptUrl)<a href="{{ $keptUrl }}" class="ds-te__btn">Open {{ $m->kept?->plate_no }}</a>@endif
                @if ($fleetUrl)<a href="{{ $fleetUrl }}" class="ds-te__btn is-main">Back to Trucks</a>@endif
            </span>
            @if ($canUndo)<small class="ds-te__hint">Undo is possible until {{ $m->created_at->addDays(\App\Support\TruckDuplicates::UNDO_DAYS)->format('M j') }}.</small>@endif
        </section>
    @else
        <span class="ds-te__title"><h1>Same truck twice? {{ $title }}</h1><small>Click the card to keep. We picked the active one with crew and more trips. Nothing is deleted.</small></span>
        <div class="ds-dp__grid">
            @foreach ($copies as $c)
                @php $on = $c['t']->id === $keepCard['t']->id; @endphp
                <button type="button" wire:click="pick({{ $c['t']->id }})" @class(['ds-dp__copy', 'is-on' => $on]) aria-pressed="{{ $on ? 'true' : 'false' }}" wire:key="c-{{ $c['t']->id }}">
                    <span class="ds-dp__top">
                        <span class="ds-fl__truck" style="--tc: {{ $on ? $c['color'] : '#c3ccd4' }}" aria-hidden="true"><i class="b"></i><i class="c"></i><i class="w"></i><i class="r1"></i><i class="r2"></i></span>
                        <span class="ds-dp__id">
                            <span class="ds-tk__line"><b class="ds-dp__plate">{{ $c['t']->plate_no }}</b><span @class(['ds-cb__pill', 'is-own' => $on, 'is-bad' => ! $on])>{{ $on ? 'Keep' : 'Becomes inactive' }}</span>@unless ($c['t']->is_active)<span class="ds-cb__pill is-muted">Inactive now</span>@endunless</span>
                            <small>{{ $c['line'] }}</small>
                        </span>
                        <i class="ds-te__radio" aria-hidden="true"></i>
                    </span>
                    <span class="ds-dp__stats">
                        @foreach ([['Trips', $c['s']['trips']], ['Crew', $c['s']['crew']], ['Fuel fills', $c['s']['fuel']], ['Last trip', $c['s']['last']], ['Photo', $c['s']['photo']], ['Booked days', $c['s']['booked'] ?: '—']] as [$l, $v])
                            <span><small>{{ $l }}</small><b>{{ $v }}</b></span>
                        @endforeach
                    </span>
                    <small @class(['ds-dp__foot', 'is-ok' => $on])>{{ $on ? '✓ Its trips, crew and history stay. The other copy’s are added.' : '#'.$c['t']->id.' · its '.$c['s']['trips'].' trips and '.$c['s']['fuel'].' fuel fill(s) move to the kept truck' }}</small>
                </button>
            @endforeach
        </div>
        @php $dropTrips = $drops->sum('s.trips'); $dropFuel = $drops->sum('s.fuel'); @endphp
        <section class="ds-cb__card ds-dp__what">
            <span class="ds-dp__what-text"><b>What happens</b>
                <span>{{ $dropTrips }} {{ Str::plural('trip', $dropTrips) }}, {{ $dropFuel }} fuel {{ Str::plural('fill', $dropFuel) }}, tracking points and any booked days move from {{ $drops->map(fn ($d) => $d['t']->plate_no.' (#'.$d['t']->id.')')->join(', ') }} to {{ $keepCard['t']->plate_no }}. Crew on both stays on {{ $keepCard['t']->plate_no }}.</span>
                <small>The copy turns <b>inactive</b> with the note “Merged into {{ $keepCard['t']->plate_no }}”. Fields that are empty on the kept truck (photo, make and model, cargo size) are copied over. Undo is possible for {{ \App\Support\TruckDuplicates::UNDO_DAYS }} days.</small>
            </span>
            <span class="ds-dp__btns">
                <button type="button" class="ds-te__btn" wire:click="different">Different trucks</button>
                <button type="button" class="ds-te__btn is-main ds-dp__go" wire:click="doMerge" wire:loading.attr="disabled">Keep {{ $keepCard['t']->plate_no }} · move everything</button>
            </span>
        </section>
    @endif
</div>
</x-filament-panels::page>
