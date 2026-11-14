<x-filament-panels::page>
<div class="ds-help">
    @if ($guide)
        <div class="ds-help__bar">
            <button type="button" class="ds-help__back" wire:click="openGuide(null)"><span aria-hidden="true">‹</span> {{ $w['all'] }}</button>
            @include('filament.help._lang')
        </div>
        @include('filament.help._guide')
    @else
        <header class="ds-help__hero">
            <div>
                <h1>{{ $w['title'] }}</h1>
                <p>{{ $w['sub'] }}</p>
            </div>
            @include('filament.help._lang')
        </header>

        @include('filament.help._search')

        @if (trim($q) === '')
            <section @class(['ds-help__ai', 'is-off' => ! $aiOn])>
                <span class="ds-help__ai-icon" aria-hidden="true">✨</span>
                <div>
                    <strong>{{ $w['aiTitle'] }}</strong>
                    <p>{{ $aiOn ? $w['aiText'] : $w['aiOff'] }}</p>
                </div>
            </section>
            @include('filament.help._topics')
        @endif
    @endif
</div>
</x-filament-panels::page>
