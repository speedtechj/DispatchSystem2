{{-- All photos of one box, oldest first: scan photos plus delivery photos. Needs $items from BoxAlbum::forInvoice(). --}}
@if ($items->isEmpty())
    <p class="ds-board__muted">No photos of this box yet. Staff add them while scanning, and drivers when they deliver.</p>
@else
    @php($list = $items->map(fn ($i) => [
        'src' => $i['url'], 'dl' => $i['download'], 'name' => $i['name'],
        'step' => $i['label'].($i['kind'] !== 'scan' ? ' '.$i['n'].'/'.$i['of'] : ''),
        'cond' => \App\Models\BoxPhoto::CONDITIONS[$i['condition']] ?? null,
        'meta' => collect([$i['ref'], $i['place'], $i['who'], $i['at']?->format('d M Y g:i A')])->filter()->join(' · '),
        'note' => $i['note'],
    ])->values())
    <div class="ds-phs" x-data="{ i: {{ $list->count() - 1 }}, items: @js($list) }">
        <img class="ds-phs__big" x-bind:src="items[i].src" x-bind:alt="items[i].name">
        <div>
            <strong x-text="items[i].step + (items[i].cond ? ' · ' + items[i].cond : '')"></strong>
            <p class="ds-board__muted" x-text="items[i].meta"></p>
            <p x-show="items[i].note" x-text="'“' + items[i].note + '”'"></p>
            <a class="ds-phs__link" x-bind:href="items[i].dl" x-bind:download="items[i].name">Download <span x-text="items[i].name"></span></a>
        </div>
        <div class="ds-phs__thumbs">
            <template x-for="(it, k) in items" x-bind:key="k">
                <button type="button" x-on:click="i = k" x-bind:class="{ 'is-on': i === k }"><img x-bind:src="it.src" alt=""><span x-text="it.step"></span></button>
            </template>
        </div>
    </div>
@endif
