{{-- Inside a barcodeScanner() camera (Scan app, Driver app): camera off, dark, hard to read, photos uploading (board 51). --}}
<button type="button" class="ds-cx__off" x-show="! scanning && ! loading && ! error" x-on:click="start()" x-cloak>
    <span>📷</span><b>Camera off · tap to scan</b><small x-show="offWhy" x-text="offWhy"></small>
</button>
<span class="ds-cx__cam" x-show="scanning && ! typing" x-bind:class="{ 'is-front': facing === 'front' }" x-text="facing === 'front' ? '🤳 Front camera' : '📷 ' + ((camChoices().find((c) => c.id === currentId) || { name: 'Back camera' }).name)" x-cloak></span>
<div class="ds-cx__dark is-front" x-show="facing === 'front' && scanning && ! typing && ! camList" x-cloak>
    <span>Front camera: it cannot see the box. Use a back camera?</span><button type="button" x-on:click="backCamera()">Back camera</button>
</div>
<div class="ds-cx__dark" x-show="darkTip && facing !== 'front' && scanning && ! typing" x-cloak>
    <span>🌙 Dark here · turn on the flashlight?</span><button type="button" x-on:click="turnTorchOn()">Turn on</button>
</div>
<div class="ds-cx__type ds-cx__cams" x-show="camList" x-on:click.outside="camList = false" x-cloak>
    <b>Choose the camera</b>
    <small>Back cameras scan best. Your choice is kept on this phone.</small>
    <template x-for="c in camChoices()" :key="c.id">
        <button type="button" x-on:click="useCamera(c.id)" x-bind:class="{ 'is-on': c.id === currentId, 'is-front': c.front }">
            <span x-text="c.front ? '🤳' : '📷'"></span><span><b x-text="c.name"></b><small x-text="c.sub"></small></span><em x-text="c.id === currentId ? '✓' : ''"></em>
        </button>
    </template>
    <button type="button" class="ds-cx__back" x-on:click="camList = false">Close</button>
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
