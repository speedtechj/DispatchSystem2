<x-filament-panels::page>
<div class="ds-fl">
    <div class="ds-fl__top">
        <span class="ds-tk__month is-big"><button type="button" wire:click="shiftMonth(-1)" aria-label="Previous month">‹</button>{{ $monthLabel }}<button type="button" wire:click="shiftMonth(1)" aria-label="Next month">›</button></span>
        <span class="ds-fl__tools">
            <select class="ds-fl__search" wire:model.live="company" aria-label="Rental company">
                <option value="">All rental companies</option>
                @foreach ($companyOptions as $id => $name)<option value="{{ $id }}">{{ $name }}</option>@endforeach
            </select>
            <button type="button" class="ds-fl__add" wire:click="download">Download statement</button>
        </span>
    </div>
    <div class="ds-tk__tiles">
        @foreach ($kpis as [$label, $value, $sub])
            <span class="ds-cb__card"><small class="ds-cb__label">{{ $label }}</small><b class="ds-tk__big">{{ $value }}</b><small class="ds-cb__label">{{ $sub }}</small></span>
        @endforeach
    </div>
    <section class="ds-cb__card ds-tk__table is-rent">
        <span class="ds-tk__tr is-head"><span>Date</span><span>Trip</span><span>Truck</span><span>Charged</span><span>Boxes</span><span>Per box</span></span>
        @forelse ($rows as $r)
            <span class="ds-tk__tr"><span>{{ $r['date']->format('M j') }}</span><b>{{ $r['trip']->trip_number }}{{ $r['trip']->destination ? ' · '.$r['trip']->destination->hub_name : '' }}</b><span>{{ $r['plate'] }} · {{ $r['company'] }}</span><span>{{ $r['cost'] !== null ? '₱'.number_format($r['cost']).' '.($r['rate'] ?? '') : '—' }}</span><span>{{ $r['boxes'] }}</span><span @class(['is-bad' => $r['perBox'] && $r['perBox'] > 150])>{{ $r['perBox'] ? '₱'.number_format($r['perBox']) : '—' }}</span></span>
        @empty
            <p class="ds-cb__muted">No rental trips in {{ $monthLabel }}.</p>
        @endforelse
    </section>
    @if ($note)<section class="ds-fl__note is-warn ds-tk__ai">✦ {{ $note }}</section>@endif
    <section class="ds-cb__card ds-tk__narrow">
        <header><b>Rental companies</b><span class="ds-cb__count">{{ count($companies) }}</span></header>
        @foreach ($companies as $c)
            <span class="ds-cb__person"><span><b>{{ $c['c']->name }}</b><small>{{ collect([$c['c']->contact_name, $c['c']->phone])->filter()->join(' · ') ?: 'No contact yet' }} · {{ $c['trucks'] }} {{ str('truck')->plural($c['trucks']) }}</small></span></span>
        @endforeach
        <form wire:submit="addCompany" class="ds-tk__addco">
            <input type="text" wire:model="newName" placeholder="Company name" aria-label="Company name" required>
            <input type="text" wire:model="newContact" placeholder="Contact person" aria-label="Contact person">
            <input type="text" wire:model="newPhone" placeholder="Phone" aria-label="Phone">
            <button type="submit" class="ds-fl__add">Add</button>
        </form>
    </section>
</div>
</x-filament-panels::page>
