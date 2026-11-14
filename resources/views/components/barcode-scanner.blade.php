@props([
    'id' => null,
    'method' => null,
    'statePath' => null,
    'formats' => ['code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'itf', 'qr_code'],
    'autoStart' => false,
    'continuous' => false,
    'cooldown' => 2500,
    'beep' => true,
    'placeholder' => 'Scan or type invoice / box number',
    'buttonLabel' => 'Scan with camera',
])

@php
    $id = $id ?? 'bb-scanner-' . \Illuminate\Support\Str::random(8);
@endphp

@once
    <style>
        .bb-scanner { display: flex; flex-direction: column; gap: .75rem; width: 100%; }
        .bb-scanner__row { display: flex; gap: .5rem; align-items: stretch; flex-wrap: wrap; }
        .bb-scanner__row > .bb-scanner__grow { flex: 1 1 14rem; min-width: 0; }

        .bb-scanner__viewport {
            position: relative; overflow: hidden; border-radius: .75rem; background: #000;
            width: 100%; max-width: 32rem; margin-inline: auto; height: min(60vh, 26rem);
        }
        .bb-scanner__video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }

        .bb-scanner__guide {
            position: absolute; left: 6%; right: 6%; top: 30%; bottom: 30%;
            border: 3px solid rgba(255, 255, 255, .9); border-radius: .75rem;
            box-shadow: 0 0 0 9999px rgba(0, 0, 0, .35);
            transition: border-color .15s, box-shadow .15s;
        }
        .bb-scanner__guide::after {
            content: ''; position: absolute; left: 4%; right: 4%; top: 50%; height: 2px;
            background: rgba(239, 68, 68, .9); animation: bb-line 1.6s ease-in-out infinite;
        }
        .bb-scanner__guide.is-hit { border-color: #22c55e; box-shadow: 0 0 0 9999px rgba(34, 197, 94, .25); }
        .bb-scanner__guide.is-hit::after { background: #22c55e; animation: none; }
        @keyframes bb-line { 0%, 100% { top: 15%; } 50% { top: 85%; } }

        .bb-scanner__loading {
            position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
            color: #fff; font-size: .875rem; gap: .5rem; background: rgba(0, 0, 0, .55);
        }
        .bb-scanner__torch {
            position: absolute; right: .75rem; bottom: .75rem; width: 2.75rem; height: 2.75rem;
            border-radius: 9999px; display: flex; align-items: center; justify-content: center;
            background: rgba(0, 0, 0, .55); color: #fff; font-size: 1.25rem; border: 1px solid rgba(255, 255, 255, .3);
        }
        .bb-scanner__torch.is-on { background: #facc15; color: #000; }

        .bb-scanner__hint { font-size: .8125rem; color: rgb(107 114 128); text-align: center; }
        .bb-scanner__error {
            font-size: .875rem; border-radius: .5rem; padding: .625rem .75rem;
            background: rgb(254 242 242); color: rgb(185 28 28); border: 1px solid rgb(254 202 202);
        }
        .bb-scanner__last {
            font-size: .875rem; border-radius: .5rem; padding: .5rem .75rem;
            background: rgb(240 253 244); color: rgb(21 128 61); border: 1px solid rgb(187 247 208);
            word-break: break-all;
        }
        .bb-scanner__select {
            width: 100%; border-radius: .5rem; padding: .5rem .75rem; font-size: .875rem;
            border: 1px solid rgb(209 213 219); background: #fff; color: inherit;
        }
        .dark .bb-scanner__hint { color: rgb(156 163 175); }
        .dark .bb-scanner__error { background: rgb(127 29 29 / .25); color: rgb(252 165 165); border-color: rgb(127 29 29 / .6); }
        .dark .bb-scanner__last { background: rgb(20 83 45 / .25); color: rgb(134 239 172); border-color: rgb(20 83 45 / .6); }
        .dark .bb-scanner__select { background: rgb(255 255 255 / .05); border-color: rgb(255 255 255 / .15); }

        @keyframes bb-spin { to { transform: rotate(360deg); } }
        .bb-scanner__spin {
            width: 1rem; height: 1rem; border-radius: 9999px;
            border: 2px solid rgb(255 255 255 / .35); border-top-color: #fff; animation: bb-spin .8s linear infinite;
        }
    </style>
@endonce

<div
    wire:ignore
    x-data="barcodeScanner(@js([
        'id' => $id,
        'method' => $method,
        'statePath' => $statePath,
        'formats' => $formats,
        'autoStart' => (bool) $autoStart,
        'continuous' => (bool) $continuous,
        'cooldown' => (int) $cooldown,
        'beep' => (bool) $beep,
    ]))"
    {{ $attributes->class('bb-scanner') }}
>
    {{-- Manual typing / handheld USB-Bluetooth scanner --}}
    <div class="bb-scanner__row">
        <div class="bb-scanner__grow">
            <x-filament::input.wrapper prefix-icon="heroicon-m-magnifying-glass">
                <x-filament::input
                    type="text"
                    x-model="manualCode"
                    x-on:keydown.enter.prevent="submitManual()"
                    :placeholder="$placeholder"
                    autocomplete="off"
                    autocapitalize="characters"
                    spellcheck="false"
                    enterkeyhint="search"
                />
            </x-filament::input.wrapper>
        </div>

        <x-filament::button type="button" color="gray" icon="heroicon-m-magnifying-glass" x-on:click="submitManual()">
            Search
        </x-filament::button>
    </div>

    {{-- Camera on/off --}}
    <x-filament::button type="button" icon="heroicon-m-camera" x-on:click="toggle()" class="w-full">
        <span x-show="!scanning && !loading">{{ $buttonLabel }}</span>
        <span x-show="scanning || loading" x-cloak>Stop camera</span>
    </x-filament::button>

    {{-- Camera preview --}}
    <div class="bb-scanner__viewport" x-show="scanning || loading" x-cloak>
        <video x-ref="video" class="bb-scanner__video" playsinline muted autoplay></video>

        <div class="bb-scanner__guide" x-bind:class="{ 'is-hit': flash }"></div>

        <div class="bb-scanner__loading" x-show="loading">
            <span class="bb-scanner__spin"></span> Starting camera…
        </div>

        <button type="button" class="bb-scanner__torch"
                x-show="scanning && torchSupported" x-cloak
                x-bind:class="{ 'is-on': torchOn }"
                x-on:click="toggleTorch()" aria-label="Flashlight">
            🔦
        </button>
    </div>

    <p class="bb-scanner__hint" x-show="scanning" x-cloak>
        Fit the barcode inside the box. Hold steady about 15–25 cm away.
    </p>

    {{-- Camera picker (only if the phone has more than one camera) --}}
    <template x-if="cameras.length > 1">
        <select class="bb-scanner__select" x-on:change="useCamera($event.target.value)">
            <option value="" x-bind:selected="!cameraId">Back camera (auto)</option>
            <template x-for="cam in cameras" :key="cam.id">
                <option x-bind:value="cam.id" x-bind:selected="cam.id === cameraId" x-text="cam.label"></option>
            </template>
        </select>
    </template>

    <div class="bb-scanner__error" x-show="error" x-text="error" x-cloak role="alert"></div>

    <div class="bb-scanner__last" x-show="lastCode && !error" x-cloak>
        Last scanned: <strong x-text="lastCode"></strong>
    </div>
</div>
