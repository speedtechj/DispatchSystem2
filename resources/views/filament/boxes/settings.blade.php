@php($fmt = fn ($n) => \App\Support\BoxSizes::fmt((float) $n))
<x-filament-panels::page>
<div class="ds-bx">
    <header class="ds-bx__head">
        <p>The box types below come from your manifests. Your normal box is <b>1</b>; set the others next to it. Trucks are then filled by space, not by count. Changes are saved right away.</p>
        <button type="button" wire:click="toggle" @class(['ds-bx__switch', 'is-on' => $on]) aria-pressed="{{ $on ? 'true' : 'false' }}">
            <i aria-hidden="true"></i>{{ $on ? 'Plan trips by space: on' : 'Plan trips by space: off (count boxes)' }}
        </button>
    </header>
    @if ($on && ! $working)
        <p class="ds-bx__note">Every box type is still 1, so trucks are counted in boxes. Set a bigger or smaller type below and trips are planned by space.</p>
    @endif

    <div class="ds-bx__two">
        <section class="ds-board__panel ds-bx__types">
            <div class="ds-board__panel-head"><h2>Box types from your manifests</h2><span class="ds-board__muted">Last 30 days</span></div>
            @forelse ($sizes as $s)
                <div wire:key="size-{{ $s->id }}" @class(['ds-bx__type', 'is-new' => ! $s->is_set])>
                    <span class="ds-bx__name">
                        <span><b>{{ $s->name }}</b>
                            @if ($s->is_base)<em class="ds-bx__tag is-base">Normal box = 1</em>@endif
                            @unless ($s->is_set)<em class="ds-bx__tag is-new">New · not set</em>@endunless
                        </span>
                        <small>{{ number_format($counts30[$s->id] ?? 0) }} {{ str('box')->plural($counts30[$s->id] ?? 0) }}@if (($countsAll[$s->id] ?? 0) !== ($counts30[$s->id] ?? 0)) ({{ number_format($countsAll[$s->id] ?? 0) }} in all)@endif
                            @if ($written[$s->id] ?? null)· written as {{ implode(' · ', $written[$s->id]) }}@endif</small>
                        @if ($dimsOn)
                            <span class="ds-bx__dims">
                                <input type="number" min="1" max="999" placeholder="L" value="{{ $s->length_cm }}" wire:change="setDim({{ $s->id }}, 'length_cm', $event.target.value)" aria-label="Length cm">×
                                <input type="number" min="1" max="999" placeholder="W" value="{{ $s->width_cm }}" wire:change="setDim({{ $s->id }}, 'width_cm', $event.target.value)" aria-label="Width cm">×
                                <input type="number" min="1" max="999" placeholder="H" value="{{ $s->height_cm }}" wire:change="setDim({{ $s->id }}, 'height_cm', $event.target.value)" aria-label="Height cm"> cm
                                @if (! $s->is_base && ($fd = \App\Support\TruckSpace::spaceFromDims($s)) && abs($fd - (float) $s->space) >= 0.25)
                                    <button type="button" wire:click="useDims({{ $s->id }})">From the size: {{ $fmt($fd) }} · use it</button>
                                @endif
                            </span>
                        @endif
                        @unless ($s->is_base)
                            <span class="ds-bx__links">
                                @unless ($s->is_set)<button type="button" wire:click="confirm({{ $s->id }})">Keep at 1</button>@endunless
                                <button type="button" wire:click="makeBase({{ $s->id }})" wire:confirm="Make {{ $s->name }} your normal box (1)? The other sizes are changed to stay the same real size.">Make this the normal box</button>
                            </span>
                        @endunless
                    </span>
                    <span class="ds-bx__step">
                        @if ($s->is_base)
                            <b>1</b>
                        @else
                            <button type="button" wire:click="step({{ $s->id }}, -1)" aria-label="Smaller">−</button>
                            <b>{{ $s->is_set ? $fmt($s->space) : '1?' }}</b>
                            <button type="button" wire:click="step({{ $s->id }}, 1)" aria-label="Bigger">+</button>
                        @endif
                    </span>
                    <span class="ds-bx__pic" aria-hidden="true"><i style="width: {{ round(14 + ($s->is_set ? $s->space : 1) * 15) }}px; height: {{ round(10 + ($s->is_set ? $s->space : 1) * 11) }}px"></i></span>
                </div>
            @empty
                <p class="ds-board__muted">No box types on your invoices yet. They show up here after a manifest is imported.</p>
            @endforelse
            <div class="ds-bx__type is-plain">
                <span class="ds-bx__name"><span><b>No box type on the manifest</b></span><small>{{ number_format($noType) }} {{ str('box')->plural($noType) }} · counts as your normal box</small></span>
                <span class="ds-bx__step"><b>1</b></span><span></span>
            </div>
        </section>

        <div class="ds-bx__side">
            @if ($pairs->isNotEmpty())
                <section class="ds-board__panel ds-bx__same">
                    <div class="ds-board__panel-head"><h2>These look like the same box</h2></div>
                    @foreach ($pairs as $p)
                        <div wire:key="pair-{{ $p['from']->id }}-{{ $p['into']->id }}">
                            <span><span>“{{ $p['from']->name }}” ({{ number_format($countsAll[$p['from']->id] ?? 0) }}) looks like <b>{{ $p['into']->name }}</b></span><small>{{ $p['why'] }}</small></span>
                            <x-filament::button size="sm" wire:click="join({{ $p['from']->id }}, {{ $p['into']->id }})">Join</x-filament::button>
                            <x-filament::button size="sm" color="gray" wire:click="keepApart({{ $p['from']->id }}, {{ $p['into']->id }})">Keep apart</x-filament::button>
                        </div>
                    @endforeach
                </section>
            @endif
            @if ($aiOn && $sizes->count() > 1)
                <button type="button" class="ds-bx__ai" wire:click="askAi" wire:loading.attr="disabled" wire:target="askAi">
                    <span wire:loading.remove wire:target="askAi">✨ {{ $aiChecked ? 'Ask the AI again' : 'Ask the AI to find more look-alikes' }}</span>
                    <span wire:loading wire:target="askAi">Checking…</span>
                </button>
            @endif

            <section class="ds-board__panel ds-bx__trucks">
                <div class="ds-board__panel-head"><h2>Truck space</h2><span class="ds-board__muted">In normal boxes{{ isset($base) ? ' ('.$base->name.')' : '' }}</span></div>
                @forelse ($trucks as $t)
                    @php($cap = (int) ($t->capacity ?: 50))
                    <div wire:key="truck-{{ $t->id }}">
                        <span>
                            <b>{{ $t->plate_no }}</b> <small>{{ $t->description ?: $t->category }}{{ ($hubs[$t->logistichub_id] ?? null) ? ' · '.$hubs[$t->logistichub_id] : '' }}{{ $t->capacity ? '' : ' · not set, 50 is used' }}</small>
                            <small>= {{ collect([$cap.' '.($base?->name ?? 'normal'), $big ? (int) floor($cap / $big->space).' '.$big->name : null, $small ? (int) floor($cap / $small->space).' '.$small->name : null])->filter()->join(', or ') }}</small>
                            @if ($dimsOn)
                                <span class="ds-bx__dims">
                                    Cargo box <input type="number" min="1" max="2000" placeholder="L" value="{{ $t->cargo_length_cm }}" wire:change="setTruckDim({{ $t->id }}, 'cargo_length_cm', $event.target.value)" aria-label="Cargo length cm">×
                                    <input type="number" min="1" max="2000" placeholder="W" value="{{ $t->cargo_width_cm }}" wire:change="setTruckDim({{ $t->id }}, 'cargo_width_cm', $event.target.value)" aria-label="Cargo width cm">×
                                    <input type="number" min="1" max="2000" placeholder="H" value="{{ $t->cargo_height_cm }}" wire:change="setTruckDim({{ $t->id }}, 'cargo_height_cm', $event.target.value)" aria-label="Cargo height cm"> cm ·
                                    packed <input type="number" min="40" max="100" placeholder="85" value="{{ $t->fill_pct }}" wire:change="setTruckDim({{ $t->id }}, 'fill_pct', $event.target.value)" aria-label="Packed percent">% ·
                                    reserve <input type="number" min="0" max="50" placeholder="0" value="{{ $t->reserve_pct }}" wire:change="setTruckDim({{ $t->id }}, 'reserve_pct', $event.target.value)" aria-label="Reserve percent">%
                                    @if (($fit = \App\Support\TruckSpace::fit($t)) && $fit !== (int) $t->capacity)<button type="button" wire:click="useFit({{ $t->id }})">From the cargo box: {{ $fit }} · use it</button>@endif
                                </span>
                                @if ($t->reserve_pct)<small>Trips are planned up to {{ \App\Support\TruckSpace::usable($t) }}: {{ $t->reserve_pct }}% kept free for bikes, TVs and odd items, or a top-up at loading.</small>@endif
                            @endif
                            @if ($past[$t->id] ?? null)<small class="ds-bx__past">Last 90 days: carried up to {{ $fmt($past[$t->id]['space']) }} space ({{ $past[$t->id]['boxes'] }} boxes) on one trip</small>@endif
                        </span>
                        <span class="ds-bx__step">
                            <button type="button" wire:click="truckStep({{ $t->id }}, -1)" aria-label="Less">−</button>
                            <input type="number" min="1" max="2000" value="{{ $cap }}" wire:change="setTruck({{ $t->id }}, $event.target.value)" aria-label="Space for {{ $t->plate_no }}">
                            <button type="button" wire:click="truckStep({{ $t->id }}, 1)" aria-label="More">+</button>
                        </span>
                    </div>
                @empty
                    <p class="ds-board__muted">No active trucks.</p>
                @endforelse
            </section>
        </div>
    </div>
</div>
</x-filament-panels::page>
