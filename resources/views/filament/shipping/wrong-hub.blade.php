<x-filament-panels::page>
<div class="ds-sp">
    <div class="ds-sp__filter">
        <button type="button" wire:click="$set('tab', 'list')" @class(['is-on' => $tab === 'list'])>List</button>
        <button type="button" wire:click="$set('tab', 'report')" @class(['is-on' => $tab === 'report'])>Report</button>
    </div>

    @if ($tab === 'list')
        @unless ($isAdmin)
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
                    <span><b>{{ $w->invoice?->invoice }} · {{ \Illuminate\Support\Str::title($w->invoice?->receiver_name) }}</b><small>{{ collect([$w->invoice?->receiver_city, $w->invoice?->receiver_province])->filter()->join(', ') }}{{ $isAdmin ? ' · at '.$w->hub?->hub_name : '' }}{{ $w->shipment ? ' · '.$w->shipment->code : '' }}</small></span>
                    <span><em @class(['ds-sp__tag', 'is-bad' => $w->reason === 'wrong_hub'])>{{ $reasons[$w->reason] ?? $w->reason }}</em>@if ($w->note)<small>“{{ $w->note }}”</small>@endif</span>
                    <span>
                        @if ($w->status === 'waiting')
                            <b>{{ $r['tip']['text'] }}</b><small>{{ $r['tip']['why'] }}</small>
                            @if ($w->reason === 'wrong_hub')
                                <select wire:change="setHub({{ $w->id }}, $event.target.value)" aria-label="Right hub"><option value="">Right hub: not a partner hub</option>@foreach ($hubs as $hid => $hn)<option value="{{ $hid }}" @selected($w->correct_hub_id == $hid)>Right hub: {{ $hn }}</option>@endforeach</select>
                            @endif
                        @else
                            <b class="ds-sp__ok">✓ {{ \App\Models\Shipping\WrongHubBox::STATUS[$w->status] ?? $w->status }}</b><small>{{ $w->done_at?->format('M j, g:i A') }}{{ $w->status === 'sent_hub' ? ' · '.$w->correctHub?->hub_name : '' }}</small>
                        @endif
                    </span>
                    <span class="ds-sp__btns">
                        @if ($w->status === 'waiting')
                            @if ($r['tip']['way'] === 'hub')<x-filament::button size="sm" wire:click="sendToHub({{ $w->id }})" wire:confirm="Hand {{ $w->invoice?->invoice }} over to {{ $w->correctHub?->hub_name }}?">Send to {{ $w->correctHub?->hub_name }}</x-filament::button>@endif
                            <x-filament::button size="sm" color="gray" wire:click="sendBack({{ $w->id }})" wire:confirm="Send {{ $w->invoice?->invoice }} back to the warehouse?">Back to warehouse</x-filament::button>
                        @endif
                    </span>
                </div>
            @empty
                <p class="ds-board__muted ds-sp__pad">Nothing here. 👍</p>
            @endforelse
        </section>
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
