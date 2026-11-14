<x-filament-panels::page>
    <div class="ds-co">
        <div class="ds-co__tabs" role="tablist" aria-label="Period">
            @foreach ($periods as $value => $label)
                <button type="button" role="tab" wire:click="$set('days', {{ $value }})" @class(['is-active' => $days === $value]) aria-selected="{{ $days === $value ? 'true' : 'false' }}">{{ $label }}</button>
            @endforeach
        </div>

        <div class="ds-board__cards">
            @foreach ($cards as [$label, $value, $sub])
                <div class="ds-board__card ds-board__card--static">
                    <span class="ds-board__card-head"><span>{{ $label }}</span></span>
                    <span class="ds-board__card-value">{{ $value }}</span>
                    <span class="ds-board__card-sub">{{ $sub }}</span>
                </div>
            @endforeach
        </div>

        <section class="ds-board__panel">
            @forelse ($drivers as $i => $d)
                @if ($loop->first)
                    <div class="ds-co__driver ds-co__driver--head"><span>#</span><span></span><span>Driver · truck</span><span>Delivered</span><span>First try</span><span>Not delivered</span><span>Most common reason</span></div>
                @endif
                <div class="ds-co__driver" wire:key="driver-{{ $d['user']->id }}">
                    <span class="ds-co__rank">{{ $i === 0 && $d['delivered'] ? '🏆' : $i + 1 }}</span>
                    <span class="ds-co__avatar">{{ $d['initials'] ?: '?' }}</span>
                    <span class="ds-co__area-name"><strong>{{ $d['name'] }}</strong><small>{{ $d['truck'] ?? 'No truck' }}</small></span>
                    <strong class="ds-co__num">{{ number_format($d['delivered']) }}</strong>
                    <span class="ds-co__rate">
                        @if ($d['firstTry'] !== null)
                            <b @class(['is-ok' => $d['firstTry'] >= 90, 'is-warn' => $d['firstTry'] < 90])>{{ $d['firstTry'] }}%</b>
                            <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $d['firstTry'] >= 90 ? 'ok' : 'warn' }}" style="width: {{ $d['firstTry'] }}%"></span></span>
                        @else
                            <span class="ds-board__muted">—</span>
                        @endif
                    </span>
                    <span class="ds-co__num">{{ $d['failed'] }}</span>
                    <span class="ds-board__muted">{{ $d['reason'] ?? '—' }}</span>
                </div>
            @empty
                <p class="ds-board__muted">No drivers yet. Add your drivers in Company Crew and mark their position as crew.</p>
            @endforelse
        </section>
    </div>
</x-filament-panels::page>
