<x-filament-panels::page>
<div class="ds-fl ds-ad">
    <div class="ds-ad__top">
        <span class="ds-te__title"><small>Settings › AI</small><h1>AI address cleaning</h1><small>Your existing helper, upgraded: it now also fills in a missing barangay. Same switch, same key.</small></span>
        <span class="ds-ad__master">
            <span class="ds-cb__pill is-own ds-ad__model">Claude · fast model ({{ $model }})</span>
            <button type="button" role="switch" aria-checked="{{ $on ? 'true' : 'false' }}" aria-label="AI address cleaning" wire:click="toggleOn" @class(['ds-te__switch', 'ds-ad__bigswitch', 'is-on' => $on])><i></i></button>
            <b>{{ $on ? 'On' : 'Off' }}</b>
        </span>
    </div>
    @unless ($hasKey)<span class="ds-ad__pending"><span>No AI key yet: steps 1–3 (same receiver, map, driver GPS) still work. Add the key in Settings → AI.</span></span>@endunless
    <div class="ds-fl__seg" role="tablist">
        @foreach (['settings' => 'Settings', 'try' => 'Try it', 'compare' => 'Today vs upgraded'] as $k => $l)
            <button type="button" role="tab" aria-selected="{{ $tab === $k ? 'true' : 'false' }}" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k])>{{ $l }}</button>
        @endforeach
    </div>

    @if ($tab === 'settings')
        <div @class(['ds-ad__set', 'is-off' => ! $on])>
            <section class="ds-cb__card ds-ad__card">
                <span class="ds-te__head"><b>What it does</b><small>Click a row to turn it on or off</small></span>
                @foreach ($options as $k => $o)
                    <button type="button" class="ds-ad__optrow" wire:click="flip('{{ $k }}')" role="switch" aria-checked="{{ $o['on'] ? 'true' : 'false' }}">
                        <span class="ds-ad__icon">{{ $o['icon'] }}</span>
                        <span class="ds-ad__optt"><span><b>{{ $o['title'] }}</b>@if ($o['new'])<span class="ds-cb__pill is-warn">New</span>@endif</span><small>{{ $o['sub'] }}</small></span>
                        <span @class(['ds-te__switch', 'ds-ad__smswitch', 'is-on' => $o['on']])><i></i></span>
                    </button>
                @endforeach
                <span class="ds-ad__level">
                    <span><b>Use it by itself when the AI is at least</b><small>Below this, the box goes to Addresses to check</small></span>
                    <span class="ds-fl__seg">@foreach ($levels as $l => $label)<button type="button" wire:click="setLevel({{ $l }})" @class(['is-on' => $level === $l])>{{ $label }}</button>@endforeach</span>
                </span>
            </section>
            <div class="ds-ad__col">
                <section class="ds-cb__card ds-ad__card">
                    <b class="ds-ad__h">Order it tries</b>
                    @foreach ([['Same receiver before', 'your own delivery history', 'free', 'is-own'], ['Map lookup', $mapName, 'map key', 'is-info'], ['Driver GPS', 'saved at earlier deliveries', 'free', 'is-own'], ['AI reads the address', 'only when 1–3 find nothing', '< 1¢', 'is-warn']] as $n => [$t, $sub, $cost, $tone])
                        <span @class(['ds-ad__step', 'is-ai' => $n === 3])><b class="ds-ad__num">{{ $n + 1 }}</b><span><b>{{ $t }}</b><small>{{ $sub }}</small></span><span class="ds-cb__pill {{ $tone }}">{{ $cost }}</span></span>
                    @endforeach
                </section>
                <section class="ds-cb__card ds-ad__card">
                    <b class="ds-ad__h">This month</b>
                    <span class="ds-ad__month">
                        @foreach ([['Addresses cleaned', number_format($month['cleaned'])], ['Barangays filled in', number_format($month['filled'])], ['Sent to check', number_format($month['check'])], ['AI cost', '$'.number_format($month['cost'], 2)]] as [$l, $v])
                            <span><small>{{ $l }}</small><b>{{ $v }}</b></span>
                        @endforeach
                    </span>
                    <small class="ds-te__hint">Counts toward your AI monthly limit (${{ number_format($limit, 2) }}). Sent to the AI: address and city only, never the name or phone.</small>
                </section>
            </div>
        </div>
    @elseif ($tab === 'try')
        <div class="ds-ad__try">
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Try an address</b>
                @foreach ($samples as $n => $s)
                    <button type="button" wire:click="sample({{ $n }})" @class(['ds-ad__sample', 'is-on' => $tryAddress === $s['address']])><b>{{ $s['address'] }}</b><small>{{ $s['city'] }}</small></button>
                @endforeach
                <label class="ds-te__field">Address<input type="text" wire:model="tryAddress" class="ds-te__input" placeholder="Blk 5 Lot 12 Villa Arcadia Subd., near SM Marilao"></label>
                <label class="ds-te__field">City, province<input type="text" wire:model="tryCity" class="ds-te__input" placeholder="Marilao, Bulacan"></label>
                @error('tryAddress')<small class="ds-te__err">{{ $message }}</small>@enderror @error('tryCity')<small class="ds-te__err">{{ $message }}</small>@enderror
                <button type="button" class="ds-te__btn is-main" wire:click="runTry" wire:loading.attr="disabled"><span wire:loading.remove wire:target="runTry">Try it</span><span wire:loading wire:target="runTry">Asking…</span></button>
                <small class="ds-te__hint">The test uses your key and costs the same as a real box (less than 1¢).</small>
            </section>
            <section class="ds-cb__card ds-ad__card">
                @if ($result)
                    @php($k = $result['status'])
                    <span class="ds-ad__rhead"><b class="ds-ad__h">What it answers</b><span class="ds-cb__pill ds-ad__tag is-{{ $k }}">{{ ['used' => 'Used by itself', 'check' => 'Goes to Addresses to check', 'none' => 'No clues'][$k] }}</span></span>
                    <span class="ds-ad__kv"><small>Written on the manifest</small><span>{{ $result['raw'] }}</span></span>
                    <span class="ds-ad__kv"><small>Cleaned for the map (same as today)</small><span>{{ $result['clean'] }}</span></span>
                    <span class="ds-ad__two">
                        <span class="ds-ad__kv is-{{ $k }}"><small>Barangay (new)</small><b>{{ $result['barangay'] ?: '—' }}</b></span>
                        <span class="ds-ad__kv"><small>How sure</small><b>{{ $result['barangay'] ? $result['confidence'].'%' : '—' }}</b></span>
                    </span>
                    <span class="ds-ad__kv is-plain"><small>{{ ($result['source'] ?? null) && $result['source'] !== 'ai' ? 'Found by' : 'Clue it used' }}</small><span>{{ ($result['source'] ?? null) && $result['source'] !== 'ai' ? (\App\Support\Maps\Barangays::SOURCES[$result['source']] ?? '').' · ' : '' }}{{ $result['clue'] }}</span></span>
                    <span class="ds-ad__next is-{{ $k }}">{{ ['used' => 'Sure enough ('.$level.'% or more), so the box gets '.$result['barangay'].' and the receiver is remembered.', 'check' => 'Below '.$level.'%: the office sees it in Addresses to check (✓ OK or Change).', 'none' => 'Stays in the city group; still goes on the trip. The driver uses the full address.'][$k] }}</span>
                @else
                    <b class="ds-ad__h">What it answers</b>
                    <p class="ds-cb__muted">Pick an address on the left (or type one) and press Try it.</p>
                @endif
            </section>
        </div>
    @else
        <section class="ds-cb__card ds-ad__table">
            <span class="ds-ad__cmp is-head"><span></span><span>Today</span><span>Upgraded</span></span>
            @foreach ([['Missing barangay', 'Left empty', 'Filled in from the real barangay list'], ['Landmarks (“near SM Marilao”)', 'Removed', 'Used as clues, kept for the driver'], ['When it runs', 'Only when a trip is put on the map', 'Right after the manifest is read'], ['How sure', 'Not shown', 'Shown; unsure ones go to Addresses to check'], ['Same receiver next time', 'Asked again', 'Remembered, no AI, no cost'], ['What is sent to the AI', 'Address', 'Address + city (never name or phone)'], ['Setting, key, limit', 'Settings → AI', 'Same (nothing new)']] as [$w, $a, $b])
                <span class="ds-ad__cmp"><b>{{ $w }}</b><span class="ds-ad__muted">{{ $a }}</span><span><span class="ds-ad__tick">✓</span>{{ $b }}</span></span>
            @endforeach
        </section>
        <span class="ds-ad__info">Nothing new to set up: same switch in Settings → AI, same API key, same monthly limit. The “Read a manifest” helper still does the first clean-up when a consolidator file is read.</span>
    @endif
</div>
</x-filament-panels::page>
