<x-filament-panels::page>
<form wire:submit="save" class="ds-mp">
    <section class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>Where each truck's location comes from</h2></div>
        <div class="ds-mp__providers">
            @foreach ($options as $k => [$name, $text])
                <button type="button" wire:click="setAll('{{ $k }}')" class="ds-mp__provider">
                    <span class="ds-mp__provhead"><b>{{ $name }}</b><em>{{ collect($sources)->filter(fn ($s) => $s === $k)->count() }} {{ str('truck')->plural(collect($sources)->filter(fn ($s) => $s === $k)->count()) }}</em></span>
                    <small>{{ $text }}</small>
                    <code>Click to use for all trucks</code>
                </button>
            @endforeach
        </div>
        <div class="ds-tm__srcs">
            @foreach ($trucks as $t)
                <label wire:key="src-{{ $t->id }}"><span><b>{{ $t->plate_no }}</b> <small>{{ $t->description ?: $t->category }}</small></span>
                    <select wire:model="sources.{{ $t->id }}">@foreach ($options as $k => [$name])<option value="{{ $k }}">{{ $name }}</option>@endforeach</select></label>
            @endforeach
        </div>
        <div class="ds-tm__link">
            <span><b>Tracker link</b> · put this in the GPS tracker or its server (Traccar: forward / OsmAnd). Send <code>id</code> = plate number, <code>lat</code>, <code>lon</code>, and if you can <code>speed</code> (km/h) and <code>timestamp</code>.</span>
            <code>{{ $trackerLink }}?id=ABC1234&amp;lat=10.31&amp;lon=123.89</code>
            <x-filament::button type="button" size="sm" color="gray" wire:click="newTrackerLink" wire:confirm="Make a new link? Trackers with the old link stop sending.">Make a new link</x-filament::button>
        </div>
    </section>

    <div class="ds-mp__two">
        <section class="ds-board__panel ds-tm__form">
            <div class="ds-board__panel-head"><h2>When to track</h2></div>
            <label><span>Only during an active trip</span><b class="is-ok">Always on</b></label>
            <label><span>Send location every</span><select wire:model="values.interval"><option value="15">15 seconds</option><option value="30">30 seconds</option><option value="60">1 minute</option><option value="120">2 minutes</option></select></label>
            <label><span>Keep the route history for</span><select wire:model="values.keep_days"><option value="30">30 days</option><option value="90">90 days</option><option value="180">180 days</option><option value="365">1 year</option></select></label>
            <label><span>Map on the tracking page</span><select wire:model.live="values.map"><option value="osm">OpenStreetMap (free)</option><option value="google">Google Maps (browser key)</option></select></label>
            @if (($values['map'] ?? 'osm') === 'google')
                <label><span>Google Maps browser key {!! $hasGoogle ? '<small class="is-ok">saved ✓</small>' : '' !!}</span><input type="password" wire:model="googleKey" placeholder="{{ $hasGoogle ? 'Paste to replace' : 'Paste the key' }}" autocomplete="off"></label>
                <p class="ds-board__muted">Use a separate key with <b>Maps JavaScript API</b> on, limited to your website address (HTTP referrers). It is seen by browsers, so never use the server key from Maps &amp; routes here. @if ($hasGoogle)<button type="button" class="ds-nav__link" wire:click="removeGoogleKey">Remove key</button>@endif</p>
                @error('googleKey')<p class="ds-ai__err">The key has a space in it. Paste it again.</p>@enderror
            @endif
        </section>
        <section class="ds-board__panel ds-tm__form">
            <div class="ds-board__panel-head"><h2>Alerts (bell, to the hub and Admin)</h2></div>
            <label><span>Stopped, not at a stop, for more than</span><select wire:model="values.stopped"><option value="10">10 min</option><option value="15">15 min</option><option value="20">20 min</option><option value="30">30 min</option><option value="45">45 min</option><option value="60">1 hour</option></select></label>
            <label><span>No location for more than</span><select wire:model="values.no_signal"><option value="15">15 min</option><option value="30">30 min</option><option value="45">45 min</option><option value="60">1 hour</option></select></label>
            <label><span>Far off the planned stops, more than</span><select wire:model="values.off_route"><option value="2">2 km</option><option value="3">3 km</option><option value="5">5 km</option><option value="10">10 km</option></select></label>
            <label><span>End-of-day summary by email at 6 PM (emails, comma between)</span><input type="text" wire:model="summaryEmails" placeholder="you@company.com"></label>
            <label><span>Back at the warehouse with boxes left</span><select wire:model="values.back"><option value="1">On</option><option value="0">Off</option></select></label>
        </section>
    </div>
    <p class="ds-board__muted">Warehouse and Partner hub see only their own trucks on Truck tracking. Drivers agree once in the Driver app before anything is sent (Data Privacy Act). Locations are only sent during an active trip.</p>
    <div><x-filament::button type="submit">Save</x-filament::button></div>
</form>
</x-filament-panels::page>
