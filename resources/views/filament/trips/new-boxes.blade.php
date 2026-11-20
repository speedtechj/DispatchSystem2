<x-filament-panels::page>
<div class="ds-nb">
    <span class="ds-te__title"><h1>New boxes since the trips were made</h1><small>Boxes of cities that already have a trip. Space left → add (combos first, never split). Full → a new trip, or Add anyway (space is an estimate). Locked or on the road → a new trip.</small></span>

    @if (! $rows)
        <section class="ds-cb__card ds-nb__empty">
            <b>No new boxes for cities with a trip.</b>
            <small>Boxes of cities without a trip are planned in ✦ Plan trips.</small>
            @if ($planUrl)<a href="{{ $planUrl }}" class="ds-nt__plan">✦ Plan trips</a>@endif
        </section>
    @else
        <section class="ds-cb__card ds-nb__apply">
            <span><b>✦ {{ $total }} new {{ Str::plural('box', $total) }}: {{ $toAdd }} go on trips with space{{ $toNew ? ', '.$toNew.' on a new trip' : '' }}</b>
                <small>Combos (one receiver, or one set) always go together. Same rules in Admin, Warehouse and Partner hubs.</small></span>
            <button type="button" class="ds-nt__go" wire:click="applyAll" wire:loading.attr="disabled">Apply</button>
        </section>

        <section class="ds-cb__card ds-nb__list">
            <div class="ds-nb__row ds-nb__head"><span>City</span><span>New boxes</span><span>✦ The AI suggests</span><span></span></div>
            @foreach ($rows as $r)
                @php($t = $r['trip'])
                @php($pct = $t && ! empty($t['cap']) ? min(100, round($t['used'] / max(1, $t['cap']) * 100)) : 100)
                <div class="ds-nb__row" wire:key="nb-{{ $r['key'] }}">
                    <span class="ds-nb__city"><b>{{ $r['city'] }}</b><small>{{ $r['province'] }}</small></span>
                    <b class="ds-nb__n">{{ $r['n'] }}</b>
                    <span class="ds-nb__trip">
                        <span class="ds-nb__tline"><b>{{ $t['number'] ?? '—' }}</b>
                            <span @class(['ds-nb__pill', 'is-'.$r['kind']])>{{ ['open' => 'Space left', 'full' => 'Full', 'closed' => ($t['state'] ?? 'Locked')][$r['kind']] }}</span></span>
                        @if ($r['kind'] !== 'closed')
                            <span class="ds-nb__space"><span class="ds-tl__bar"><i style="width: {{ $pct }}%"></i></span><small>{{ $fmt($t['used']) }} of {{ $t['cap'] }}{{ $t['room'] > 0 ? ' · room for '.$fmt($t['room']) : ' · full' }}</small></span>
                        @else
                            <small class="ds-te__hint">No more boxes join a locked trip or one on the road.</small>
                        @endif
                    </span>
                    <span class="ds-nb__acts">
                        @if ($r['kind'] === 'open')
                            <button type="button" class="ds-nt__go ds-nb__btn" wire:click="openPick('{{ $r['key'] }}')">Add to {{ $t['number'] }}</button>
                        @elseif ($r['kind'] === 'full')
                            <button type="button" class="ds-nt__go ds-nb__btn" wire:click="newTrip('{{ $r['key'] }}')">New trip</button>
                            <button type="button" class="ds-nt__only ds-nb__btn is-anyway" wire:click="openPick('{{ $r['key'] }}', true)">Add anyway</button>
                        @else
                            <button type="button" class="ds-nt__only ds-nb__btn" wire:click="newTrip('{{ $r['key'] }}')">+ New trip for these</button>
                        @endif
                    </span>
                </div>
            @endforeach
        </section>
    @endif

    @if ($p)
        <div class="ds-nb__modal" wire:key="nb-pick">
            <section class="ds-cb__card ds-nb__pick">
                <span class="ds-nb__ph"><b>Add {{ $p['row']['city'] }} boxes to {{ $p['trip']['number'] }}</b><small>Combos first: a set or one receiver’s boxes go together, never split. Pick one box or many.</small></span>
                <span class="ds-nb__meter"><span class="ds-tl__bar"><i class="is-used" style="width: {{ $p['usedPct'] }}%"></i><i @class(['is-new', 'is-over' => $p['over']]) style="width: {{ $p['newPct'] }}%"></i></span>
                    <small @class(['is-over' => $p['over']])>{{ $p['trip']['number'] }}: {{ $fmt($p['trip']['used']) }} of {{ $p['trip']['cap'] }} + {{ $fmt($p['space']) }} picked = {{ $fmt($p['trip']['used'] + $p['space']) }} of {{ $p['trip']['cap'] }}{{ $p['over'] ? ' · '.$fmt($p['overBy']).' over' : ' · room for '.$fmt(max(0, $p['trip']['cap'] - $p['trip']['used'] - $p['space'])).' more' }}</small></span>
                <span class="ds-nb__items">
                    @foreach ($p['row']['combos'] as $c)
                        @php($on = ! empty($sel[$c['key']]))
                        <button type="button" wire:click="toggle('{{ $c['key'] }}')" @class(['ds-nb__item', 'is-on' => $on])>
                            <i class="ds-nb__check">{{ $on ? '✓' : '' }}</i>
                            <span><b>{{ $c['n'] >= 2 ? ($c['kind'] === 'set' ? 'Set' : 'Receiver').' · '.$c['name'] : 'Box '.($c['codes'][0] ?? '').' · '.$c['name'] }}</b>
                                <small>{{ $c['n'] >= 2 ? $c['n'].' boxes · '.implode(', ', array_slice($c['codes'], 0, 6)).(count($c['codes']) > 6 ? ' …' : '') : 'single box' }}{{ $c['barangay'] ? ' · '.$c['barangay'] : '' }}{{ $c['prio'] ? ' · ▲ priority' : '' }}</small></span>
                            <em @class(['ds-nb__tag', 'is-combo' => $c['n'] >= 2])>{{ $c['n'] >= 2 ? 'Combo · '.($c['kind'] === 'set' ? 'set' : 'receiver') : 'Single' }}</em>
                        </button>
                    @endforeach
                </span>
                @if ($p['over'])
                    <span class="ds-nb__warn">Over the space by {{ $fmt($p['overBy']) }}. Space is an estimate: Add anyway saves your name and a reason.
                        <select wire:model="reason" class="ds-te__input"><option value="">Why? (needed)</option>@foreach ($p['reasons'] as $why)<option value="{{ $why }}">{{ $why }}</option>@endforeach</select></span>
                @endif
                <span class="ds-nb__foot">
                    <span><button type="button" class="ds-nt__only ds-nb__btn" wire:click="pickFit">Pick what fits</button><button type="button" class="ds-te__link" wire:click="pickNone">Clear</button></span>
                    <span><button type="button" class="ds-nt__only ds-nb__btn" wire:click="closePick">Cancel</button>
                        <button type="button" @class(['ds-nt__go', 'ds-nb__btn', 'is-anyway' => $p['over']]) wire:click="confirmPick" @disabled($p['n'] === 0)>{{ $p['n'] === 0 ? 'Pick boxes' : ($p['over'] ? 'Add anyway · ' : 'Add ').$p['n'].' '.Str::plural('box', $p['n']) }}</button></span>
                </span>
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
