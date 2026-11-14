<x-filament-panels::page>
    <div class="ds-co">
        <div class="ds-co__tabs" role="tablist" aria-label="How to show the boxes">
            <button type="button" role="tab" wire:click="$set('show', 'areas')" @class(['is-active' => $show === 'areas']) aria-selected="{{ $show === 'areas' ? 'true' : 'false' }}">By area</button>
            <button type="button" role="tab" wire:click="$set('show', 'oldest')" @class(['is-active' => $show === 'oldest']) aria-selected="{{ $show === 'oldest' ? 'true' : 'false' }}">Oldest first</button>
        </div>

        @if ($areas->isEmpty())
            <div class="ds-co__empty">
                <x-filament::icon icon="heroicon-o-inbox" class="h-8 w-8" />
                <strong>No boxes waiting</strong>
                <span>Boxes appear here once the main hub loads them on a truck to your hub.</span>
            </div>
        @elseif ($show === 'areas')
            <div class="ds-co__areas">
                @foreach ($areas as $area)
                    @php($on = in_array($area['key'], $picked, true))
                    @php($tone = $area['oldest'] >= 3 ? 'bad' : ($area['oldest'] >= 2 ? 'warn' : 'ok'))
                    <button type="button" wire:click="togglePick('{{ $area['key'] }}')" wire:key="area-{{ $area['key'] }}"
                            @class(['ds-co__area', 'is-on' => $on]) aria-pressed="{{ $on ? 'true' : 'false' }}">
                        <span class="ds-co__check" aria-hidden="true">✓</span>
                        <span class="ds-co__area-name"><strong>{{ $area['city'] }}</strong><small>{{ $area['barangays'] ?: 'No barangay' }}</small></span>
                        <span class="ds-board__bar"><span class="ds-board__bar-fill ds-board__bar-fill--teal" style="width: {{ $area['boxes'] / $max * 100 }}%"></span></span>
                        <strong class="ds-co__num">{{ number_format($area['boxes']) }}</strong>
                        <span class="ds-co__age is-{{ $tone }}">{{ $area['oldest'] ? 'Oldest '.$area['oldest'].' '.str('day')->plural($area['oldest']) : 'Arrived today' }}</span>
                    </button>
                @endforeach
            </div>
        @else
            <div class="ds-board__panel">
                <div class="ds-co__oldest ds-co__oldest--head"><span>Box</span><span>Receiver</span><span>Area</span><span>Type</span><span>Waiting</span></div>
                @foreach ($oldest as $box)
                    <div class="ds-co__oldest" wire:key="old-{{ $box['id'] }}">
                        <strong>{{ $box['invoice'] }}</strong><span>{{ $box['receiver'] }}</span><span>{{ $box['area'] }}</span><span>{{ $box['boxtype'] }}</span>
                        <span @class(['ds-co__age', 'is-bad' => $box['days'] >= 3, 'is-warn' => $box['days'] === 2, 'is-ok' => $box['days'] < 2])>{{ $box['days'] ? $box['days'].' '.str('day')->plural($box['days']) : 'Today' }}</span>
                    </div>
                @endforeach
                <p class="ds-board__muted">Switch to "By area" to pick boxes for a trip.</p>
            </div>
        @endif

        @if ($areas->isNotEmpty())
            <div class="ds-co__tripbar" aria-live="polite">
                @if ($pickedCount)
                    <span>
                        <strong>{{ number_format($pickedBoxes) }} boxes from {{ $pickedCount }} {{ str('area')->plural($pickedCount) }}</strong>
                        <small>
                            {{ $trucksNeeded > 1 ? "About {$trucksNeeded} trucks at {$capacity} boxes each" : "Fits one truck (about {$capacity} boxes)" }}
                            · {{ $freeTrucks }} free {{ str('truck')->plural($freeTrucks) }}
                        </small>
                    </span>
                    <button type="button" class="ds-co__clear" wire:click="clearPicks">Clear</button>
                    {{ $this->createTripAction }}
                @else
                    <span><small>Tap areas above to build a trip.</small></span>
                @endif
            </div>
        @endif
    </div>

    <x-filament-actions::modals />
</x-filament-panels::page>
