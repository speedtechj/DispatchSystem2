<x-filament-panels::page>
<div class="ds-ai">
    <div class="ds-ai__said">
        <span class="ds-ai__badge">AI</span>
        <span>
            <span>@if ($suggested)
                <b>Suggested from your deliveries of the last {{ \App\Support\Aging\LimitSuggester::MONTHS }} months.</b> Warning = slower than 3 out of 4 boxes. Late = slower than 9 out of 10. Far places get their own total. Change any number with − and +, then press Use these limits.
            @else
                <b>These are the limits in use now.</b> Press <b>Suggest from my history</b> to let the system work them out from your own deliveries.
            @endif</span>
            <span class="ds-ai__two is-left"><x-filament::button size="sm" color="gray" wire:click="suggest" wire:loading.attr="disabled" wire:target="suggest"><span wire:loading.remove wire:target="suggest">Suggest from my history</span><span wire:loading wire:target="suggest">Counting…</span></x-filament::button></span>
        </span>
    </div>

    <section class="ds-ai__card" style="padding: 0; gap: 0; overflow: auto">
        <div class="ds-agl__tr is-head"><span>Stage</span><span>Usually takes</span><span>Warning after</span><span>Late after</span><span>Why</span></div>
        @foreach ($rows as $i => $r)
            <div @class(['ds-agl__tr', 'is-changed' => [$r['warn'], $r['late']] !== $r['orig']]) wire:key="l-{{ $r['stage'] }}-{{ $r['region'] }}">
                <span><b>{{ $stageLabels[$r['stage']] ?? $r['stage'] }}</b><small>{{ $regionLabels[$r['region']] ?? $r['region'] }}</small></span>
                <span>{{ $r['usual'] }}</span>
                <span class="ds-agl__num"><button type="button" wire:click="bump({{ $i }}, 'warn', -1)" aria-label="Less">−</button><b class="is-amber">{{ $r['warn'] }} d</b><button type="button" wire:click="bump({{ $i }}, 'warn', 1)" aria-label="More">+</button></span>
                <span class="ds-agl__num"><button type="button" wire:click="bump({{ $i }}, 'late', -1)" aria-label="Less">−</button><b class="is-red">{{ $r['late'] }} d</b><button type="button" wire:click="bump({{ $i }}, 'late', 1)" aria-label="More">+</button></span>
                <span class="ds-agl__why">{{ $r['reason'] }}</span>
            </div>
        @endforeach
    </section>
    <div class="ds-ai__card ds-ai__foot">
        <span>{{ $changed ? $changed.' '.str('row')->plural($changed).' changed (yellow).' : ($suggested ? 'These are the suggestions.' : 'No changes.') }}</span>
        <x-filament::button color="gray" wire:click="mount">Back to the limits in use</x-filament::button>
        <x-filament::button wire:click="save">Use these limits</x-filament::button>
    </div>

    <section class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>Morning summary</h2></div>
        <p class="ds-board__muted">Everyone gets late boxes in the bell (Admin all, Warehouse their warehouse, Partner hub their hub). Email is extra:</p>
        <label class="ds-gm__check ds-ps__row"><input type="checkbox" wire:model="mailAdmin"><span><b>Email to Admin</b></span><small></small></label>
        <label class="ds-gm__check ds-ps__row"><input type="checkbox" wire:model="mailWarehouse"><span><b>Email to Warehouse staff</b></span><small></small></label>
        <label class="ds-gm__check ds-ps__row"><input type="checkbox" wire:model="mailHub"><span><b>Email to Partner hubs</b></span><small></small></label>
        <label class="ds-gm__field" style="max-width: 16rem"><span>Send at (hour, 0–23)</span><input type="number" min="0" max="23" wire:model="hour"></label>
        <div class="ds-ai__two is-left">
            <x-filament::button wire:click="saveNotify">Save</x-filament::button>
            <x-filament::button color="gray" wire:click="sendNow" wire:confirm="Send the morning summary to everyone now?">Send a summary now</x-filament::button>
        </div>
        <p class="ds-board__muted">Needs the scheduler (<code>php artisan schedule:work</code>). Once a month the system checks the limits again and tells Admin if it would suggest different numbers.</p>
    </section>
</div>
</x-filament-panels::page>
