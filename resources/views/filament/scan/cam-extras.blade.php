{{-- Inside a barcodeScanner() camera (Scan app, Driver app): camera off, dark, hard to read, photos uploading (board 51). --}}
<button type="button" class="ds-cx__off" x-show="! scanning && ! loading && ! error" x-on:click="start()" x-cloak>
    <span>📷</span><b>Camera off · tap to scan</b><small x-show="offWhy" x-text="offWhy"></small>
</button>
<div class="ds-cx__dark" x-show="darkTip && scanning && ! typing" x-cloak>
    <span>🌙 Dark here · turn on the flashlight?</span><button type="button" x-on:click="turnTorchOn()">Turn on</button>
</div>
<button type="button" class="ds-cx__hard" x-show="hard && scanning && ! typing && ! paused" x-on:click="openTyping()" x-cloak>⌨ Hard to read? Type the number</button>
<div class="ds-cx__type" x-show="typing" x-cloak>
    <small>Type the number on the sticker, exactly (with the zeros if it has them)</small>
    <span class="ds-cx__field"><b x-text="typed"></b><i></i><button type="button" x-on:click="findTyped()">Find</button></span>
    <span class="ds-cx__keys">
        <template x-for="k in ['1','2','3','4','5','6','7','8','9','⌫','0','00']" :key="k"><button type="button" x-on:click="key(k)" x-text="k"></button></template>
    </span>
    <button type="button" class="ds-cx__back" x-on:click="closeTyping()">Back to camera</button>
</div>
@if ($uploads ?? false)
    <div class="ds-cx__chips" x-data="{ p() { return window.dsPhotos ? window.dsPhotos : null } }" x-show="p() && (p().going().length || p().saved() || p().failed().length || torchOn)" x-cloak>
        <template x-if="p() && p().going().length"><span class="is-up" x-text="'⇡ ' + p().going().length + (p().going().length > 1 ? ' photos' : ' photo') + ' uploading · ' + ((p().going()[0] || {}).p || 0) + '%'"></span></template>
        <template x-if="p() && p().failed().length"><span class="is-bad" x-on:click="p().failed().forEach((i) => p().retry(i))" x-text="'⚠ ' + p().failed().length + ' not saved · tap to retry'"></span></template>
        <template x-if="p() && p().saved()"><span class="is-ok" x-text="'✓ ' + p().saved() + (p().saved() > 1 ? ' photos' : ' photo') + ' saved'"></span></template>
        <template x-if="torchOn"><span class="is-torch">🔦 Flashlight on</span></template>
    </div>
@endif
