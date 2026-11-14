<x-filament-widgets::widget>
    <div class="ds-co__today" wire:poll.60s>
        <section class="ds-board__panel">
            <div class="ds-board__panel-head">
                <h2>Drivers today</h2>
                <a href="{{ $tripsUrl }}" class="ds-co__link">All trips</a>
            </div>
            @forelse ($drivers as $d)
                <div class="ds-co__trip" wire:key="trip-{{ $d['trip']->id }}">
                    <span class="ds-co__avatar">{{ $d['initials'] }}</span>
                    <span class="ds-co__area-name">
                        <strong>{{ $d['driver'] }}</strong>
                        <small>{{ collect([$d['truck'], 'Trip '.$d['trip']->trip_number, $d['areas']])->filter()->join(' · ') }}</small>
                    </span>
                    <span class="ds-co__rate">
                        <span class="ds-board__muted"><b>{{ $d['done'] }}</b> of {{ $d['total'] }} delivered</span>
                        <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $d['status'] === 'loading' ? 'yellow' : 'ok' }}" style="width: {{ $d['total'] ? $d['done'] / $d['total'] * 100 : 0 }}%"></span></span>
                    </span>
                    <span class="ds-co__status is-{{ $d['status'] }}">{{ ['road' => 'On the road', 'loading' => 'Loading', 'done' => 'Done'][$d['status']] ?? '' }}</span>
                </div>
            @empty
                <p class="ds-board__muted">No trips out right now. Plan one from Incoming boxes.</p>
            @endforelse
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Needs attention</h2><span>{{ $attention->count() ?: 'All clear' }}</span></div>
            @forelse ($attention as $item)
                <div class="ds-co__attn">
                    <span class="ds-board__tag ds-board__tag--{{ $item['tone'] }}">{{ $item['tag'] }}</span>
                    <span class="ds-board__muted">{{ $item['detail'] }}</span>
                    @if ($url = $this->link($item['link']))
                        <a href="{{ $url }}" class="ds-co__link">{{ $item['action'] }}</a>
                    @endif
                </div>
            @empty
                <p class="ds-board__muted">Nothing needs your attention. 👍</p>
            @endforelse
        </section>
    </div>
</x-filament-widgets::widget>
