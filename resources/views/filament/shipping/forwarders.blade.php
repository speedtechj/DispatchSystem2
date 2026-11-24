<x-filament-panels::page>
<div class="ds-fw">
    <div class="ds-fw__top">
        <p class="ds-board__muted">Companies that carry LCL boxes, and their branches. Used when you send a sea shipment as LCL.</p>
        {{ $this->newAction }}
    </div>
    <div class="ds-fw__grid">
        @forelse ($forwarders as $f)
            <section @class(['ds-fw__card', 'is-off' => ! $f->is_active]) wire:key="fw-{{ $f->id }}">
                <header>
                    <span class="ds-fw__ini">{{ mb_strtoupper(mb_substr($f->name, 0, 2)) }}</span>
                    <span><b>{{ $f->name }}</b><small>{{ collect([$f->charge_basis ? ($charges[$f->charge_basis] ?? $f->charge_basis).($f->charge_rate ? ' · ₱'.number_format($f->charge_rate, 2) : '') : null, $f->branches->count().' '.\Illuminate\Support\Str::plural('branch', $f->branches->count())])->filter()->join(' · ') }}</small></span>
                    <i @class(['ds-fw__state', 'is-on' => $f->is_active])>{{ $f->is_active ? 'Active' : 'Off' }}</i>
                </header>
                @foreach ($f->branches as $b)
                    <div class="ds-fw__branch">
                        <b>{{ $b->name }}</b><small>{{ $b->hours }}</small>
                        <small>{{ $b->address }}</small><small>{{ $b->phone }}</small>
                    </div>
                @endforeach
                <footer><small>{{ ($used[$f->id] ?? 0) ? 'Used on '.$used[$f->id].' '.\Illuminate\Support\Str::plural('shipment', $used[$f->id]) : 'Not used yet' }}</small>
                    <button type="button" class="ds-fu__link" wire:click="mountAction('edit', { id: {{ $f->id }} })">Edit · add branch</button></footer>
            </section>
        @empty
            <p class="ds-board__muted">No forwarders yet. Press New forwarder.</p>
        @endforelse
    </div>
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
