<x-filament-panels::page>
<div class="ds-fw">
    <div class="ds-fw__top">
        <p class="ds-board__muted">For Container and RoRo: where the truck takes the van, and where it arrives. Picked on each sea shipment.</p>
        {{ $this->newAction }}
    </div>
    <div class="ds-fw__ports">
        @forelse ($ports as $p)
            <button type="button" @class(['ds-fw__port', 'is-off' => ! $p->is_active]) wire:click="mountAction('edit', { id: {{ $p->id }} })" wire:key="pt-{{ $p->id }}">
                <b>{{ $p->name }}</b><small>{{ \App\Models\Shipping\Port::KINDS[$p->kind] ?? $p->kind }}{{ $p->address ? ' · '.$p->address : '' }}{{ $p->is_active ? '' : ' · off' }}</small>
            </button>
        @empty
            <p class="ds-board__muted">No ports yet. Press New port.</p>
        @endforelse
    </div>
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
