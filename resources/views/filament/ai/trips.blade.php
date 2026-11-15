<x-filament-panels::page>
<div class="ds-ai ds-ai-trips">
    @include('filament.ai.paused', ['paused' => $paused])

    @if (count($modes) > 1)
        <div class="ds-ai__seg">
            @foreach ($modes as $k => $l)
                <button type="button" wire:click="setMode('{{ $k }}')" @class(['is-on' => $mode === $k])>{{ $l }}</button>
            @endforeach
        </div>
    @endif

    @if ($created)
        <section class="ds-ai__card">
            <div class="ds-ai__made"><span>✓</span><span><b>{{ count($created) }} {{ str($word)->plural(count($created)) }} created</b><small>Boxes are on the trips. Load them with Load Truck or the Scan app, as usual.</small></span></div>
            @foreach ($created as $c)
                <div class="ds-ai__madeRow"><b>{{ $c['number'] }}</b><span>🚚 {{ $c['truck'] }}</span><span>{{ $c['places'] }}</span><b>{{ $c['boxes'] }} boxes</b>
                    @if ($c['skipped'])<small class="is-amber">{{ $c['skipped'] }} skipped (already on another trip)</small>@endif</div>
            @endforeach
            <div class="ds-ai__two"><x-filament::button color="gray" wire:click="startOver">Plan more {{ str($word)->plural() }}</x-filament::button></div>
        </section>
    @else
        <div class="ds-ai__card ds-ai__plan">
            <span class="ds-ai__badge">AI</span>
            <input type="text" wire:model="instruction" placeholder="Optional: e.g. only Cebu and Bohol, keep NBC 557 for tomorrow" maxlength="300" aria-label="Instructions for the AI">
            <label class="ds-ai__date"><span>Date</span><input type="date" wire:model="date"></label>
            <x-filament::button wire:click="suggest" wire:loading.attr="disabled" wire:target="suggest">
                <span wire:loading.remove wire:target="suggest">{{ $drafted ? 'Suggest again' : 'Suggest '.str($word)->plural() }}</span>
                <span wire:loading wire:target="suggest">Planning…</span>
            </x-filament::button>
        </div>

        <div class="ds-ai__split is-trips">
            <section class="ds-ai__card">
                <div class="ds-ai__card-head"><b>{{ $mode === 'hub' ? 'At your hub' : 'Waiting for a '.$word }}</b><small class="ds-board__muted">{{ number_format($ready) }} boxes @if ($bySpace && $readySpace != $ready)· {{ \App\Support\BoxSizes::fmt($readySpace) }} space @endif</small></div>
                <div class="ds-ai__two is-left">
                    @if ($prio)<i class="ds-ai__tag is-damaged">{{ $prio }} priority</i>@endif
                    @if ($retry)<i class="ds-ai__tag is-open">{{ $retry }} tried before</i>@endif
                    @if ($bigGroups)<i class="ds-ai__tag is-wet">{{ $bigGroups }} {{ str('receiver')->plural($bigGroups) }} with 5+ boxes</i>@endif
                </div>
                <div class="ds-ai__tree">
                    @forelse ($tree as $p)
                        <div><b>{{ $p['name'] }} <small>{{ $p['n'] }}</small></b>
                            @foreach ($p['cities'] as $c)
                                <span><b>{{ $c['name'] }} <small>{{ $c['n'] }}</small></b><small>{{ $c['brgys'] }}</small></span>
                            @endforeach
                        </div>
                    @empty
                        <p class="ds-ai__empty">No boxes are waiting.</p>
                    @endforelse
                </div>
                <small class="ds-board__muted">Free trucks{{ $bySpace ? ' (space)' : '' }}: {{ $trucks->map(fn ($t) => $t['plate'].' ('.$t['capacity'].($t['set'] ? '' : '?').')')->join(', ') ?: 'none' }}@if ($trucks->contains('set', false)) · ? = no capacity set, {{ \App\Support\Ai\TripPlanner::DEFAULT_CAPACITY }} is used @endif</small>
            </section>

            <section class="ds-ai__tripcol">
                @if ($error)<p class="ds-ai__err">{{ $error }}</p>@endif
                @if (! $drafted)
                    <div class="ds-ai__card ds-ai__empty">Press <b>Suggest {{ str($word)->plural() }}</b>. Boxes are grouped by province, city and barangay; priority and tried-before boxes go first; boxes for the same receiver always stay together.</div>
                @else
                    <div class="ds-ai__said"><span class="ds-ai__badge">{{ $usedAi ? 'AI' : '≡' }}</span><span><b>Draft · nothing created yet.</b> {{ $note }}</span></div>
                    <div class="ds-ai__trips">
                        @forelse ($tripsView as $t)
                            <div @class(['ds-ai__trip', 'is-over' => $t['over']]) wire:key="t-{{ $t['i'] }}-{{ $t['truck_id'] }}">
                                <div class="ds-ai__card-head"><b>{{ $t['title'] }}</b><button type="button" class="ds-ai__link" wire:click="removeTrip({{ $t['i'] }})">Remove</button></div>
                                <select class="ds-ai__select is-full" wire:change="setTruck({{ $t['i'] }}, $event.target.value)" aria-label="Truck">
                                    @foreach ($trucks as $tr)<option value="{{ $tr['id'] }}" @selected($tr['id'] === $t['truck_id'])>🚚 {{ $tr['plate'] }} · fits {{ $tr['capacity'] }}{{ $bySpace ? ' space' : '' }}</option>@endforeach
                                </select>
                                @if ($mode !== 'hub')
                                    <label class="ds-ai__dest"><span>{{ $mode === 'transfer' ? 'To warehouse' : 'Going to' }}</span>
                                        <select class="ds-ai__select" wire:change="setDest({{ $t['i'] }}, $event.target.value)">
                                            @foreach ($dests as $d)<option value="{{ $d['id'] }}" @selected($d['id'] === $t['dest'])>{{ $d['name'] }}</option>@endforeach
                                        </select>
                                    </label>
                                @endif
                                @if ($bySpace)
                                    <div class="ds-ai__fill"><span><b>{{ \App\Support\BoxSizes::fmt($t['space']) }} / {{ $t['capacity'] }}</b> space · {{ $t['boxes'] }} {{ str('box')->plural($t['boxes']) }}</span><span class="{{ $t['over'] ? 'is-red' : '' }}">{{ $t['over'] ? \App\Support\BoxSizes::fmt($t['space'] - $t['capacity']).' too much' : $t['pct'].'% full' }}</span></div>
                                @else
                                    <div class="ds-ai__fill"><span><b>{{ $t['boxes'] }}</b> {{ str('box')->plural($t['boxes']) }}</span><span class="{{ $t['over'] ? 'is-red' : '' }}">{{ $t['over'] ? ($t['boxes'] - $t['capacity']).' too many' : $t['pct'].'% full' }}</span></div>
                                @endif
                                <i class="ds-ai__meter"><s style="width: {{ $t['pct'] }}%" @class(['is-bad' => $t['over'], 'is-warn' => ! $t['over'] && $t['pct'] > 85])></s></i>
                                @if ($bySpace && $t['mix'])<small class="ds-board__muted">{{ $t['mix'] }}</small>@endif
                                <div class="ds-ai__two is-left">
                                    @if ($t['prio'])<i class="ds-ai__tag is-damaged">{{ $t['prio'] }} priority</i>@endif
                                    @if ($t['retry'])<i class="ds-ai__tag is-open">{{ $t['retry'] }} tried before</i>@endif
                                </div>
                                @foreach ($t['places'] as $pi => $p)
                                    <button type="button" class="ds-ai__place" wire:click="movePlace({{ $t['i'] }}, {{ $pi }})" title="Move to the next {{ $word }}">
                                        <span><b>{{ $p['barangay'] }}</b> {{ $p['city'] }}<small>{{ $p['receivers'] }} {{ str('receiver')->plural($p['receivers']) }}@if ($p['big'] && $p['big']['n'] >= 3) · {{ $p['big']['name'] }} {{ $p['big']['n'] }} together @endif</small></span>
                                        <span>{{ $p['n'] }}@if ($bySpace && $p['space'] != $p['n'])<small> · {{ \App\Support\BoxSizes::fmt($p['space']) }} sp</small>@endif ⇄</span>
                                    </button>
                                @endforeach
                                @if ($t['why'])<small class="ds-ai__why1">✦ {{ $t['why'] }}</small>@endif
                            </div>
                        @empty
                            <div class="ds-ai__card ds-ai__empty">{{ $note ?: 'No trips could be made.' }}</div>
                        @endforelse
                    </div>
                    @if ($waitingPlaces->isNotEmpty() && $tripsView->isNotEmpty())
                        <section class="ds-ai__card">
                            <div class="ds-ai__card-head"><b>Left for later</b><small class="ds-board__muted">Click to add to {{ $word }} 1, or press Suggest again</small></div>
                            <div class="ds-ai__two is-left">
                                @foreach ($waitingPlaces->take(40) as $w)
                                    <button type="button" class="ds-ai__chipbtn {{ $w['prio'] ? 'is-prio' : '' }}" wire:click="addPlace(@js($w['place']), 0)">{{ \Illuminate\Support\Str::afterLast($w['place'], ' › ') }} · {{ $w['n'] }}</button>
                                @endforeach
                            </div>
                        </section>
                    @endif
                    @if ($tripsView->isNotEmpty())
                        <div class="ds-ai__card ds-ai__foot">
                            <span>{{ $tripsView->count() }} {{ str($word)->plural($tripsView->count()) }} · {{ $tripsView->sum('boxes') }} of {{ $ready }} boxes @if ($bySpace) · {{ \App\Support\BoxSizes::fmt($tripsView->sum('space')) }} space used of {{ $tripsView->sum('capacity') }}@endif. Click a barangay to move it to the next {{ $word }}. Trip numbers are given when you press Create.</span>
                            <x-filament::button color="gray" wire:click="startOver">Start over</x-filament::button>
                            <x-filament::button wire:click="create" wire:confirm="Create {{ $tripsView->count() }} {{ str($word)->plural($tripsView->count()) }} for {{ $date }}?" wire:loading.attr="disabled">Create {{ $tripsView->count() }} {{ str($word)->plural($tripsView->count()) }}</x-filament::button>
                        </div>
                    @endif
                @endif
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
