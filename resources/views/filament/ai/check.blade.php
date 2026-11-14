<x-filament-panels::page>
<div class="ds-ai">
    @include('filament.ai.paused', ['paused' => $paused])

    <div class="ds-ai__bar">
        <div class="ds-ai__seg">
            @foreach (['today' => 'Today', 'week' => '7 days', 'month' => '30 days'] as $k => $l)
                <button type="button" wire:click="$set('period', '{{ $k }}')" @class(['is-on' => $period === $k])>{{ $l }}</button>
            @endforeach
        </div>
    </div>

    <div class="ds-ai__stats">
        <div><small>Photos checked</small><b>{{ number_format($stats['checked']) }}</b><em>{{ $stats['waiting'] ? number_format($stats['waiting']).' waiting' : 'none waiting' }}</em></div>
        <div><small>Flagged</small><b class="is-red">{{ number_format($stats['flagged']) }}</b><em>looked damaged, wet, open or blurry</em></div>
        <div><small>Worker said Good</small><b class="is-amber">{{ number_format($stats['missed']) }}</b><em>the AI disagrees</em></div>
        <div><small>Decided</small><b class="is-green">{{ number_format($stats['decided']) }} <span>of {{ number_format($stats['flagged']) }}</span></b><em>by your staff</em></div>
    </div>

    <div class="ds-ai__split">
        <section class="ds-ai__card ds-ai__list">
            <div class="ds-ai__card-head">
                <b>To look at</b>
                <div class="ds-ai__seg is-small">
                    @foreach (['open' => 'Not decided', 'missed' => 'Worker said Good', 'delivery' => 'Delivery photos', 'all' => 'All'] as $k => $l)
                        <button type="button" wire:click="$set('show', '{{ $k }}')" @class(['is-on' => $show === $k])>{{ $l }}</button>
                    @endforeach
                </div>
            </div>
            @forelse ($list as $c)
                <button type="button" wire:key="c-{{ $c->id }}" wire:click="pick({{ $c->id }})" @class(['ds-ai__row', 'is-sel' => $cur?->id === $c->id])>
                    <img src="{{ $c->url() }}" alt="" loading="lazy">
                    <span class="ds-ai__row-main">
                        <span><b>{{ $c->invoice ?? 'No box number' }}</b> <i class="ds-ai__tag is-{{ $c->verdict }}">{{ $c->label() }} · {{ $c->confidence }}%</i></span>
                        <span>{{ $c->note }}</span>
                        <small>{{ \App\Models\Ai\AiPhotoCheck::stepLabel($c->step) }} · {{ $c->created_at->format('M j g:i A') }}@if ($c->source === 'scan') · worker said {{ ucfirst($c->worker_said ?: 'good') }}@endif</small>
                    </span>
                    <span class="ds-ai__state is-{{ $c->decision ?? 'open' }}">{{ ['damaged' => 'Issue opened', 'fine' => 'Looks fine'][$c->decision] ?? 'To decide' }}</span>
                </button>
            @empty
                <p class="ds-ai__empty">Nothing here. {{ $stats['checked'] ? 'Every checked photo looks fine.' : 'Photos are checked as staff take them.' }}</p>
            @endforelse
        </section>

        @if ($cur)
            <section class="ds-ai__card ds-ai__detail" wire:key="sel-{{ $cur->id }}">
                <a href="{{ $cur->url() }}" target="_blank" rel="noopener" class="ds-ai__photo"><img src="{{ $cur->url() }}" alt="Photo of box {{ $cur->invoice }}"><span>{{ \App\Models\Ai\AiPhotoCheck::stepLabel($cur->step) }}</span></a>
                <div class="ds-ai__detail-head"><b>Box {{ $cur->invoice }}</b><small>{{ $cur->created_at->format('M j, g:i A') }}</small></div>
                <div class="ds-ai__said"><span class="ds-ai__badge">AI</span><span><b>{{ $cur->label() }} · {{ $cur->confidence }}% sure</b><small>{{ $cur->note ?: '—' }}</small></span></div>
                @if ($cur->source === 'scan')<p class="ds-board__muted">Worker marked it <b>{{ ucfirst($cur->worker_said ?: 'good') }}</b>.</p>@endif
                @if (! $cur->decision)
                    <div class="ds-ai__two">
                        <x-filament::button color="danger" wire:click="confirmDamaged">{{ $cur->source === 'delivery' ? 'Problem · open issue' : 'Damaged · open issue' }}</x-filament::button>
                        <x-filament::button color="gray" wire:click="looksFine">Looks fine</x-filament::button>
                    </div>
                @else
                    <p class="ds-ai__done is-{{ $cur->decision }}">
                        {{ $cur->decision === 'damaged' ? ($cur->invoiceissue_id ? 'Invoice Issue opened with this photo.' : 'Marked as damaged.') : 'Marked as fine.' }}
                        {{ $cur->decider?->full_name }} · {{ $cur->decided_at?->format('M j g:i A') }}
                        @unless ($cur->invoiceissue_id)<button type="button" wire:click="undoDecision" class="ds-ai__link">Undo</button>@endunless
                    </p>
                @endif
                <p class="ds-board__muted">The AI only suggests. Nothing changes until someone clicks.</p>
            </section>
        @endif
    </div>
</div>
</x-filament-panels::page>
