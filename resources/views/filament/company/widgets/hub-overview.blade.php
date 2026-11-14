<x-filament-widgets::widget>
    <div class="ds-hubsteps" wire:poll.60s>
        <div class="ds-co__hello">
            <div>
                <p class="ds-co__hello-title">{{ $greeting }}{{ $name ? ', '.$name : '' }}</p>
                <p class="ds-board__muted">
                    {{ $hubName }} · {{ now()->format('l, M j') }}
                    · {{ $trucks->where('is_assigned', true)->count() }} {{ str('truck')->plural($trucks->where('is_assigned', true)->count()) }} out, {{ $trucks->where('is_assigned', false)->count() }} free
                </p>
            </div>
            <form method="GET" action="{{ $trackUrl }}" class="ds-co__search ds-co__search--small" role="search">
                <label for="hub-track" class="sr-only">Track a box</label>
                <x-filament::icon icon="heroicon-m-magnifying-glass" class="h-4 w-4" />
                <input id="hub-track" type="text" name="code" placeholder="Track a box…" autocomplete="off">
            </form>
            <x-filament::button tag="a" :href="$planUrl" icon="heroicon-m-truck">Plan a trip</x-filament::button>
        </div>
        <h2>Your boxes right now</h2>
        <ol class="ds-hubsteps__row">
            @foreach ($steps as [$label, $value, $sub, $tone])
                <li class="ds-hubsteps__step is-{{ $tone }}">
                    <span class="ds-hubsteps__label">{{ $label }}</span>
                    <span class="ds-hubsteps__value">{{ number_format($value) }}</span>
                    <span class="ds-hubsteps__sub">{{ $sub }}</span>
                </li>
            @endforeach
        </ol>

        @if ($late['count'] > 0)
            <div class="ds-hubsteps__alert" role="status">
                <x-filament::icon icon="heroicon-o-archive-box" class="h-7 w-7" />
                <span>
                    <strong>{{ number_format($waiting) }} {{ Str::plural('box', $waiting) }} {{ $waiting === 1 ? 'is' : 'are' }} waiting for a trip</strong>
                    <span>{{ number_format($late['count']) }} of them {{ $late['count'] === 1 ? 'was' : 'were' }} due more than {{ \App\Filament\Company\Widgets\HubOverview::WAIT_DAYS }} days ago. Oldest: {{ $late['oldest'] }}, due {{ $lateSince }}.</span>
                </span>
                <x-filament::button tag="a" :href="$planUrl" icon="heroicon-m-truck">Plan a trip</x-filament::button>
            </div>
        @endif

        @if ($failed > 0)
            <p class="ds-hubsteps__note">{{ $failed }} failed {{ Str::plural('attempt', $failed) }} today. See Delivery Log for the reasons.</p>
        @endif
    </div>
</x-filament-widgets::widget>
