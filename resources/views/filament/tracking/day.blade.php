<x-filament-panels::page>
<div class="ds-tm">
    <div class="ds-tm__top">
        <span class="ds-tm__who"><b>{{ $date->isToday() ? 'Today' : $date->format('l') }} · {{ $date->format('M j, Y') }}</b></span>
        <span class="ds-mp__keyrow">
            <x-filament::button color="gray" size="sm" wire:click="move(-1)">◀ {{ $date->copy()->subDay()->format('M j') }}</x-filament::button>
            @unless ($date->isToday())<x-filament::button color="gray" size="sm" wire:click="move(1)">{{ $date->copy()->addDay()->format('M j') }} ▶</x-filament::button>@endunless
            <x-filament::button size="sm" wire:click="write" wire:loading.attr="disabled">{{ $aiOn ? '✨ Write the summary now' : 'Count again' }}</x-filament::button>
        </span>
    </div>

    <section class="ds-board__panel ds-tm__daytext">
        <small>{{ $aiOn && ($summary?->data['day'] ?? null) ? '✨ The day in short' : 'The day in numbers' }}</small>
        <p>{{ $summary?->data['day'] ?: $summary?->data['plain'] }}</p>
        @if (! $aiOn)<small class="ds-board__muted">Switch on "End-of-day truck summary" in Settings → AI for a written summary of the day and each truck.</small>@endif
        @if ($summary)<small class="ds-board__muted">Written {{ \Illuminate\Support\Carbon::parse($summary->data['made_at'])->diffForHumans() }} · it is written again every day at 6 PM</small>@endif
    </section>

    @if ($trucks->isNotEmpty())
        <div class="ds-tm__daygrid">
            @foreach ($trucks as $t)
                <button type="button" wire:key="d-{{ $t['truck_id'] }}" wire:click="$set('sel', {{ $t['truck_id'] }})" @class(['ds-tm__daycard', 'is-sel' => $cur && $cur['truck_id'] === $t['truck_id']])>
                    <span><b>🚚 {{ $t['plate'] }}</b><em @class(['is-ok' => $t['grade'] === 'A', 'is-mid' => $t['grade'] === 'B', 'is-warn' => $t['grade'] === 'C'])>Day {{ $t['grade'] }}</em></span>
                    <small>{{ $t['driver'] }} · {{ $t['trips'] }}</small>
                    <span class="ds-tm__daynums"><i>km<b>{{ $t['km'] }}</b></i><i>Delivered<b>{{ $t['delivered'] }}/{{ $t['total'] }}</b></i><i>Per stop<b>{{ $t['per_stop'] ? $t['per_stop'].' min' : '—' }}</b></i><i>Last seen<b>{{ $t['back'] ?? '—' }}</b></i></span>
                </button>
            @endforeach
        </div>

        @if ($cur)
            <section class="ds-board__panel">
                <span class="ds-tm__cardhead"><b>🚚 {{ $cur['plate'] }} · {{ $cur['driver'] }}</b><x-filament::button tag="a" size="sm" color="gray" :href="$truckUrl($cur['truck_id'])">Open truck</x-filament::button></span>
                @if ($cur['summary'])
                    <p class="ds-tm__aibox"><small>✨ Summary</small>{{ $cur['summary'] }}</p>
                    <div class="ds-tm__goodbad"><span class="is-ok"><b>Went well</b>{{ $cur['good'] }}</span><span class="is-warn"><b>Look at</b>{{ $cur['bad'] }}</span></div>
                @else
                    <p class="ds-tm__now">{{ $cur['km'] }} km · driving {{ $cur['driving'] }} · delivered {{ $cur['delivered'] }} of {{ $cur['total'] }}{{ $cur['failed'] ? ' · '.$cur['failed'].' not delivered' : '' }}{{ $cur['started'] ? ' · from '.$cur['started'].' to '.$cur['back'] : '' }}</p>
                @endif
                @if ($cur['alerts'])<p class="ds-board__muted">Alerts: {{ implode(' · ', $cur['alerts']) }}</p>@endif
            </section>
        @endif
    @endif
</div>
</x-filament-panels::page>
