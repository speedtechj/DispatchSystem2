<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#0a1219">
    <link rel="manifest" href="/pwa/delivery/manifest">
    <title>Driver · {{ $company }}</title>
    <style>
        * { box-sizing: border-box; }
        html, body { margin: 0; min-height: 100%; background: #0a1219; color: #eef3f6; font-family: Archivo, system-ui, -apple-system, 'Segoe UI', sans-serif; }
        #dso-shell noscript, .dso-loading { display: block; max-width: 30rem; margin: 0 auto; padding: 6rem 1.5rem; text-align: center; color: #7f93a1; }
    </style>
</head>
<body>
    {{-- The screens are drawn by driver-offline.js from the trip saved on this phone. --}}
    <div id="dso-shell">
        <p class="dso-loading">Opening your saved trip…</p>
        <noscript>Please turn on JavaScript to use the Driver app.</noscript>
    </div>
    <script src="{{ $script }}"></script>
</body>
</html>
