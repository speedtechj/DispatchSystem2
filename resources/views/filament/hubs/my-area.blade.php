<x-filament-panels::page>
<div class="ds-fl ds-wc">
    <span class="ds-te__title"><small>{{ $hub->hub_name }} › My area</small><h1>My delivery area</h1><small>The places your hub delivers. Only the office can change them: ask here, the office approves.</small></span>
    <div class="ds-ma__grid">
        <section class="ds-cb__card ds-wc__card">
            <span class="ds-wc__head"><b class="ds-ad__h">{{ $hub->hub_name }} delivers</b><small>{{ $provinces->count() }} {{ Str::plural('province', $provinces->count()) }} · {{ $cities->count() }} {{ Str::plural('city', $cities->count()) }} · {{ $brgys->count() }} split {{ Str::plural('city', $brgys->count()) }}</small></span>
            @foreach ($provinces as $a)<span class="ds-ma__row is-prov"><b>{{ $a->province }}</b><span>whole province</span></span>@endforeach
            @foreach ($cities as $a)<span class="ds-ma__row"><b>{{ $a->city }}, {{ $a->province }}</b><span>whole city</span></span>@endforeach
            @foreach ($brgys as $city => $g)
                <span class="ds-wc__towns"><span class="ds-wc__head"><b>{{ $city }}</b><small>only these barangays</small></span><span class="ds-wc__chips">@foreach ($g as $a)<span class="ds-wc__chip is-own">{{ $a->barangay }}</span>@endforeach @foreach ($requests->where('status', 'pending')->where('city', explode(', ', $city)[0]) as $r)<span class="ds-wc__chip">{{ $r->barangay }} · asked</span>@endforeach</span></span>
            @endforeach
            @if ($provinces->isEmpty() && $cities->isEmpty() && $brgys->isEmpty())<small class="ds-te__hint">No places yet. Ask the office for the places you deliver.</small>@endif
            <span class="ds-wc__asked">You can only load and deliver boxes for these places. Other boxes stop with “Not for {{ $hub->hub_name }}”.</span>
        </section>
        <section class="ds-cb__card ds-wc__card">
            <b class="ds-ad__h">Ask for a place</b>
            <form wire:submit="send" class="ds-hs__form">
                <label><small>Province</small><input type="text" list="ma-provinces" wire:model="ask.province" class="ds-te__input" placeholder="La Union"></label>
                <label><small>City (empty = whole province)</small><input type="text" wire:model="ask.city" class="ds-te__input" placeholder="San Fernando"></label>
                <label><small>Barangay (optional)</small><input type="text" wire:model="ask.barangay" class="ds-te__input" placeholder="Catbangen"></label>
                <label><small>Why</small><textarea wire:model="ask.reason" class="ds-te__input" rows="3" placeholder="20 minutes from our hub"></textarea></label>
                <button type="submit" class="ds-te__btn is-main">Send to the office</button>
            </form>
            <datalist id="ma-provinces">@foreach ($list as $p)<option value="{{ $p }}">@endforeach</datalist>
            @foreach ($requests as $r)
                <span @class(['ds-ha__ok' => $r->status === 'approved', 'ds-wc__asked' => $r->status === 'pending', 'ds-ha__warn' => $r->status === 'refused'])>{{ ['pending' => '⏳ Sent', 'approved' => '✓ Approved', 'refused' => 'Refused'][$r->status] }}: {{ $r->label() }}{{ $r->status === 'pending' && $r->now_hub_id ? '. Until the office answers, '.\App\Support\Hubs\HubAreas::name($r->now_hub_id).' keeps it.' : '' }}</span>
            @endforeach
            <small class="ds-te__hint">The office gets it in the bell.</small>
        </section>
    </div>
</div>
</x-filament-panels::page>
