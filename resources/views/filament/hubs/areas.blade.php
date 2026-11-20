<x-filament-panels::page>
<div class="ds-fl ds-wc">
    <div class="ds-ad__top">
        <span class="ds-te__title"><small>Settings › Hub areas · active partner hubs</small><h1>Which hub delivers each place</h1><small>One owner per place, never two. The smallest place wins: barangay, then city, then province. Places with no hub are delivered direct by the warehouse.</small></span>
        @if ($setupUrl)<a href="{{ $setupUrl }}" class="ds-te__btn is-main">+ Add a hub</a>@endif
    </div>
    <div class="ds-ha__grid">
        <div class="ds-ad__col">
            @forelse ($hubs as $i => $c)
                @php($h = $c['hub'])
                @php($color = \App\Support\Hubs\HubAreas::color($h->id))
                <section class="ds-cb__card ds-wc__card" wire:key="h-{{ $h->id }}" style="--hub: {{ $color }}">
                    <span class="ds-wc__head">
                        <span class="ds-ha__name"><i></i><span><b>{{ $h->hub_name }}</b><small>{{ $h->hub_code }}{{ $h->province ? ' · in '.collect([$h->city, $h->province])->filter()->join(', ') : ' · location not set' }}</small></span></span>
                        <span class="ds-cb__pill is-muted">{{ $c['areas']->count() }} {{ Str::plural('place', $c['areas']->count()) }}</span>
                    </span>
                    <span class="ds-wc__chips">
                        @forelse ($c['areas'] as $a)
                            <span class="ds-wc__chip ds-ha__chip">{{ $a->label() }}<button type="button" wire:click="removeArea({{ $a->id }})" wire:confirm="Remove {{ $a->label() }} from {{ $h->hub_name }}? Its boxes go direct from the warehouse." aria-label="Remove {{ $a->label() }}">✕</button></span>
                        @empty
                            <small class="ds-te__hint">No places yet: its boxes go direct from the warehouse.</small>
                        @endforelse
                    </span>
                    <form wire:submit="addPlace({{ $h->id }})" class="ds-ha__add">
                        <input type="text" list="ha-provinces" wire:model="add.{{ $h->id }}.province" class="ds-te__input" placeholder="Province" aria-label="Province">
                        <input type="text" wire:model="add.{{ $h->id }}.city" class="ds-te__input" placeholder="City (empty = whole province)" aria-label="City">
                        <input type="text" wire:model="add.{{ $h->id }}.barangay" class="ds-te__input" placeholder="Barangay (optional)" aria-label="Barangay">
                        <button type="submit" class="ds-te__btn">Add</button>
                    </form>
                    @if ($conflict && $conflict['hub'] === $h->id)
                        <span class="ds-wc__conflict">
                            <b>{{ $conflict['label'] }} already belongs to {{ \App\Support\Hubs\HubAreas::name($conflict['owner']) }}</b>
                            <span>A place has one hub only. Move it to {{ $h->hub_name }}?</span>
                            <span class="ds-wc__btns"><button type="button" class="ds-te__btn is-main" wire:click="moveIt">Move to {{ $h->hub_name }}</button><button type="button" class="ds-te__btn ds-wc__ghost" wire:click="cancel">Cancel</button></span>
                        </span>
                    @endif
                </section>
            @empty
                <section class="ds-cb__card ds-wc__card"><b>No active partner hubs</b><small class="ds-te__hint">Add a hub first. Until a hub has places, every box goes direct from the warehouse.</small></section>
            @endforelse
            <datalist id="ha-provinces">@foreach ($provinces as $p)<option value="{{ $p }}">@endforeach</datalist>
        </div>
        <div class="ds-ad__col">
            @foreach ($split as $s)
                <section class="ds-cb__card ds-wc__card">
                    <span class="ds-wc__head"><span><b>{{ $s['city'] }}, {{ $s['province'] }}</b><small>Split city · {{ $s['known'] }} barangays seen</small></span><span class="ds-cb__pill is-warn">{{ $s['byHub']->count() + ($s['main'] ? 1 : 0) }} hubs</span></span>
                    @php($given = $s['byHub']->flatten()->count())
                    <span class="ds-ha__split"><i style="width: {{ max(4, 100 - round($given / max(1, $s['known']) * 100)) }}%; background: {{ $s['main'] ? \App\Support\Hubs\HubAreas::color($s['main']) : '#c3ccd4' }}"></i>@foreach ($s['byHub'] as $hid => $g)<i style="width: {{ round($g->count() / max(1, $s['known']) * 100) }}%; background: {{ \App\Support\Hubs\HubAreas::color((int) $hid) }}"></i>@endforeach</span>
                    <small>{{ $s['main'] ? \App\Support\Hubs\HubAreas::name($s['main']).' is the main hub: every barangay not listed below.' : 'No main hub: barangays not listed go direct.' }}</small>
                    @foreach ($s['byHub'] as $hid => $g)
                        <span class="ds-wc__towns"><b>Barangays for {{ \App\Support\Hubs\HubAreas::name((int) $hid) }}</b><span class="ds-wc__chips">@foreach ($g as $a)<span class="ds-wc__chip is-own">{{ $a->barangay }}</span>@endforeach</span></span>
                    @endforeach
                </section>
            @endforeach
            <section class="ds-cb__card ds-wc__card">
                <b class="ds-ad__h">How a box finds its hub</b>
                @foreach (['Barangay: if it is listed for a hub, that hub.', 'No barangay on the box: the barangay the AI filled in, or the one this receiver had before.', 'Still none: the city’s main hub, then the province’s hub.', 'No hub for the place: the warehouse delivers it direct.', 'Address too poor: Addresses to check (AI helps).'] as $n => $t)
                    <span class="ds-pt__how"><b>{{ $n + 1 }}</b><span>{{ $t }}</span></span>
                @endforeach
            </section>
        </div>
        <div class="ds-ad__col">
            @foreach ($orphans as $o)
                <section class="ds-ha__off">
                    <b>{{ $o['hub'] }} is off: {{ $o['places']->count() }} {{ Str::plural('place', $o['places']->count()) }} have no hub now</b>
                    <span>{{ $o['places']->map->label()->join(', ') }}. New boxes there go direct from the warehouse. Trips already going to {{ $o['hub'] }} finish as planned.</span>
                    <span class="ds-wc__btns">
                        <button type="button" class="ds-te__btn ds-ha__btnbad" wire:click="keepDirect({{ $o['id'] }})">Keep direct</button>
                        @foreach ($hubs->take(3) as $c)<button type="button" class="ds-te__btn ds-wc__ghost" wire:click="giveTo({{ $o['id'] }}, {{ $c['hub']->id }})" wire:confirm="Give these places to {{ $c['hub']->hub_name }}?">Give to {{ $c['hub']->hub_name }}</button>@endforeach
                    </span>
                </section>
            @endforeach
            <section class="ds-cb__card ds-wc__card">
                <span class="ds-wc__head"><b class="ds-ad__h">Requests from hubs</b><span @class(['ds-cb__pill', 'is-warn' => $requests->isNotEmpty(), 'is-muted' => $requests->isEmpty()])>{{ $requests->isEmpty() ? 'None waiting' : $requests->count().' waiting' }}</span></span>
                @foreach ($requests as $r)
                    <span class="ds-ha__req" wire:key="r-{{ $r->id }}">
                        <span class="ds-wc__head"><b>{{ $r->hub?->hub_name }} asks for {{ $r->label() }}</b><small>{{ $r->created_at->diffForHumans() }}</small></span>
                        <small>{{ $r->now_hub_id ? 'Now '.\App\Support\Hubs\HubAreas::name($r->now_hub_id) : 'No hub now' }}</small>
                        @if ($r->reason)<small>“{{ $r->reason }}”{{ $r->user ? ' · '.$r->user->first_name : '' }}</small>@endif
                        <span class="ds-wc__btns"><button type="button" class="ds-te__btn is-main" wire:click="decide({{ $r->id }}, true)">Approve</button><button type="button" class="ds-te__btn ds-wc__ghost" wire:click="decide({{ $r->id }}, false)">Refuse</button></span>
                    </span>
                @endforeach
                @foreach ($answered as $r)<small class="ds-te__hint">{{ $r->status === 'approved' ? '✓ Approved' : 'Refused' }}: {{ $r->label() }} → {{ $r->hub?->hub_name }}</small>@endforeach
                <small class="ds-te__hint">New boxes follow the change. Boxes already on a trip stay on it.</small>
            </section>
            <section class="ds-cb__card ds-wc__card">
                <b class="ds-ad__h">Check</b>
                <span class="ds-ha__ok">✓ No place has two hubs</span>
                @if ($split->isNotEmpty())<span class="ds-ha__ok">✓ Split cities: every barangay has one hub</span>@endif
                @if ($unclear)<span class="ds-ha__warn">{{ $unclear }} {{ Str::plural('box', $unclear) }} in a split city: barangay unclear → main hub, or Addresses to check</span>@endif
            </section>
            <section class="ds-cb__card ds-wc__card">
                <b class="ds-ad__h">Changes</b>
                @forelse ($log as $l)<small class="ds-te__hint">{{ \Illuminate\Support\Carbon::parse($l->created_at)->format('M j') }} · {{ $l->text }}</small>
                @empty<small class="ds-te__hint">No changes yet.</small>@endforelse
            </section>
        </div>
    </div>
</div>
</x-filament-panels::page>
