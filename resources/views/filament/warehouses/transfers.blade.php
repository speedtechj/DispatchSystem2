<x-filament-panels::page>
<div class="ds-fl ds-wc">
    <div class="ds-ad__top">
        <span class="ds-te__title"><h1>Transfers from {{ $hereName }}</h1><small>Only boxes that the other warehouse delivers. Each transfer takes only its own provinces.</small></span>
        @if ($canSwitch && $warehouses->count() > 1)
            <span class="ds-fl__seg">@foreach ($warehouses as $w)<button type="button" wire:click="setHere({{ $w->id }})" @class(['is-on' => (int) $here === $w->id])>At {{ $w->name }}</button>@endforeach</span>
        @endif
    </div>
    @unless ($active)
        <span class="ds-ad__pending"><span>Set which warehouse delivers each province first (Settings → Warehouse coverage).</span></span>
    @endunless
    <div class="ds-wc__tgrid">
        <div class="ds-ad__col">
            @foreach ($made as $dest => $num)
                <span class="ds-pt__made">✓ Transfer {{ $num }} to {{ \App\Support\Warehouses\Coverage::name((int) $dest) }} created. Load it with “Load transfer truck”.</span>
            @endforeach
            @forelse ($groups as $g)
                <section class="ds-cb__card ds-ad__card" wire:key="g-{{ $g['dest'] }}">
                    <span class="ds-pt__lhead"><b>{{ $hereName }} → {{ $g['name'] }}</b><small>{{ $g['total'] }} {{ Str::plural('box', $g['total']) }} · {{ $g['rows']->count() }} {{ Str::plural('province', $g['rows']->count()) }}</small></span>
                    @foreach ($g['rows'] as $r)
                        <span class="ds-wc__prow"><span class="ds-pt__lhead"><b>{{ $r['name'] }}</b><small>{{ $r['n'] }} boxes · oldest {{ $r['days'] ? $r['days'].' '.Str::plural('day', $r['days']) : 'today' }}</small></span><span class="ds-pt__bar"><i style="width: {{ round($r['n'] / $g['max'] * 100) }}%; background: #1d6fb8"></i></span></span>
                    @endforeach
                    <span class="ds-pt__sum">
                            <span><b>Transfer all {{ $g['total'] }} to {{ $g['name'] }}</b>
                                <span class="ds-wc__pick">
                                    <select wire:model="truck.{{ $g['dest'] }}" class="ds-wc__sel" aria-label="Truck">@forelse ($trucks as $t)<option value="{{ $t->id }}">{{ $t->plate_no }} · {{ \App\Support\TruckSpace::usable($t) }} space</option>@empty<option value="">No free truck</option>@endforelse</select>
                                    <input type="date" wire:model="date" class="ds-wc__sel" aria-label="Leaves on">
                                </span>
                            </span>
                            <button type="button" wire:click="create({{ $g['dest'] }})" @disabled($trucks->isEmpty())>Create transfer</button>
                        </span>
                </section>
            @empty
                <p class="ds-cb__card ds-cb__muted">{{ $active ? 'No boxes here belong to another warehouse.' : 'Nothing yet.' }}</p>
            @endforelse
        </div>
        <div class="ds-ad__col">
            <section class="ds-wc__stop">
                <b>⛔ Wrong boxes are stopped</b>
                <span>At “Load transfer truck”, a box that this warehouse delivers is not loaded: “Not for {{ $groups->first()['name'] ?? 'the other warehouse' }}: it is delivered from {{ $hereName }}.” The office can still load it with a reason.</span>
            </section>
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">When it arrives</b>
                <span class="ds-te__hint">The other warehouse scans the boxes in (Receive transfer truck). They show in its Plan trips by city, ready for delivery.</span>
            </section>
            @if ($onTheWay->isNotEmpty())
                <section class="ds-cb__card ds-ad__card">
                    <b class="ds-ad__h">On the way</b>
                    @foreach ($onTheWay as $x)<span class="ds-pt__un"><span>{{ $x['t']->trip_number }} → {{ $x['t']->warehouse?->name }}</span><b>{{ $x['left'] }} of {{ $x['n'] }} not received</b></span>@endforeach
                </section>
            @endif
        </div>
    </div>
</div>
</x-filament-panels::page>
