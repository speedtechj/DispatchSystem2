{{-- Search + "Ask in your own words". Needs: $w, $tries, $aiOn, $results, $answerGuide, $lang, $answer (Livewire) --}}
<form class="ds-help__search" wire:submit="ask">
    <span class="ds-help__search-icon" aria-hidden="true">
        <svg viewBox="0 0 20 20" width="18" height="18"><circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="m13 13 4.5 4.5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>
    </span>
    <input type="search" wire:model.live.debounce.300ms="q" placeholder="{{ $w['search'] }}" aria-label="{{ $w['search'] }}" autocomplete="off" enterkeyhint="search">
    @if (trim($q) !== '')
        <button type="button" class="ds-help__clear" wire:click="clearSearch" aria-label="{{ $w['clear'] }}">×</button>
    @endif
    <button type="submit" class="ds-help__ask" wire:loading.attr="disabled" wire:target="ask">
        <span wire:loading.remove wire:target="ask">{{ $aiOn ? '✨ ' : '' }}{{ $w['ask'] }}</span>
        <span wire:loading wire:target="ask">…</span>
    </button>
</form>

@if ($tries && trim($q) === '')
    <p class="ds-help__tries">
        <span>{{ $w['try'] }}</span>
        @foreach ($tries as $t)
            <button type="button" wire:click="ask(@js($t))">{{ $t }}</button>
        @endforeach
    </p>
@endif

@if ($answer)
    <section @class(['ds-help__answer', 'is-ai' => $answer['ai']]) aria-live="polite">
        <small>{{ $answer['ai'] ? '✨ '.$w['aiAnswer'] : $w['bestMatch'] }}</small>
        <p>{{ $answer['answer'] }}</p>
        @if ($answerGuide)
            <button type="button" class="ds-help__answer-open" wire:click="openGuide('{{ $answerGuide->slug }}')">
                {{ $w['open'] }}: {{ $answerGuide->t('title', $lang) }} <span aria-hidden="true">›</span>
            </button>
        @endif
    </section>
@endif

@if (trim($q) !== '')
    <section class="ds-help__results">
        <h3>{{ $w['results'] }}</h3>
        @forelse ($results as $r)
            @include('filament.help._row', ['r' => $r])
        @empty
            <p class="ds-help__muted">{{ $w['none'] }}</p>
        @endforelse
    </section>
@endif
