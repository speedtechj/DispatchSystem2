<x-filament-panels::page>
<div class="ds-sp">
    <p class="ds-board__muted">Only hubs reached <b>by sea</b> show in Sea shipments → trip to the port. Visayas and Mindanao start as By sea, Luzon as By truck. Change a hub if you reach it differently (for example a Luzon hub by RoRo, like Palawan or Mindoro).</p>
    <section class="ds-board__panel ds-sp__table">
        <div class="ds-sp__tr is-isl is-head"><span>Hub</span><span>Island group</span><span>How boxes get there</span><span>Usual port</span></div>
        @foreach ($hubs as $r)
            <div class="ds-sp__tr is-isl" wire:key="hi-{{ $r['h']->id }}">
                <span><b>{{ $r['h']->hub_name }}</b><small>{{ $r['h']->is_company ? 'Partner hub' : 'Main hub' }}{{ $r['set'] ? '' : ' · suggested from '.$r['suggest']['from'] }}</small></span>
                <span><select wire:change="setIsland({{ $r['h']->id }}, $event.target.value)" aria-label="Island of {{ $r['h']->hub_name }}">@foreach ($islands as $k => $l)<option value="{{ $k }}" @selected($r['island'] === $k)>{{ $l }}{{ ! $r['set'] && $r['island'] === $k ? ' (suggested)' : '' }}</option>@endforeach</select></span>
                <span>
                    @if ($r['h']->is_company)
                        <button type="button" wire:click="toggleSea({{ $r['h']->id }})" @class(['ds-sp__way', 'is-sea' => $r['sea']])>{{ $r['sea'] ? '🚢 By sea · shows in Sea shipments' : '🚚 By truck' }}</button>
                    @else
                        <small>Main hub: the boxes start here</small>
                    @endif
                </span>
                <span>@if ($r['h']->is_company)<input type="text" value="{{ $r['port'] }}" placeholder="{{ $r['lastPort'] ?: 'e.g. Cebu Port' }}" wire:change="setPort({{ $r['h']->id }}, $event.target.value)" aria-label="Usual port">@endif</span>
            </div>
        @endforeach
    </section>
</div>
</x-filament-panels::page>
