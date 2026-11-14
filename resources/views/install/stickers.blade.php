<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>{{ $name }} · install stickers</title>
    <style>
        @page { size: letter; margin: 0.4in; }
        * { box-sizing: border-box; }
        body { margin: 0; font-family: Archivo, 'Helvetica Neue', Arial, sans-serif; color: #0e2433; background: #e9edf0; }
        .sheet { width: 7.7in; margin: 0.3in auto; background: #fff; display: grid; grid-template-columns: 1fr 1fr; gap: 0.15in; padding: 0.1in; }
        .st { border: 1.5px dashed #b8c2ca; border-radius: 14px; padding: 14px; display: flex; gap: 14px; align-items: center; height: 3.2in; }
        .st div { display: flex; flex-direction: column; gap: 6px; }
        .st img { width: 40px; height: 40px; border-radius: 10px; }
        .st b { font-size: 20px; letter-spacing: -0.01em; } .st small { font-size: 12px; color: #5b6b78; line-height: 1.4; }
        .st code { font-family: ui-monospace, Menlo, monospace; font-size: 10px; color: #5b6b78; }
        .bar { position: fixed; top: 12px; right: 12px; } .bar button { font: inherit; font-weight: 800; padding: 10px 16px; border: 0; border-radius: 10px; background: #f6be00; cursor: pointer; }
        @media print { body { background: #fff; } .bar { display: none; } .sheet { margin: 0 auto; } }
    </style>
</head>
<body>
<div class="bar"><button type="button" onclick="window.print()">Print</button></div>
<div class="sheet">
    @for ($i = 0; $i < 6; $i++)
        <div class="st">{!! $qr !!}
            <div><img src="{{ $icon }}" alt=""><b>{{ $name }}</b><small>Scan with the phone camera, sign in, then Install (Android) or Share → Add to Home Screen (iPhone).</small><small><b style="font-size: 12px">{{ $place }}</b></small><code>{{ preg_replace('#^https?://#', '', $url) }}</code></div>
        </div>
    @endfor
</div>
</body>
</html>
