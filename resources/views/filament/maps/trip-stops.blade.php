@php($zoneName = ['front' => 'FRONT', 'middle' => 'MIDDLE', 'back' => 'BACK'])
<x-filament-panels::page>
@assets
    <link rel="stylesheet" href="{{ \Filament\Support\Facades\FilamentAsset::getStyleHref('leaflet') }}">
    <script src="{{ \Filament\Support\Facades\FilamentAsset::getScriptSrc('leaflet') }}"></script>
    <script src="{{ \Filament\Support\Facades\FilamentAsset::getScriptSrc('trip-map') }}"></script>
@endassets
<div class="ds-mp">
    @if ($transfer)
        <section class="ds-board__panel">
            <p>This trip goes to <b>{{ $trip->destination?->hub_name ?? 'another hub' }}</b>. All boxes are one stop, so the loading order does not matter. The partner hub sorts its own trips when it makes them.</p>
        </section>
    @elseif ($stops->isEmpty())
        <section class="ds-board__panel"><p>No boxes on this trip yet. Add boxes and the stops are sorted right away.</p></section>
    @else
        <div class="ds-mp__badges">
            @if ($sourceText)
                <span class="is-ok">✓ {{ $sourceText }}@if ($route?->km) · {{ rtrim(rtrim(number_format($route->km, 1), '0'), '.') }} km · about {{ intdiv((int) $route->minutes, 60) ? intdiv((int) $route->minutes, 60).' h ' : '' }}{{ (int) $route->minutes % 60 }} min driving @endif</span>
            @endif
            @if ($route?->ai_fixed)<span class="is-ai">AI fixed {{ $route->ai_fixed }} {{ str('address')->plural($route->ai_fixed) }}</span>@endif
            @if ($noPin)<span class="is-warn">{{ $noPin }} {{ str('stop')->plural($noPin) }} without a pin: placed by barangay</span>@endif
            @if ($route?->waiting)<span class="is-warn">Finding {{ $route->waiting }} more {{ str('address')->plural($route->waiting) }}… refresh in a minute</span>@endif
            <span class="ds-mp__badgeactions">
                <x-filament::button tag="a" :href="$printUrl" target="_blank" color="gray" icon="heroicon-o-printer">Print loading list</x-filament::button>
                <x-filament::button color="gray" wire:click="toggleLock">{{ $route?->locked ? '🔒 Order locked · unlock' : '🔓 Auto-sort on · lock' }}</x-filament::button>
                <x-filament::button wire:click="resort" wire:loading.attr="disabled">Sort again</x-filament::button>
            </span>
        </div>

        <section class="ds-board__panel ds-mp__truck" aria-label="Truck seen from above">
            <span class="ds-mp__cab">CAB</span>
            @foreach (['front', 'middle', 'back'] as $z)
                @php($in = $stops->where('zone', $z))
                <span class="ds-mp__zone is-{{ $z }}"><b>{{ $zoneName[$z] }}</b><small>{{ $in->isEmpty() ? '—' : 'stops '.$in->pluck('stop_no')->sortDesc()->join(', ') }}</small><small>{{ $in->sum('boxes') }} {{ str('box')->plural($in->sum('boxes')) }}</small></span>
            @endforeach
            <span class="ds-mp__door">DOOR</span>
        </section>

        <div class="ds-mp__grid">
            <section class="ds-board__panel ds-mp__mapwrap">
                <div wire:ignore class="ds-mp__map" x-data x-init="
                    const boot = () => window.L && window.dsTripMap ? (window.dsTripMapNow = window.dsTripMap($el, @js($map))) : setTimeout(boot, 80); boot();
                " x-on:trip-map.window="window.dsTripMapNow && window.dsTripMapNow.draw($event.detail.data)"></div>
                <p class="ds-mp__legend"><span class="is-ok">● exact pin</span><span class="is-area">● area only</span><span class="is-prio">● priority</span><span>WH = start · map © OpenStreetMap</span></p>
            </section>

            <section class="ds-board__panel">
                <div class="ds-board__panel-head"><h2>Delivery order</h2><span class="ds-board__muted">drag ⠿ to change · load # is the loading order</span></div>
                <ol class="ds-mp__stops" x-data="{ from: null, over: null }">
                    @foreach ($stops as $i => $s)
                        <li wire:key="st-{{ $s->id }}-{{ $s->stop_no }}" draggable="true"
                            x-on:dragstart="from = {{ $s->id }}; $event.dataTransfer.effectAllowed = 'move'"
                            x-on:dragover.prevent="over = {{ $i }}" x-on:dragleave="over = null"
                            x-on:drop.prevent="if (from !== null && from !== {{ $s->id }}) $wire.moveStop(from, {{ $i }}); from = null; over = null"
                            x-bind:class="{ 'is-over': over === {{ $i }} }">
                            <span class="ds-mp__grab">⠿</span>
                            <span class="ds-mp__no">{{ $s->stop_no }}</span>
                            <span class="ds-mp__who"><b>{{ $s->name }}</b> · {{ $s->barangay ? $s->barangay.', ' : '' }}{{ $s->city }}
                                <span class="ds-mp__tags">
                                    @if ($s->priority)<em class="is-prio">priority</em>@endif
                                    @if (! $s->hasPin())<em class="is-warn">no pin · barangay order</em>@elseif (! $s->exact)<em class="is-area">area only</em>@endif
                                </span>
                            </span>
                            <span class="ds-mp__n">{{ $s->boxes }} {{ str('box')->plural($s->boxes) }}</span>
                            <span class="ds-mp__spot is-{{ $s->zone }}">{{ $zoneName[$s->zone] ?? '' }}</span>
                            <span class="ds-mp__load">load #{{ $stops->count() - $i }}</span>
                            <span class="ds-mp__updown"><button type="button" wire:click="moveStop({{ $s->id }}, {{ max(0, $i - 1) }})" @disabled($i === 0) aria-label="Move up">▲</button><button type="button" wire:click="moveStop({{ $s->id }}, {{ $i + 1 }})" @disabled($loop->last) aria-label="Move down">▼</button></span>
                        </li>
                    @endforeach
                </ol>
                <p class="ds-board__muted">Load #1 (stop {{ $stops->count() }}) goes in first, at the front next to the cab; stop 1 goes in last, at the door. All boxes of one receiver stay together.</p>
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
