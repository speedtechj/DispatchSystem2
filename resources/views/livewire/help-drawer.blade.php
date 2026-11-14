{{-- The "?" help panel. Desktop: a panel on the right. Scan app and Driver app: the whole phone screen. --}}
<div x-data x-on:keydown.escape.window="$wire.open && $wire.close()">
    @if ($open)
        <div @class(['ds-help-drawer', 'is-phone' => $phone]) role="dialog" aria-modal="true" aria-label="{{ $w['help'] }}">
            @unless ($phone)
                <button type="button" class="ds-help-drawer__shade" wire:click="close" aria-label="{{ $w['close'] }}"></button>
            @endunless
            <div class="ds-help-drawer__panel ds-help">
                <div class="ds-help__bar">
                    @if ($guide)
                        <button type="button" class="ds-help__back" wire:click="back"><span aria-hidden="true">‹</span> {{ $w['back'] }}</button>
                    @else
                        <strong class="ds-help__bar-title">{{ $w['help'] }}</strong>
                    @endif
                    @include('filament.help._lang')
                    <button type="button" class="ds-help__x" wire:click="close" aria-label="{{ $w['close'] }}">×</button>
                </div>

                @if ($guide)
                    @include('filament.help._guide')
                @else
                    @include('filament.help._search')
                    @if (trim($q) === '')
                        @if ($pageGuides->isNotEmpty())
                            <section class="ds-help__results">
                                <h3>{{ $w['thisPage'] }}</h3>
                                @foreach ($pageGuides as $r)
                                    @include('filament.help._row', ['r' => $r])
                                @endforeach
                            </section>
                        @endif
                        @if ($phone || $pageGuides->isEmpty())
                            @include('filament.help._topics')
                        @endif
                    @endif
                @endif

                @if ($centerUrl && ! $phone)
                    <a class="ds-help__center-link" href="{{ $centerUrl }}">{{ $w['center'] }} <span aria-hidden="true">›</span></a>
                @endif
            </div>
        </div>
    @endif
</div>
