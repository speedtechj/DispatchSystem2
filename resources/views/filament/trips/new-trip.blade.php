<x-filament-panels::page>
<div class="ds-nt">
    <div class="ds-nt__top">
        <span class="ds-te__title"><a href="{{ $listUrl }}" class="ds-te__link">‹ Delivery trips</a><h1>New trip by hand</h1><small>For a trip Plan trips does not make. Most days, ✦ Plan trips makes them for you.</small></span>
        @if ($planUrl)<a href="{{ $planUrl }}" class="ds-nt__plan">✦ Use Plan trips instead</a>@endif
    </div>
    <div class="ds-nt__grid">
        <div class="ds-nt__steps">
            @if (! $atHub)
                <section class="ds-cb__card ds-nt__card">
                    <span class="ds-nt__h"><i>1</i><b>Where does it go?</b></span>
                    <span class="ds-nt__two">
                        <button type="button" wire:click="pickGo('direct')" @class(['ds-nt__opt', 'is-on' => $go === 'direct'])><em>🏠</em><span><b>Direct to customers</b><small>Our truck delivers to each receiver{{ $hubName ? ' · from '.$hubName : '' }}</small></span></button>
                        <button type="button" wire:click="pickGo('hub')" @class(['ds-nt__opt', 'is-on' => $go === 'hub'])><em>⌂</em><span><b>To a partner hub</b><small>The hub delivers with its own trucks</small></span></button>
                    </span>
                    @if ($go === 'hub')
                        <span class="ds-nt__chips">
                            @forelse ($hubs as $h)
                                <button type="button" wire:click="pickHub({{ $h->id }})" @class(['ds-nt__chip', 'is-on' => $hub === $h->id])><i style="background: {{ $color($h->id) }}"></i>{{ $h->hub_name }}</button>
                            @empty
                                <small class="ds-te__hint">No other active hub.</small>
                            @endforelse
                        </span>
                    @endif
                </section>
            @endif
            <section class="ds-cb__card ds-nt__card">
                <span class="ds-nt__h"><i>{{ $atHub ? 1 : 2 }}</i><b>Truck</b><small>Check its space first: a full truck is safe, an overloaded one is not</small></span>
                <span class="ds-nt__trucks">
                    @forelse ($trucks as $t)
                        <button type="button" wire:click="pickTruck({{ $t['id'] }})" @disabled($t['state'] === 'off') @class(['ds-nt__truck', 'is-on' => $truck === $t['id'], 'is-off' => $t['state'] === 'off'])>
                            <span class="ds-nt__trow"><b>{{ $t['plate'] }}</b><em class="is-{{ $t['state'] }}">{{ $t['state'] === 'busy' && $t['on'] ? 'On '.$t['on'] : $t['label'] }}</em></span>
                            <small>{{ $t['kind'] ?: 'Truck' }} · {{ $t['capacity'] }} space</small>
                            <small class="ds-nt__crew">👥 {{ $t['state'] === 'free' ? $t['sub'] : ($t['state'] === 'busy' ? 'Crew on '.$t['on'] : '—') }}</small>
                        </button>
                    @empty
                        <small class="ds-te__hint">No trucks in this hub yet.</small>
                    @endforelse
                </span>
                @if ($sel && $sel['state'] === 'busy')
                    <span class="ds-wc__asked">{{ $sel['plate'] }} is still on {{ $sel['on'] }}: this trip waits and starts when it closes. The crew sees it as soon as the truck is free.</span>
                @endif
                @error('truck')<small class="ds-nt__err">{{ $message }}</small>@enderror
            </section>
            <section class="ds-cb__card ds-nt__card">
                <span class="ds-nt__h"><i>{{ $atHub ? 2 : 3 }}</i><b>When</b></span>
                <span class="ds-nt__when">
                    <label><small>Leaves</small><span class="ds-nt__chips">@foreach (['today' => 'Today', 'tomorrow' => 'Tomorrow', 'date' => 'Pick a date'] as $k => $l)<button type="button" wire:click="setDay('{{ $k }}')" @class(['ds-nt__chip', 'is-on' => $day === $k])>{{ $l }}</button>@endforeach</span>
                        @if ($day === 'date')<input type="date" wire:model.live="date" class="ds-te__input">@endif</label>
                    <label><small>Arrives (ETA)</small><input type="date" wire:model="eta" class="ds-te__input"></label>
                    <label><small>Trip day</small><span class="ds-nt__chips">@foreach ([1, 2, 3] as $n)<button type="button" wire:click="$set('tripDay', {{ $n }})" @class(['ds-nt__chip', 'is-on' => $tripDay === $n])>Day {{ $n }}</button>@endforeach</span></label>
                </span>
            </section>
            <section class="ds-cb__card ds-nt__card">
                <span class="ds-nt__h"><i>{{ $atHub ? 3 : 4 }}</i><b>Paperwork</b><small>optional</small></span>
                <span class="ds-nt__two">
                    <label><small>Waybill no.</small><span class="ds-nt__field"><input type="text" wire:model.live.debounce.400ms="waybill" class="ds-te__input" placeholder="WB-12345">@if ($waybillOk === true)<em class="is-ok">✓ looks right</em>@elseif ($waybillOk === false)<em class="is-bad">format: WB-12345</em>@endif</span></label>
                    <label><small>Container no.</small><input type="text" wire:model="container" class="ds-te__input" placeholder="CN-12345"></label>
                </span>
            </section>
        </div>
        <aside class="ds-cb__card ds-nt__sum">
            <b class="ds-nt__sumh">Trip summary</b>
            @foreach ([
                'Going to' => $atHub ? 'Direct to customers' : ($go === 'hub' ? '→ '.$toName : 'Direct to customers'),
                'Truck' => $sel ? $sel['plate'].' · '.$sel['capacity'].' space' : 'No truck yet',
                'Crew' => $sel && $sel['state'] === 'free' ? $sel['sub'] : ($sel ? 'Crew of '.$sel['plate'] : '—'),
                'Leaves' => $fmt($date),
                'Arrives' => $fmt($eta),
                'Trip day' => 'Day '.$tripDay,
                'Made by' => '✎ By hand · '.(auth()->user()?->first_name ?? 'you'),
            ] as $k => $v)
                <span class="ds-nt__row"><span>{{ $k }}</span><b>{{ $v }}</b></span>
            @endforeach
            <span class="ds-nt__space"><small>Truck space</small><span class="ds-tl__bar"><i style="width: 0%"></i></span><small>0 of {{ $sel['capacity'] ?? 0 }} · boxes are added after Create</small></span>
            <button type="button" class="ds-nt__go" wire:click="createTrip(true)" wire:loading.attr="disabled">Create trip and add boxes</button>
            <button type="button" class="ds-nt__only" wire:click="createTrip(false)" wire:loading.attr="disabled">Create only</button>
            <a href="{{ $listUrl }}" class="ds-nt__cancel">Cancel</a>
            <small class="ds-te__hint">Saved as “✎ By hand” in Delivery trips. The trip number is given when you press Create. Delivered date fills itself when the last box is delivered.</small>
        </aside>
    </div>
</div>
</x-filament-panels::page>
