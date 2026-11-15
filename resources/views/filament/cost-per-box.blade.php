@php
    $peso = fn ($n, $d = 2) => '₱'.number_format((float) $n, $d);
@endphp
<x-filament-panels::page>
<div class="ds-sp">
    <div class="ds-sp__head">
        <select wire:model.live="month" aria-label="Month">@foreach ($months as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
        <span class="ds-board__muted">Fuel of each hub's trucks + sea shipments to the hub, divided by the boxes the hub delivered.</span>
    </div>
    <div class="ds-sp__nums4">
        <span><small>Boxes delivered</small><b class="num">{{ number_format($all['boxes']) }}</b></span>
        <span><small>Fuel</small><b class="num">{{ $peso($all['fuel'], 0) }}</b></span>
        <span><small>Sea shipping</small><b class="num">{{ $peso($all['sea'], 0) }}</b></span>
        <span><small>Per box, all hubs</small><b class="num">{{ $all['boxes'] ? $peso($all['total'] / $all['boxes']) : '—' }}</b></span>
    </div>
    <section class="ds-board__panel ds-sp__table">
        <div class="ds-sp__tr is-cost is-head"><span>Hub</span><span>Boxes delivered</span><span>Fuel</span><span>Sea shipping</span><span>Per box</span></div>
        @forelse ($rows as $r)
            <div class="ds-sp__tr is-cost">
                <span><b>{{ $r['hub']->hub_name }}</b><small>{{ $r['hub']->is_company ? 'Partner hub' : 'Main hub' }}</small></span>
                <span class="num">{{ number_format($r['boxes']) }}</span>
                <span><span class="num">{{ $peso($r['fuel'], 0) }}</span><small>{{ $r['fuelPerBox'] ? $peso($r['fuelPerBox']).' per box' : '' }}</small></span>
                <span><span class="num">{{ $r['sea'] ? $peso($r['sea'], 0) : '—' }}</span><small>{{ $r['seaPerBox'] ? $peso($r['seaPerBox']).' per box' : '' }}</small></span>
                <span><b class="num">{{ $r['perBox'] ? $peso($r['perBox']) : '—' }}</b></span>
            </div>
        @empty
            <p class="ds-board__muted ds-sp__pad">No deliveries or costs this month.</p>
        @endforelse
    </section>
    <div class="ds-sp__grid">
        <section class="ds-board__panel ds-sp__box">
            <h3>Container vs RoRo · last 6 months</h3>
            @forelse ($modes as $mode => $m)
                <p class="ds-sp__perbox"><span>{{ $mode === 'roro' ? 'RoRo' : 'Container' }} <small class="ds-board__muted">{{ $m['shipments'] }} shipments · {{ number_format($m['boxes']) }} boxes</small></span><b class="num">{{ $m['perBox'] ? $peso($m['perBox']) : '—' }}</b></p>
            @empty
                <p class="ds-board__muted">No sea shipments with a cost yet.</p>
            @endforelse
            <p class="ds-board__muted">Per box shipped. Type the costs on each sea shipment so this is right.</p>
        </section>
        <section class="ds-board__panel ds-sp__box">
            <h3>Sea shipments this month</h3>
            @forelse ($shipments as $s)
                <span class="ds-sp__barrow is-plain"><span>{{ $s->code }} → {{ $s->hub?->hub_name }}</span><span class="ds-board__muted">{{ $s->mode === 'roro' ? 'RoRo' : 'Container' }}</span><b class="num">{{ $s->cost() ? $peso($s->cost(), 0) : '—' }}</b></span>
            @empty
                <p class="ds-board__muted">None.</p>
            @endforelse
        </section>
    </div>
</div>
</x-filament-panels::page>
