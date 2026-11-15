<x-filament-panels::page>
<div class="ds-sp">
    @if (! $incoming)
        <div class="ds-sp__grid">
            <section class="ds-board__panel ds-sp__box">
                <h3>Trip to the port</h3>
                <label class="ds-sp__search"><span aria-hidden="true">🔍</span><input type="text" wire:model.live.debounce.300ms="tripSearch" placeholder="Search trip no., hub, truck or port" aria-label="Search trips">@if ($tripSearch !== '')<button type="button" wire:click="$set('tripSearch', '')" aria-label="Clear">✕</button>@endif</label>
                <div class="ds-sp__filter">
                    @foreach (['' => 'All', 'visayas' => 'Visayas', 'mindanao' => 'Mindanao'] + ($allTrips ? ['luzon' => 'Luzon'] : []) as $k => $l)
                        <button type="button" wire:click="$set('island', '{{ $k }}')" @class(['is-on' => $island === $k])>{{ $l }}</button>
                    @endforeach
                </div>
                <small class="ds-board__muted">{{ $tripSearch !== '' || $island ? $shownCount.' of '.$tripCount.' trips' : $tripCount.' '.str('trip')->plural($tripCount).' to hubs reached by sea' }}</small>
                @forelse ($groups as $isl => $rows)
                    <b class="ds-sp__group">{{ \App\Support\Shipping\Islands::ISLANDS[$isl] ?? $isl }}</b>
                    @foreach ($rows as $r)
                        <button type="button" wire:click="pickTrip({{ $r['t']->id }})" @class(['ds-sp__pick', 'is-on' => in_array($r['t']->id, $this->picked, true)]) wire:key="tp-{{ $r['t']->id }}">
                            <i aria-hidden="true"></i>
                            <span><b>Trip {{ $r['t']->trip_number }} → {{ $r['t']->destination?->hub_name }}</b><small>{{ $r['sub'] }}</small></span>
                            <em>{{ $r['boxes'] }} {{ str('box')->plural($r['boxes']) }}</em>
                        </button>
                    @endforeach
                @empty
                    <p class="ds-sp__none">{{ $tripSearch !== '' ? 'No trip matches "'.$tripSearch.'". Check the trip number, or the trip may go to a hub reached by truck.' : 'No open trip to a hub reached by sea. Make the trip first in Delivery Log.' }}</p>
                @endforelse
                @if ($hidden > 0)
                    <p class="ds-board__muted">{{ $hidden }} {{ str('trip')->plural($hidden) }} to hubs reached by truck {{ $hidden === 1 ? 'is' : 'are' }} not listed · <button type="button" class="ds-fu__link" wire:click="$set('allTrips', true)">show them anyway</button></p>
                @elseif ($allTrips)
                    <p class="ds-board__muted"><button type="button" class="ds-fu__link" wire:click="$set('allTrips', false)">Only trips to hubs reached by sea</button> · set in Settings → Hubs · island & sea</p>
                @endif
            </section>
            <form wire:submit="create" class="ds-board__panel ds-sp__box">
                <h3>New sea shipment</h3>
                @if (count($pickedRows) > 1)
                    <p class="ds-board__muted">One container for {{ count($pickedRows) }} hubs · {{ collect($pickedRows)->sum('boxes') }} boxes. The first unloads first (load it near the door).</p>
                    @foreach ($pickedRows as $i => $pr)
                        <span class="ds-sp__stop" wire:key="pr-{{ $pr['t']->id }}">
                            <b class="ds-sp__stopn">{{ $i + 1 }}</b>
                            <span><b>{{ $pr['t']->destination?->hub_name }}</b> · trip {{ $pr['t']->trip_number }}<small>{{ $pr['boxes'] }} boxes · {{ $pr['port'] ?: 'port not set' }} · {{ $i === 0 ? 'unloads first, near the door' : ($i === count($pickedRows) - 1 ? 'unloads last, deep inside' : 'in the middle') }}</small></span>
                            @if ($i > 0)<button type="button" class="ds-fu__link" wire:click="moveFirst({{ $pr['t']->id }})">Unloads first</button>@endif
                        </span>
                    @endforeach
                    @if ($clash)<p class="ds-sp__err">Different ports: {{ implode(' and ', $clash) }}. One container goes to one port: make a shipment for each.</p>@endif
                @elseif ($pickedRow)
                    <dl class="ds-sp__dl">
                        <dt>Goes to</dt><dd><b>{{ $pickedRow['t']->destination?->hub_name }}</b></dd>
                        <dt>Island</dt><dd>{{ \App\Support\Shipping\Islands::ISLANDS[$pickedRow['island']] ?? '' }}</dd>
                        <dt>Usual port</dt><dd>{{ $pickedRow['port'] ?: '—' }}</dd>
                        <dt>Boxes on the trip</dt><dd>{{ $pickedRow['boxes'] }}</dd>
                    </dl>
                    <p class="ds-board__muted">More hubs in the same container? Tick their trips too.</p>
                @else
                    <p class="ds-board__muted">Pick the trip to the port on the left.</p>
                @endif
                <label class="ds-sp__lbl"><span>How it's shipped</span><select wire:model.live="mode">@foreach ($modes as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                @if ($mode !== 'roro')
                    <label class="ds-sp__lbl"><span>Port check</span><select wire:model="portCheck">@foreach ($checks as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select></label>
                @endif
                @error('tripId')<p class="ds-sp__err">{{ $message }}</p>@enderror
                <x-filament::button type="submit" :disabled="! $pickedRow || $clash">{{ count($pickedRows) > 1 ? 'Make 1 shipment · '.count($pickedRows).' hubs' : 'Make shipment' }}</x-filament::button>
                <p class="ds-board__muted">Make the trip first in Delivery Log, as a normal trip to the partner hub, and put the boxes on it.</p>
            </form>
        </div>
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
