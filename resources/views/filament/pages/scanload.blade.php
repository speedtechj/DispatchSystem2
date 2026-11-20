<x-filament-panels::page>
    @php($progress = $this->progress())

    <x-scan.station :heading="$this->stationHeading()" :description="$this->stationDescription()" :icon="$this->stationIcon()">
        <x-slot name="form">
            {{ $this->form }}

            <x-barcode-scanner method="scan" continuous :cooldown="1500" />
        </x-slot>

        <x-slot name="progress">
            @if ($this->data['deliverylog_id'] ?? null)
                @if (method_exists($this, 'loadNext') && ($next = $this->loadNext()))
                    @include('filament.partials.load-next', ['next' => $next])
                @endif
                <x-scan.progress :loaded="$progress['loaded']" :total="$progress['total']" :label="$this->progressLabel()" :last="$progress['last'] ?? null" />
            @endif
        </x-slot>

        <x-slot name="result">
            <x-scan.result
                :invoice="$this->lastInvoice()"
                :status="$lastStatus"
                :title="$lastMessage"
                :meta="method_exists($this, 'lastReason') ? ['Driver said' => $this->lastReason()] : []"
            />
            @if (($fu = (property_exists($this, 'wrongHub') ? $this->wrongHub : null)) && ($fu['kind'] ?? null) === 'full')
                <div class="ds-ld__early is-full"><strong>Truck full · {{ $fu['code'] }} does not fit</strong><span>{{ $fu['for'] }}. Put it back{{ $fu['section'] !== '—' ? ' in section '.$fu['section'] : '' }}.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">It still fits · load anyway</x-filament::button></div>
            @endif
            @if (($wx = (property_exists($this, 'wrongHub') ? $this->wrongHub : null)) && ($wx['kind'] ?? null) === 'wh')
                <div class="ds-ld__early is-full"><strong>Not for {{ $wx['trip'] }} · {{ $wx['code'] }} is for {{ $wx['for'] }}</strong><span>Delivered from {{ $wx['home'] }}: it stays here.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">The office says load it</x-filament::button></div>
            @endif
            @if (property_exists($this, 'bypass') && $this->bypass)
                <div class="ds-ld__bypass">
                    @if ($this->bypass['need'] === 'office')
                        <strong>{{ \App\Support\Trips\TripRules::RULES[$this->bypass['rule']][0] }}: office only</strong><span>Ask the office to allow {{ $this->bypass['code'] }}.</span>
                        <span class="ds-ld__reasons"><x-filament::button size="sm" wire:click="askOffice">Ask the office</x-filament::button><x-filament::button size="sm" color="gray" wire:click="cancelBypass">Cancel</x-filament::button></span>
                    @else
                        <strong>Why? (the office sees this)</strong>
                        <span class="ds-ld__reasons">@foreach (\App\Support\Trips\TripRules::reasons() as $r)<x-filament::button size="sm" color="gray" wire:click="bypassWith(@js($r))">{{ $r }}</x-filament::button>@endforeach<x-filament::button size="sm" color="gray" outlined wire:click="cancelBypass">Cancel</x-filament::button></span>
                    @endif
                </div>
            @endif
            @if (method_exists($this, 'cityTopUp') && ! $this->lastStatus && ($ctu = $this->cityTopUp()))
                <div class="ds-ld__citytop"><strong>✦ Room for {{ $ctu['room'] }} more boxes</strong><span>{{ $ctu['same'] ? 'Same way' : 'Next province' }}: {{ $ctu['city'] }}, {{ $ctu['province'] }} · {{ $ctu['boxes'] }} boxes{{ $ctu['section'] ? ' · section '.$ctu['section'] : '' }}</span><x-filament::button size="sm" wire:click="addTopUpCity(@js($ctu['key']))">Add {{ $ctu['city'] }} to this trip</x-filament::button></div>
            @endif
            @if (($oc = (property_exists($this, 'wrongHub') ? $this->wrongHub : null)) && ($oc['kind'] ?? null) === 'city')
                <div class="ds-ld__early"><strong>Other city · {{ $oc['code'] }} is for {{ $oc['for'] }}</strong><span>This trip goes to {{ $oc['trip'] }}. Put it back in section {{ $oc['section'] }}.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">Add it to this trip anyway</x-filament::button></div>
            @endif
            @if ($early = (property_exists($this, 'early') ? $this->early : null))
                <div class="ds-ld__early"><strong>Too early · stop {{ $early['stop'] }} goes in at the {{ $early['zone'] === 'back' ? 'door' : 'middle' }}</strong><span>Put it aside and load stop {{ $early['nextStop'] }} first.</span><x-filament::button size="sm" color="gray" wire:click="loadAnyway">Load it anyway</x-filament::button></div>
            @endif
            @include('filament.partials.scan-photo')
        </x-slot>

        <x-slot name="aside">
            <x-scan.household :rows="$this->household()" done-label="on this trip" />
        </x-slot>
    </x-scan.station>
</x-filament-panels::page>
