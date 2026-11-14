{{-- Install QR codes for the phone apps. $compact: the dashboard card. --}}
@php
    $problem = \App\Support\InstallLinks::problem();
    $apps = collect(\App\Support\InstallLinks::APPS)->map(fn ($a, $key) => [
        'key' => $key, 'name' => \App\Support\InstallLinks::name($key), 'url' => \App\Support\InstallLinks::url($key), 'for' => $a['for'],
        'icon' => route('pwa.icon', ['panel' => $a['panel'], 'size' => 192]).'?v='.\App\Support\Pwa::version(),
        'qr' => \App\Support\InstallLinks::svg($key, $compact ?? false ? 120 : 170),
    ]);
@endphp
<div @class(['ds-qr', 'is-compact' => $compact ?? false, 'is-off' => $problem])>
    @if ($problem)
        <p class="ds-qr__warn"><b>!</b> {{ $problem }}@if (! ($compact ?? false)) The codes below won't work on phones until this is fixed.@endif</p>
    @endif
    <div class="ds-qr__grid">
        @foreach ($apps as $a)
            <section class="ds-qr__card" wire:key="qr-{{ $a['key'] }}">
                <div class="ds-qr__code">{!! $a['qr'] !!}</div>
                <div class="ds-qr__info">
                    <span class="ds-qr__title"><img src="{{ $a['icon'] }}" alt="" width="36" height="36"><b>{{ $a['name'] }}</b></span>
                    <small>{{ $a['for'] }}</small>
                    @unless ($compact ?? false)
                        <span class="ds-qr__link" x-data="{ copied: false }">
                            <code>{{ $a['url'] }}</code>
                            <button type="button" x-on:click="navigator.clipboard.writeText(@js($a['url'])); copied = true; setTimeout(() => copied = false, 1500)" x-text="copied ? 'Copied ✓' : 'Copy link'"></button>
                        </span>
                        <ol><li>Point the phone camera at the code and tap the link.</li><li>Sign in with their own email and password.</li><li>Android: tap <b>Install</b>. iPhone: <b>Share → Add to Home Screen</b>.</li></ol>
                    @endunless
                    <span class="ds-qr__actions">
                        <a href="{{ route('install-qr.poster', $a['key']) }}" target="_blank" rel="noopener" class="is-main">Print poster</a>
                        @unless ($compact ?? false)
                            <a href="{{ route('install-qr.png', $a['key']) }}">Download QR</a>
                            <a href="{{ route('install-qr.stickers', $a['key']) }}" target="_blank" rel="noopener">Print stickers (6 per page)</a>
                        @endunless
                    </span>
                </div>
            </section>
        @endforeach
    </div>
    @if (! ($compact ?? false) && \App\Support\InstallLinks::printedForOtherAddress())
        <p class="ds-qr__warn is-amber"><b>!</b> The address changed since posters were last printed. Print new posters and stickers.</p>
    @endif
    <small class="ds-qr__note">The code only holds the link. Everyone still signs in with their own password.</small>
</div>
