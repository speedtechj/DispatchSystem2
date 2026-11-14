<x-filament-panels::page>
@include('filament.tracking._assets')
<div class="ds-tm" wire:poll.30s="refresh">
    <div class="ds-tm__top">
        <div class="ds-mp__badges">
            <span class="is-ok">● {{ $counts['moving'] }} moving or at a stop</span>
            @if ($counts['stopped'])<span class="is-warn">● {{ $counts['stopped'] }} stopped too long</span>@endif
            @if ($counts['bad'])<span class="is-bad">● {{ $counts['bad'] }} no signal</span>@endif
            <span>{{ $counts['delivered'] }} of {{ $counts['total'] }} boxes delivered</span>
        </div>
        <span class="ds-tm__tabs">
            <button type="button" wire:click="setTab('live')" @class(['is-on' => $tab === 'live'])>Live</button>
            <button type="button" wire:click="setTab('replay')" @class(['is-on' => $tab === 'replay'])>Replay today</button>
        </span>
    </div>

    @if ($cards->isEmpty())
        <section class="ds-board__panel"><p>No truck is on a trip right now. Trucks show up here when a trip is active and the Driver app (or a GPS tracker) sends its location.</p></section>
    @endif

    <div class="ds-tm__grid" @style(['display: none' => $cards->isEmpty()])>
        <section class="ds-board__panel ds-tm__mapwrap">
            <div wire:ignore class="ds-tm__map" x-data x-init="
                    const boot = () => window.L && window.dsTruckMap ? (window.dsTruckMapNow = window.dsTruckMap($el, @js($map), @js($googleKey))) : setTimeout(boot, 80); boot();
                " x-on:truck-map.window="window.dsTruckMapNow && window.dsTruckMapNow.draw($event.detail.data)"
                x-on:truck-pick="$wire.pick($event.detail)"></div>
            @if ($tab === 'replay')
                <div class="ds-tm__replay" wire:key="replay-{{ $cur['id'] ?? 0 }}" x-data="{ i: {{ max(0, count($replayPath) - 1) }}, n: {{ count($replayPath) }}, times: @js(array_column($replayPath, 2)), timer: null,
                        play() { if (this.timer) { clearInterval(this.timer); this.timer = null; return } if (this.i >= this.n - 1) this.i = 0; this.timer = setInterval(() => { if (this.i >= this.n - 1) { clearInterval(this.timer); this.timer = null; return } this.i++; window.dsTruckMapNow && window.dsTruckMapNow.at(this.i) }, 120) } }">
                    @if (count($replayPath))
                        <button type="button" x-on:click="play()" x-text="timer ? '❚❚' : '▶'"></button>
                        <input type="range" min="0" x-bind:max="n - 1" x-model.number="i" x-on:input="window.dsTruckMapNow && window.dsTruckMapNow.at(i)">
                        <b x-text="times[i]"></b><small>{{ $replayPath[0][2] }} → {{ end($replayPath)[2] }} · {{ $cur['trip'] }}</small>
                    @else
                        <small>No locations for {{ $cur['plate'] ?? 'this truck' }} on this trip yet.</small>
                    @endif
                </div>
            @endif
            <p class="ds-mp__legend"><span class="is-ok">━ driven</span><span>┅ stops still to go</span><span class="is-area">⏸ long stop</span><span>{{ $googleKey ? 'Google Maps' : 'map © OpenStreetMap' }}</span></p>
        </section>

        <div class="ds-tm__side">
            <section class="ds-board__panel ds-tm__list">
                @foreach ($cards as $c)
                    <button type="button" wire:key="tr-{{ $c['id'] }}" wire:click="pick({{ $c['id'] }})" @class(['ds-tm__row', 'is-sel' => $cur && $cur['id'] === $c['id']])>
                        <span><b>🚚 {{ $c['plate'] }} · {{ $c['trip'] }}</b><em class="is-{{ $c['kind'] }}">{{ $c['state'] }}</em></span>
                        <small>{{ $c['driver'] }} · {{ $c['delivered'] }} of {{ $c['total'] }} delivered</small>
                    </button>
                @endforeach
            </section>

            @if ($cur)
                <section class="ds-board__panel ds-tm__card">
                    <span class="ds-tm__cardhead"><b>🚚 {{ $cur['plate'] }} · {{ $cur['trip'] }}</b><em class="is-{{ $cur['kind'] }}">{{ $cur['state'] }}</em></span>
                    <span class="ds-tm__crew">Driver <b>{{ $cur['driver'] }}</b>{{ $cur['helpers'] ? ' · '.$cur['helpers'] : '' }}</span>
                    <div class="ds-tm__facts">
                        <span>Last seen<b>{{ $cur['seen'] }}</b></span>
                        <span>Speed<b>{{ $cur['speed'] }}</b></span>
                        <span>Next stop<b>{{ $cur['next'] }}</b></span>
                        <span>Delivered<b>{{ $cur['delivered'] }} of {{ $cur['total'] }}</b></span>
                    </div>
                    @if ($cur['near'])<span class="ds-board__muted">Near {{ $cur['near'] }}</span>@endif
                    @if ($cur['alert'])<span class="ds-mp__warn">{{ $cur['alert'] }}</span>@endif
                    <span class="ds-tm__btns">
                        @if ($cur['phone'])<x-filament::button tag="a" href="tel:{{ preg_replace('/[^0-9+]/', '', $cur['phone']) }}" color="gray" size="sm">📞 Call driver</x-filament::button>@endif
                        <x-filament::button tag="a" :href="$truckUrl($cur['id'])" size="sm">Open truck</x-filament::button>
                    </span>
                    <small class="ds-board__muted">Location from: {{ $cur['source'] }}</small>
                </section>
            @endif
        </div>
    </div>
</div>
</x-filament-panels::page>
