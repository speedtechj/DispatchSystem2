<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Section labels · {{ $warehouse->name }}</title>
<style>
    @page { size: A4; margin: 12mm; }
    body { margin: 0; font-family: system-ui, -apple-system, "Segoe UI", sans-serif; color: #0b1620; }
    .bar { padding: 14px 18px; display: flex; gap: 12px; align-items: center; justify-content: space-between; background: #f3f5f7; }
    .bar button { padding: 10px 16px; border: 0; border-radius: 10px; background: #f6be00; font-weight: 800; cursor: pointer; }
    .label { page-break-after: always; break-after: page; min-height: 255mm; box-sizing: border-box; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10mm; padding: 10mm; }
    .code { width: 120mm; height: 120mm; border-radius: 10mm; color: #fff; display: flex; align-items: center; justify-content: center; font-size: 90mm; font-weight: 900; line-height: 1; }
    .name { font-size: 16mm; font-weight: 800; text-align: center; }
    .prov { font-size: 6mm; color: #44525e; text-align: center; max-width: 170mm; }
    .qr svg { width: 55mm; height: 55mm; }
    .hint { font-size: 4.5mm; color: #6b7b88; }
    @media print { .bar { display: none; } }
</style>
</head>
<body>
<div class="bar"><strong>{{ $sections->count() }} section labels · {{ $warehouse->name }}</strong><button type="button" onclick="window.print()">Print</button></div>
@forelse ($sections as $s)
    <div class="label">
        <div class="code" style="background: {{ $s['color'] }}">{{ $s['code'] }}</div>
        <div class="name">{{ $s['name'] }}</div>
        @if ($s['provinces'])<div class="prov">{{ $s['provinces'] }}</div>@endif
        <div class="qr">{!! $s['qr'] !!}</div>
        <div class="hint">Scan this label in the Scan app (only when "section label scan" is on)</div>
    </div>
@empty
    <p style="padding: 20px">No sections for this warehouse yet.</p>
@endforelse
</body>
</html>
