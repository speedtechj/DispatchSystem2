<x-filament-panels::page>
<div class="ds-pg" wire:poll.10s.visible>
    <span class="ds-pt__head">
        <h1 class="ds-pt__title" style="font-size: 1.6rem; font-weight: 800; margin: 0">Picking</h1>
        <span style="color: #6b7b88">Give each trip its pickers. They see it in the Scan app (Pick boxes), pick from the sections, then load it with Load truck.</span>
    </span>

    <section class="ds-pg__card">
        <div class="ds-pg__head"><span>Trip</span><span>Sections</span><span>Pickers</span><span>Picked</span><span>Next</span></div>
        @forelse ($rows as $t)
            <div class="ds-pg__row" wire:key="pg-{{ $t['id'] }}">
                <span class="ds-pg__trip"><b>{{ $t['no'] }}</b><small>{{ $t['to'] }} · {{ $t['truck'] }}</small></span>
                <span class="ds-pg__secs">{{ $t['secs'] }}</span>
                <span class="ds-pg__pickers">
                    @foreach ($t['pickers'] as $p)
                        <span class="ds-pg__chip" wire:key="pc-{{ $t['id'] }}-{{ $p['id'] }}">{{ $p['name'] }}<button type="button" wire:click="remove({{ $t['id'] }}, {{ $p['id'] }})" aria-label="Remove {{ $p['name'] }}">✕</button></span>
                    @endforeach
                    @if ($t['status'] !== 'ready' && count($t['others']))
                        <button type="button" class="ds-pg__add" wire:click="openAdd({{ $t['id'] }})">+ Add picker</button>
                    @endif
                    @if ($addFor === $t['id'])
                        <span class="ds-pg__pop" x-on:click.outside="$wire.openAdd(null)">
                            @foreach ($t['others'] as $o)
                                <button type="button" wire:click="add({{ $t['id'] }}, {{ $o['id'] }})">{{ $o['name'] }}@if ($o['busy'])<small>on another trip</small>@endif</button>
                            @endforeach
                        </span>
                    @endif
                    @if (! count($t['pickers']) && $t['status'] !== 'ready')
                        <small class="ds-pg__none">No picker yet · anyone free can Take it in the Scan app</small>
                    @endif
                    @if ($t['sug'])
                        <span class="ds-pg__sug"><small>✦ Suggested: {{ implode(', ', $t['sug']['names']) }} <span>· {{ $t['sug']['why'] }}</span></small><button type="button" wire:click="useSuggestion({{ $t['id'] }})">Use</button></span>
                    @endif
                </span>
                <span class="ds-pg__prog">
                    <span><i style="width: {{ $t['pct'] }}%"></i></span>
                    <small>{{ $t['p']['picked'] }} of {{ $t['p']['total'] }} picked</small>
                    @if ($t['missing']->isNotEmpty())
                        <span class="ds-pg__miss">Not found:
                            @foreach ($t['missing'] as $m)<span>{{ $m->invoice }} <button type="button" wire:click="found({{ $m->id }})">Found it</button></span>@endforeach
                        </span>
                    @endif
                </span>
                @php($st = ['ready' => ['Ready to load', 'is-ready'], 'picking' => ['Picking', 'is-picking'], 'wait' => ['Waiting for pickers', 'is-wait'], 'none' => ['Give it a picker', 'is-wait']][$t['status']])
                <span class="ds-pg__st {{ $st[1] }}">{{ $st[0] }}</span>
            </div>
        @empty
            <div class="ds-pg__empty">No trips to pick. Trips with boxes still in the sections show here.</div>
        @endforelse
    </section>

    <section class="ds-pg__card ds-pg__log">
        <b>Live · who is picking</b>
        @forelse ($log as $l)
            <span><small>{{ $l['t'] }}</small><span style="flex: 1">{{ $l['m'] }}</span>@if ($l['undo'])<button type="button" class="ds-pg__add" style="height: 24px" wire:click="undo({{ $l['undo'] }})" wire:confirm="Put this box back on the pick list?">↶ Undo</button>@endif</span>
        @empty
            <small style="width: auto">Nothing picked yet today.</small>
        @endforelse
    </section>
</div>
</x-filament-panels::page>
