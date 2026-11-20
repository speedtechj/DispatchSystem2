<x-filament-panels::page>
<div class="ds-fl ds-wc">
    <span class="ds-te__title"><small>@if ($areasUrl)<a href="{{ $areasUrl }}" class="ds-te__link">‹ Hub areas</a> · @endif Settings › Hubs</small><h1>{{ $record ? $record->hub_name.': where it is and its area' : 'Add a hub and its area' }}</h1><small>Tell the system where the hub is. It suggests the places nearby that have no hub yet. You confirm.</small></span>
    <div class="ds-hs__grid">
        <section class="ds-cb__card ds-wc__card">
            <b class="ds-ad__h">1 · The hub</b>
            <form wire:submit="save" class="ds-hs__form">
                <label><small>Hub name</small><input type="text" wire:model="form.name" class="ds-te__input" placeholder="Dagupan Hub"></label>
                <label><small>Code (trip numbers start with it)</small><input type="text" wire:model="form.code" class="ds-te__input" placeholder="DGP" maxlength="6"></label>
                <label><small>Where is the hub? Province</small><input type="text" list="hs-provinces" wire:model="form.province" class="ds-te__input" placeholder="Pangasinan"></label>
                <label><small>City</small><input type="text" wire:model="form.city" class="ds-te__input" placeholder="Dagupan City"></label>
                <label><small>Barangay</small><input type="text" wire:model="form.barangay" class="ds-te__input" placeholder="Tapuac"></label>
                <label><small>Hub phone (in texts to receivers)</small><input type="text" wire:model="form.phone" class="ds-te__input" placeholder="0917 …"></label>
                <button type="submit" class="ds-te__btn is-main">{{ $record ? 'Save' : 'Add the hub' }}</button>
            </form>
            <datalist id="hs-provinces">@foreach ($provinces as $p)<option value="{{ $p }}">@endforeach</datalist>
        </section>
        <section class="ds-cb__card ds-wc__card">
            <span class="ds-wc__head"><b class="ds-ad__h">2 · ✦ Suggested area</b>@if ($record)<small>{{ $picked }} {{ Str::plural('place', $picked) }} picked</small>@endif</span>
            @if (! $record || ! $record->province)
                <small class="ds-te__hint">Save the hub with its province first.</small>
            @else
                <small class="ds-te__hint">Only places with no hub now (the warehouse delivers them direct). Click to leave one out.</small>
                @forelse ($free as $i => $g)
                    <button type="button" wire:click="toggleLeave({{ $i }})" @class(['ds-hs__sug', 'is-off' => ! empty($leave[$i])])><i>{{ empty($leave[$i]) ? '✓' : '' }}</i><span><b>{{ $g['city'] ? $g['city'].', ' : '' }}{{ $g['province'] }}</b><small>{{ $g['sub'] }}</small></span><small>{{ $g['perWeek'] }} boxes/week</small></button>
                @empty
                    <small class="ds-te__hint">Every place near {{ $record->province }} already has a hub. Add places by hand in Hub areas.</small>
                @endforelse
                @foreach ($closer as $c)
                    <span class="ds-wc__conflict" wire:key="c-{{ $c['area']->id }}">
                        <b>Closer than its hub now</b>
                        <span>{{ $c['sub'] }} Never moved without you.</span>
                        @if (! isset($move[$c['area']->id]))
                            <span class="ds-wc__btns"><button type="button" class="ds-te__btn is-main" wire:click="decideMove({{ $c['area']->id }}, 'yes')">Move to {{ $record->hub_name }}</button><button type="button" class="ds-te__btn ds-wc__ghost" wire:click="decideMove({{ $c['area']->id }}, 'no')">Keep with {{ \App\Support\Hubs\HubAreas::name($c['area']->logistichub_id) }}</button></span>
                        @else
                            <small><b>{{ $move[$c['area']->id] === 'yes' ? '✓ Moves to '.$record->hub_name.' when you approve' : 'Stays with '.\App\Support\Hubs\HubAreas::name($c['area']->logistichub_id) }}</b></small>
                        @endif
                    </span>
                @endforeach
                @if ($picked)<button type="button" class="ds-te__btn is-main" wire:click="approve">Approve {{ $picked }} {{ Str::plural('place', $picked) }} for {{ $record->hub_name }}</button>@endif
                @if ($saved)<span class="ds-ha__ok">✓ {{ $record->hub_name }} has {{ $mine->count() }} {{ Str::plural('place', $mine->count()) }}. Its boxes go on “To hub” trips from the next plan.</span>@endif
                <small class="ds-te__hint">Until the area is approved, no box goes to this hub: the warehouse keeps delivering direct.</small>
            @endif
        </section>
        <section class="ds-cb__card ds-wc__card">
            <b class="ds-ad__h">When a hub is switched off</b>
            @if ($record)
                <span class="ds-hs__switch"><span>{{ $record->hub_name }} active</span><button type="button" role="switch" aria-checked="{{ $record->is_active ? 'true' : 'false' }}" wire:click="toggleActive" @class(['ds-hs__sw', 'is-on' => $record->is_active])><i></i></button></span>
                @if (! $record->is_active && $mine->isNotEmpty())
                    <span class="ds-ha__off"><b>{{ $record->hub_name }} is off: {{ $mine->count() }} {{ Str::plural('place', $mine->count()) }} have no hub now</b><span>{{ $mine->map->label()->join(', ') }}. New boxes there go direct from the warehouse. Trips already going to {{ $record->hub_name }} finish as planned. Give them to another hub in Hub areas.</span></span>
                @endif
            @endif
            <span class="ds-wc__asked">Only active hubs show in Hub areas and Plan trips. A hub switched on again gets its places back.</span>
        </section>
    </div>
</div>
</x-filament-panels::page>
