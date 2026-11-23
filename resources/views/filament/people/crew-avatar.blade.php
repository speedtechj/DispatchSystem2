@if ($m['pic'] ?? null)
    <img src="{{ $m['pic'] }}" alt="" @class(['ds-us__av', 'is-sm' => $small ?? false])>
@else
    <span @class(['ds-us__av', 'is-sm' => $small ?? false]) style="background: {{ $m['av'] }}">{{ $m['ini'] }}</span>
@endif
