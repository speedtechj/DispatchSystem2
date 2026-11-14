<div style="font-family: Arial, sans-serif; font-size: 14px; color: #0e2433; line-height: 1.55; max-width: 600px">
    <p>Good morning{{ $name ? ', '.$name : '' }},</p>
    <table style="border-collapse: separate; border-spacing: 8px 0; margin: 0 -8px 12px">
        <tr>
            <td style="padding: 12px 14px; border-radius: 10px; background: #fde8e6"><b style="font-size: 22px; color: #b3261e">{{ $sum['late'] }}</b><br><span style="font-size: 12px">late now</span></td>
            <td style="padding: 12px 14px; border-radius: 10px; background: #fff1d6"><b style="font-size: 22px; color: #9a6400">{{ $sum['tomorrow'] }}</b><br><span style="font-size: 12px">late tomorrow</span></td>
            <td style="padding: 12px 14px; border-radius: 10px; background: #e5f6ee"><b style="font-size: 22px; color: #17895e">{{ $sum['onTime'] !== null ? $sum['onTime'].'%' : '—' }}</b><br><span style="font-size: 12px">on time (30 days)</span></td>
        </tr>
    </table>
    @if ($advice)
        <p style="margin: 0 0 4px"><b>What to do today</b></p>
        <ol style="margin: 0 0 12px; padding-left: 20px">
            @foreach ($advice as $a)<li>{{ $a['t'] }} <b>{{ $a['act'] }}</b></li>@endforeach
        </ol>
    @endif
    @if ($sum['oldest'])
        <p style="color: #5b6b78">Oldest box: <b style="color: #0e2433">{{ $sum['oldest']['invoice'] }}</b> ({{ $sum['oldest']['name'] }}, {{ $sum['oldest']['place'] }}), {{ $sum['oldest']['total'] }} days since unload.</p>
    @endif
    <p><a href="{{ $url }}" style="display: inline-block; padding: 10px 16px; border-radius: 8px; background: #0e2433; color: #fff; text-decoration: none; font-weight: bold">Open Box aging</a></p>
    <p style="font-size: 12px; color: #8a99a5">{{ config('app.name') }} · you get this because Box aging emails are on in Admin → Settings → Aging limits.</p>
</div>
