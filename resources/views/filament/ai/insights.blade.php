<x-filament-panels::page>
<div class="ds-ai">
    @include('filament.ai.paused', ['paused' => $paused])
    @if ($error)<p class="ds-ai__err">{{ $error }}</p>@endif
    <div class="ds-ai__split is-even">
        @if ($forecast)
            @php($max = max(1, collect($forecast['next'])->max('n'), collect($forecast['next'])->max('last_year'), collect($forecast['past'])->max('n')))
            <section class="ds-ai__card">
                <div class="ds-ai__card-head"><b>Boxes per week</b><small class="ds-board__muted">grey = last 8 weeks · yellow = expected · line = last year</small></div>
                <div class="ds-ai__bars">
                    @foreach ($forecast['past'] as $w)
                        <span class="ds-ai__barcol"><em>{{ number_format($w['n']) }}</em><i class="is-past" style="height: {{ round($w['n'] / $max * 140) }}px"></i><small>{{ $w['label'] }}</small></span>
                    @endforeach
                    @foreach ($forecast['next'] as $w)
                        <span class="ds-ai__barcol"><em>{{ number_format($w['n']) }}</em><i class="is-next" style="height: {{ round($w['n'] / $max * 140) }}px"><s style="bottom: {{ round($w['last_year'] / $max * 140) }}px"></s></i><small>{{ $w['label'] }}</small></span>
                    @endforeach
                </div>
                <p class="ds-board__muted">{{ $forecast['has_history'] ? 'Expected = the same week last year × '.$forecast['growth'].' (how this year compares so far).' : 'No boxes from last year yet, so "expected" is the average of the last 8 weeks.' }} Counted by container unload date.</p>
                <div class="ds-ai__said"><span class="ds-ai__badge">AI</span>
                    <span>
                        @if ($advice){{ $advice }}@else<small>Press the button for advice on staff and trucks.</small>@endif
                        <span class="ds-ai__two">
                            <x-filament::button size="sm" color="gray" wire:click="writeAdvice({{ $advice ? 'true' : 'false' }})" wire:loading.attr="disabled" wire:target="writeAdvice">
                                <span wire:loading.remove wire:target="writeAdvice">{{ $advice ? 'Write again' : 'Write advice' }}</span><span wire:loading wire:target="writeAdvice">Writing…</span>
                            </x-filament::button>
                        </span>
                    </span>
                </div>
            </section>
        @endif

        <section class="ds-ai__card">
            <div class="ds-ai__card-head"><b>Weekly hub report</b>
                @if ($hubs->count() > 1)
                    <select wire:model.live="hubId" class="ds-ai__select">@foreach ($hubs as $h)<option value="{{ $h->id }}">{{ $h->hub_name }}</option>@endforeach</select>
                @endif
            </div>
            @if ($stats)
                <p class="ds-board__muted">{{ $stats['hub'] }} · week of {{ $stats['week'] }}</p>
                <div class="ds-ai__stats is-small">
                    <div><small>Delivered</small><b>{{ $stats['delivered'] }}</b><em>{{ $stats['delivered_first_try'] }} on the first try</em></div>
                    <div><small>Failed tries</small><b class="is-amber">{{ $stats['failed_attempts'] }}</b><em>{{ $stats['failed_by_reason']->keys()->first() ?? '—' }}</em></div>
                    <div><small>Waiting 5+ days</small><b class="is-red">{{ $stats['boxes_waiting_over_5_days'] }}</b><em>not delivered</em></div>
                </div>
                <div class="ds-ai__said"><span class="ds-ai__badge">AI</span>
                    <span>
                        @if ($report){{ $report }}@else<small>Press the button to write this week's report.</small>@endif
                        <span class="ds-ai__two">
                            <x-filament::button size="sm" color="gray" wire:click="writeReport({{ $report ? 'true' : 'false' }})" wire:loading.attr="disabled" wire:target="writeReport">
                                <span wire:loading.remove wire:target="writeReport">{{ $report ? 'Write again' : 'Write report' }}</span><span wire:loading wire:target="writeReport">Writing…</span>
                            </x-filament::button>
                        </span>
                    </span>
                </div>
            @else
                <p class="ds-ai__empty">No partner hubs yet.</p>
            @endif
        </section>
    </div>
</div>
</x-filament-panels::page>
