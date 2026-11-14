@props([
    'loaded' => 0,
    'total' => 0,
    'label' => 'Loaded',
    'last' => null,
    'issues' => 0,
    'unmanifested' => 0,
    'doneText' => 'Everything is loaded — the truck is ready to go.',
])

@php
    $percent = $total > 0 ? (int) round($loaded / $total * 100) : 0;
    $done = $total > 0 && $loaded >= $total;
    $left = max(0, $total - $loaded);
    $lastAt = $last ? \Illuminate\Support\Carbon::parse($last) : null;
    $problems = collect([
        $issues ? trans_choice('{1} 1 box with a problem|[2,*] :count boxes with a problem', $issues, ['count' => $issues]) : null,
        $unmanifested ? trans_choice('{1} 1 unmanifested box|[2,*] :count unmanifested boxes', $unmanifested, ['count' => $unmanifested]) : null,
    ])->filter()->join(' · ');
@endphp

<div {{ $attributes->class(['ds-progress', 'is-done' => $done]) }}>
    <div class="ds-progress__head">
        <span class="ds-progress__label">{{ $label }}</span>
        <span class="ds-progress__count">
            <strong>{{ number_format($loaded) }}</strong> / {{ number_format($total) }}
            <span class="ds-progress__pct">{{ $percent }}%</span>
        </span>
    </div>
    <div class="ds-progress__track" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="{{ $percent }}">
        <div class="ds-progress__bar" style="width: {{ $percent }}%"></div>
    </div>
    @unless ($done)
        <div class="ds-progress__meta" aria-live="polite">
            <span class="ds-progress__left">{{ number_format($left) }} left</span>
            @if ($lastAt)
                <span>Last scan {{ $lastAt->diffInSeconds(now()) < 60 ? 'just now' : $lastAt->diffForHumans(['parts' => 1]) }}</span>
            @endif
            @if ($problems)
                <span class="ds-progress__problems">{{ $problems }}</span>
            @endif
        </div>
    @endunless
    @if ($done)
        <p class="ds-progress__done">
            <x-filament::icon icon="heroicon-m-check-badge" class="h-5 w-5" />
            {{ $doneText }}
            @if ($problems) <span class="ds-progress__problems">· {{ $problems }}</span> @endif
        </p>
    @endif
</div>
