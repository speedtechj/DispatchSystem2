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
