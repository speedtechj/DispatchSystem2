<x-filament-panels::page>
<div class="ds-fl">
    <div class="ds-fl__top">
        <span class="ds-fl__summary">{{ $summary }}</span>
        <span class="ds-fl__tools">
            <input type="search" class="ds-fl__search" wire:model.live.debounce.300ms="search" placeholder="🔍 Plate, crew or trip" aria-label="Search trucks">
            @if ($createUrl)<a href="{{ $createUrl }}" class="ds-fl__add">+ Add truck</a>@endif
        </span>
    </div>
    @if ($dupes->isNotEmpty())
        <section class="ds-cb__card ds-fl__dupes">
            <span class="ds-fl__dupes-head">
                <span><b>{{ $dupes->count() }} possible {{ Str::plural('duplicate', $dupes->count()) }}</b><small>Same plate once spaces, dashes and capitals are ignored. Pick the one to keep; the other's trips move to it.</small></span>
                <small class="ds-te__hint">Not the same truck? Mark “Different trucks”.</small>
            </span>
            @foreach ($dupes as $g)
                <span class="ds-fl__dupe" wire:key="d-{{ $g['ids'] }}">
                    <b>{{ $g['plate'] }}</b>
                    <span class="ds-fl__dupe-copies">@foreach ($g['copies'] as $c)<span><b>{{ $c['plate'] }}</b> · {{ $c['hub'] ?? '—' }} · {{ $c['trips'] }} {{ Str::plural('trip', $c['trips']) }}{{ $c['off'] ? ' · inactive' : '' }}</span>@endforeach</span>
                    <a href="{{ $g['url'] }}" class="ds-te__btn is-main">Compare &amp; keep one</a>
                    <button type="button" class="ds-te__btn" wire:click="notDuplicates('{{ $g['ids'] }}')">Different trucks</button>
                </span>
            @endforeach
        </section>
    @endif
    <div class="ds-fl__chips" role="group" aria-label="Show">
        @foreach (['all' => 'All', 'trip' => 'On a trip', 'free' => 'Free', 'rental' => 'Rental', 'off' => 'Inactive'] as $k => $l)
            <button type="button" wire:click="setFilter('{{ $k }}')" @class(['ds-fl__chip', 'is-on' => $filter === $k])>{{ $l }} <span>{{ $counts[$k] }}</span></button>
        @endforeach
    </div>
    <div class="ds-fl__grid">
        @forelse ($cards as $c)
            <a href="{{ $c['url'] }}" @class(['ds-cb__card', 'ds-fl__card', 'is-dim' => in_array($c['tone'], ['bad', 'muted'], true) && $c['group'] !== 'trip', 'is-dupe' => isset($flagged[$c['truck']->id])]) wire:key="t-{{ $c['truck']->id }}">
                <span class="ds-fl__head">
                    <span><b class="ds-fl__plate">{{ $c['truck']->plate_no }}</b><small>{{ $c['kind'] }}</small></span>
                    <span class="ds-fl__tags">
                        <span class="ds-cb__pill is-{{ $c['tone'] }}">{{ $c['state'] }}</span>
                        <span @class(['ds-cb__pill', 'is-rent' => $c['rental'], 'is-own' => ! $c['rental']])>{{ $c['rental'] ? 'Rental' : 'Own' }}</span>
                    </span>
                </span>
                <span class="ds-fl__mid">
                    <span class="ds-fl__truck" style="--tc: {{ $c['truck']->is_active ? $c['color'] : '#c3ccd4' }}" aria-hidden="true"><i class="b"></i><i class="c"></i><i class="w"></i><i class="r1"></i><i class="r2"></i></span>
                    <span class="ds-fl__crew">
                        @forelse ($c['crew'] as $i => $p)
                            <span title="{{ $p['name'] }}">{{ $p['ini'] }}</span>
                        @empty
                            <small class="ds-cb__none">No crew</small>
                        @endforelse
                    </span>
                </span>
                <span class="ds-fl__load"><small>{{ $c['loadLabel'] }}</small><small>{{ $c['load'] }} of {{ $c['space'] }} space</small></span>
                <span class="ds-fl__bar"><i style="width: {{ $c['pct'] }}%" @class(['is-full' => $c['pct'] > 90])></i></span>
                @if (isset($flagged[$c['truck']->id]))<span class="ds-fl__note is-warn">Possible duplicate of {{ $flagged[$c['truck']->id] }}</span>
                @elseif ($c['note'])<span class="ds-fl__note is-{{ $c['note'][1] }}">{{ $c['note'][0] }}</span>@endif
            </a>
        @empty
            <p class="ds-cb__muted">No trucks here.</p>
        @endforelse
    </div>
</div>
</x-filament-panels::page>
