<x-filament-panels::page>
<div class="ds-pt">
    <header class="ds-pt__top">
        <span class="ds-pt__title">
            <span class="ds-pt__h"><span class="ds-pt__logo" aria-hidden="true">✦</span><h1>Plan trips</h1></span>
            @if ($atHub)
                <small>{{ $hubName }}: direct to customers in your area only. Your trucks, your trip numbers. The boxes at your hub go on the trip when you press Create.</small>
            @else
                <small>The AI makes trips by city: nearby cities of one province fill one truck. Create puts the waiting boxes on the trips. Boxes of a new container: New boxes (to a trip with room).</small>
            @endif
        </span>
        {{-- the day only matters when you press Create: switching it happens in the browser, no wait --}}
        <span class="ds-pt__days" x-data="{ day: $wire.entangle('day'), date: $wire.entangle('date') }">
            <span class="ds-fl__seg">
                @foreach (['today' => [__('Today'), today()->toDateString()], 'tomorrow' => [__('Tomorrow'), today()->addDay()->toDateString()], 'date' => [__('Pick a date'), null]] as $k => [$l, $d])
                    <button type="button" x-on:click="day = '{{ $k }}'{{ $d ? "; date = '".$d."'" : '' }}" :class="{ 'is-on': day === '{{ $k }}' }" @class(['is-on' => $day === $k])>{{ $l }}</button>
                @endforeach
            </span>
            <input type="date" x-show="day === 'date'" x-model="date" @style(['display: none' => $day !== 'date']) class="ds-te__input ds-pt__date" aria-label="Trip date">
        </span>
    </header>

    @if ($hubsOn)
        <nav class="ds-pt__tabs" role="tablist">
            <button type="button" role="tab" wire:click="setTab('direct')" @class(['is-on' => $tab === 'direct']) aria-selected="{{ $tab === 'direct' ? 'true' : 'false' }}">Direct to customers <span>{{ $directBoxes }}</span></button>
            <button type="button" role="tab" wire:click="setTab('hubs')" @class(['is-on' => $tab === 'hubs']) aria-selected="{{ $tab === 'hubs' ? 'true' : 'false' }}">To hubs <span>{{ count($hubPlan) }} {{ Str::plural('hub', count($hubPlan)) }} · {{ $hubBoxes }}</span></button>
        </nav>
    @endif

    @if ($tab === 'hubs' && $hubsOn)
        @include('filament.trips.plan-hubs')
    @else
    <section class="ds-cb__card ds-pt__ask">
        <span class="ds-pt__spark" aria-hidden="true">✦</span>
        <span class="ds-pt__asktext">
            <b>What matters today?</b>
            <span class="ds-pt__chips">
                @foreach (array_filter(['oldest' => 'Oldest boxes first', 'first' => $top ? $top.' first' : null, 'keep' => 'Keep a truck free', 'full' => 'Only full trucks']) as $k => $l)
                    <button type="button" wire:click="setAsk('{{ $k }}')" @class(['ds-pt__chip', 'is-on' => $ask === $k && $instruction === ''])>{{ $l }}</button>
                @endforeach
            </span>
        </span>
        <form wire:submit="askAi" class="ds-pt__type">
            <input type="text" wire:model="instruction" class="ds-te__input" placeholder="Or type it: “{{ $top ?? 'Bulacan' }} first, keep one truck”" @disabled(! $aiOn) title="{{ $aiOn ? '' : 'Switch on the AI trip helper in Settings → AI' }}">
        </form>
    </section>

    <div class="ds-pt__grid">
        <section class="ds-cb__card ds-pt__left">
            <span class="ds-pt__lhead"><b>{{ $atHub ? 'Arrived, by city' : 'Waiting, by city' }}</b><small>{{ number_format($waitTotal) }} boxes</small></span>
            @if ($notMine)<span class="ds-pt__transfer is-bad"><span>{{ $notMine }} {{ Str::plural('box', $notMine) }} here {{ $notMine === 1 ? 'belongs' : 'belong' }} to another hub’s area: not planned. Tell the office.</span></span>@endif
            <small class="ds-pt__muted">Click a province to see its cities</small>
            <span class="ds-pt__provs" x-data="{ open: $wire.entangle('open') }">
            @forelse ($provinces as $p)
                <span @class(['ds-pt__prov', 'is-planned' => $p['planned']]) wire:key="p-{{ $p['key'] }}">
                    <button type="button" class="ds-pt__provhead" x-on:click="open = open === @js($p['key']) ? '' : @js($p['key'])" :aria-expanded="open === @js($p['key'])"><b><span x-text="open === @js($p['key']) ? '▾' : '▸'">{{ $open === $p['key'] ? '▾' : '▸' }}</span> {{ $p['name'] }}</b><span>{{ $p['boxes'] }} boxes</span></button>
                    <span class="ds-pt__bar"><i style="width: {{ round($p['boxes'] / $max * 100) }}%" @class(['is-old' => $p['days'] >= 4, 'is-mid' => $p['days'] === 3])></i></span>
                    <span class="ds-pt__provfoot"><span>{{ $p['days'] ? 'Oldest '.$p['days'].' '.Str::plural('day', $p['days']) : 'Today' }}</span><b @class(['is-in' => $p['planned']])>{{ $p['trip'] ? 'On '.$p['trip'] : ($p['planned'] ? 'In a trip' : 'Not planned') }}</b></span>
                    <span class="ds-pt__cities" x-show="open === @js($p['key'])" @style(['display: none' => $open !== $p['key']])>
                            @foreach ($p['cities'] as $c)
                                <span><span>{{ $c['city'] }}@if (isset($covered[$c['key']])) <em>· {{ $covered[$c['key']] }}</em>@elseif (isset($draft[$c['key']])) <em>· in a trip</em>@endif</span><span class="ds-pt__muted">{{ $c['boxes'] }} · {{ $c['days'] ? $c['days'].' '.Str::plural('day', $c['days']) : 'today' }}</span></span>
                            @endforeach
                    </span>
                </span>
            @empty
                <p class="ds-cb__muted">No boxes are waiting for a trip.</p>
            @endforelse
            </span>
            @foreach ($transferOut as $t)
                <a href="{{ $trUrl }}" class="ds-pt__transfer"><span>{{ $t['n'] }} {{ Str::plural('box', $t['n']) }} → transfer to {{ $t['name'] }} (not planned here)</span><b>Open ›</b></a>
            @endforeach
            @if ($arriving)<span class="ds-pt__transfer"><span>{{ $arriving }} {{ Str::plural('box', $arriving) }} arriving on a transfer: planned when received</span></span>@endif
            @if ($unclear)
                @if ($addrUrl)<a href="{{ $addrUrl }}" class="ds-pt__unclear"><span>📍 {{ $unclear }} {{ Str::plural('box', $unclear) }}: city not clear</span><b>Addresses to check ›</b></a>
                @else<span class="ds-pt__unclear"><span>📍 {{ $unclear }} {{ Str::plural('box', $unclear) }}: city not clear</span></span>@endif
            @endif
            <small class="ds-pt__muted">No barangay is fine: the box goes by its city, the barangay only sets the stop order.</small>
        </section>

        <section class="ds-pt__mid">
            <span class="ds-pt__lhead"><b class="ds-pt__big">Suggested trips</b><small>{{ $ai ? '✦ ' : '' }}{{ $note }}</small></span>
            @if ($made)
                <span class="ds-pt__made">✓ {{ count($made) }} {{ Str::plural('trip', count($made)) }} created: {{ collect($made)->pluck('number')->join(', ') }}. Their boxes are on them (not loaded yet).</span>
            @endif
            @forelse ($cards as $t)
                <article @class(['ds-cb__card', 'ds-pt__trip', 'is-off' => ! $t['on'] && empty($t['madeAs']), 'is-made' => ! empty($t['madeAs'])]) wire:key="t-{{ $t['i'] }}-{{ $t['province'] }}">
                    <span class="ds-pt__trow">
                        <button type="button" role="switch" aria-checked="{{ $t['on'] ? 'true' : 'false' }}" aria-label="Include this trip" wire:click="toggleTrip({{ $t['i'] }})" @disabled(! empty($t['madeAs'])) @class(['ds-te__switch', 'ds-ad__smswitch', 'is-on' => $t['on'] && empty($t['madeAs'])])><i></i></button>
                        <span class="ds-pt__tname"><b>{{ $t['province'] }} <span>› {{ $t['path'] }}</span></b><small>{{ ! empty($t['madeAs']) ? 'Made · '.$t['madeAs']['number'] : ($t['on'] ? 'New trip · number given when you press Create' : 'Switched off: not in Create all') }}</small></span>
                        <button type="button" wire:click="cycleTruck({{ $t['i'] }})" @class(['ds-pt__truck', 'is-free' => $t['truck'] && $t['truck']['state'] === 'free', 'is-busy' => $t['truck'] && $t['truck']['state'] === 'busy'])>🚚 {{ $t['truck'] ? $t['truck']['plate'] : 'No truck yet' }}@if ($t['truck'] && $t['truck']['state'] === 'busy') · after {{ $t['truck']['on'] }}@endif <span>▾</span></button>
                    </span>
                    <span class="ds-pt__stops">
                        @foreach ($t['cities'] as $n => $c)
                            <span class="ds-pt__stop"><span class="ds-pt__dot"></span><small><b>{{ $c['city'] }}</b></small><small class="ds-pt__muted">{{ $c['boxes'] }} {{ Str::plural('box', $c['boxes']) }}</small></span>
                            @if (! $loop->last)<span class="ds-pt__line"></span>@endif
                        @endforeach
                    </span>
                    <span class="ds-pt__fillrow">
                        <span class="ds-pt__fill"><i style="width: {{ $t['pct'] }}%" @class(['is-full' => $t['pct'] >= 100])></i><span>About {{ $t['load'] }} of {{ $t['cap'] }} space{{ $t['pct'] >= 100 ? ' · full' : '' }}</span></span>
                        <span @class(['ds-pt__age', 'is-old' => $t['days'] >= 4, 'is-mid' => $t['days'] === 3])>{{ $t['days'] ? 'Oldest '.$t['days'].' '.Str::plural('day', $t['days']) : 'Today' }}</span>
                    </span>
                    <span class="ds-pt__why"><span aria-hidden="true">✦</span><span>{{ $t['why'] }}</span></span>
                    @if ($tops[$t['i']] ?? [])
                        @php($pick = $t['topPick'] ?? $tops[$t['i']][0]['key'])
                        <span class="ds-pt__top">
                            <b><span aria-hidden="true">✦</span> Room for {{ $t['cap'] - $t['load'] }} more · top up with</b>
                            @foreach ($tops[$t['i']] as $o)
                                <button type="button" wire:click="pickTop({{ $t['i'] }}, @js($o['key']))" @class(['ds-pt__topopt', 'is-on' => $pick === $o['key']])><i class="ds-te__radio"></i><span><b>{{ $o['city'] }}, {{ $o['province'] }}</b><small>{{ $o['same'] ? 'Same province' : 'Next province' }} · {{ $o['days'] ? $o['days'].' '.Str::plural('day', $o['days']).' old' : 'today' }}</small></span><span class="ds-cb__pill">{{ $o['boxes'] }} {{ Str::plural('box', $o['boxes']) }}</span></button>
                            @endforeach
                            <span class="ds-pt__topbtns"><button type="button" class="ds-te__btn is-main" wire:click="addTop({{ $t['i'] }})">Add to this trip</button><button type="button" class="ds-te__btn ds-wc__ghost" wire:click="skipTop({{ $t['i'] }})">No thanks</button></span>
                        </span>
                    @endif
                    @if (! empty($t['topped']))<small class="ds-pt__ok">✓ {{ $t['topped'] }}</small>@elseif (! empty($t['noTop']))<small class="ds-pt__muted">No top-up · {{ $t['cap'] - $t['load'] }} space stays free</small>@endif
                    @if ($t['on'])
                        <button type="button" wire:click="toggleSms({{ $t['i'] }})" @disabled(! $smsOn) @class(['ds-pt__sms', 'is-on' => $smsOn && ($t['sms'] ?? true)])><i>{{ $smsOn && ($t['sms'] ?? true) ? '✓' : '' }}</i>Send SMS for this trip <small>· {{ ! $smsOn ? 'off for all trips in SMS settings' : (($t['sms'] ?? true) ? 'receivers get a text when it is locked' : 'no text for this trip only') }}</small></button>
                    @endif
                    @if ($sets[$t['i']] ?? [])
                        <span class="ds-pt__sets">
                            <span class="ds-pt__lhead"><b>Kept together on this trip</b><small>customers with 2+ boxes</small></span>
                            @foreach ($sets[$t['i']] as $st)
                                <span class="ds-pt__set"><span><b>{{ $st['name'] }}</b> · {{ $st['city'] }}</span><span @class(['ds-cb__pill', 'is-own' => ! $st['missing'], 'is-warn' => $st['missing']])>{{ $st['missing'] ? $st['n'].' here · '.$st['missing'].' not unloaded yet' : $st['n'].' of '.$st['n'].' together' }}</span></span>
                            @endforeach
                        </span>
                    @endif
                    {{-- board 46: make only this trip; the others stay here --}}
                    @if (empty($t['madeAs']))
                        <span class="ds-pt__one"><button type="button" class="ds-nt__go" wire:click="createOne({{ $t['i'] }})" wire:loading.attr="disabled">Create this trip</button></span>
                    @else
                        <span class="ds-pt__one is-made"><span class="ds-pt__madeone">✓ {{ $t['madeAs']['number'] }} made · {{ $t['madeAs']['boxes'] }} {{ Str::plural('box', $t['madeAs']['boxes']) }} on it</span>
                            @if ($tripsPage)<a href="{{ $tripsPage::getUrl('index') }}" class="ds-te__link">Open in Delivery trips ›</a>@endif</span>
                    @endif
                </article>
            @empty
                <p class="ds-cb__card ds-cb__muted">Nothing to plan: every waiting city is already on a trip, or no boxes are waiting.</p>
            @endforelse
            <span class="ds-pt__sum">
                <span><b>{{ $leftTrips < count($cards) ? $leftTrips.' '.Str::plural('trip', $leftTrips).' not made yet · '.$onTrips->count().' switched on' : $onTrips->count().' '.Str::plural('trip', $onTrips->count()).' · about '.$onTrips->sum('load').' boxes' }}</b><small>Create this trip makes one · Create all makes every trip switched on · {{ $atHub ? 'Trip numbers with your hub code · the boxes go on the trip when you press Create' : 'Trip numbers and their boxes now (combos together)' }} · @if ($smsOn)SMS to receivers when the trip is locked{{ ($noSms = $onTrips->filter(fn ($t) => ! ($t['sms'] ?? true))->count()) ? ', except '.$noSms.' '.Str::plural('trip', $noSms) : '' }}@else No SMS (off in @if ($smsUrl)<a href="{{ $smsUrl }}" class="ds-pt__smslink">SMS settings ›</a>@else SMS settings @endif)@endif</small></span>
                @if ($changedAny && $needPlan === 'reason')
                    <select wire:model="planReason" class="ds-wc__sel" aria-label="Why did you change the AI plan?"><option value="">Why did you change the plan?</option>@foreach ($reasons as $r)<option value="{{ $r }}">{{ $r }}</option>@endforeach</select>
                @endif
                <button type="button" wire:click="create" wire:loading.attr="disabled" @disabled(! $onTrips->count())>{{ $made && ! $onTrips->count() ? '✓ Created' : 'Create all '.$onTrips->count().' switched on' }}</button>
            </span>
        </section>

        <aside class="ds-pt__side">
            <section class="ds-cb__card ds-pt__card">
                <b class="ds-pt__h3">Trucks</b>
                @forelse ($trucks as $k)
                    @php($st = $k['id'] === $kept ? 'kept' : $k['state'])
                    <span class="ds-pt__trk"><i class="is-{{ $st }}"></i><span><b>{{ $k['plate'] }}</b><small>{{ $st === 'kept' ? 'Kept free today' : $k['sub'] }}</small></span><small class="is-{{ $st }}">{{ $st === 'kept' ? 'Kept' : $k['label'] }}</small></span>
                @empty
                    <p class="ds-cb__muted">No trucks in this hub yet.</p>
                @endforelse
            </section>
            <section class="ds-pt__free">
                @if ($given)
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>{{ $given }}</b></span>
                    <span>Crew copied from the truck team. Load from the sections of its cities, oldest first.</span>
                @elseif ($freeTruck && $waitingTrips->isNotEmpty())
                    @php($w = $waitingTrips->first())
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>{{ $freeTruck['plate'] }} is free</b></span>
                    <span>Best next trip: {{ $w['province'] }} ({{ $w['trip']->trip_number }} · {{ $w['cities'] }}). {{ $w['days'] ? 'Its boxes are the oldest ('.$w['days'].' '.Str::plural('day', $w['days']).').' : '' }}</span>
                    <button type="button" class="ds-te__btn is-main" wire:click="give({{ $w['trip']->id }}, {{ $freeTruck['id'] }})">Give {{ $w['province'] }} to {{ $freeTruck['plate'] }}</button>
                @elseif ($waitingTrips->isNotEmpty())
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>{{ $waitingTrips->count() }} {{ Str::plural('trip', $waitingTrips->count()) }} wait for a truck</b></span>
                    <span>When a truck is free, it shows here with the most urgent trip to give it.</span>
                @elseif ($freeTruck)
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>{{ $freeTruck['plate'] }} is free</b></span>
                    <span>Create the trips: the most urgent one gets this truck.</span>
                @else
                    <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>No free truck right now</b></span>
                    <span>Trips without a truck wait; the next free truck gets the most urgent one.</span>
                @endif
            </section>
            <section class="ds-cb__card ds-pt__card">
                <b class="ds-pt__h3">How the top-up is picked</b>
                @foreach (['Same province first, then the next province.', 'Only cities that fit the room left.', 'Oldest and priority boxes first; whole customers only.', 'Never over the truck space; the reserve stays free.'] as $n => $h)
                    <span class="ds-pt__how"><b>{{ $n + 1 }}</b><span>{{ $h }}</span></span>
                @endforeach
            </section>
            @if (! $atHub)
            <section class="ds-cb__card ds-pt__card">
                <span class="ds-pt__lhead"><b class="ds-pt__h3">Unloading now</b><small>{{ $unload['container'] ?? 'Nothing today' }}</small></span>
                @foreach ($unload['rows'] as [$a, $b, $here])
                    <span class="ds-pt__un"><span>{{ $a }}</span><b @class(['is-here' => $here])>{{ $b }}</b></span>
                @endforeach
                <small class="ds-pt__muted">Boxes for a truck that is here go straight on it. The rest wait in their section.</small>
            </section>
            @endif
        </aside>
    </div>
    @endif
</div>
</x-filament-panels::page>
