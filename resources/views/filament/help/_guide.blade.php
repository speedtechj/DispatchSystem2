{{-- One guide. Needs: $guide, $lang, $w, $related, $doIt, $voted --}}
@php($steps = $guide->stepsIn($lang))
@php($problems = $guide->problemsIn($lang))
<article class="ds-help__guide" wire:key="guide-{{ $guide->slug }}-{{ $lang }}">
    <header class="ds-help__ghead">
        <span class="ds-help__gicon" aria-hidden="true">{{ $guide->icon ?: '📘' }}</span>
        <div>
            <h2>{{ $guide->t('title', $lang) }}</h2>
            <p>{{ $guide->t('summary', $lang) }}</p>
        </div>
        @if ($doIt)
            <a class="ds-help__doit" href="{{ $doIt }}">{{ $w['doIt'] }} <span aria-hidden="true">›</span></a>
        @endif
    </header>

    @if ($guide->t('when', $lang))
        <p class="ds-help__when"><strong>{{ $w['when'] }}</strong> {{ $guide->t('when', $lang) }}</p>
    @endif

    <ol class="ds-help__steps">
        @foreach ($steps as $i => $s)
            <li>
                <span class="ds-help__n" aria-hidden="true">{{ $i + 1 }}</span>
                <div>
                    <strong>{{ $s['title'] }}</strong>
                    <p>{{ $s['text'] }}</p>
                    @if ($s['image'])
                        <a href="{{ $s['image'] }}" target="_blank" rel="noopener" class="ds-help__shot"><img src="{{ $s['image'] }}" alt="{{ $s['title'] }}" loading="lazy"></a>
                    @endif
                </div>
            </li>
        @endforeach
    </ol>

    @if ($guide->t('result', $lang))
        <p class="ds-help__result"><strong>✓ {{ $w['result'] }}</strong> {{ $guide->t('result', $lang) }}</p>
    @endif

    @if ($problems)
        <section class="ds-help__problems">
            <h3>{{ $w['problems'] }}</h3>
            @foreach ($problems as $p)
                <details>
                    <summary>{{ $p['q'] }}</summary>
                    <p>{{ $p['a'] }}</p>
                </details>
            @endforeach
        </section>
    @endif

    @if ($related->isNotEmpty())
        <section class="ds-help__related">
            <h3>{{ $w['related'] }}</h3>
            @foreach ($related as $r)
                @include('filament.help._row', ['r' => $r])
            @endforeach
        </section>
    @endif

    <footer class="ds-help__vote">
        @if ($voted === null)
            <span>{{ $w['helpful'] }}</span>
            <button type="button" wire:click="vote(true)">👍 {{ $w['yes'] }}</button>
            <button type="button" wire:click="vote(false)">👎 {{ $w['no'] }}</button>
        @else
            <span>{{ $w['thanks'] }}</span>
        @endif
    </footer>
</article>
