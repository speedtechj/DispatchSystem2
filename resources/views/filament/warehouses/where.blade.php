<x-filament-panels::page>
<div class="ds-fl ds-wc">
    <span class="ds-te__title"><h1>Containers on the way · where to unload</h1><small>Counted from the manifest before the container is unloaded. The office decides.</small></span>
    @unless ($active)<span class="ds-ad__pending"><span>Set which warehouse delivers each province first (Settings → Warehouse coverage).</span></span>@endunless
    <section class="ds-cb__card ds-ad__table">
        <span class="ds-wc__row is-head"><span>Container</span><span>Added</span><span>Boxes by warehouse</span><span>Suggestion</span><span>Unload at</span></span>
        @forelse ($rows as $r)
            @php($c = $r['c'])
            <span class="ds-wc__row" wire:key="c-{{ $c->id }}">
                <b>{{ $c->container_no }}</b>
                <span>{{ $c->created_at?->format('M j') }}</span>
                <span class="ds-wc__split">
                    <span class="ds-wc__bar">@foreach ($whs as $i => $w)@if ($n = $r['split'][$w->id] ?? 0)<i style="width: {{ round($n / $r['total'] * 100) }}%; background: {{ $colors[$i % 4] }}"></i>@endif @endforeach</span>
                    <small class="ds-te__hint">{{ $whs->map(fn ($w) => \Illuminate\Support\Str::before($w->name, ' ').' '.($r['split'][$w->id] ?? 0))->join(' · ') }}</small>
                </span>
                <span class="ds-wc__tip">✦ {{ $r['tip'] }}</span>
                <span class="ds-fl__seg">@foreach ($whs as $w)<button type="button" wire:click="setWarehouse({{ $c->id }}, {{ $w->id }})" @class(['is-on' => (int) $c->warehouse_id === $w->id])>{{ \Illuminate\Support\Str::before($w->name, ' ') }}</button>@endforeach</span>
            </span>
        @empty
            <p class="ds-cb__muted ds-ad__empty">No containers waiting to be unloaded.</p>
        @endforelse
    </section>
    <span class="ds-ad__info">Box aging keeps counting from the first unload, so you see if a transfer makes boxes late.</span>
</div>
</x-filament-panels::page>
