@php
    $total = max((int) $getRecord()->boxes_count, 0);
    $loaded = (int) $getRecord()->loaded_count;
    $delivered = (int) $getRecord()->delivered_count;
    $pct = fn ($n) => $total ? round($n / $total * 100) : 0;
@endphp

<div class="ds-trip-progress" title="{{ $loaded }} loaded, {{ $delivered }} delivered of {{ $total }}">
    <div class="ds-trip-progress__track">
        <span class="ds-trip-progress__loaded" style="width: {{ $pct($loaded) }}%"></span>
        <span class="ds-trip-progress__delivered" style="width: {{ $pct($delivered) }}%"></span>
    </div>
    <span class="ds-trip-progress__nums">{{ $loaded }} / {{ $delivered }} <span>of {{ $total }}</span></span>
</div>
