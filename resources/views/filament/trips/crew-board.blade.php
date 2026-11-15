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
                        <span class="ds-cb__pill is-{{ $r['stage'] }}">{{ $r['trip']->trip_number }} · {{ \App\Support\TripFlow::STAGES[$r['stage']][0] ?? '' }}</span>
                    @else
                        <span class="ds-cb__pill is-free">Free</span>
                    @endif
                </header>

                <small class="ds-board__muted">Truck team</small>
                @forelse ($r['team'] as $c)
                    <span class="ds-cb__person" wire:key="p-{{ $r['truck']->id }}-{{ $c->crew }}">
                        <span><b>{{ $c->user->full_name }}</b><small>{{ $c->user->workposition?->position_description }}</small></span>
                        <button type="button" class="ds-fu__link" wire:click="removeCrew({{ $r['truck']->id }}, {{ $c->crew }})" aria-label="Take {{ $c->user->full_name }} off {{ $r['truck']->plate_no }}">✕</button>
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
                    <small class="ds-cb__next">Next trip waiting: <b>{{ $r['next']->trip_number }}</b> · starts when {{ $r['trip']->trip_number }} closes</small>
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
