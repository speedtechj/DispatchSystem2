<x-filament-panels::page>
<div class="ds-hi">
    <div class="ds-hi__top">
        <p class="ds-board__muted">{{ $hubName }} · {{ $onWay }} boxes on the way</p>
        <span class="ds-sv__modes">
            @foreach (['coming' => 'Coming', 'container' => 'Container', 'roro' => 'RoRo', 'lcl' => 'LCL', 'received' => 'Received'] as $k => $l)
                <button type="button" @class(['is-on' => $kind === $k]) wire:click="$set('kind', '{{ $k }}')">{{ $l }} <small>{{ $counts[$k] }}</small></button>
            @endforeach
        </span>
    </div>
    @forelse ($cards as $c)
        <section class="ds-hi__card" wire:key="hi-{{ $c['id'] }}">
            <header>
                <span class="ds-hi__ico" aria-hidden="true">{{ ['roro' => '⛴️', 'lcl' => '📦'][$c['kind']] ?? '🚢' }}</span>
                <span><span class="ds-hi__t"><a href="{{ $c['url'] }}"><b>{{ $c['title'] }}</b></a><i class="ds-hi__tag is-{{ $c['kind'] }}">{{ $c['tag'] }}</i></span><small>{{ $c['sub'] }}</small></span>
            </header>
            <div class="ds-hi__facts">@foreach ($c['facts'] as $l => $v)<span><small>{{ $l }}</small><b>{{ $v }}</b></span>@endforeach</div>
            <div class="ds-hi__steps">
                @foreach ($c['steps'] as $i => $st)
                    <span @class(['is-done' => $i < $c['at'], 'is-now' => $i === $c['at']])><i>{{ $i < $c['at'] ? '✓' : $i + 1 }}</i>{{ $st }}</span>
                    @if (! $loop->last)<em @class(['is-done' => $i < $c['at']])></em>@endif
                @endforeach
            </div>
            @if (! $c['received'])
                <div class="ds-hi__todo">
                    <span><b>To do:</b> {{ $c['todo'] }}</span>
                    @foreach ($c['actions'] as $a)
                        @if (isset($a['url']))
                            <a href="{{ $a['url'] }}" @class(['ds-hi__btn', 'is-primary' => $a['primary']])>{{ $a['label'] }}</a>
                        @else
                            <button type="button" @class(['ds-hi__btn', 'is-primary' => $a['primary']]) wire:click="hubPress({{ $c['id'] }}, '{{ $a['press'] }}')" wire:confirm="{{ $a['label'] }}?">{{ $a['label'] }}</button>
                        @endif
                    @endforeach
                    <a href="{{ $c['url'] }}" class="ds-hi__btn">Details</a>
                </div>
            @endif
        </section>
    @empty
        <p class="ds-board__muted">{{ $kind === 'received' ? 'Nothing received yet.' : 'No sea shipments coming to your hub right now.' }}</p>
    @endforelse
    <p class="ds-board__muted">Sorted by what arrives first. Each kind shows its own steps and what you need to do.</p>
</div>
</x-filament-panels::page>
