<x-filament-panels::page>
@include('filament.tracking._assets')
<div class="ds-tm" @if ($tab === 'today') wire:poll.30s="refresh" @endif>
    <div class="ds-tm__top">
        <span class="ds-tm__who">
            <span class="ds-tm__icon">🚚</span>
            <span><b>{{ $truck->plate_no }}</b> <small>{{ $truck->description ?: $truck->category }}{{ $truck->capacity ? ' · capacity '.$truck->capacity.' boxes' : '' }}</small><br>
                <small>Driver <b>{{ $crew['driver']?->full_name ?? '—' }}</b>{{ $crew['helpers']->isNotEmpty() ? ' · '.$crew['helpers']->pluck('full_name')->join(', ') : '' }} · location from <b>{{ $source }}</b></small></span>
        </span>
        <span class="ds-tm__tabs">
            @foreach (['today' => 'Today', 'history' => 'Trip history', 'alerts' => 'Alerts'] as $k => $l)
                <button type="button" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k])>{{ $l }}</button>
            @endforeach
        </span>
    </div>

    @if ($tab === 'today')
        <div class="ds-tm__stats">
            @foreach ($stats as [$l, $v, $n])
                <span class="ds-board__panel"><small>{{ $l }}</small><b>{{ $v }}</b><em>{{ $n }}</em></span>
            @endforeach
        </div>
    @endif

    <div class="ds-tm__grid" @style(['display: none' => $tab === 'alerts' || ($tab === 'history' && ! $replayTrip)])>
        <section class="ds-board__panel ds-tm__mapwrap">
            @if ($tab === 'today')
                <span class="ds-tm__cardhead"><b>{{ $trip ? 'Trip '.$trip->trip_number.' · today' : 'Not on a trip now' }}</b>@if ($card)<em class="is-{{ $card['kind'] }}">{{ $card['state'] }} · {{ $card['seen'] }}</em>@endif</span>
            @else
                <span class="ds-tm__cardhead"><b>Replay · {{ $history->firstWhere('id', $replayTrip)['trip'] ?? '' }}</b><button type="button" class="ds-nav__link" wire:click="$set('replayTrip', null)">Close</button></span>
            @endif
            <div wire:ignore class="ds-tm__map is-small" x-data x-init="
                    const boot = () => window.L && window.dsTruckMap ? (window.dsTruckMapNow = window.dsTruckMap($el, @js($map), @js($googleKey))) : setTimeout(boot, 80); boot();
                " x-on:truck-map.window="window.dsTruckMapNow && window.dsTruckMapNow.draw($event.detail.data)"></div>
            <p class="ds-mp__legend"><span class="is-ok">━ driven</span><span>┅ still to go</span><span class="is-area">⏸ long stop</span><span>numbers = stops left</span></p>
        </section>

        @if ($tab === 'today')
            <div class="ds-tm__side">
                <section class="ds-board__panel">
                    <div class="ds-board__panel-head"><h2>Right now</h2></div>
                    @if ($card)
                        <p class="ds-tm__now">@if ($card['near'])Near <b>{{ $card['near'] }}</b><br>@endif Next: <b>{{ $card['next'] }}</b><br>Boxes on the truck: <b>{{ $card['total'] - $card['delivered'] }}</b> · delivered <b>{{ $card['delivered'] }} of {{ $card['total'] }}</b></p>
                        @if ($card['alert'])<span class="ds-mp__warn">{{ $card['alert'] }}</span>@endif
                        <span class="ds-tm__btns">
                            @if ($card['phone'])<x-filament::button tag="a" href="tel:{{ preg_replace('/[^0-9+]/', '', $card['phone']) }}" color="gray" size="sm">📞 Call {{ \Illuminate\Support\Str::before($card['driver'], ' ') }}</x-filament::button>@endif
                            <x-filament::button tag="a" :href="route('trip.loading-list', $trip)" target="_blank" color="gray" size="sm">Loading list</x-filament::button>
                        </span>
                    @else
                        <p class="ds-board__muted">This truck is not on a trip. Its past trips are under Trip history.</p>
                    @endif
                </section>
                <section class="ds-board__panel">
                    <div class="ds-board__panel-head"><h2>Today, step by step</h2></div>
                    <ol class="ds-tm__events">
                        @forelse ($events as $e)
                            <li class="is-{{ $e['kind'] }}"><small>{{ $e['t'] }}</small><i></i><span>{{ $e['text'] }}</span></li>
                        @empty
                            <li><span class="ds-board__muted">Nothing yet today.</span></li>
                        @endforelse
                    </ol>
                </section>
            </div>
        @endif
    </div>

    @if ($tab === 'history')
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Trips of {{ $truck->plate_no }}</h2><span>last 30 days · ▶ Replay shows the route it drove</span></div>
            <div class="ds-tm__table">
                <div class="is-head"><span>Date</span><span>Trip</span><span>Driver</span><span>km</span><span>Hours</span><span>Delivered</span><span>Notes</span><span></span></div>
                @forelse ($history as $h)
                    <div wire:key="h-{{ $h['id'] }}" @class(['is-sel' => $replayTrip === $h['id']])><span>{{ $h['date'] }}{{ $h['today'] ? ' (now)' : '' }}</span><b>{{ $h['trip'] }}</b><span>{{ $h['driver'] }}</span><span>{{ $h['km'] ?? '—' }}</span><span>{{ $h['hours'] }}</span>
                        <span @class(['is-ok' => $h['total'] && $h['delivered'] === $h['total'], 'is-warn' => $h['delivered'] < $h['total'] && ! $h['today']])>{{ $h['delivered'] }} / {{ $h['total'] }}</span><small>{{ $h['note'] }}</small>
                        @if ($h['points'])<button type="button" wire:click="replay({{ $h['id'] }})">▶ Replay</button>@else<small>no route</small>@endif</div>
                @empty
                    <p class="ds-board__muted">No trips in the last 30 days.</p>
                @endforelse
            </div>
        </section>
        <div class="ds-tm__stats is-four">
            <span class="ds-board__panel"><small>km (30 days)</small><b>{{ number_format($totals['km']) }}</b></span>
            <span class="ds-board__panel"><small>Trips</small><b>{{ $totals['trips'] }}</b></span>
            <span class="ds-board__panel"><small>Delivered first try</small><b class="is-ok">{{ $totals['firstTry'] !== null ? $totals['firstTry'].'%' : '—' }}</b></span>
            <span class="ds-board__panel"><small>Location from</small><b>{{ $source }}</b></span>
        </div>
    @endif

    @if ($tab === 'alerts')
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Alerts of {{ $truck->plate_no }}</h2></div>
            <div class="ds-tm__alerts">
                @forelse ($alerts as $a)
                    <div wire:key="al-{{ $a->id }}">
                        <span class="ds-tm__aicon">{{ \App\Models\Tracking\TruckAlert::ICONS[$a->kind] ?? '!' }}</span>
                        <span class="ds-tm__atext"><b>{{ $a->title }}</b><small>{{ $a->text }}{{ $a->trip ? ' · trip '.$a->trip->trip_number : '' }}{{ $a->ended_at ? ' · lasted '.\App\Support\Tracking\Tracker::dur($a->minutes()) : ' · still going' }}</small>
                            @if ($a->ai_note)<span class="ds-tm__ainote"><small>✨ What probably happened{{ $a->ai_level ? ' · '.ucfirst($a->ai_level).' concern' : '' }}</small>{{ $a->ai_note }}</span>@endif
                            @if ($a->ai_actions)<span class="ds-tm__aiacts">@foreach ($a->ai_actions as $act)<i>{{ $act }}</i>@endforeach</span>@endif
                            @if ($a->checked_at)<small>✓ {{ $a->checker?->full_name }}{{ $a->note ? ': '.$a->note : '' }}</small>@endif</span>
                        <small class="ds-tm__when">{{ $a->started_at->isToday() ? 'Today '.$a->started_at->format('g:i A') : $a->started_at->format('M j, g:i A') }}</small>
                        @if ($a->checked_at)
                            <em class="is-ok">Checked</em>
                        @else
                            <input type="text" wire:model="notes.{{ $a->id }}" placeholder="What happened? (optional)">
                            <x-filament::button size="sm" wire:click="check({{ $a->id }})">Mark checked</x-filament::button>
                        @endif
                    </div>
                @empty
                    <p class="ds-board__muted">No alerts for this truck.</p>
                @endforelse
            </div>
        </section>
    @endif
</div>
</x-filament-panels::page>
