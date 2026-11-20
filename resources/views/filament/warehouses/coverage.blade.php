<x-filament-panels::page>
<div class="ds-fl ds-wc">
    <span class="ds-te__title"><small>Settings › Warehouse coverage</small><h1>Which warehouse delivers each province</h1><small>Each province belongs to one warehouse. Boxes unloaded at the other warehouse are transferred, at most once.</small></span>
    <div class="ds-wc__grid">
        @foreach ($warehouses as $c)
            @php($w = $c['w'])
            <section class="ds-cb__card ds-wc__card" wire:key="w-{{ $w->id }}">
                <span class="ds-wc__head">
                    <span><b>{{ $w->name }}</b><small>{{ $c['default'] ? 'Main · gets every province not listed elsewhere' : $c['provinces']->count().' '.Str::plural('province', $c['provinces']->count()).($w->city ? ' · '.$w->city : '') }}</small></span>
                    @if ($c['default'])<span class="ds-cb__pill is-info">Default</span>
                    @else<span class="ds-cb__pill is-warn">{{ $c['provinces']->count() }} {{ Str::plural('province', $c['provinces']->count()) }}</span>@endif
                </span>
                <span class="ds-wc__chips">
                    @foreach ($c['provinces'] as $p)
                        <span @class(['ds-wc__chip', 'is-own' => ! $c['default']])>{{ $p->province }}@if ($c['edit'])<button type="button" wire:click="remove({{ $p->id }})" wire:confirm="Remove {{ $p->province }} from {{ $w->name }}?" aria-label="Remove {{ $p->province }}">✕</button>@endif</span>
                    @endforeach
                    @foreach ($c['rest'] as $p)<span class="ds-wc__chip">{{ $p }}</span>@endforeach
                    @if ($c['restMore'])<span class="ds-wc__chip">+ {{ $c['restMore'] }} more</span>@endif
                    @if (! $c['default'] && $c['provinces']->isEmpty())<small class="ds-te__hint">No provinces yet: add the ones this warehouse delivers.</small>@endif
                </span>
                @if ($c['edit'])
                    <span class="ds-wc__add">
                        @foreach ($c['suggest'] as $s)<button type="button" class="ds-wc__plus" wire:click="addProvince({{ $w->id }}, @js($s))">+ {{ $s }}</button>@endforeach
                        <form wire:submit="addProvince({{ $w->id }})" class="ds-wc__form"><input type="text" list="provinces" wire:model="newProvince.{{ $w->id }}" class="ds-te__input" placeholder="Add a province…"><button type="submit" class="ds-te__btn">Add</button></form>
                    </span>
                @endif
                <span class="ds-wc__towns">
                    <b>Town exceptions</b>
                    @forelse ($c['towns'] as $t)
                        <span><span>{{ $t->city }}, {{ $t->province }}</span><span class="ds-te__hint">→ {{ $w->name }}@if ($c['edit']) <button type="button" class="ds-te__link is-bad" wire:click="remove({{ $t->id }})">✕</button>@endif</span></span>
                    @empty
                        <span class="ds-te__hint">None yet</span>
                    @endforelse
                    @if ($c['edit'])<form wire:submit="addTown({{ $w->id }})" class="ds-wc__form"><input type="text" wire:model="newTown.{{ $w->id }}" class="ds-te__input" placeholder="Town, Province → {{ $w->name }}"><button type="submit" class="ds-te__btn">Add</button></form>@endif
                </span>
                @if ($admin && ! $c['default'])<button type="button" class="ds-te__link" wire:click="makeDefault({{ $w->id }})" wire:confirm="Make {{ $w->name }} the default warehouse (gets every province not listed elsewhere)?">Make this the default warehouse</button>@endif
            </section>
        @endforeach
        <div class="ds-wc__side">
            @if ($conflict)
                <section class="ds-wc__conflict">
                    <b>{{ $conflict['province'] }} belongs to {{ \App\Support\Warehouses\Coverage::name($conflict['owner']) }}</b>
                    <span>A province has one warehouse only. {{ $admin ? 'Move '.$conflict['province'].' to '.\App\Support\Warehouses\Coverage::name($conflict['warehouse']).'?' : 'Ask the admin to move '.$conflict['province'].' to '.\App\Support\Warehouses\Coverage::name($conflict['warehouse']).'?' }}</span>
                    <span class="ds-wc__btns"><button type="button" class="ds-te__btn is-main" wire:click="resolveConflict">{{ $admin ? 'Move it' : 'Ask to move' }}</button><button type="button" class="ds-te__btn ds-wc__ghost" wire:click="cancelConflict">Cancel</button></span>
                </section>
            @endif
            @foreach ($myRequests as $p)<span class="ds-wc__asked">⏳ Asked the admin to move {{ $p }}. Until then the other warehouse keeps it.</span>@endforeach
            @if ($admin && $requests->isNotEmpty())
                <section class="ds-cb__card ds-wc__card">
                    <b class="ds-ad__h">Requests</b>
                    @foreach ($requests as $r)
                        <span class="ds-wc__req"><span><b>{{ $r->warehouse?->name }}</b> asks for <b>{{ $r->province }}</b><small>now {{ $r->fromWarehouse?->name }} · {{ $r->user?->first_name }} · {{ $r->created_at->format('M j') }}</small></span>
                            <span class="ds-wc__btns"><button type="button" class="ds-te__btn is-main ds-ad__sm" wire:click="decide({{ $r->id }}, true)">Move it</button><button type="button" class="ds-te__btn ds-ad__sm" wire:click="decide({{ $r->id }}, false)">Refuse</button></span></span>
                    @endforeach
                </section>
            @endif
            <section class="ds-cb__card ds-wc__card">
                <b class="ds-ad__h">Check</b>
                <span class="ds-wc__ok">✓ No province in two warehouses</span>
                <span class="ds-wc__ok">✓ Every province has a home ({{ \App\Support\Warehouses\Coverage::name(\App\Support\Warehouses\Coverage::defaultId()) ?: 'the default warehouse' }} takes the rest)</span>
                <span class="ds-wc__info">{{ $active ? 'In use: unloading, transfers and Plan trips follow this list.' : 'Not in use yet: add a province to a warehouse to start.' }} Partner hubs (Cebu, Davao…) still get their boxes by sea as today.</span>
            </section>
            <section class="ds-cb__card ds-wc__card">
                <b class="ds-ad__h">Changes</b>
                @forelse ($log as $l)<small class="ds-te__hint">{{ \Illuminate\Support\Carbon::parse($l->created_at)->format('M j') }} · {{ $users[$l->user_id] ?? 'System' }} · {{ $l->text }}</small>
                @empty<small class="ds-te__hint">No changes yet.</small>@endforelse
            </section>
        </div>
    </div>
    <datalist id="provinces">@foreach ($known as $k)<option value="{{ $k }}">@endforeach</datalist>
</div>
</x-filament-panels::page>
