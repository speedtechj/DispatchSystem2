<x-filament-panels::page>
<div class="ds-fl ds-wc">
    <div class="ds-ad__top">
        <span class="ds-te__title"><h1>Overrides</h1><small>Every time a rule was bypassed: who, why, and what the system notices.</small></span>
        <span class="ds-fl__seg"><button type="button" wire:click="$set('period', 'week')" @class(['is-on' => $period === 'week'])>This week</button><button type="button" wire:click="$set('period', 'month')" @class(['is-on' => $period === 'month'])>This month</button></span>
    </div>
    <div class="ds-tk__tiles">
        @foreach ($tiles as [$l, $v, $sub, $ring])
            <span @class(['ds-cb__card', 'ds-ad__tile', 'is-ring' => $ring])><small class="ds-cb__label">{{ $l }}</small><b class="ds-ad__big">{{ $v }}</b><small class="ds-cb__label">{{ $sub }}</small></span>
        @endforeach
    </div>
    <div class="ds-tr__grid">
        <section class="ds-cb__card ds-ad__table">
            <span class="ds-ov__row is-head"><span>When</span><span>Rule</span><span>Who</span><span>Why</span><span></span></span>
            @forelse ($rows as $o)
                <span class="ds-ov__row" wire:key="o-{{ $o->id }}">
                    <span>{{ $o->created_at->isToday() ? 'Today '.$o->created_at->format('g:i') : ($o->created_at->isYesterday() ? 'Yesterday' : $o->created_at->format('M j')) }}<small>{{ $o->trip_number }}{{ $o->box ? ' · '.$o->box : '' }}</small></span>
                    <b>{{ $rules[$o->rule][0] ?? $o->rule }}</b>
                    <span>{{ $o->user?->first_name ?? '—' }}</span>
                    <span>{{ $o->reason ?: '—' }}@if ($o->note)<small>{{ $o->note }}</small>@endif</span>
                    <span class="ds-ad__act">
                        @if ($o->status === 'pending')
                            @if ($office)<button type="button" class="ds-te__btn is-main ds-ad__sm" wire:click="decide({{ $o->id }}, true)">Approve</button><button type="button" class="ds-te__btn ds-ad__sm" wire:click="decide({{ $o->id }}, false)">Refuse</button>
                            @else<span class="ds-cb__pill is-warn">Waiting for the office</span>@endif
                        @else
                            <span @class(['ds-cb__pill', 'is-own' => $o->status === 'approved', 'is-bad' => $o->status === 'refused', 'is-muted' => $o->status === 'allowed'])>{{ ['approved' => 'Approved'.($o->decider ? ' by '.$o->decider->first_name : ''), 'refused' => 'Refused by office', 'allowed' => 'Allowed'][$o->status] ?? $o->status }}</span>
                        @endif
                    </span>
                </span>
            @empty
                <p class="ds-cb__muted ds-ad__empty">No bypasses {{ $period === 'month' ? 'this month' : 'this week' }}.</p>
            @endforelse
        </section>
        <div class="ds-ad__col">
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">By reason</b>
                @forelse ($byReason as $r => $n)
                    <span class="ds-ov__bar"><span class="ds-pt__lhead"><span>{{ $r }}</span><b>{{ $n }}</b></span><span class="ds-pt__bar"><i style="width: {{ round($n / $max * 100) }}%; background: #1d6fb8"></i></span></span>
                @empty
                    <small class="ds-te__hint">No reasons yet.</small>
                @endforelse
            </section>
            <section class="ds-pt__free">
                <span class="ds-pt__fhead"><span aria-hidden="true">✦</span><b>What the system notices</b></span>
                @forelse ($learned as $l)<span>{{ $l }}</span>
                @empty<span>Nothing stands out yet. When the same reason keeps coming back, it shows here.</span>@endforelse
                <small class="ds-te__hint">Part 22: “What the AI learned” lets the AI act on these (truck space, city order), with Undo.</small>
            </section>
        </div>
    </div>
</div>
</x-filament-panels::page>
