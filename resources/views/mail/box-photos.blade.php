<div style="font-family: Arial, sans-serif; font-size: 14px; color: #0e2433; line-height: 1.5">
    {!! nl2br(e($body)) !!}
    <table style="margin-top: 16px; border-collapse: collapse; font-size: 13px">
        <tr style="background: #f3f5f7"><th style="text-align: left; padding: 6px 10px">Photo</th><th style="text-align: left; padding: 6px 10px">Invoice</th><th style="text-align: left; padding: 6px 10px">Where</th><th style="text-align: left; padding: 6px 10px">Condition</th><th style="text-align: left; padding: 6px 10px">Date</th></tr>
        @foreach ($photos as $p)
            <tr>
                <td style="padding: 6px 10px; border-top: 1px solid #eef1f4">{{ $p['name'] }}</td>
                <td style="padding: 6px 10px; border-top: 1px solid #eef1f4">{{ $p['invoice'] ?? 'Batch' }}</td>
                <td style="padding: 6px 10px; border-top: 1px solid #eef1f4">{{ $p['label'] }} · {{ $p['ref'] }}</td>
                <td style="padding: 6px 10px; border-top: 1px solid #eef1f4">{{ \App\Models\BoxPhoto::CONDITIONS[$p['condition']] ?? '—' }}{{ $p['note'] ? ' — '.$p['note'] : '' }}</td>
                <td style="padding: 6px 10px; border-top: 1px solid #eef1f4">{{ $p['at']?->format('d M Y g:i A') }}</td>
            </tr>
        @endforeach
    </table>
    @if ($senderName)
        <p style="margin-top: 16px">— {{ $senderName }}, {{ config('app.name') }}</p>
    @endif
</div>
