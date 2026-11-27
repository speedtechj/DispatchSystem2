{{-- Board 71: one photo in a gallery row. Its width follows the photo (wide stays wide), caption on hover. --}}
@php($tone = ['good' => 'ok', 'damaged' => 'bad', 'wet' => 'wet', 'open' => 'warn'][$i['condition'] ?? ''] ?? null)
<figure data-tile wire:key="t-{{ $key }}" class="group relative m-0 h-40 min-w-28 overflow-hidden rounded-xl bg-(--bp-raised) [flex:133_1_12.5rem] sm:h-44"
        x-bind:class="{ 'ring-3 ring-(--bp-gold) ring-offset-2 ring-offset-(--bp-surf)': isSel(@js($key)) || (open && cur === @js($key)) }">
    <button type="button" class="block size-full cursor-zoom-in" x-on:click="show(@js($key))" aria-label="Open {{ $i['name'] }}">
        <img src="{{ $i['url'] }}" alt="{{ $i['label'] }} · {{ $i['invoice'] }}" loading="lazy" decoding="async"
             x-on:load="fit($event)" x-init="$el.complete && fit({ target: $el })"
             class="size-full object-cover transition duration-300 group-hover:scale-[1.04]">
    </button>
    <span class="pointer-events-none absolute left-2 top-2 inline-flex max-w-[calc(100%-3rem)] items-center gap-1.5 truncate whitespace-nowrap rounded-full bg-black/55 px-2 py-0.5 text-[0.68rem] font-extrabold text-white backdrop-blur-sm">
        @if ($tone)<i @class(['ds-bp__dot', 'is-'.$tone])></i>@endif
        {{ $i['label'] }}{{ $tone && $tone !== 'ok' ? ' · '.(\App\Models\BoxPhoto::CONDITIONS[$i['condition']] ?? '') : '' }}
    </span>
    <button type="button" x-on:click.stop="toggle(@js($key))" aria-label="Select {{ $i['name'] }}" x-bind:aria-pressed="isSel(@js($key))"
            class="absolute right-2 top-2 grid size-7 place-items-center rounded-full text-sm font-black transition"
            x-bind:class="isSel(@js($key)) ? 'bg-(--bp-gold) text-[#0e2433] opacity-100' : 'bg-black/45 text-transparent ring-2 ring-white/90 ' + (picking ? 'opacity-100' : 'opacity-0 group-hover:opacity-100 focus:opacity-100')">✓</button>
    <figcaption class="pointer-events-none absolute inset-x-0 bottom-0 flex translate-y-[58%] flex-col gap-0.5 bg-linear-to-t from-black/85 via-black/55 to-transparent px-3 pb-2 pt-7 text-white transition duration-200 group-hover:translate-y-0">
        <b class="truncate text-[0.8rem] font-extrabold">{{ $i['invoice'] }}{{ $i['who'] ? ' · '.$i['who'] : '' }}</b>
        <small class="truncate text-[0.72rem] text-white/80">{{ $i['at']?->format('d M Y · g:i A') }}{{ $i['note'] ? ' · “'.\Illuminate\Support\Str::limit($i['note'], 40).'”' : '' }}</small>
    </figcaption>
</figure>
