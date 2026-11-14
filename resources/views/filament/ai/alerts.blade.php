<x-filament-panels::page>
<div class="ds-ai">
    <div class="ds-ai__bar">
        <div class="ds-ai__seg">
            @foreach ($kinds as $k => $l)
                <button type="button" wire:click="$set('kind', '{{ $k }}')" @class(['is-on' => $kind === $k])>{{ $l }}@php($n = $k === '' ? $counts->sum() : ($counts[$k] ?? 0))@if ($n) <i>{{ $n }}</i>@endif</button>
            @endforeach
        </div>
        <div class="ds-ai__seg is-small">
            <button type="button" wire:click="$set('status', 'open')" @class(['is-on' => $status === 'open'])>Open</button>
            <button type="button" wire:click="$set('status', 'done')" @class(['is-on' => $status !== 'open'])>Handled</button>
            <button type="button" wire:click="checkNow" wire:loading.attr="disabled">Check now</button>
        </div>
    </div>
    <section class="ds-ai__card">
        @forelse ($list as $a)
            <div class="ds-ai__alert is-{{ $a->severity }}" wire:key="a-{{ $a->id }}">
                <span class="ds-ai__alert-ic">{{ ['drivers' => '⏱', 'warehouse' => '📦', 'trips' => '🚚', 'customers' => '☎'][$a->kind] ?? '!' }}</span>
                <span class="ds-ai__row-main">
                    <span><b>{{ $a->title }}</b> <small>{{ $a->updated_at->diffForHumans() }}</small></span>
                    <span>{{ $a->body }}</span>
                    @if ($a->link)<a href="{{ $panelUrl.'/'.$a->link }}" class="ds-ai__link">Open photos and history ›</a>@endif
                </span>
                <span class="ds-ai__alert-act">
                    @if ($a->status === 'open')
                        <x-filament::button size="sm" wire:click="handle({{ $a->id }}, 'checked')">Checked</x-filament::button>
                        <x-filament::button size="sm" color="gray" wire:click="handle({{ $a->id }}, 'ignored')">Normal, ignore</x-filament::button>
                    @else
                        <small>{{ $a->status === 'checked' ? 'Checked' : 'Ignored' }} {{ $a->handled_at?->format('M j g:i A') }}</small>
                        <button type="button" class="ds-ai__link" wire:click="handle({{ $a->id }}, 'open')">Reopen</button>
                    @endif
                </span>
            </div>
        @empty
            <p class="ds-ai__empty">{{ $status === 'open' ? 'No open alerts. Checks run every 15 minutes.' : 'Nothing handled yet.' }}</p>
        @endforelse
    </section>
</div>
</x-filament-panels::page>
