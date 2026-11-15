@php
    $photoJs = "{ busy: false, failed: false, pct: 0,
        take() { this.failed = false; this.\$refs.file.value = ''; this.\$refs.file.click() },
        async send(e) {
            const file = e.target.files[0]; if (! file) return;
            this.busy = true; this.pct = 0;
            const out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
            await new Promise(done => \$wire.upload('upload', out, () => \$wire.savePhoto().then(done), () => { this.failed = true; done() }, (ev) => { this.pct = ev.detail.progress }));
            this.busy = false;
        } }";
    $placeJs = "{ init() { if (navigator.geolocation) navigator.geolocation.getCurrentPosition(p => \$wire.setPlace(p.coords.latitude, p.coords.longitude), () => {}, { enableHighAccuracy: true, timeout: 15000, maximumAge: 120000 }) } }";
@endphp
<x-filament-panels::page>
<div class="ds-sa ds-dr ds-fd" x-data="{{ $placeJs }}">
    <section class="ds-sa__screen" wire:key="port-{{ $step }}">
        <header class="ds-fd__top">
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-fd__back" aria-label="Back to today">‹</a>
            <span><small>{{ $s ? 'Trip '.$s->trip?->trip_number : 'No sea shipment' }}</small><strong>At the port</strong></span>
            <span class="ds-fd__dots" aria-hidden="true">@foreach (['intro', 'count', 'photo'] as $k)<i @class(['is-on' => $step === $k, 'is-done' => array_search($step, ['intro', 'count', 'photo', 'done']) > $loop->index])></i>@endforeach</span>
        </header>

        @if (! $s)
            <div class="ds-fd__intro"><span class="ds-fd__big" aria-hidden="true">🚢</span><strong>Nothing to count at the port</strong><p>Your trip today is not a sea shipment with a port count.</p></div>
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-sa__primary ds-fd__btn">Back to today</a>
        @elseif ($step === 'intro')
            <div class="ds-fd__cash"><small>Sea shipment</small><b style="font-size: 1.3rem">🚢 {{ $s->code }} → {{ $s->hub?->hub_name }}</b>
                <small>Hand the boxes to {{ $s->shipping_line ?: 'the forwarder' }}{{ $s->port_from ? ' at '.$s->port_from : '' }}. Left the warehouse: {{ $left }} boxes.</small></div>
            @if ($s->port_count !== null)<div class="ds-fd__warn">Already counted: {{ $s->port_count }} boxes. You can count again.</div>@endif
            <div class="ds-fd__intro"><span class="ds-fd__big" aria-hidden="true">📦</span><strong>When the forwarder has counted the boxes</strong><p>Type the count from the forwarder, then take a photo of the receipt.</p></div>
            <button type="button" class="ds-sa__primary" wire:click="start">Boxes handed over</button>
        @elseif ($step === 'count')
            <strong class="ds-pt__q">How many boxes did the forwarder count?</strong>
            <div class="ds-pt__count">
                <button type="button" wire:click="bump(-1)" aria-label="One less">−</button>
                <input type="text" inputmode="numeric" wire:model.live.debounce.400ms="count" aria-label="Boxes handed over">
                <button type="button" wire:click="bump(1)" aria-label="One more">+</button>
            </div>
            <p class="ds-pt__hint">{{ $left }} left the warehouse · tap the number to type it</p>
            @error('count')<p class="ds-sa__err">{{ $message }}</p>@enderror
            @if ($short)
                <div class="ds-fd__warn is-bad"><b>{{ $short }} {{ $short === 1 ? 'box' : 'boxes' }} short.</b> Check the truck now, and ask the forwarder to count again. The office sees it right away.</div>
            @elseif ($count !== '')
                <div class="ds-fd__cash">✓ Same as what left the warehouse.</div>
            @endif
            <button type="button" class="ds-sa__primary" wire:click="toPhoto">Next · photo of the receipt</button>
        @elseif ($step === 'photo')
            <div class="ds-fd__intro"><span class="ds-fd__big" aria-hidden="true">🧾</span><strong>Photo of the forwarder receipt</strong><p>{{ $n }} boxes. The count, van and seal on it are kept with the shipment.</p></div>
            <div x-data="{{ $photoJs }}" class="ds-fd__actions">
                <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                <button type="button" class="ds-sa__primary" x-on:click="take()" x-bind:disabled="busy"><span x-show="! busy">📷 Take photo</span><span x-show="busy" x-cloak>Saving… <span x-text="pct < 100 ? pct + '%' : ''"></span></span></button>
                <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again where there is signal.</p>
                @error('upload')<p class="ds-sa__err">{{ $message }}</p>@enderror
                <button type="button" class="ds-dr__link" wire:click="save">No receipt · save the count only</button>
            </div>
        @else
            <div class="ds-fd__intro"><span class="ds-fd__big is-ok" aria-hidden="true">✓</span><strong>Handed over at the port</strong>
                <p>{{ $short ? $n.' of '.$left.' boxes · the office is told about the '.$short.' short.' : 'All '.$left.' boxes · '.$s->code.' is at the port.' }}</p></div>
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-sa__primary ds-fd__btn">Done · back to today</a>
        @endif
    </section>
</div>
</x-filament-panels::page>
