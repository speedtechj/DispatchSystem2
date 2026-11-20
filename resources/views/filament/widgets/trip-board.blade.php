<x-filament-widgets::widget>
    <div class="ds-board" wire:poll.60s>
        {{-- Today at a glance: each card filters the trip list --}}
        <div class="ds-board__cards">
            @foreach ($cards as $card)
                <a href="{{ $this->cardUrl($card['id']) }}"
                   @class(['ds-board__card', 'is-active' => $activeCard === $card['id']])
                   aria-current="{{ $activeCard === $card['id'] ? 'true' : 'false' }}">
                    <span class="ds-board__card-head">
                        <span>{{ $card['label'] }}</span>
                        <span class="ds-board__dot ds-board__dot--{{ $card['tone'] }}"></span>
                    </span>
                    <span class="ds-board__card-value">{{ $card['value'] }}</span>
                    @if ($card['pct'] !== null)
                        <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $card['tone'] }}" style="width: {{ $card['pct'] }}%"></span></span>
                    @endif
                    <span class="ds-board__card-sub">{{ $card['sub'] }}</span>
                </a>
            @endforeach
        </div>

        {{-- Trips that need attention --}}
        @if ($attention->isNotEmpty())
            <section class="ds-board__panel">
                <div class="ds-board__panel-head">
                    <h2>Needs attention</h2>
                    <span>{{ $attention->count() }} {{ Str::plural('trip', $attention->count()) }}</span>
                </div>
                <ul class="ds-board__attention">
                    @foreach ($attention as $item)
                        <li wire:key="attention-{{ $item['trip']->id }}">
                            <span class="ds-board__tag ds-board__tag--{{ $item['tone'] }}">{{ $item['tag'] }}</span>
                            <span class="ds-board__attention-text">
                                <strong>Trip {{ $item['trip']->trip_number }}</strong>
                                @if ($item['destination']) <span class="ds-board__muted">· {{ $item['destination'] }}</span> @endif
                                <span class="ds-board__detail">{{ $item['detail'] }}</span>
                            </span>
                            <span class="ds-board__muted ds-board__truck">{{ $item['truck'] }}</span>
                            @if ($item['action'] === 'release')
                                <x-filament::button size="sm" icon="heroicon-m-truck"
                                    wire:click="releaseTruck({{ $item['trip']->id }})"
                                    wire:confirm="Release the truck and close trip {{ $item['trip']->trip_number }}?">
                                    Release truck
                                </x-filament::button>
                            @elseif ($item['action'] === 'lock')
                                {{-- the trip is locked only on the Trip page, when ready --}}
                                <x-filament::button size="sm" color="gray" outlined tag="a" icon="heroicon-m-lock-closed" :href="$this->tripPageUrl($item['trip']->id)">
                                    Open to lock
                                </x-filament::button>
                            @else
                                <x-filament::button size="sm" color="gray" outlined tag="a" :href="$this->tripUrl($item['trip']->id)">
                                    Open trip
                                </x-filament::button>
                            @endif
                        </li>
                    @endforeach
                </ul>
            </section>
        @endif

        {{-- Trends --}}
        <div class="ds-board__trends">
            <section class="ds-board__panel">
                <div class="ds-board__panel-head">
                    <h2>Boxes {{ $board->doneWord() }} per day</h2>
                    <span>Last 14 days</span>
                </div>
                <div class="ds-board__chart" role="img"
                     aria-label="Boxes {{ $board->doneWord() }} per day: {{ $days->map(fn ($d) => $d['date']->format('M j').' '.$d['boxes'])->join(', ') }}">
                    @foreach ($days as $day)
                        <span class="ds-board__col" title="{{ $day['date']->format('D, M j') }}: {{ $day['boxes'] }} boxes">
                            <span class="ds-board__col-n">{{ $day['boxes'] ?: '' }}</span>
                            <span @class(['ds-board__col-bar', 'is-today' => $day['date']->isToday(), 'is-zero' => ! $day['boxes']])
                                  style="height: {{ max(2, round($day['boxes'] / $dayMax * 120)) }}px"></span>
                            <span class="ds-board__col-day">{{ $day['date']->isToday() ? 'Today' : $day['date']->format('j') }}</span>
                        </span>
                    @endforeach
                </div>
            </section>

            <section class="ds-board__panel">
                <div class="ds-board__panel-head">
                    <h2>{{ $board->breakdownTitle() }}</h2>
                    <span>Last 7 days</span>
                </div>
                @forelse ($breakdown as $row)
                    <div class="ds-board__reason">
                        <span class="ds-board__reason-row"><span>{{ $row['label'] }}</span><strong>{{ $row['count'] }}</strong></span>
                        <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $board->isWarehouse() ? 'navy' : 'warn' }}" style="width: {{ round($row['count'] / $breakdownMax * 100) }}%"></span></span>
                    </div>
                @empty
                    <p class="ds-board__muted">{{ $board->isWarehouse() ? 'No boxes sent in the last 7 days.' : 'Every box was delivered on the first try this week.' }}</p>
                @endforelse
            </section>
        </div>
    </div>
</x-filament-widgets::widget>
