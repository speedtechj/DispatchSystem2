<x-filament-panels::page>
<div class="ds-sp">
    <div class="ds-sp__filter">
        <button type="button" wire:click="$set('tab', 'list')" @class(['is-on' => $tab === 'list'])>List</button>
        <button type="button" wire:click="$set('tab', 'return')" @class(['is-on' => $tab === 'return'])>{{ $comingBack ? 'Return shipments' : 'Return shipment'.($openReturn ? ' · '.$openBoxes->count() : '') }}</button>
        <button type="button" wire:click="$set('tab', 'report')" @class(['is-on' => $tab === 'report'])>Report</button>
    </div>

    @if ($tab === 'list')
        @if ($comingBack)
            <p class="ds-board__muted">Boxes the partner hubs send back to the warehouse: returns, and wrong-hub boxes that belong here. "Back to the warehouse" means the box is in the pool again; it comes with the next shipment or truck.</p>
        @endif
        @unless ($isAdmin || $comingBack)
            <form wire:submit="addBox" class="ds-board__panel ds-sp__new">
                <h3>Add a box</h3>
                <div class="ds-sp__newrow">
                    <input type="text" wire:model="code" placeholder="Box number" aria-label="Box number">
                    <select wire:model="reason" aria-label="Why">@foreach ($reasons as $k => $l)<option value="{{ $k }}">{{ $l }}</option>@endforeach</select>
                    <input type="text" wire:model="note" placeholder="Note (optional)" maxlength="300" aria-label="Note">
                    <x-filament::button type="submit">Add</x-filament::button>
                </div>
                @error('code')<p class="ds-sp__err">{{ $message }}</p>@enderror
                <p class="ds-board__muted">Wrong-hub boxes are added by themselves when you receive a container.</p>
            </form>
        @endunless

        <section class="ds-board__panel ds-sp__table">
            <div class="ds-sp__tr is-head"><span>Box</span><span>Why</span><span>Suggested way</span><span></span></div>
            @forelse ($list as $r)
                @php($w = $r['w'])
                <div class="ds-sp__tr" wire:key="wh-{{ $w->id }}">
                    <span><b>{{ $w->invoice?->invoice }} · {{ \Illuminate\Support\Str::title($w->invoice?->receiver_name) }}</b><small>{{ collect([$w->invoice?->receiver_city, $w->invoice?->receiver_province])->filter()->join(', ') }}{{ $isAdmin || $comingBack ? ' · at '.$w->hub?->hub_name : '' }}{{ $w->shipment ? ' · '.$w->shipment->code : '' }}</small></span>
                    <span><em @class(['ds-sp__tag', 'is-bad' => $w->reason === 'wrong_hub'])>{{ $reasons[$w->reason] ?? $w->reason }}</em>@if ($w->note)<small>“{{ $w->note }}”</small>@endif</span>
                    <span>
                        @if ($w->status === 'waiting')
                            <b>{{ $r['tip']['text'] }}</b><small>{{ $r['tip']['why'] }}</small>
                            @if ($w->reason === 'wrong_hub' && ! $comingBack)
                                <select wire:change="setHub({{ $w->id }}, $event.target.value)" aria-label="Right hub"><option value="">Right hub: not a partner hub</option>@foreach ($hubs as $hid => $hn)<option value="{{ $hid }}" @selected($w->correct_hub_id == $hid)>Right hub: {{ $hn }}</option>@endforeach</select>
                            @endif
                        @else
                            <b class="ds-sp__ok">✓ {{ \App\Models\Shipping\WrongHubBox::STATUS[$w->status] ?? $w->status }}</b><small>{{ $w->done_at?->format('M j, g:i A') }}{{ $w->status === 'sent_hub' ? ' · '.$w->correctHub?->hub_name : '' }}</small>
                        @endif
                    </span>
                    <span class="ds-sp__btns">
                        @if ($w->status === 'waiting' && ! $comingBack)
                            @if ($r['tip']['way'] === 'hub')<x-filament::button size="sm" wire:click="sendToHub({{ $w->id }})" wire:confirm="Hand {{ $w->invoice?->invoice }} over to {{ $w->correctHub?->hub_name }}?">Send to {{ $w->correctHub?->hub_name }}</x-filament::button>@endif
                            <x-filament::button size="sm" color="gray" wire:click="sendBack({{ $w->id }})">Back to warehouse</x-filament::button>
                        @endif
                    </span>
                </div>
            @empty
                <p class="ds-board__muted ds-sp__pad">Nothing here. 👍</p>
            @endforelse
        </section>
    @elseif ($tab === 'return')
        @if (! $comingBack)
            @if ($openReturn)
                <form wire:submit="saveReturn" class="ds-board__panel ds-sp__form">
                    <h3>{{ $openReturn->code }} · to the warehouse · {{ $openBoxes->count() }} {{ str('box')->plural($openBoxes->count()) }}</h3>
                    <div class="ds-sp__lines">
                        @foreach ($openBoxes as $b)
                            <span class="ds-sp__line"><b>{{ $b->invoice?->invoice }}</b> {{ \Illuminate\Support\Str::title($b->invoice?->receiver_name) }} · {{ $reasons[$b->reason] ?? $b->reason }} <button type="button" class="ds-sp__x" wire:click="takeOff({{ $b->id }})" aria-label="Take off">✕</button></span>
                        @endforeach
                    </div>
                    <div class="ds-sp__fields">
                        <label><span>Van no.</span><input type="text" wire:model="rf.van_no"></label>
                        <label><span>Seal no.</span><input type="text" wire:model="rf.seal_no"></label>
                        <label><span>Vessel / truck</span><input type="text" wire:model="rf.vessel"></label>
                        <label><span>BL / ticket no.</span><input type="text" wire:model="rf.bl_no"></label>
                        <label><span>Arrives (ETA)</span><input type="date" wire:model="rf.eta"></label>
                        <label><span>Cost ₱</span><input type="text" inputmode="decimal" wire:model="rf.cost"></label>
                        <label class="is-wide"><span>Note</span><input type="text" wire:model="rf.note" maxlength="300"></label>
                    </div>
                    <div class="ds-sp__acts"><x-filament::button type="submit" color="gray">Save</x-filament::button><x-filament::button type="button" wire:click="sendReturn" wire:confirm="Send {{ $openReturn->code }} to the warehouse?">Mark: Sent to the warehouse</x-filament::button></div>
                </form>
            @else
                <p class="ds-board__muted">No return shipment being filled. Press "Back to warehouse" on a box and it starts one.</p>
            @endif
        @endif
        <section class="ds-board__panel ds-sp__table">
            <div class="ds-sp__tr is-head"><span>Return shipment</span><span>Boxes</span><span>Status</span><span></span></div>
            @forelse ($returns as $r)
                <div class="ds-sp__tr" wire:key="rs-{{ $r['rs']->id }}">
                    <span><b>{{ $r['rs']->code }} · from {{ $r['rs']->hub?->hub_name }}</b><small>{{ collect([$r['rs']->van_no ? 'Van '.$r['rs']->van_no : null, $r['rs']->vessel, $r['rs']->eta ? 'ETA '.$r['rs']->eta->format('M j') : null])->filter()->join(' · ') }}</small></span>
                    <span class="num">{{ $r['c']['back'] }} / {{ $r['c']['total'] }} back</span>
                    <span>{{ \App\Models\Shipping\ReturnShipment::STATUS[$r['rs']->status] ?? $r['rs']->status }}</span>
                    <span class="ds-sp__btns">@if ($comingBack && $r['rs']->status === 'sent')<x-filament::button size="sm" color="success" wire:click="finishReturn({{ $r['rs']->id }})" wire:confirm="Finish receiving {{ $r['rs']->code }}? Boxes not scanned in get an Invoice Issue each.">Finish receiving</x-filament::button>@endif</span>
                </div>
            @empty
                <p class="ds-board__muted ds-sp__pad">No return shipments yet.</p>
            @endforelse
        </section>
        @if ($comingBack)<p class="ds-board__muted">Scan the boxes in with Scan app → Receive returns: each box goes back in the pool, in its section.</p>@endif
    @else
        <div class="ds-sp__grid">
            <section class="ds-board__panel ds-sp__box">
                <h3>By reason · {{ now()->format('F') }} · {{ $report['total'] }} {{ str('box')->plural($report['total']) }}</h3>
                @php($max = max(1, ...array_values($report['byReason'] ?: [1])))
                @forelse ($report['byReason'] as $k => $n)<span class="ds-sp__barrow"><span>{{ $k }}</span><i><b style="width: {{ round($n / $max * 100) }}%"></b></i><b class="num">{{ $n }}</b></span>@empty<p class="ds-board__muted">Nothing this month.</p>@endforelse
            </section>
            <section class="ds-board__panel ds-sp__box">
                <h3>By consolidator</h3>
                @php($max2 = max(1, ...array_values($report['byConsolidator'] ?: [1])))
                @forelse ($report['byConsolidator'] as $k => $n)<span class="ds-sp__barrow"><span>{{ $k }}</span><i><b style="width: {{ round($n / $max2 * 100) }}%"></b></i><b class="num">{{ $n }}</b></span>@empty<p class="ds-board__muted">Nothing this month.</p>@endforelse
                <p class="ds-board__muted">If one consolidator causes most of them (wrong addresses on the manifest), show them this, or charge the extra shipping back.</p>
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
