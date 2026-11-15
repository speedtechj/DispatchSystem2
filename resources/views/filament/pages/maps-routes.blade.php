<x-filament-panels::page>
<div class="ds-mp">
    <section class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>What the system uses now</h2></div>
        <div class="ds-mp__chain">
            @foreach ($chain as $i => [$title, $what, $text, $on])
                <div @class(['ds-mp__step', 'is-on' => $on])>
                    <span class="ds-mp__stephead"><i>{{ $i + 1 }}</i><b>{{ $title }}</b></span>
                    <strong>{{ $what }}</strong>
                    <small>{{ $text }}</small>
                </div>
            @endforeach
        </div>
        @if ($fallback)
            <p class="ds-mp__warn">{{ \App\Support\Maps\MapSettings::providerName(\App\Support\Maps\MapSettings::chosen()) }} has no key yet, so {{ $inUse === 'none' ? 'the barangay order' : \App\Support\Maps\MapSettings::providerName($inUse) }} is used for now.</p>
        @endif
        <p class="ds-board__muted">Always, with or without keys: one stop per receiver (all their boxes together) · loading order is the reverse of the delivery order · staff can drag stops · an address the map can't find goes next to its barangay, so a trip is never blocked.</p>
    </section>

    @if ($full)
    <section class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>Map service</h2><span class="ds-board__muted">finds each address and the best order of stops</span></div>
        <div class="ds-mp__providers">
            @foreach ($providers as $p)
                <button type="button" wire:click="pick('{{ $p['key'] }}')" @class(['ds-mp__provider', 'is-picked' => $provider === $p['key']])>
                    <span class="ds-mp__provhead"><b>{{ $p['name'] }}</b>
                        <em @class(['is-on' => $inUse === $p['key']])>{{ $inUse === $p['key'] ? 'In use' : ($p['masked'] ? 'Key saved' : ($p['key'] === 'none' ? 'Fallback' : 'No key')) }}</em></span>
                    <small>{{ $p['text'] }}</small>
                    <code>{{ $p['key'] === 'none' ? 'Nothing to set' : ($p['masked'] ? 'Key: '.$p['masked'] : 'No key yet') }}</code>
                </button>
            @endforeach
        </div>
        @if ($provider !== 'none')
            <form wire:submit="saveKey" class="ds-mp__keyrow">
                <input type="password" wire:model="key" autocomplete="off" placeholder="Paste your {{ \App\Support\Maps\MapSettings::PROVIDERS[$provider] }} key" aria-label="Map key">
                <x-filament::button type="submit">Save key</x-filament::button>
                <x-filament::button type="button" color="gray" wire:click="test">Test</x-filament::button>
                @if (\App\Support\Maps\MapSettings::key($provider))
                    <x-filament::button type="button" color="danger" outlined wire:click="removeKey" wire:confirm="Remove this key? Trips go back to the other map or the barangay order.">Remove</x-filament::button>
                @endif
            </form>
            @error('key')<p class="ds-ai__err">{{ $message }}</p>@enderror
            <label class="ds-mp__testaddr"><span>Test with this address</span><input type="text" wire:model="testAddress"></label>
            @if ($testResult)
                <p @class(['ds-mp__result', 'is-ok' => $testOk])>{{ $testResult }}</p>
            @endif
            <p class="ds-board__muted">
                @if ($provider === 'google')
                    Get a key at console.cloud.google.com → APIs &amp; Services. Turn on <b>Geocoding API</b> and <b>Routes API</b> (the older Directions API also still works). The key stays on the server; the map picture in the app is OpenStreetMap, so it is not shown to phones.
                @else
                    Get a free key at openrouteservice.org → Sign up → Dashboard → Tokens (the same key works on api.heigit.org).
                @endif
            </p>
        @endif
    </section>

    @else
        <section class="ds-board__panel">
            <p class="ds-board__muted">Map keys and the switches below are set by Admin (Settings → Maps &amp; routes), for every warehouse and hub. Here you set where your routes start and fix the pins of addresses on your trips.</p>
            <div class="ds-mp__stats">
                <span><b>AI address cleaning:</b> {{ $aiReady ? 'on' : 'off' }}</span>
                <span><b>Priority stops first:</b> {{ $priorityFirst ? 'on' : 'off' }}</span>
                <span><b>"Too early" warning in Load truck:</b> {{ $warnEarly ? 'on' : 'off' }}</span>
            </div>
        </section>
    @endif

    <div @class(['ds-mp__two', 'is-one' => ! $full])>
        @if ($full)
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>AI address cleaning</h2></div>
            <p class="ds-board__muted">Uses the AI key from Settings → AI. Turns "purok 3 near chapel, Lapu2" into "Purok 3, Pusok, Lapu-Lapu City, Cebu" before the map looks it up.</p>
            <button type="button" wire:click="toggleAi" @class(['ds-mp__toggle', 'is-on' => $aiOn])>{{ $aiOn ? ($aiReady ? 'On · AI key found ✓' : 'On · but no AI key yet') : 'Off · switch on' }}</button>
            @if ($aiOn && ! $hasAiKey)
                <p class="ds-mp__warn">Add the AI key in Settings → AI, or addresses are used as typed.</p>
            @endif

            <div class="ds-board__panel-head" style="margin-top: 1rem"><h2>Priority boxes</h2></div>
            <p class="ds-board__muted">Deliver receivers with a priority box first, even if the route is a bit longer.</p>
            <button type="button" wire:click="togglePriority" @class(['ds-mp__toggle', 'is-on' => $priorityFirst])>{{ $priorityFirst ? 'On · priority stops first' : 'Off · shortest route' }}</button>

            <div class="ds-board__panel-head" style="margin-top: 1rem"><h2>"Too early" warning</h2></div>
            <p class="ds-board__muted">Load truck stops a box that goes in too early (it belongs nearer the door). The crew can still press "Load it anyway".</p>
            <button type="button" wire:click="toggleEarly" @class(['ds-mp__toggle', 'is-on' => $warnEarly])>{{ $warnEarly ? 'On · warn the crew' : 'Off · just show the truck spot' }}</button>
        </section>
        @endif

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Start of every route</h2></div>
            <p class="ds-board__muted">Paste the pin of each place, like <code>10.3157, 123.8854</code>. In Google Maps: right-click the building and click the numbers to copy them. Empty = found from the address.</p>
            <form wire:submit="saveStarts" class="ds-mp__starts">
                @foreach ($warehouses as $w)
                    <label><span>{{ $w->name }} <small>warehouse</small></span><input type="text" wire:model="starts.wh:{{ $w->id }}" placeholder="not set"></label>
                @endforeach
                @if ($warehouses->isEmpty() && $hubs->isEmpty())
                    <p class="ds-board__muted">Your account has no warehouse or hub, so there is no start pin to set.</p>
                @endif
                @foreach ($hubs as $h)
                    <label><span>{{ $h->hub_name }} <small>hub</small></span><input type="text" wire:model="starts.hub:{{ $h->id }}" placeholder="not set"></label>
                @endforeach
                @if ($warehouses->isNotEmpty() || $hubs->isNotEmpty())<div><x-filament::button type="submit" size="sm">Save pins</x-filament::button></div>@endif
            </form>
        </section>
    </div>

    <section class="ds-board__panel">
        <div class="ds-mp__stats">
            <span><b>Saved locations:</b> {{ number_format($stats['found']) }}</span>
            <span><b>Map look-ups this month:</b> {{ number_format($stats['month']) }} <small>(new addresses only)</small></span>
            <span><b>Waiting:</b> {{ number_format($stats['waiting']) }}</span>
            <span><b>Not found:</b> {{ number_format($stats['missing']) }} <small>(placed by barangay)</small></span>
        </div>
    </section>

    @if ($suggested->isNotEmpty())
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Pins from drivers</h2><span class="ds-board__muted">"Can't find it" in the Driver app: the driver dropped a pin where the house really is</span></div>
            <div class="ds-mp__fix">
                @foreach ($suggested as $g)
                    <div wire:key="sg-{{ $g->id }}">
                        <span><b>{{ $g->clean ?: $g->raw }}</b><small>Driver's pin {{ round($g->suggested_lat, 5) }}, {{ round($g->suggested_lng, 5) }} · {{ $g->suggested_at?->diffForHumans() }}
                            · <a href="https://www.google.com/maps/search/?api=1&query={{ $g->suggested_lat }},{{ $g->suggested_lng }}" target="_blank" rel="noopener">see on map</a></small></span>
                        <x-filament::button size="sm" wire:click="acceptSuggestion({{ $g->id }})">Use this pin</x-filament::button>
                        <x-filament::button size="sm" color="gray" wire:click="rejectSuggestion({{ $g->id }})">Ignore</x-filament::button>
                    </div>
                @endforeach
            </div>
        </section>
    @endif

    @if ($fix->isNotEmpty())
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Fix pins</h2><span class="ds-board__muted">addresses the map could not find</span></div>
            <div class="ds-mp__fix">
                @foreach ($fix as $g)
                    <div wire:key="fx-{{ $g->id }}">
                        <span><b>{{ $g->raw }}</b>@if ($g->clean && $g->clean !== $g->raw)<small>AI: {{ $g->clean }}</small>@endif</span>
                        <input type="text" wire:model="pins.{{ $g->id }}" placeholder="10.3157, 123.8854">
                        <x-filament::button size="sm" wire:click="savePin({{ $g->id }})">Save pin</x-filament::button>
                    </div>
                @endforeach
            </div>
        </section>
    @endif
</div>
</x-filament-panels::page>
