<x-filament-panels::page>
<div class="ds-cr">
    <div class="ds-cr__top">
        <span class="ds-cr__sum">{{ $activeCount }} active crew · {{ count($trucks) }} {{ \Illuminate\Support\Str::plural('truck', count($trucks)) }} · {{ $hubName }}</span>
        <span class="ds-cr__tabs">
            <button type="button" wire:click="setTab('trucks')" @class(['is-on' => $tab === 'trucks'])>Trucks</button>
            <button type="button" wire:click="setTab('people')" @class(['is-on' => $tab === 'people'])>People</button>
        </span>
        {{ $this->newCrewAction }}
    </div>

    @if ($tab === 'trucks')
        <div class="ds-cr__grid">
            @forelse ($trucks as $t)
                <section class="ds-cr__truck" wire:key="t-{{ $t['id'] }}">
                    <header><span class="ds-cr__ico">🚚</span><span><b>{{ $t['plate'] }}</b><small>{{ $t['sub'] }}</small></span>
                        <i @class(['ds-cr__state', 'is-ok' => $t['state'] === 'ready'])>{{ ['ready' => 'Ready', 'nodriver' => 'No driver', 'empty' => 'No crew'][$t['state']] }}</i></header>
                    @foreach ($t['crew'] as $m)
                        <div class="ds-cr__m" wire:key="m-{{ $t['id'] }}-{{ $m['id'] }}">
                            @include('filament.people.crew-avatar', ['m' => $m])
                            <button type="button" class="ds-cr__who" wire:click="mountAction('editCrew', { id: {{ $m['id'] }} })"><b>{{ $m['name'] }}</b><small>{{ $m['pos'] }}{{ $m['mobile'] ? ' · '.$m['mobile'] : '' }}</small></button>
                            <button type="button" class="ds-cr__x" title="Take off this truck" wire:click="removeFromTruck({{ $t['id'] }}, {{ $m['id'] }})">✕</button>
                        </div>
                    @endforeach
                    @if (! $t['crew'])
                        <span class="ds-cr__none">No crew yet · it cannot take a trip</span>
                    @endif
                    <button type="button" @class(['ds-cr__add', 'is-on' => $picking === $t['id']]) wire:click="togglePick({{ $t['id'] }})">{{ $picking === $t['id'] ? 'Done' : '＋ Add crew to this truck' }}</button>
                    @if ($picking === $t['id'])
                        <div class="ds-cr__free">
                            <small>Free crew at {{ $hubName }} · tap to add</small>
                            @forelse ($free as $f)
                                <button type="button" wire:click="addToTruck({{ $t['id'] }}, {{ $f['id'] }})" wire:key="f-{{ $t['id'] }}-{{ $f['id'] }}">@include('filament.people.crew-avatar', ['m' => $f, 'small' => true])<b>{{ $f['name'] }}</b><i>{{ $f['pos'] }}</i></button>
                            @empty
                                <small class="ds-cr__muted">Everyone is on a truck. Add a new crew member first.</small>
                            @endforelse
                        </div>
                    @endif
                </section>
            @empty
                <p class="ds-cr__muted">No trucks at {{ $hubName }} yet.</p>
            @endforelse
        </div>
        <p class="ds-cr__muted">A truck needs someone who uses the Driver app to take a trip. One person is on one truck at a time; taking them off a truck keeps them in People.</p>
    @else
        <section class="ds-cr__list">
            <div class="ds-cr__row is-head"><span></span><span>Name</span><span>Position</span><span>Mobile</span><span>Truck</span><span>Status</span><span>Driver app</span></div>
            @forelse ($people as $p)
                <button type="button" @class(['ds-cr__row', 'is-off' => ! $p['active']]) wire:click="mountAction('editCrew', { id: {{ $p['id'] }} })" wire:key="p-{{ $p['id'] }}">
                    @include('filament.people.crew-avatar', ['m' => $p])
                    <b>{{ $p['name'] }}</b>
                    <span><i @class(['ds-cr__pos', 'is-app' => $p['app']])>{{ $p['pos'] }}</i></span>
                    <span>{{ $p['mobile'] }}</span>
                    <span @class(['ds-cr__muted' => ! $p['truck']])>{{ $p['truck'] ?? ($p['active'] ? 'No truck' : '—') }}</span>
                    <span @class(['ds-us__status', 'is-off' => ! $p['active']])><i></i>{{ $p['active'] ? 'Active' : 'Turned off' }}</span>
                    <small>{{ $p['seen'] }}</small>
                </button>
            @empty
                <p class="ds-cr__muted" style="padding: 1rem">No crew yet. Press New crew member.</p>
            @endforelse
        </section>
        <p class="ds-cr__muted">Tap a person to edit. Turned-off crew stay here with their history.</p>
    @endif
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
