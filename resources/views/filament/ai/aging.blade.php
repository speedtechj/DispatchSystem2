<x-filament-panels::page>
<div class="ds-ai ds-ag">
    <div class="ds-ai__stats">
        <div><small>Not delivered yet</small><b>{{ number_format($sum['open']) }}</b><em>counted from unload</em></div>
        <button type="button" wire:click="showOnly('late')"><small>Late now</small><b class="is-red">{{ number_format($sum['late']) }}</b><em>past the late limit · show</em></button>
        <button type="button" wire:click="showOnly('tomorrow')"><small>Late tomorrow</small><b class="is-amber">{{ number_format($sum['tomorrow']) }}</b><em>if nothing changes · show</em></button>
        <div><small>Delivered on time</small><b class="is-green">{{ $sum['onTime'] !== null ? $sum['onTime'].'%' : '—' }}</b><em>last 30 days</em></div>
    </div>

    @if ($advice['items'])
        <div class="ds-ai__said">
            <span class="ds-ai__badge">{{ $advice['ai'] ? 'AI' : '!' }}</span>
            <span>
                <b>Why boxes are late</b>
                @foreach ($advice['items'] as $a)
                    <span>• {{ $a['t'] }} <strong>{{ $a['act'] ?? '' }}</strong></span>
                @endforeach
                <span class="ds-ai__two is-left">
                    @unless ($isHub)<a class="ds-ai__link" href="{{ $tripsUrl }}">Open the AI trip helper ›</a>@endunless
                    @if (! empty($advice['canAsk']))<button type="button" class="ds-ai__link" wire:click="askAi" wire:loading.attr="disabled" wire:target="askAi"><span wire:loading.remove wire:target="askAi">Ask the AI why</span><span wire:loading wire:target="askAi">Asking…</span></button>@endif
                    <button type="button" class="ds-ai__link" wire:click="refresh">Count again</button>
                </span>
            </span>
        </div>
    @endif

    <section class="ds-ai__card ds-ag__table">
        <div class="ds-ag__tr is-head"><span>Stage (warning · late)</span>@foreach (\App\Support\Aging\BoxAging::BUCKETS as $b)<span>{{ $b[2] }}</span>@endforeach<span>Late now</span></div>
        @foreach ($table as $r)
            <div class="ds-ag__tr" wire:key="st-{{ $r['key'] }}">
                <span><b>{{ $r['label'] }}</b><small>warning {{ $r['warn'] }} d · late {{ $r['late'] }} d</small></span>
                @foreach ($r['cells'] as $c)
                    <span><button type="button" wire:click="pick('{{ $r['key'] }}', {{ $c['i'] }})" @class(['ds-ag__cell', 'is-'.($c['n'] ? $c['status'] : 'zero'), 'is-sel' => $stage === $r['key'] && $bucket === $c['i']]) @disabled(! $c['n'])>{{ $c['n'] }}</button></span>
                @endforeach
                <b @class(['ds-ag__late', 'is-red' => $r['lateN'], 'is-green' => ! $r['lateN']])>{{ $r['lateN'] }}</b>
            </div>
        @endforeach
    </section>

    <div class="ds-ai__split is-even">
        <section class="ds-ai__card">
            <div class="ds-ai__card-head"><b>{{ $listTitle }} · {{ $listCount }}</b><small class="ds-board__muted">{{ $listCount > 25 ? 'oldest 25 shown' : 'oldest first' }} · click a number above</small></div>
            @forelse ($list as $b)
                <div class="ds-ag__box" wire:key="b-{{ $b['invoice_id'] }}">
                    <b>{{ $b['invoice'] }}</b>
                    <span>{{ $b['name'] }}<small>{{ $b['place'] }} · {{ $stageLabels[$b['stage']] }}{{ $b['where'] ? ' · '.$b['where'] : '' }}{{ $b['tried'] ? ' · tried before' : '' }}</small></span>
                    <span class="ds-ag__age is-{{ $b['stageStatus'] }}">{{ $b['days'] }} d<small>{{ $b['total'] }} d total</small></span>
                </div>
            @empty
                <p class="ds-ai__empty">No boxes here. 👍</p>
            @endforelse
        </section>
        <section class="ds-ai__card">
            <div class="ds-ai__card-head"><b>By {{ $by === 'consolidator' ? 'consolidator' : 'place' }}</b>
                <div class="ds-ai__seg is-small">
                    <button type="button" wire:click="$set('by', 'place')" @class(['is-on' => $by === 'place'])>{{ $isHub ? 'Stage' : 'Hub / warehouse' }}</button>
                    <button type="button" wire:click="$set('by', 'consolidator')" @class(['is-on' => $by === 'consolidator'])>Consolidator</button>
                </div>
            </div>
            @foreach ($places as $p)
                <div class="ds-ag__bar"><span>{{ $p['name'] }} <small>{{ $p['n'] }}</small></span><i><s style="width: {{ $p['ok'] }}%" class="is-ok"></s><s style="width: {{ $p['warn'] }}%" class="is-warn"></s><s style="width: {{ $p['lateP'] }}%" class="is-late"></s></i><b class="is-red">{{ $p['late'] }} late</b></div>
            @endforeach
            <small class="ds-board__muted">green on time · amber warning · red late</small>
            @if ($sum['oldest'])
                <p class="ds-board__muted">Oldest box: <b>{{ $sum['oldest']['invoice'] }}</b> ({{ $sum['oldest']['name'] }}, {{ $sum['oldest']['place'] }}), {{ $sum['oldest']['total'] }} days since unload.</p>
            @endif
        </section>
    </div>
</div>
</x-filament-panels::page>
