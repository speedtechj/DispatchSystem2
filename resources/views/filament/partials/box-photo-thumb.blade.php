<span class="ds-bp__thumb" x-bind:class="{ 'is-cur': cur === @js($key), 'is-sel': isSel(@js($key)) }">
    <button type="button" class="ds-bp__img" x-on:click="cur = @js($key)" aria-label="Open {{ $i['name'] }}">
        <img src="{{ $i['url'] }}" alt="" loading="lazy">
        @if ($i['condition'] && $i['condition'] !== 'good')
            <i @class(['ds-bp__dot', 'is-'.(['damaged' => 'bad', 'wet' => 'wet', 'open' => 'warn'][$i['condition']] ?? 'none')])></i>
        @endif
    </button>
    <button type="button" class="ds-bp__tick" x-on:click.stop="toggle(@js($key))" aria-label="Select {{ $i['name'] }}" x-bind:aria-pressed="isSel(@js($key))">✓</button>
    <small>{{ $i['kind'] === 'scan' ? $i['label'] : ($i['note'] ?: 'Photo '.$i['n']) }}</small>
</span>
