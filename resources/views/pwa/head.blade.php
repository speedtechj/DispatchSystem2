{{-- Makes the current panel installable as its own app. --}}
<link rel="manifest" href="{{ url("/pwa/{$panel}/manifest.webmanifest") }}">
<meta name="theme-color" content="#0e2433">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="{{ $name }}">
<link rel="apple-touch-icon" href="{{ url("/pwa/{$panel}/icon-180.png?v={$version}") }}">
