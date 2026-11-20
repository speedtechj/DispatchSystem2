<x-filament-panels::page>
<div class="ds-cb">
    @if ($groups)
        <section class="ds-cb__groups" aria-label="Needs a look">
            @foreach ($groups as $g)
                <details class="ds-cb__group is-{{ $g['tone'] }}" wire:key="g-{{ $g['key'] }}">
                    <summary>
                        <span class="ds-cb__gicon" aria-hidden="true">{{ $g['icon'] }}</span>
                        <b>{{ $g['title'] }}</b>
                        <span class="ds-cb__gshow">Show</span>
                    </summary>
                    <ul>
                        @foreach ($g['items'] as $it)
                            <li>
                                <span>{{ $it['text'] }}</span>
                                @if ($it['url'])
                                    <a href="{{ $it['url'] }}">Open trip ›</a>
                                @elseif ($it['truck'] && $it['user'])
                                    <button type="button" wire:click="removeCrew({{ $it['truck'] }}, {{ $it['user'] }})">Take off</button>
                                @endif
                            </li>
                        @endforeach
                    </ul>
                </details>
            @endforeach
        </section>
    @endif

    <div class="ds-cb__grid">
        @forelse ($rows as $r)
            <section class="ds-cb__card" wire:key="tr-{{ $r['truck']->id }}">
                <header>
                    <b>{{ $r['truck']->plate_no }}</b>
                    @if ($r['trip'])
                        <a href="{{ $tripUrl($r['trip']) }}" class="ds-cb__pill is-{{ $r['stage'] }}">{{ $r['trip']->trip_number }} · {{ \App\Support\TripFlow::STAGES[$r['stage']][0] ?? '' }} ›</a>
                    @else
                        <span class="ds-cb__pill is-free">Free</span>
                    @endif
                </header>

                <small class="ds-cb__label">Truck team</small>
                @forelse ($r['team'] as $c)
                    <span @class(['ds-cb__person', 'is-inactive' => ! $c->member->is_active]) wire:key="p-{{ $r['truck']->id }}-{{ $c->crew }}">
                        <span><b>{{ $c->member->full_name }}</b><small>{{ $c->member->workposition?->position_description ?? 'Crew' }}{{ $c->member->is_active ? '' : ' · inactive' }}</small></span>
                        <button type="button" wire:click="removeCrew({{ $r['truck']->id }}, {{ $c->crew }})" aria-label="Take {{ $c->member->full_name }} off {{ $r['truck']->plate_no }}">✕</button>
                    </span>
                @empty
                    <p class="ds-cb__none">No crew on this truck.</p>
                    @if ($r['last'])
                        <button type="button" class="ds-cb__same" wire:click="sameAsLastTrip({{ $r['truck']->id }})">Same as last trip · {{ $r['last'] }}</button>
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
                    <a href="{{ $tripUrl($r['next']) }}" class="ds-cb__next">Next trip waiting: <b>{{ $r['next']->trip_number }}</b> · starts when {{ $r['trip']->trip_number }} closes ›</a>
                @endif
            </section>
        @empty
            <p class="ds-cb__muted">No active trucks.</p>
        @endforelse
    </div>

    <section class="ds-cb__card ds-cb__free">
        <header><b>Crew without a truck</b><span class="ds-cb__count">{{ $free->count() }}</span></header>
        @forelse ($free as $u)
            <span class="ds-cb__person" wire:key="f-{{ $u->id }}">
                <span><b>{{ $u->full_name }}</b><small>{{ $u->workposition?->position_description ?? 'Crew' }}</small></span>
                <select class="ds-cb__put" wire:change="addCrew($event.target.value, {{ $u->id }})" aria-label="Put {{ $u->full_name }} on a truck">
                    <option value="">Put on a truck…</option>
                    @foreach ($truckList as $tid => $plate)<option value="{{ $tid }}">{{ $plate }}</option>@endforeach
                </select>
            </span>
        @empty
            <p class="ds-cb__muted">Everyone has a truck.</p>
        @endforelse
        <small class="ds-cb__muted">The truck team is copied onto each new trip. To change one trip only, use Crew on this trip on the trip page.</small>
    </section>
</div>
</x-filament-panels::page>
