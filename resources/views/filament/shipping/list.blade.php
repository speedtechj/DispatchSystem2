<x-filament-panels::page>
<div class="ds-sp">
    @if (! $incoming)
        <form wire:submit="create" class="ds-board__panel ds-sp__new">
            <h3>New sea shipment</h3>
            <p class="ds-board__muted">Make the trip to the port first, as a normal trip to the partner hub (Delivery Log), and put the boxes on it. Then pick it here.</p>
            <div class="ds-sp__newrow">
                <select wire:model="tripId" aria-label="Trip to the port">
                    <option value="">Trip to the port…</option>
                    @foreach ($trips as $t)<option value="{{ $t->id }}">Trip {{ $t->trip_number }} → {{ $t->destination?->hub_name }}{{ $t->truck ? ' · '.$t->truck->plate_no : '' }}</option>@endforeach
                </select>
                <select wire:model.live="mode" aria-label="How it is shipped">@foreach ($modes as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                @if ($mode !== 'roro')
                    <select wire:model="portCheck" aria-label="Port check">@foreach ($checks as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                @endif
                <x-filament::button type="submit">Make shipment</x-filament::button>
            </div>
            @error('tripId')<p class="ds-sp__err">{{ $message }}</p>@enderror
            @if ($trips->isEmpty())<p class="ds-board__muted">No open trip to a partner hub yet.</p>@endif
        </form>
    @endif

    <div class="ds-sp__filter">
        <button type="button" wire:click="$set('show', 'open')" @class(['is-on' => $show === 'open'])>On the way</button>
        <button type="button" wire:click="$set('show', 'all')" @class(['is-on' => $show === 'all'])>All · {{ $done }} received</button>
    </div>

    <section class="ds-sp__list">
        @forelse ($list as $r)
            @php($s = $r['s'])
            <a href="{{ $r['url'] }}" class="ds-board__panel ds-sp__item" wire:key="sh-{{ $s->id }}">
                <span class="ds-sp__icon" aria-hidden="true">{{ $s->mode === 'roro' ? '⛴️' : '🚢' }}</span>
                <span class="ds-sp__main">
                    <b>{{ $s->code }} → {{ $s->hub?->hub_name }}</b>
                    <small>Trip {{ $s->trip?->trip_number }}{{ $s->van_no ? ' · van '.$s->van_no : '' }}{{ $s->vessel ? ' · '.$s->vessel : '' }}{{ $s->eta ? ' · ETA '.$s->eta->format('M j') : '' }}</small>
                    <span class="ds-sp__bar">@foreach ($r['steps'] as $i => $k)<i @class(['is-done' => array_search($s->status, $r['steps']) > $i, 'is-now' => $s->status === $k])></i>@endforeach</span>
                </span>
                <span class="ds-sp__nums"><b class="num">{{ $r['counts']['loaded'] }}</b><small>boxes</small></span>
                <span class="ds-sp__state is-{{ $s->status }}">{{ $r['label'] }}</span>
            </a>
        @empty
            <p class="ds-board__muted">{{ $incoming ? 'No sea shipments coming to your hub right now.' : 'No sea shipments yet.' }}</p>
        @endforelse
    </section>
</div>
</x-filament-panels::page>
