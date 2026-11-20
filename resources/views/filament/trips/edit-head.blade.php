<span class="ds-et__head">
    <a href="{{ $listUrl }}" class="ds-te__link">‹ Delivery trips</a>
    <span class="ds-et__line"><span>Trip {{ $trip->trip_number }}</span><span class="ds-tl__pill is-{{ $st['tone'] }}">{{ $st['label'] }}</span><span class="ds-tl__made is-{{ $k }}">{{ $made }}</span>@if ($trip->is_lock)<span class="ds-tl__pill">🔒 Locked</span>@endif</span>
</span>
