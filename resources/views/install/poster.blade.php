<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>{{ $name }} · install poster</title>
    <style>
        @page { size: letter; margin: 0; }
        * { box-sizing: border-box; }
        body { margin: 0; font-family: Archivo, 'Helvetica Neue', Arial, sans-serif; color: #0e2433; background: #e9edf0; }
        .sheet { width: 8.5in; min-height: 11in; margin: 0 auto; background: #fff; padding: 0.7in 0.75in 0.55in; display: flex; flex-direction: column; align-items: center; gap: 0.28in; }
        .top { align-self: stretch; display: flex; align-items: center; gap: 12px; }
        .mark { width: 46px; height: 46px; border-radius: 11px; background: #0e2433; color: #f6be00; display: grid; place-items: center; font-weight: 900; font-size: 16px; }
        .top b { font-size: 19px; display: block; } .top small { font-size: 12px; color: #5b6b78; }
        .head { display: flex; flex-direction: column; align-items: center; gap: 12px; margin-top: 0.15in; text-align: center; }
        .head img { width: 100px; height: 100px; border-radius: 24px; box-shadow: 0 12px 30px rgba(14, 36, 51, .2); }
        h1 { margin: 0; font-size: 54px; letter-spacing: -0.03em; line-height: 1; }
        .sub { font-size: 21px; color: #5b6b78; max-width: 6in; }
        .qr { padding: 22px; border-radius: 28px; border: 3px solid #0e2433; display: flex; flex-direction: column; align-items: center; gap: 10px; }
        .qr span { font-size: 15px; font-weight: 800; }
        .steps { align-self: stretch; display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }
        .steps div { padding: 14px; border-radius: 14px; background: #f3f5f7; display: flex; flex-direction: column; gap: 5px; }
        .steps strong { font-size: 30px; color: #c9980f; } .steps b { font-size: 16px; } .steps small { font-size: 13px; color: #5b6b78; line-height: 1.4; }
        .foot { margin-top: auto; font-size: 14px; color: #5b6b78; text-align: center; }
        .foot code { font-family: ui-monospace, Menlo, monospace; color: #0e2433; }
        .bar { position: fixed; top: 12px; right: 12px; display: flex; gap: 8px; }
        .bar button { font: inherit; font-weight: 800; padding: 10px 16px; border: 0; border-radius: 10px; background: #f6be00; color: #0e2433; cursor: pointer; }
        @media print { body { background: #fff; } .bar { display: none; } .sheet { margin: 0; } }
    </style>
</head>
<body>
<div class="bar"><button type="button" onclick="window.print()">Print</button></div>
<div class="sheet">
    <div class="top"><span class="mark">{{ \Illuminate\Support\Str::of($company)->explode(' ')->map(fn ($w) => mb_substr($w, 0, 1))->take(2)->join('') }}</span>
        <span><b>{{ $place }}</b>@unless ($isCompany)<small>with {{ $company }}</small>@endunless</span></div>
    <div class="head">
        <img src="{{ $icon }}" alt="">
        <h1>Install the {{ $name }}</h1>
        <div class="sub">@unless ($isCompany)For {{ $place }}: @endunless{{ $for }}</div>
    </div>
    <div class="qr">{!! $qr !!}<span>Scan with your phone camera</span></div>
    <div class="steps">
        <div><strong>1</strong><b>Scan</b><small>Point the camera at the code and tap the link.</small></div>
        <div><strong>2</strong><b>Sign in</b><small>With your own email and password.</small></div>
        <div><strong>3</strong><b>Install</b><small>Android: tap Install. iPhone: Share → Add to Home Screen.</small></div>
    </div>
    <div class="foot">No account yet? Ask the {{ $isCompany ? 'office' : $place.' office' }}. · <code>{{ preg_replace('#^https?://#', '', $url) }}</code></div>
</div>
</body>
</html>
