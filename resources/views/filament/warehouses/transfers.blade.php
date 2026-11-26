<x-filament-panels::page>
@php
    $spark = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3l1.8 4.6L18 9l-4.2 1.4L12 15l-1.8-4.6L6 9l4.2-1.4z"/><path d="M19 15l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z"/></svg>';
    $fmt = fn ($v) => \App\Support\BoxSizes::fmt($v);
@endphp
<div class="ds-fl ds-tx">
    <div class="ds-ad__top">
        <span class="ds-te__title"><h1>Transfers to warehouses</h1><small>Boxes here that another warehouse delivers · from {{ $hereName }}{{ (int) $here === (int) $mainId ? ' (main)' : '' }}</small></span>
        <span class="ds-tx__tools">
            @if ($canSwitch && $warehouses->count() > 1)
                <small>You are at</small>
                <span class="ds-fl__seg">@foreach ($warehouses as $w)<button type="button" wire:click="setHere({{ $w->id }})" @class(['is-on' => (int) $here === $w->id])>{{ $w->name }}{{ $w->id === (int) $mainId ? ' (main)' : '' }}</button>@endforeach</span>
            @endif
            <input type="date" wire:model.live="date" class="ds-wc__sel" aria-label="Leaves on">
            @if ($dv === null)
                <button type="button" class="ds-tx__ask" wire:click="askAi" @disabled($groups->isEmpty())>{!! $spark !!}<span wire:loading.remove wire:target="askAi">Ask the AI</span><span wire:loading wire:target="askAi">Thinking…</span></button>
            @else
                <button type="button" class="ds-tx__ask is-back" wire:click="manual">Back to the manual list</button>
            @endif
        </span>
    </div>
    @unless ($active)
        <span class="ds-ad__pending"><span>Set which warehouse delivers each province first (Settings → Warehouse coverage).</span></span>
    @endunless

    @if ($dv === null)
        <span class="ds-tx__note"><b>Manual, like before.</b><span>One truck per warehouse. The space bar tells you if the boxes fit. It only warns: you can still create.</span></span>
        @foreach ($made as $dest => $num)
            <span class="ds-pt__made">✓ Transfer {{ $num }} to {{ \App\Support\Warehouses\Coverage::name((int) $dest) }} created. Load it with “Load transfer truck”.</span>
        @endforeach
        <div class="ds-tx__grid">
            @foreach ($groups as $g)
                @php $over = $g['space'] > $g['cap']; $pct = $g['cap'] ? min(100, round($g['space'] * 100 / $g['cap'])) : 100; @endphp
                <section class="ds-cb__card ds-tx__card" wire:key="g-{{ $g['dest'] }}">
                    <span class="ds-tx__head"><b>To {{ $g['name'] }}</b><b>{{ $g['total'] }} {{ Str::plural('box', $g['total']) }} · {{ $g['receivers'] }} {{ Str::plural('receiver', $g['receivers']) }}</b></span>
                    @foreach ($g['rows'] as $r)
                        <span class="ds-tx__row"><span>{{ $r['name'] }}</span><small>{{ $r['n'] }} {{ Str::plural('box', $r['n']) }} · oldest {{ $r['days'] ? $r['days'].' '.Str::plural('day', $r['days']) : 'today' }}</small></span>
                    @endforeach
                    <small class="ds-tx__lbl">Truck</small>
                    <span class="ds-sv__chips">
                        @forelse ($trucks as $t)
                            <button type="button" wire:click="pickTruck({{ $g['dest'] }}, {{ $t['id'] }})" @class(['is-on' => $g['truckId'] === $t['id']])>{{ $t['plate'] }} · {{ $t['capacity'] }}</button>
                        @empty
                            <small class="ds-tx__bad">No free truck. Release a truck from a finished trip first.</small>
                        @endforelse
                    </span>
                    @if ($trucks->isNotEmpty())
                        <span class="ds-tx__space"><span>Space {{ $fmt($g['space']) }} of {{ $g['cap'] }}</span><b @class(['ds-tx__bad' => $over, 'ds-tx__ok' => ! $over])>{{ $over ? 'Too full · '.$fmt($g['space'] - $g['cap']).' over' : 'Fits' }}</b></span>
                        <span class="ds-sv__tbar"><i style="width: {{ $pct }}%; background: {{ $over ? '#c8372d' : '#17895e' }}"></i></span>
                        <small @class(['ds-tx__bad' => $over, 'ds-tx__ok' => ! $over])>{{ $over ? 'Pick a bigger truck, or press Ask the AI to split it into more trucks. You can still create.' : 'Room left: '.$fmt($g['cap'] - $g['space']).'.' }}</small>
                    @endif
                    <button type="button" wire:click="create({{ $g['dest'] }})" @class(['ds-tx__go', 'is-warn' => $over]) @disabled($trucks->isEmpty())>{{ $over ? 'Create anyway' : 'Create' }}</button>
                </section>
            @endforeach
            <section class="ds-tx__only">
                <b>{{ $groups->isEmpty() ? ($active ? 'No boxes here belong to another warehouse' : 'Nothing yet') : 'Only your warehouses show here' }}</b>
                <span>You have {{ $warehouses->count() }}: {{ $warehouses->map(fn ($w) => $w->name.($w->id === (int) $mainId ? ' (main)' : ''))->join(', ', ' and ') }}. A new warehouse in Settings shows up here by itself.</span>
            </section>
        </div>
    @else
        <span class="ds-tx__ai">{!! $spark !!}<span><b>{{ $dv['ai'] ? 'AI draft:' : 'Draft:' }}</b> {{ $dv['note'] }}</span><small>Nothing is created until you press Create.</small></span>
        <div class="ds-tx__grid">
            @foreach ($dv['cards'] as $t)
                @php $over = $t['load'] > $t['cap']; $pct = $t['cap'] ? min(100, round($t['load'] * 100 / $t['cap'])) : 100; @endphp
                <section class="ds-cb__card ds-tx__card" wire:key="d-{{ $t['i'] }}">
                    <span class="ds-tx__head"><b>{{ $t['title'] }}</b>
                        <span @class(['ds-tx__pill', 'is-made' => $t['made'], 'is-over' => ! $t['made'] && $over])>{{ $t['made'] ? 'Created · '.$t['made'] : ($over ? 'Too full' : 'Fits') }}</span></span>
                    <span class="ds-sv__chips">
                        @foreach ($trucks as $k)
                            @continue(in_array($k['id'], $t['taken']))
                            <button type="button" wire:click="pickDraftTruck({{ $t['i'] }}, {{ $k['id'] }})" @class(['is-on' => $t['truck_id'] === $k['id']]) @disabled($t['made'])>{{ $k['plate'] }} · {{ $k['capacity'] }}</button>
                        @endforeach
                    </span>
                    <span class="ds-tx__space"><span>Space {{ $fmt($t['load']) }} of {{ $t['cap'] }}</span><span>{{ $t['boxes'] }} {{ Str::plural('box', $t['boxes']) }} · {{ $t['receivers'] }} {{ Str::plural('receiver', $t['receivers']) }}</span></span>
                    <span class="ds-sv__tbar"><i style="width: {{ $pct }}%; background: {{ $over ? '#c8372d' : '#17895e' }}"></i></span>
                    @foreach ($t['rows'] as $r)
                        <span class="ds-tx__row"><span>{{ $r['name'] }}</span><small>{{ $r['n'] }}{{ $r['days'] ? ' · oldest '.$r['days'].' '.Str::plural('day', $r['days']) : '' }}{{ $r['prio'] ? ' · '.$r['prio'].' priority' : '' }}</small></span>
                    @endforeach
                    @if ($t['why'])<small class="ds-tx__why">Why: {{ $t['why'] }}</small>@endif
                    @if ($t['made'])
                        <button type="button" class="ds-tx__go is-made" disabled>Created ✓</button>
                    @elseif ($over)
                        <button type="button" class="ds-tx__go is-off" disabled>Pick a bigger truck</button>
                    @else
                        <button type="button" class="ds-tx__go" wire:click="createDraft({{ $t['i'] }})">Create this trip</button>
                    @endif
                </section>
            @endforeach
        </div>
        @php $allMade = collect($dv['trips'])->every(fn ($t) => $t['made']); @endphp
        <section class="ds-cb__card ds-tx__later">
            <b>{{ $dv['left'] ? 'Left for later · '.$dv['left'].' '.Str::plural('box', $dv['left']) : 'Nothing left over' }}</b>
            <small>{{ $dv['left'] ? 'No free truck has space left. They stay on this page for the next transfer.' : 'Every box going to another warehouse has a truck.' }}</small>
            @if ($dv['trips'])
                <button type="button" class="ds-tx__all" wire:click="createAllDraft" @disabled($allMade)>{{ $allMade ? 'All created ✓' : 'Create all that fit' }}</button>
            @endif
        </section>
        <small class="ds-tx__rules">The AI only groups the boxes and picks trucks. The rules stay in the system: one receiver's boxes are never split · a truck is never filled over its space (Trucks → Capacity, Settings → Box sizes) · priority and oldest first · only free trucks of your hub.</small>
    @endif

    @if ($onTheWay->isNotEmpty())
        <section class="ds-cb__card ds-ad__card">
            <b class="ds-ad__h">On the way</b>
            @foreach ($onTheWay as $x)<span class="ds-pt__un"><span>{{ $x['t']->trip_number }} → {{ $x['t']->warehouse?->name }}</span><b>{{ $x['left'] }} of {{ $x['n'] }} not received</b></span>@endforeach
        </section>
    @endif
</div>
</x-filament-panels::page>
