<x-filament-panels::page>
    <div class="ds-co">
        @forelse ($groups as $group)
            <section class="ds-board__panel ds-co__group is-{{ $group['reason']->getColor() }}" wire:key="group-{{ $group['reason']->value }}">
                <div class="ds-co__group-head">
                    <h2>{{ $group['reason']->getLabel() }} <span>· {{ $group['boxes']->count() }} {{ str('box')->plural($group['boxes']->count()) }}</span></h2>
                    <span class="ds-co__tip">💡 {{ \App\Support\HubDesk::retryTip($group['reason']) }}</span>
                    {{ ($this->moveAllAction)(['reason' => $group['reason']->value]) }}
                </div>
                @foreach ($group['boxes'] as $box)
                    <div class="ds-co__retry" wire:key="retry-{{ $box['id'] }}">
                        <strong>{{ $box['invoice'] }}</strong>
                        <span>{{ $box['receiver'] }}</span>
                        <span class="ds-board__muted">{{ $box['area'] }}</span>
                        <span @class(['ds-co__tries', 'is-bad' => $box['tries'] >= 3])>{{ $box['tries'] }}{{ match ($box['tries']) { 1 => 'st', 2 => 'nd', 3 => 'rd', default => 'th' } }} try</span>
                        <span class="ds-board__muted">{{ $box['trip'] ? 'On '.$box['trip'] : 'Not on a trip' }}</span>
                        <span class="ds-co__retry-actions">
                            {{ ($this->moveAction)(['box' => $box['id']]) }}
                            {{ ($this->returnAction)(['box' => $box['id']]) }}
                        </span>
                    </div>
                @endforeach
            </section>
        @empty
            <div class="ds-co__empty">
                <x-filament::icon icon="heroicon-o-check-badge" class="h-8 w-8" />
                <strong>Nothing to retry</strong>
                <span>Every box your drivers tried was delivered, or has been returned.</span>
            </div>
        @endforelse
        @if ($groups->isNotEmpty())
            <p class="ds-board__muted">Boxes on their 3rd try or more are shown in red.</p>
        @endif
    </div>

    <x-filament-actions::modals />
</x-filament-panels::page>
