<div class="ds-help__topics">
    @foreach ($topics as $t)
        <section class="ds-help__topic" wire:key="topic-{{ $t['key'] }}">
            <h3><span aria-hidden="true">{{ $t['icon'] }}</span> {{ $t['name'] }} <small>{{ $t['guides']->count() }}</small></h3>
            <ul>
                @foreach ($t['guides'] as $tg)
                    <li><button type="button" wire:click="openGuide('{{ $tg->slug }}')">{{ $tg->t('title', $lang) }}</button></li>
                @endforeach
            </ul>
        </section>
    @endforeach
</div>
