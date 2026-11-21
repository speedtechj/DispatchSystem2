<x-filament-panels::page>
<form wire:submit="save" class="ds-ws">
    <div class="ds-ws__by">
        <span><small>Sections by</small>
            <span class="ds-ws__seg">
                <button type="button" wire:click="setBy('province')" @class(['is-on' => $by === 'province'])>Province · default</button>
                <button type="button" wire:click="setBy('city')" @class(['is-on' => $by === 'city'])>City</button>
            </span></span>
    </div>
    @if ($by === 'city')
        <p class="ds-ws__citynote">City mode: each section lists cities and municipalities, always with their province (San Jose, Nueva Ecija is not San Jose, Batangas). Your province choices are kept: switch back to Province any time.</p>
    @endif
    <div class="ds-ws__top">
        <label class="ds-ws__wh"><span>Warehouse</span>
            <select wire:model.live="warehouseId">@foreach ($warehouses as $id => $name)<option value="{{ $id }}">{{ $name }}</option>@endforeach</select>
        </label>
        <span class="ds-ws__acts">
            @if ($labelsUrl && count($rows))<x-filament::button tag="a" :href="$labelsUrl" target="_blank" color="gray" icon="heroicon-o-printer">Print QR labels</x-filament::button>@endif
            <x-filament::button type="button" color="gray" wire:click="addRow" icon="heroicon-o-plus">Add section</x-filament::button>
        </span>
    </div>

    <section class="ds-board__panel ds-ws__list">
        <div @class(['ds-ws__row', 'is-head', 'has-spots' => $spotsOn])><span>Code</span><span>Name</span><span>Kind</span><span>Goes to</span><span>{{ $by === 'city' ? 'Receiver cities and municipalities' : 'Receiver provinces' }}</span>@if ($spotsOn)<span class="ds-ws__new">Spots (optional)</span>@endif<span></span></div>
        @forelse ($rows as $i => $r)
            <div @class(['ds-ws__row', 'has-spots' => $spotsOn]) wire:key="sec-{{ $r['id'] ?? 'n'.$i }}">
                <span class="ds-ws__code" style="--c: {{ $r['color'] }}"><input type="text" wire:model.live.debounce.400ms="rows.{{ $i }}.code" maxlength="8" aria-label="Code">
                    <select wire:model.live="rows.{{ $i }}.color" aria-label="Color">@foreach ($colors as $c)<option value="{{ $c }}">{{ $c }}</option>@endforeach</select></span>
                <input type="text" wire:model="rows.{{ $i }}.name" placeholder="Cebu hub" aria-label="Name">
                <select wire:model.live="rows.{{ $i }}.kind" aria-label="Kind">@foreach ($kinds as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                <select wire:model="rows.{{ $i }}.to" aria-label="Goes to">@foreach ($targets as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                @if ($r['kind'] === 'area')
                    @php($list = $by === 'city' ? ($r['cities'] ?? []) : ($r['provinces'] ?? []))
                    <span class="ds-ws__places">
                        <span @class(['ds-ws__field', 'is-open' => $pickRow === $i])>
                            @foreach ($list as $v)
                                <span @class(['ds-ws__chip', 'is-city' => $by === 'city'])>{{ $by === 'city' ? '📍 ' : '' }}{{ $v }}<button type="button" wire:click="removePlace({{ $i }}, @js($v))" aria-label="Remove {{ $v }}">✕</button></span>
                            @endforeach
                            <button type="button" class="ds-ws__add" wire:click="openPick({{ $i }})">{{ $list ? ($by === 'city' ? '+ add a city' : '+ add a province') : ($by === 'city' ? 'Pick cities…' : 'Pick provinces…') }}</button>
                        </span>
                        @if ($pickRow === $i)
                            <span class="ds-ws__pop">
                                <input type="text" wire:model.live.debounce.250ms="pickQ" placeholder="{{ $by === 'city' ? 'Type to search: san jose…' : 'Type to search: nue…' }}" aria-label="Search" autofocus>
                                <span class="ds-ws__opts">
                                    @forelse ($options as $o)
                                        <button type="button" wire:click="addPlace(@js($o['value']))"><b>{{ $o['value'] }}</b>@if ($o['in'])<small>In Section {{ $o['in'] }} · pick to move it here</small>@endif</button>
                                    @empty
                                        <small class="ds-ws__none">{{ $by === 'city' ? 'No city with that name.' : 'No province with that name.' }}</small>
                                    @endforelse
                                </span>
                                <button type="button" class="ds-ws__done" wire:click="closePick">Done</button>
                            </span>
                        @endif
                    </span>
                @else
                    <small class="ds-ws__muted">{{ $r['kind'] === 'check' ? 'Boxes with no '.($by === 'city' ? 'city' : 'province').', or one no section has.' : 'Boxes coming back from the hubs.' }}</small>
                @endif
                @if ($spotsOn)
                    <span class="ds-ws__spots">
                        <span class="ds-ws__spotsw"><button type="button" role="switch" aria-checked="{{ $r['use_spots'] ? 'true' : 'false' }}" wire:click="toggleSpots({{ $i }})" @class(['ds-te__switch', 'is-on' => $r['use_spots']])><i></i></button><small>{{ $r['use_spots'] ? count($r['spots']).' '.Str::plural('spot', count($r['spots'])) : 'No spots · one area' }}</small></span>
                        @if ($r['use_spots'])
                            <span class="ds-ws__spotlist">@foreach ($r['spots'] as $sp)<span class="ds-ws__spot">{{ $sp }}<button type="button" wire:click="removeSpot({{ $i }}, @js($sp))" aria-label="Remove spot {{ $sp }}">✕</button></span>@endforeach<button type="button" class="ds-ws__addspot" wire:click="addSpot({{ $i }})">+ add</button></span>
                        @endif
                    </span>
                @endif
                <button type="button" class="ds-ws__del" wire:click="removeRow({{ $i }})" wire:confirm="Remove section {{ $r['code'] }}?" aria-label="Remove">✕</button>
            </div>
        @empty
            <div class="ds-ws__empty">
                <p>No sections yet for this warehouse. Without sections, unloading works as before.</p>
                <x-filament::button type="button" wire:click="suggest">Start with one section per hub</x-filament::button>
            </div>
        @endforelse
        @error('rows')<p class="ds-ws__err">{{ $message }}</p>@enderror
        @foreach ($errors->get('rows.*') as $msgs)<p class="ds-ws__err">{{ $msgs[0] }}</p>@break @endforeach
    </section>

    <div class="ds-ws__two">
        <section class="ds-board__panel ds-ws__box">
            <h3>At unload</h3>
            <label class="ds-ws__toggle"><input type="checkbox" wire:model="labelScan"><span><b>Also scan the section label</b><small>Off: a box is saved in its section when it is scanned at the container. On: the crew also scans the QR on the section (once for a cartful of boxes).</small></span></label>
            <label class="ds-ws__toggle is-new"><input type="checkbox" wire:model.live="spotsOn"><span><b>Use spots inside sections (C1, C2…) <em class="ds-ws__newpill">new</em></b><small>{{ $spotsOn ? 'On: switch spots on for the sections that have racks (Spots column). At unload the crew scans the spot’s QR, taps it, or presses Skip.' : 'Off: sections only, like today.' }}</small></span></label>
            <p class="ds-ws__muted">Start with this off, for speed. Switch it on if boxes are often not where the system says.</p>
        </section>
        <section class="ds-board__panel ds-ws__box">
            <h3>How it works</h3>
            <p class="ds-ws__muted">At unload the Scan app shows the section for each box, from the receiver's {{ $by === 'city' ? 'city' : 'province' }}, and keeps a customer's boxes together ("box 2 of 3"). A box with no {{ $by === 'city' ? 'city' : 'province' }}, or one no section has, goes to <b>Check address</b>. Boxes for another warehouse can go straight onto a waiting truck.</p>
            <p class="ds-ws__muted ds-ws__spotnote"><b>Spots:</b> only in the sections where you switch them on. At unload the crew scans the spot’s QR, taps it, or presses Skip; a box with no spot is still in its section.</p>
        </section>
    </div>
    <div><x-filament::button type="submit">Save</x-filament::button></div>
</form>
</x-filament-panels::page>
