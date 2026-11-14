<!DOCTYPE html>
<html><body style="margin:0;padding:24px;background:#f3f5f7;font-family:Arial,sans-serif;color:#0e2433">
<div style="max-width:640px;margin:0 auto;background:#fff;border-radius:14px;padding:24px">
<h1 style="margin:0 0 4px;font-size:22px">Trucks today · {{ $day->format('D, M j') }}</h1>
<p style="margin:0 0 16px;color:#5b6b78">{{ $s->data['plain'] }}</p>
@if ($s->data['day'])<p style="padding:12px 14px;border-radius:10px;background:#f2efff;color:#2c2470;line-height:1.5">✨ {{ $s->data['day'] }}</p>@endif
@foreach ($s->data['trucks'] as $t)
    <div style="margin-top:12px;padding:12px 14px;border-radius:10px;background:#f6f8fa">
        <b>🚚 {{ $t['plate'] }}</b> · {{ $t['driver'] }} · Day {{ $t['grade'] }}<br>
        <span style="color:#5b6b78;font-size:13px">{{ $t['km'] }} km · delivered {{ $t['delivered'] }}/{{ $t['total'] }}{{ $t['back'] ? ' · last seen '.$t['back'] : '' }}</span>
        @if ($t['summary'])<p style="margin:8px 0 0;line-height:1.5">{{ $t['summary'] }}</p>@endif
    </div>
@endforeach
</div></body></html>
