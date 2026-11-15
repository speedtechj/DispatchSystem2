<x-filament-panels::page>
    @php($progress = $this->progress())

    <x-scan.station :heading="$this->stationHeading()" :description="$this->stationDescription()" :icon="$this->stationIcon()">
        <x-slot name="form">
            {{ $this->form }}

            <x-barcode-scanner method="scan" continuous :cooldown="1500" />
        </x-slot>

        <x-slot name="progress">
            @if ($this->data['container_id'] ?? null)
                <x-scan.progress :loaded="$progress['loaded']" :total="$progress['total']" :label="$this->progressLabel()"
                    :last="$progress['last'] ?? null" :issues="$progress['issues'] ?? 0" :unmanifested="$progress['unmanifested'] ?? 0"
                    done-text="Every box on the manifest is scanned." />
            @endif
        </x-slot>

        <x-slot name="result">
            <x-scan.result :invoice="$this->lastInvoice()" :status="$lastStatus" :title="$lastMessage">
                <div class="ds-result__actions">
                    {{ $this->reportIssueAction }}
                </div>
            </x-scan.result>

            @if ($route)
                <div class="ds-ws__result" style="--c: {{ $route['color'] ?? '#1d6fb8' }}">
                    <strong>{{ ($route['kind'] ?? '') === 'truck' ? '🚚' : $route['code'] }}</strong>
                    <span><b>{{ ($route['kind'] ?? '') === 'truck' ? 'Truck '.$route['trip'].' → '.$route['name'] : 'Section '.$route['code'].' · '.$route['name'] }}</b>
                        @if ($setInfo)<small>{{ $setInfo['name'] }} · box {{ $setInfo['n'] }} of {{ $setInfo['of'] }} · {{ $setInfo['text'] }}</small>@endif
                        @if (! empty($route['why']))<small>{{ $route['why'] }}</small>@endif</span>
                </div>
            @endif

            @if ($missingCode)
                <div class="ds-result__actions">
                    {{ $this->unmanifestedAction }}
                </div>
            @endif
            @include('filament.partials.scan-photo')
        </x-slot>

        <x-slot name="aside">
            <x-scan.household :rows="$this->household()" done-label="verified" />
        </x-slot>
    </x-scan.station>

</x-filament-panels::page>
