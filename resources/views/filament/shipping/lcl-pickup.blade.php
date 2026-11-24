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
@endphp
<x-filament-panels::page>
<div class="ds-sa ds-dr ds-fd">
    <section class="ds-sa__screen" wire:key="lcl-{{ $step }}">
        <header class="ds-fd__top">
            <a href="{{ $backUrl }}" class="ds-fd__back" aria-label="Back to Incoming shipments">‹</a>
            <span><small>{{ $s ? $s->code.' · waybill '.($s->waybill_no ?: '—') : 'No LCL to pick up' }}</small><strong>LCL pick-up at {{ $s?->forwarder ?: 'the forwarder' }}</strong></span>
            <span class="ds-fd__dots" aria-hidden="true">@foreach (['intro', 'count', 'photo'] as $k)<i @class(['is-on' => $step === $k, 'is-done' => array_search($step, ['intro', 'count', 'photo', 'done']) > $loop->index])></i>@endforeach</span>
        </header>

        @if (! $s)
            <div class="ds-fd__intro"><span class="ds-fd__big" aria-hidden="true">📦</span><strong>Nothing to pick up</strong><p>This shipment is not an LCL ready to pick up for your hub.</p></div>
            <a href="{{ $backUrl }}" class="ds-sa__primary ds-fd__btn">Back to Incoming shipments</a>
        @elseif ($step === 'intro')
            <div class="ds-fd__cash"><small>Pick up at</small><b style="font-size: 1.1rem">{{ $s->pick_up_at ?: ($s->forwarder ?: 'the forwarder') }}</b>
                <small>Bring the waybill no. {{ $s->waybill_no ?: '' }} and an ID. Boxes on the waybill: {{ $expected }}.</small></div>
            <div class="ds-fd__intro"><span class="ds-fd__big" aria-hidden="true">📦</span><strong>At the forwarder</strong><p>Count the boxes they hand you, then take a photo of the release paper.</p></div>
            <button type="button" class="ds-sa__primary" wire:click="start">Count the boxes</button>
        @elseif ($step === 'count')
            <strong class="ds-pt__q">How many boxes did you get?</strong>
            <div class="ds-pt__count">
                <button type="button" wire:click="bump(-1)" aria-label="One less">−</button>
                <input type="text" inputmode="numeric" wire:model.live.debounce.400ms="count" aria-label="Boxes picked up">
                <button type="button" wire:click="bump(1)" aria-label="One more">+</button>
            </div>
            <p class="ds-pt__hint">{{ $expected }} on the waybill · tap the number to type it</p>
            @error('count')<p class="ds-sa__err">{{ $message }}</p>@enderror
            @if ($short)
                <div class="ds-fd__warn is-bad"><b>{{ $short }} {{ $short === 1 ? 'box' : 'boxes' }} short.</b> Ask the forwarder to check before you leave. The office sees it.</div>
            @elseif ($count !== '')
                <div class="ds-fd__cash">✓ Same as the waybill.</div>
            @endif
            <button type="button" class="ds-sa__primary" wire:click="toPhoto">Next · photo of the release</button>
        @elseif ($step === 'photo')
            <div class="ds-fd__intro"><span class="ds-fd__big" aria-hidden="true">🧾</span><strong>Photo of the release paper</strong><p>{{ $n }} boxes. It is kept with the shipment.</p></div>
            <div x-data="{{ $photoJs }}" class="ds-fd__actions">
                <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                <button type="button" class="ds-sa__primary" x-on:click="take()" x-bind:disabled="busy"><span x-show="! busy">📷 Take photo</span><span x-show="busy" x-cloak>Saving… <span x-text="pct < 100 ? pct + '%' : ''"></span></span></button>
                <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again where there is signal.</p>
                @error('upload')<p class="ds-sa__err">{{ $message }}</p>@enderror
                <button type="button" class="ds-dr__link" wire:click="save">No paper · picked up without a photo</button>
            </div>
        @else
            <div class="ds-fd__intro"><span class="ds-fd__big is-ok" aria-hidden="true">✓</span><strong>Picked up</strong>
                <p>{{ $s->pickup_count !== null ? $s->pickup_count.' boxes' : '' }} · at your hub, scan them in: Scan app → Receive container.</p></div>
            <a href="{{ $scanUrl }}" class="ds-sa__primary ds-fd__btn">Picked up · go to the hub and scan</a>
            <a href="{{ $backUrl }}" class="ds-dr__link">Back to Incoming shipments</a>
        @endif
    </section>
</div>
</x-filament-panels::page>
