<x-filament-panels::page>
    <div class="ds-tm__stats is-five">
        <span class="ds-board__panel"><small>Sent today</small><b>{{ number_format($today) }}</b></span>
        <span class="ds-board__panel"><small>This month</small><b>{{ number_format($month) }} <em>/ {{ number_format($limit) }}</em></b></span>
        <span class="ds-board__panel"><small>Failed / bad numbers</small><b @class(['is-bad' => $failed])>{{ number_format($failed) }}</b></span>
        <span class="ds-board__panel"><small>Numbers stopped</small><b>{{ number_format($stopped) }}</b></span>
        <span class="ds-board__panel"><small>Credits left</small><b>{{ $credits !== null ? number_format($credits) : '—' }}</b></span>
    </div>
    {{ $this->table }}
    <p class="ds-board__muted">Bad numbers: fix the receiver's mobile number on the box, then press Send again. "Stop texting" keeps a number from getting texts (for example when the receiver asked to stop).</p>
</x-filament-panels::page>
