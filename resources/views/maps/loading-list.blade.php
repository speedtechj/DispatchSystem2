@php($title = ['front' => 'FRONT · load first, deep inside next to the cab', 'middle' => 'MIDDLE', 'back' => 'BACK · at the door, load last'])
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Loading list · {{ $trip->trip_number }}</title>
<style>
    @page { size: A4; margin: 14mm; }
    * { box-sizing: border-box; }
    body { margin: 0; font: 13px/1.4 Archivo, "Helvetica Neue", Arial, sans-serif; color: #0e2433; }
    header { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 3px solid #0e2433; padding-bottom: 8px; }
    h1 { margin: 0; font-size: 22px; font-weight: 900; }
    .muted { color: #5b6b78; }
    .how { margin: 10px 0 4px; }
    .group { margin-top: 12px; break-inside: avoid; }
    .group h2 { margin: 0; padding: 5px 9px; color: #fff; font-size: 13px; font-weight: 900; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .is-front h2 { background: #1f5f9e; } .is-middle h2 { background: #4b3aa8; } .is-back h2 { background: #8a5a00; }
    .row { display: grid; grid-template-columns: 22px 56px 1fr 44%; gap: 8px; align-items: start; padding: 7px 9px; border-bottom: 1px solid #e3e7ea; }
    .tick { width: 16px; height: 16px; border: 1.5px solid #0e2433; border-radius: 3px; margin-top: 1px; }
    .codes { font-family: ui-monospace, Menlo, monospace; font-size: 11.5px; text-align: right; }
    footer { display: flex; justify-content: space-between; margin-top: 26px; color: #5b6b78; }
    .noprint { margin: 12px 0; } @media print { .noprint { display: none; } }
</style>
</head>
<body>
<div class="noprint"><button onclick="window.print()">Print</button></div>
<header>
    <div><h1>Loading list</h1><span class="muted">Trip {{ $trip->trip_number }}{{ $trip->truck?->plate_no ? ' · '.$trip->truck->plate_no : '' }} · {{ ($trip->departure_date ?? $trip->eta)?->format('M j, Y') }}</span></div>
    <div class="muted" style="text-align: right">{{ $boxes }} boxes · {{ $count }} stops<br>Load from top to bottom</div>
</header>
<p class="how">Load from the top of this list. The first group goes deepest in the truck, next to the cab. Tick each box as it goes in.</p>
@foreach ($groups as $zone => $stops)
    <div class="group is-{{ $zone }}">
        <h2>{{ $title[$zone] }}</h2>
        @foreach ($stops as $s)
            <div class="row">
                <span class="tick"></span>
                <b>Stop {{ $s->stop_no }}</b>
                <span><b>{{ $s->name }}</b> · {{ $s->barangay ? $s->barangay.', ' : '' }}{{ $s->city }}@if ($s->priority) · <b>PRIORITY</b>@endif</span>
                <span class="codes">{{ collect($s->box_ids)->map(fn ($id) => $codes[$id] ?? null)->filter()->join(', ') }}</span>
            </div>
        @endforeach
    </div>
@endforeach
<footer><span>Loaded by: ______________________</span><span>Checked by: ______________________</span></footer>
<script>window.addEventListener('load', () => setTimeout(() => window.print(), 300));</script>
</body>
</html>
