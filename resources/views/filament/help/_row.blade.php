<button type="button" class="ds-help__row" wire:click="openGuide('{{ $r->slug }}')" wire:key="row-{{ $r->slug }}">
    <span class="ds-help__row-icon" aria-hidden="true">{{ $r->icon ?: '📘' }}</span>
    <span class="ds-help__row-text">
        <strong>{{ $r->t('title', $lang) }}</strong>
        <small>{{ $r->t('summary', $lang) }}</small>
    </span>
    <span class="ds-help__row-n">{{ count($r->steps ?? []) }} {{ $w['steps'] }}</span>
    <span class="ds-help__chev" aria-hidden="true">›</span>
</button>
