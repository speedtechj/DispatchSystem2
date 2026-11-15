<x-filament-panels::page>
<div class="ds-ws">
    <section class="ds-board__panel ds-ws__box">
        <h3>Find a box</h3>
        <input type="text" wire:model.live.debounce.400ms="find" placeholder="Box number" aria-label="Box number">
        @if ($code !== '')
            @if ($hit)
                <div class="ds-ws__result" style="--c: {{ $hit['box']->whSection?->color ?? '#6b7b88' }}">
                    <strong>{{ $hit['box']->whSection?->code ?? '?' }}</strong>
                    <span><b>{{ $hit['box']->invoice }} · {{ \Illuminate\Support\Str::title($hit['box']->receiver_name) }}</b>
                        <small>{{ $hit['where'] }}</small>
                        <small>{{ $hit['box']->sectioned_at ? 'Put there '.$hit['box']->sectioned_at->format('M j, g:i A') : '' }}{{ $hit['box']->verifiedBy ? ' · unloaded by '.$hit['box']->verifiedBy->first_name : '' }}</small></span>
                </div>
            @else
                <p class="ds-ws__muted">No box {{ $code }}.</p>
            @endif
        @endif
    </section>

    <section class="ds-board__panel ds-ws__list">
        <div class="ds-ws__row is-view is-head"><span>Section</span><span>Goes to</span><span>Receiver provinces</span><span>Boxes now</span><span>Last count</span></div>
        @forelse ($sections as $r)
            <div class="ds-ws__row is-view" wire:key="sv-{{ $r['s']->id }}">
                <span class="ds-ws__badge" style="--c: {{ $r['s']->color }}">{{ $r['s']->code }}</span>
                <span><b>{{ $r['s']->name }}</b><small class="ds-ws__muted">{{ $r['s']->goesTo() }}</small></span>
                <span class="ds-ws__muted">{{ implode(', ', (array) $r['s']->provinces) ?: '—' }}</span>
                <b class="num">{{ $r['boxes'] }}</b>
                <span class="ds-ws__muted">{{ $r['counted'] ? $r['counted']->finished_at->format('M j').' · '.$r['counted']->found.' found, '.$r['counted']->missing.' missing' : 'not counted yet' }}</span>
            </div>
        @empty
            <p class="ds-ws__muted ds-ws__pad">No sections yet. Admin sets them in Settings → Warehouse sections.</p>
        @endforelse
    </section>

    <div class="ds-ws__two">
        <section class="ds-board__panel ds-ws__box">
            <h3>At unload</h3>
            <p class="ds-ws__muted">Section label scan is <b>{{ $labelScan ? 'on' : 'off' }}</b>. Admin changes it in Settings → Warehouse sections.</p>
            @if ($labelsUrl)<div><x-filament::button tag="a" :href="$labelsUrl" target="_blank" color="gray" icon="heroicon-o-printer">Print QR labels</x-filament::button></div>@endif
        </section>
        <section class="ds-board__panel ds-ws__box">
            <h3>Count a section</h3>
            <p class="ds-ws__muted">Scan app → Count a section → pick the section, and scan every box on it. A box that is in the wrong place is moved here; boxes not found are listed at the end.</p>
        </section>
    </div>
</div>
</x-filament-panels::page>
