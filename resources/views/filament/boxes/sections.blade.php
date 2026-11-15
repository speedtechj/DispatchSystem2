<x-filament-panels::page>
<form wire:submit="save" class="ds-ws">
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
        <div class="ds-ws__row is-head"><span>Code</span><span>Name</span><span>Kind</span><span>Goes to</span><span>Receiver provinces (comma between)</span><span>Boxes</span><span></span></div>
        @forelse ($rows as $i => $r)
            <div class="ds-ws__row" wire:key="sec-{{ $r['id'] ?? 'n'.$i }}">
                <span class="ds-ws__code" style="--c: {{ $r['color'] }}"><input type="text" wire:model.live.debounce.400ms="rows.{{ $i }}.code" maxlength="8" aria-label="Code">
                    <select wire:model.live="rows.{{ $i }}.color" aria-label="Color">@foreach ($colors as $c)<option value="{{ $c }}">{{ $c }}</option>@endforeach</select></span>
                <input type="text" wire:model="rows.{{ $i }}.name" placeholder="Cebu hub" aria-label="Name">
                <select wire:model.live="rows.{{ $i }}.kind" aria-label="Kind">@foreach ($kinds as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                <select wire:model="rows.{{ $i }}.to" aria-label="Goes to">@foreach ($targets as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                @if ($r['kind'] === 'area')
                    <textarea wire:model="rows.{{ $i }}.provinces" rows="2" placeholder="Cebu, Bohol, Negros Oriental" aria-label="Provinces"></textarea>
                @else
                    <small class="ds-ws__muted">{{ $r['kind'] === 'check' ? 'Boxes with no province, or a province no section has.' : 'Boxes coming back from the hubs.' }}</small>
                @endif
                <b class="num">{{ $r['id'] ? ($counts[$r['id']] ?? 0) : '—' }}</b>
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
            <p class="ds-ws__muted">Start with this off, for speed. Switch it on if boxes are often not where the system says.</p>
        </section>
        <section class="ds-board__panel ds-ws__box">
            <h3>How it works</h3>
            <p class="ds-ws__muted">At unload the Scan app shows the section for each box, from the receiver's province, and keeps a customer's boxes together ("box 2 of 3"). A box with no province, or a province no section has, goes to <b>Check address</b>. Boxes for another warehouse can go straight onto a waiting truck.</p>
        </section>
    </div>
    <div><x-filament::button type="submit">Save</x-filament::button></div>
</form>
</x-filament-panels::page>
