{{-- Plan trips › To hubs: one trip per partner hub (more when the boxes do not fit one truck). The hub delivers with its own trucks. --}}
@php($tips = collect($hubPlan)->reject(fn ($h) => ($hubState[$h['hub']] ?? null) || ! empty($h['open']))->take(3))
<section class="ds-ph__ai">
    <span class="ds-pt__spark" aria-hidden="true">✦</span>
    <span class="ds-ph__aitext">
        <b>Suggested for today</b>
        @forelse ($tips as $h)
            <span>• <b>{{ $h['name'] }}:</b> {{ $h['tip'] }}</span>
        @empty
            <span>Nothing waits for a hub right now.</span>
        @endforelse
    </span>
</section>
@if ($askDirect)
    <section class="ds-ph__why">
        @php([$ah, $ap, $ac] = array_pad(explode('|', $askDirect, 3), 3, ''))
        <b>{{ Str::title($ac) }} → direct instead of {{ \App\Support\Hubs\HubAreas::name((int) $ah) }}. Why? (the office sees this)</b>
        <span class="ds-ph__reasons">@foreach (\App\Support\Trips\TripRules::reasons() as $r)<button type="button" wire:click="directWith(@js($r))">{{ $r }}</button>@endforeach<button type="button" class="is-cancel" wire:click="cancelDirect">Cancel</button></span>
    </section>
@endif
<div class="ds-ph__grid">
    @forelse ($hubPlan as $n => $h)
        @php($state = $hubState[$h['hub']] ?? null)
        @php($when = $hubWhen[$h['hub']] ?? 'now')
        @php($multi = count($h['trips']) > 1)
        <section class="ds-cb__card ds-ph__card" wire:key="hub-{{ $h['hub'] }}" style="--hub: {{ \App\Support\Hubs\HubAreas::color($h['hub']) }}">
            <span class="ds-ph__head">
                <span><b>⌂ {{ $h['name'] }}</b><small>{{ $h['boxes'] }} {{ Str::plural('box', $h['boxes']) }} · {{ count($h['cities']) }} {{ Str::plural('city', count($h['cities'])) }}{{ $multi ? ' · '.count($h['trips']).' trips' : '' }}</small></span>
                <span @class(['ds-cb__pill', 'is-bad' => $h['days'] >= 4, 'is-warn' => $h['days'] === 3, 'is-muted' => $h['days'] < 3])>{{ $h['days'] ? 'Oldest '.$h['days'].' '.Str::plural('day', $h['days']) : 'Today' }}</span>
            </span>
            <span class="ds-ph__cities">
                @foreach (collect($h['cities'])->take(5) as $c)
                    <span><span><b>{{ $c['city'] }}</b> · {{ $c['boxes'] }} {{ Str::plural('box', $c['boxes']) }}{{ $c['prio'] ? ' · '.$c['prio'].' priority' : '' }}</span>
                        @if (! $state && empty($h['open']))<button type="button" wire:click="askDirectCity({{ $h['hub'] }}, @js($c['key']))">Deliver direct instead</button>@endif</span>
                @endforeach
                @if (count($h['cities']) > 5)<small class="ds-pt__muted">+ {{ count($h['cities']) - 5 }} more {{ Str::plural('city', count($h['cities']) - 5) }}</small>@endif
            </span>
            @if (! empty($h['open']))
                <span class="ds-ph__done is-made">On {{ implode(', ', $h['open']) }}: new boxes of the hub join it while it has room (New boxes).</span>
            @elseif ($multi)
                <span class="ds-fl__seg ds-ph__when">
                    <button type="button" wire:click="setWhen({{ $h['hub'] }}, 'now')" @class(['is-on' => $when === 'now'])>Both now</button>
                    <button type="button" wire:click="setWhen({{ $h['hub'] }}, 'later')" @class(['is-on' => $when === 'later'])>Trip 2{{ count($h['trips']) > 2 ? '+' : '' }} tomorrow</button>
                </span>
                @foreach ($h['trips'] as $ti => $t)
                    @php($later = $ti > 0 && $when === 'later')
                    <span class="ds-ph__part">
                        <span class="ds-ph__head"><b>Trip {{ $ti + 1 }}</b><span @class(['ds-cb__pill', 'is-own' => ! $later, 'is-warn' => $later])>{{ $later ? 'Tomorrow' : 'Now' }}</span></span>
                        <small>🚚 {{ $later ? 'next free truck' : ($t['plate'] ?? 'No truck yet') }} · {{ collect($t['cities'])->pluck('city')->unique()->join(', ') }}</small>
                        <span class="ds-ph__bar"><i style="width: {{ min(100, round($t['load'] / max(1, $t['cap']) * 100)) }}%">About {{ $t['load'] }} of {{ $t['cap'] }} space</i></span>
                        <small class="ds-pt__muted">✦ {{ $ti === 0 ? 'Priority, tried-before and oldest boxes first. Whole customers only.' : ($later ? 'Waits for a truck'.($h['coming'] ? ' and the next container ('.$h['coming'].' boxes on the way)' : '').'.' : 'Same cities kept together, so the hub splits them easily.') }}</small>
                    </span>
                @endforeach
            @elseif ($h['trips'])
                @php($t = $h['trips'][0])
                <span @class(['ds-cb__pill', 'ds-ph__truck', 'is-own' => $t['plate'], 'is-none' => ! $t['plate']])>🚚 {{ $t['plate'] ?? 'No truck yet' }}{{ $t['plate'] ? ' · '.$t['cap'].' space' : '' }}</span>
                <span class="ds-ph__bar"><i style="width: {{ min(100, round($t['load'] / max(1, $t['cap']) * 100)) }}%">About {{ $t['load'] }} of {{ $t['cap'] }} space</i></span>
            @endif
            <small class="ds-ph__tip">✦ {{ $h['tip'] }}</small>
            @if ($state)
                <span @class(['ds-ph__done', 'is-made' => $state === 'made'])>{{ $state === 'made' ? $hubMade[$h['hub']] ?? '✓ Created' : 'Waiting · shows again on the next plan' }}</span>
            @elseif (empty($h['open']))
                <span class="ds-ph__btns">
                    <button type="button" class="ds-te__btn is-main" wire:click="makeHub({{ $h['hub'] }})" wire:loading.attr="disabled">{{ $multi ? ($when === 'later' ? 'Create Trip 1 to '.$h['name'] : 'Create '.count($h['trips']).' trips to '.$h['name']) : 'Create trip to '.$h['name'] }}</button>
                    <button type="button" class="ds-te__btn ds-wc__ghost" wire:click="waitHub({{ $h['hub'] }})">Wait</button>
                </span>
            @endif
        </section>
    @empty
        <p class="ds-cb__card ds-cb__muted">No boxes wait for a hub. Places get a hub in Settings › Hub areas.</p>
    @endforelse
</div>
<span class="ds-wc__asked">One trip per hub, not split by city: the hub splits the boxes into its own trips. The hub’s boxes go on the trip when you press Create. No SMS from here; the hub texts the receivers when it locks its own trip.</span>
