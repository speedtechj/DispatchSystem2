<x-filament-widgets::widget>
    <div class="ds-board" wire:poll.120s>
        <div class="ds-board__cards">
            @foreach ($cards as $card)
                <div class="ds-board__card ds-board__card--static">
                    <span class="ds-board__card-head">
                        <span>{{ $card['label'] }}</span>
                        <span class="ds-board__dot ds-board__dot--{{ $card['tone'] }}"></span>
                    </span>
                    <span @class(['ds-board__card-value', 'is-alert' => $card['alert'] ?? false])>{{ $card['value'] }}</span>
                    @if (($card['pct'] ?? null) !== null)
                        <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $card['tone'] }}" style="width: {{ $card['pct'] }}%"></span></span>
                    @endif
                    <span class="ds-board__card-sub">{{ $card['sub'] }}</span>
                </div>
            @endforeach
        </div>

        @if ($attention->isNotEmpty())
            <section class="ds-board__panel">
                <div class="ds-board__panel-head">
                    <h2>Needs attention</h2>
                    <span>{{ $attention->count() }} {{ Str::plural('item', $attention->count()) }}</span>
                </div>
                <ul class="ds-board__attention">
                    @foreach ($attention as $item)
                        <li>
                            <span class="ds-board__tag ds-board__tag--{{ $item['tone'] }}">{{ $item['tag'] }}</span>
                            <span class="ds-board__attention-text">
                                <strong>{{ $item['title'] }}</strong>
                                @if ($item['sub'] ?? null) <span class="ds-board__muted">· {{ $item['sub'] }}</span> @endif
                                <span class="ds-board__detail">{{ $item['detail'] }}</span>
                            </span>
                            <span class="ds-board__muted ds-board__truck">{{ $item['meta'] ?? '' }}</span>
                            @if ($item['url'] ?? null)
                                <x-filament::button size="sm" tag="a" :href="$item['url']" :color="($item['primary'] ?? false) ? 'primary' : 'gray'" :outlined="! ($item['primary'] ?? false)">
                                    {{ $item['action'] }}
                                </x-filament::button>
                            @else
                                <span></span>
                            @endif
                        </li>
                    @endforeach
                </ul>
            </section>
        @endif

        @if ($charts)
            <div @class(['ds-board__trends', 'ds-board__trends--even' => collect($charts)->every(fn ($c) => $c['type'] === 'bars')])>
                @foreach ($charts as $chart)
                    <section class="ds-board__panel">
                        <div class="ds-board__panel-head">
                            <h2>{{ $chart['title'] }}</h2>
                            <span>{{ $chart['note'] }}</span>
                        </div>

                        @if ($chart['type'] === 'days')
                            @php($max = max(1, $chart['rows']->max('boxes')))
                            <div class="ds-board__chart" role="img" aria-label="{{ $chart['title'] }}: {{ $chart['rows']->map(fn ($d) => $d['date']->format('M j').' '.$d['boxes'])->join(', ') }}">
                                @foreach ($chart['rows'] as $day)
                                    <span class="ds-board__col" title="{{ $day['date']->format('D, M j') }}: {{ $day['boxes'] }}">
                                        <span class="ds-board__col-n">{{ $day['boxes'] ?: '' }}</span>
                                        <span @class(['ds-board__col-bar', 'is-today' => $day['date']->isToday(), 'is-zero' => ! $day['boxes']]) style="height: {{ max(2, round($day['boxes'] / $max * 120)) }}px"></span>
                                        <span class="ds-board__col-day">{{ $day['date']->isToday() ? 'Today' : $day['date']->format('j') }}</span>
                                    </span>
                                @endforeach
                            </div>
                        @else
                            @php($max = max(1, $chart['rows']->max('count') ?? 0))
                            @forelse ($chart['rows'] as $row)
                                <div class="ds-board__reason">
                                    <span class="ds-board__reason-row"><span>{{ $row['label'] }}</span><strong>{{ number_format($row['count']) }}</strong></span>
                                    <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--{{ $chart['tone'] ?? 'navy' }}" style="width: {{ round($row['count'] / $max * 100) }}%"></span></span>
                                </div>
                            @empty
                                <p class="ds-board__muted">{{ $chart['empty'] }}</p>
                            @endforelse
                        @endif
                    </section>
                @endforeach
            </div>
        @endif

        @if ($openCount !== null || $photos->isNotEmpty())
            <section class="ds-board__panel">
                <div class="ds-board__panel-head">
                    <h2>{{ $photosTitle }}</h2>
                    <span>{{ $openCount !== null ? trans_choice('{0} None open|{1} 1 open, newest first|[2,*] :count open, newest first', $openCount, ['count' => $openCount]) : 'Newest first' }}</span>
                </div>

                @if ($photos->isEmpty())
                    <p class="ds-slider__empty">
                        <x-filament::icon icon="heroicon-m-check-circle" class="h-5 w-5" />
                        No open issues. Every reported box is resolved.
                    </p>
                @else
                    <div class="ds-slider"
                         wire:key="slider-{{ $photos->pluck('id')->join('-') }}"
                         x-data="{
                            index: 0,
                            count: {{ $photos->count() }},
                            perView: 4,
                            timer: null,
                            paused: false,
                            get last() { return Math.max(0, this.count - this.perView) },
                            init() {
                                this.measure();
                                window.addEventListener('resize', () => this.measure());
                                if (! window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
                                    this.timer = setInterval(() => { if (! this.paused && ! document.hidden) this.next(true) }, 4000);
                                }
                            },
                            destroy() { clearInterval(this.timer) },
                            measure() {
                                const w = this.$refs.viewport.clientWidth;
                                this.perView = w < 520 ? 1 : w < 820 ? 2 : w < 1100 ? 3 : 4;
                                this.index = Math.min(this.index, this.last);
                            },
                            next(auto = false) { this.index = this.index >= this.last ? 0 : this.index + 1 },
                            prev() { this.index = this.index <= 0 ? this.last : this.index - 1 },
                         }"
                         x-on:mouseenter="paused = true"
                         x-on:mouseleave="paused = false"
                         x-on:focusin="paused = true"
                         x-on:focusout="paused = false"
                         role="region"
                         aria-roledescription="carousel"
                         aria-label="{{ $photosTitle }}">
                        <div class="ds-slider__viewport" x-ref="viewport">
                            <div class="ds-slider__track" x-bind:style="`transform: translateX(-${index * (100 / perView)}%)`">
                                @foreach ($photos as $i => $photo)
                                    <figure class="ds-slider__slide" x-bind:style="`flex-basis: ${100 / perView}%`" wire:key="issue-{{ $photo['id'] }}"
                                            role="group" aria-roledescription="slide" aria-label="{{ $i + 1 }} of {{ $photos->count() }}">
                                        <div class="ds-slider__card">
                                            <div class="ds-slider__photo">
                                                @if ($photo['url'])
                                                    <a data-ds-photo href="{{ $photo['url'] }}" target="_blank" rel="noopener"><img src="{{ $photo['url'] }}" alt="Photo of {{ $photo['title'] }}" loading="lazy"></a>
                                                @else
                                                    <span class="ds-board__photo-none">No photo</span>
                                                @endif
                                                <span class="ds-board__tag ds-board__tag--warn">{{ $photo['label'] }}</span>
                                            </div>
                                            <figcaption>
                                                <strong>{{ $photo['title'] }}</strong>
                                                <span>{{ $photo['meta'] }}</span>
                                                @if ($photo['note'] ?? null)
                                                    <span class="ds-slider__note">{{ $photo['note'] }}</span>
                                                @endif
                                            </figcaption>
                                            @isset($photo['id'])
                                                <x-filament::button size="sm" color="success" outlined icon="heroicon-m-check"
                                                    wire:click="resolveIssue({{ $photo['id'] }})"
                                                    wire:confirm="Mark {{ $photo['title'] }} as resolved? It will leave the slider.">
                                                    Mark resolved
                                                </x-filament::button>
                                            @endisset
                                        </div>
                                    </figure>
                                @endforeach
                            </div>
                        </div>

                        <div class="ds-slider__controls" x-show="count > perView">
                            <button type="button" class="ds-slider__arrow" x-on:click="prev()" aria-label="Previous issues">
                                <x-filament::icon icon="heroicon-m-chevron-left" class="h-5 w-5" />
                            </button>
                            <span class="ds-slider__counter" x-show="last + 1 > 10" x-text="`${index + 1} / ${last + 1}`" aria-live="polite"></span>
                            <div class="ds-slider__dots" x-show="last + 1 <= 10">
                                <template x-for="n in last + 1" :key="n">
                                    <button type="button" class="ds-slider__dot" x-bind:class="{ 'is-active': n - 1 === index }"
                                            x-on:click="index = n - 1" x-bind:aria-label="`Go to slide ${n}`" x-bind:aria-current="n - 1 === index"></button>
                                </template>
                            </div>
                            <button type="button" class="ds-slider__arrow" x-on:click="next()" aria-label="Next issues">
                                <x-filament::icon icon="heroicon-m-chevron-right" class="h-5 w-5" />
                            </button>
                        </div>
                    </div>
                @endif
            </section>
        @endif
    </div>
</x-filament-widgets::widget>
