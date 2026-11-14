<x-filament-widgets::widget>
    <div class="ds-board" wire:poll.120s>
        <div class="ds-board__cards">
            @foreach ([
                ['Boxes at hubs now', $totals['now'], 'Waiting, loading and out for delivery', 'navy'],
                ['Waiting at hubs', $totals['waiting'], 'Handed over, not on a hub trip yet', 'teal'],
                ['Delivered today', $totals['today'], number_format($totals['month']).' this month', 'ok'],
                ['Not delivered today', $totals['failed'], 'Failed attempts, all hubs', 'bad'],
            ] as [$label, $value, $sub, $tone])
                <div class="ds-board__card ds-board__card--static">
                    <span class="ds-board__card-head"><span>{{ $label }}</span><span class="ds-board__dot ds-board__dot--{{ $tone }}"></span></span>
                    <span class="ds-board__card-value">{{ number_format($value) }}</span>
                    <span class="ds-board__card-sub">{{ $sub }}</span>
                </div>
            @endforeach
        </div>

        <section class="ds-board__panel ds-hubs">
            <div class="ds-hubs__head">
                <div>
                    <h2>Boxes by hub</h2>
                    <div class="ds-hubs__legend">
                        <span><i class="is-wait"></i>Waiting at hub</span>
                        <span><i class="is-load"></i>Loading</span>
                        <span><i class="is-out"></i>Out for delivery</span>
                        <span><i class="is-done"></i>Delivered today</span>
                    </div>
                </div>
                <div class="ds-hubs__sort" role="group" aria-label="Sort hubs">
                    @foreach (['now' => 'Most boxes now', 'today' => 'Delivered today', 'name' => 'A – Z'] as $key => $label)
                        <button type="button" wire:click="sortBy('{{ $key }}')" @class(['is-active' => $sortBy === $key]) aria-pressed="{{ $sortBy === $key ? 'true' : 'false' }}">{{ $label }}</button>
                    @endforeach
                </div>
            </div>

            <div class="ds-hubs__table" role="table" aria-label="Boxes by hub">
                <div class="ds-hubs__row ds-hubs__row--head" role="row">
                    <span role="columnheader">Hub</span><span role="columnheader">Now and today</span>
                    <span role="columnheader">Waiting</span><span role="columnheader">Loading</span><span role="columnheader">Out</span>
                    <span role="columnheader">Today</span><span role="columnheader">This month</span><span role="columnheader">Failed</span>
                </div>
                @forelse ($hubs as $hub)
                    <a href="{{ $this->tripsUrl($hub->id, (bool) $hub->is_company) }}" class="ds-hubs__row" role="row" wire:key="hub-{{ $hub->id }}">
                        <span role="cell" class="ds-hubs__name"><strong>{{ $hub->hub_name }}</strong><small>{{ $hub->is_company ? 'Partner hub' : 'Main hub · your trucks' }}</small></span>
                        <span role="cell" class="ds-hubs__bar">
                            <span class="ds-hubs__track" aria-hidden="true">
                                <span class="is-wait" style="width: {{ $hub->boxes_waiting / $scale * 100 }}%"></span>
                                <span class="is-load" style="width: {{ $hub->boxes_loading / $scale * 100 }}%"></span>
                                <span class="is-out" style="width: {{ $hub->boxes_out / $scale * 100 }}%"></span>
                                <span class="is-done" style="width: {{ $hub->boxes_today / $scale * 100 }}%"></span>
                            </span>
                            <b>{{ number_format($hub->boxes_now) }}</b>
                        </span>
                        <span role="cell">{{ $hub->is_company ? ($hub->boxes_waiting ? number_format($hub->boxes_waiting) : '—') : '' }}</span>
                        <span role="cell">{{ $hub->boxes_loading ? number_format($hub->boxes_loading) : '—' }}</span>
                        <span role="cell">{{ $hub->boxes_out ? number_format($hub->boxes_out) : '—' }}</span>
                        <span role="cell" class="is-good">{{ number_format($hub->boxes_today) }}</span>
                        <span role="cell" class="is-muted">{{ number_format($hub->boxes_month) }}</span>
                        <span role="cell" @class(['is-bad' => $hub->failed_today >= 5, 'is-muted' => $hub->failed_today < 5])>{{ $hub->failed_today ?: '—' }}</span>
                    </a>
                @empty
                    <p class="ds-board__muted">No active hubs.</p>
                @endforelse
                <div class="ds-hubs__row ds-hubs__row--total" role="row">
                    <span role="cell">All hubs</span><span role="cell" class="ds-hubs__bar"><b>{{ number_format($totals['now']) }} now</b></span>
                    <span role="cell">{{ number_format($totals['waiting']) }}</span><span role="cell">{{ number_format($totals['loading']) }}</span>
                    <span role="cell">{{ number_format($totals['out']) }}</span><span role="cell">{{ number_format($totals['today']) }}</span>
                    <span role="cell">{{ number_format($totals['month']) }}</span><span role="cell">{{ number_format($totals['failed']) }}</span>
                </div>
            </div>
            <p class="ds-board__muted">Click a hub to open its trips. Main hubs have no "waiting" count: their boxes stay in warehouse inventory until they go on a trip.</p>
        </section>
    </div>
</x-filament-widgets::widget>
