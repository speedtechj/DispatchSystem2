<x-filament-panels::page>
    {{-- Refresh every minute so new boxes and deliveries show without reloading. --}}
    <div wire:poll.60s class="ds-driver">

        @if (! $trip)
            {{-- Not on a trip --}}
            <section class="ds-driver__empty">
                <span class="ds-driver__empty-icon"><x-filament::icon icon="heroicon-o-truck" class="h-9 w-9" /></span>
                <h2>You're not on a trip right now</h2>
                <p>Ask your dispatcher to add you to a truck. Your boxes will show here as soon as the trip is loaded.</p>
                <x-filament::button wire:click="$refresh" icon="heroicon-m-arrow-path" color="gray" size="lg">
                    Check again
                </x-filament::button>
            </section>

        @elseif ($finished)
            {{-- All delivered --}}
            <section class="ds-driver__trip ds-driver__trip--done">
                <x-filament::icon icon="heroicon-o-check-circle" class="h-12 w-12" />
                <p class="ds-driver__done-title">All {{ $progress['total'] }} boxes delivered</p>
                <p class="ds-driver__done-sub">Trip {{ $trip->trip_number }} · {{ $trip->truck?->plate_no }}</p>
                <div class="ds-driver__bar"><span style="width: 100%"></span></div>
            </section>

            <section class="ds-driver__card">
                <h2>What's next</h2>
                <p>Drive back to the hub. Your dispatcher will close the trip and free the truck.</p>
            </section>

        @else
            {{-- Today's trip --}}
            <section class="ds-driver__trip" aria-label="Today's trip">
                <div class="ds-driver__trip-head">
                    <div>
                        <span class="ds-driver__muted">Trip</span>
                        <span class="ds-driver__trip-no">{{ $trip->trip_number }}</span>
                    </div>
                    <span class="ds-driver__pill">{{ $trip->is_current ? 'On the road' : 'Loading' }}</span>
                </div>

                <div class="ds-driver__trip-grid">
                    <div>
                        <span class="ds-driver__muted">Truck</span>
                        <strong>{{ $trip->truck?->plate_no ?? '—' }}</strong>
                        <span class="ds-driver__soft">{{ $trip->truck?->description }}</span>
                    </div>
                    <div>
                        <span class="ds-driver__muted">With you</span>
                        @forelse ($crew as $mate)
                            <strong>{{ $mate['name'] }}</strong>
                            <span class="ds-driver__soft">{{ $mate['role'] }}</span>
                        @empty
                            <strong>Just you</strong>
                        @endforelse
                    </div>
                </div>

                <div class="ds-driver__progress">
                    <div class="ds-driver__progress-head">
                        <span><strong>{{ $progress['delivered'] }}</strong> of {{ $progress['total'] }} delivered</span>
                        <span class="ds-driver__left">{{ $progress['left'] }} left</span>
                    </div>
                    <div class="ds-driver__bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="{{ $progress['percent'] }}">
                        <span style="width: {{ $progress['percent'] }}%"></span>
                    </div>
                    @if ($progress['notDelivered'])
                        <p class="ds-driver__warn">{{ $progress['notDelivered'] }} not delivered yet — check “My deliveries” for the reasons.</p>
                    @endif
                </div>
            </section>

            <div class="ds-driver__actions">
                <a href="{{ $deliveriesUrl }}" class="ds-driver__action ds-driver__action--primary">
                    <x-filament::icon icon="heroicon-o-qr-code" class="h-6 w-6" />
                    Scan a box
                </a>
                <a href="{{ $deliveriesUrl }}" class="ds-driver__action">
                    <x-filament::icon icon="heroicon-o-list-bullet" class="h-6 w-6" />
                    All boxes
                </a>
            </div>

            @if ($priority->isNotEmpty())
                <section class="ds-driver__section">
                    <h2>Priority boxes <span class="ds-driver__count">{{ $priority->count() }}</span></h2>
                    @foreach ($priority as $stop)
                        <x-driver.stop :stop="$stop" tone="priority" />
                    @endforeach
                </section>
            @endif

            @if ($areas->isNotEmpty())
                <section class="ds-driver__section" x-data="{ open: @js($areas->first()['key']) }">
                    <div class="ds-driver__section-head">
                        <h2>Where to go next</h2>
                        <span class="ds-driver__soft">{{ $areas->sum('boxes') }} boxes · {{ $areas->sum(fn ($a) => $a['stops']->count()) }} stops</span>
                    </div>
                    <div class="ds-driver__areas">
                        @foreach ($areas as $area)
                            <div class="ds-driver__area">
                                <button type="button" class="ds-driver__area-btn"
                                        x-on:click="open = open === @js($area['key']) ? null : @js($area['key'])"
                                        x-bind:aria-expanded="open === @js($area['key'])">
                                    <span class="ds-driver__area-name">
                                        <strong>{{ $area['city'] }}</strong>
                                        @if ($area['barangay'])
                                            <span>{{ $area['barangay'] }}</span>
                                        @endif
                                    </span>
                                    <span class="ds-driver__area-count">
                                        <strong>{{ $area['boxes'] }}</strong>
                                        <span>{{ trans_choice('{1} 1 stop|[2,*] :count stops', $area['stops']->count(), ['count' => $area['stops']->count()]) }}</span>
                                    </span>
                                    <x-filament::icon icon="heroicon-m-chevron-down" class="ds-driver__chev h-5 w-5" x-bind:class="{ 'is-open': open === @js($area['key']) }" />
                                </button>
                                <div x-show="open === @js($area['key'])" x-collapse class="ds-driver__stops">
                                    @foreach ($area['stops'] as $stop)
                                        <x-driver.stop :stop="$stop" tone="soft" />
                                    @endforeach
                                </div>
                            </div>
                        @endforeach
                    </div>
                </section>
            @endif

            @if ($problems->isNotEmpty())
                <section class="ds-driver__section">
                    <h2>Check before handing over</h2>
                    @foreach ($problems as $stop)
                        <x-driver.stop :stop="$stop" tone="problem" :label="$stop['issue']">
                            @if ($stop['remarks'])
                                <span class="ds-stop__remark">{{ $stop['remarks'] }}</span>
                            @endif
                        </x-driver.stop>
                    @endforeach
                </section>
            @endif
        @endif

        @if ($trip && $delivered->isNotEmpty())
            <section class="ds-driver__section">
                <h2>Delivered today</h2>
                <p class="ds-driver__soft">You can undo your own delivery for 30 minutes. After that, ask the office.</p>
                <div class="ds-driver__list">
                    @foreach ($delivered as $box)
                        <div class="ds-driver__done-row">
                            @if ($box['photo'])
                                <a href="{{ $box['photo'] }}" target="_blank" rel="noopener"><img src="{{ $box['photo'] }}" alt="Delivery photo for {{ $box['invoice'] }}"></a>
                            @else
                                <span class="ds-driver__nophoto" aria-hidden="true"><x-filament::icon icon="heroicon-o-camera" class="h-5 w-5" /></span>
                            @endif
                            <span class="ds-driver__done-text">
                                <strong>{{ $box['invoice'] }}</strong>
                                <span>{{ $box['name'] }}</span>
                            </span>
                            <span class="ds-driver__done-when">
                                <span class="ds-driver__ok">Delivered {{ $box['time'] }}</span>
                                @if ($box['undoMinutesLeft'])
                                    <span class="ds-driver__undo">
                                        {{ ($this->undoDeliveryAction)(['tripinvoice' => $box['id']]) }}
                                        <span>{{ $box['undoMinutesLeft'] }} min left</span>
                                    </span>
                                @else
                                    <span class="ds-driver__locked">
                                        <x-filament::icon icon="heroicon-m-lock-closed" class="h-3.5 w-3.5" /> Office only
                                    </span>
                                @endif
                            </span>
                        </div>
                    @endforeach
                </div>
            </section>
        @endif
    </div>
</x-filament-panels::page>
