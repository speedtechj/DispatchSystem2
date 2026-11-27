@php
    $condColor = ['good' => 'ok', 'damaged' => 'bad', 'wet' => 'wet', 'open' => 'warn'];
@endphp
<x-filament-panels::page>
    <div class="ds-bp" wire:key="bp-{{ md5($q.'|'.$place.'|'.$cond.'|'.implode(',', array_keys($viewer))) }}"
         x-data="{
            items: @js($viewer),
            cur: null, open: false, zoom: 1, playing: null, picking: false,
            sel: $wire.entangle('selected'),
            isSel(k) { return this.sel.includes(k) },
            toggle(k) { this.sel = this.isSel(k) ? this.sel.filter(x => x !== k) : [...this.sel, k] },
            get it() { return this.items[this.cur] || null },
            get strip() { const inv = this.it?.invoice; return Object.keys(this.items).filter(k => this.items[k].invoice === inv) },
            get pos() { return this.strip.indexOf(this.cur) + 1 },
            get selSize() { const b = this.sel.reduce((s, k) => s + (this.items[k]?.size || 0), 0); return b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(b / 1024)) + ' KB' },
            step(d) { const s = this.strip; const i = s.indexOf(this.cur); if (s.length) { this.cur = s[(i + d + s.length) % s.length]; this.zoom = 1 } },
            show(k) { if (this.picking) { this.toggle(k); return } this.cur = k; this.zoom = 1; this.open = true },
            close() { this.open = false; this.zoom = 1; this.play(false) },
            play(on) { clearInterval(this.playing); this.playing = null; if (on) this.playing = setInterval(() => this.step(1), 3000) },
            fit(e) { const i = e.target; if (i.naturalWidth && i.naturalHeight) { const r = Math.min(2.4, Math.max(0.5, i.naturalWidth / i.naturalHeight)); i.closest('[data-tile]').style.flex = Math.round(r * 100) + ' 1 ' + Math.round(r * 9.5) + 'rem' } },
         }"
         x-on:keydown.arrow-right.window="open && step(1)" x-on:keydown.arrow-left.window="open && step(-1)" x-on:keydown.escape.window="open && close()">

        <header class="ds-bp__head">
            <div>
                <h1>Box Photos</h1>
                <p>Every photo of every box, from container to doorstep.</p>
            </div>
            <div class="ds-bp__stats">
                <span><strong>{{ number_format($stats['week']) }}</strong><small>photos this week</small></span>
                <span class="is-bad"><strong>{{ $stats['damaged'] }}</strong><small>damaged</small></span>
                <span class="is-wet"><strong>{{ $stats['wet'] }}</strong><small>wet</small></span>
            </div>
        </header>

        {{-- Part 45 (board 72): nothing is searched while typing; Enter, 🔍 Search or the scanner (it sends Enter) starts it --}}
        <form class="ds-bp__search" x-data="{ draft: @js($q), get waiting() { return this.draft.trim() !== (this.$wire.q ?? '').trim() && this.draft.trim() !== '' } }"
              x-init="$watch('$wire.q', (v) => draft = v ?? '')" x-on:submit.prevent="$wire.searchFor(draft)" role="search">
            <x-filament::icon icon="heroicon-o-magnifying-glass" class="h-5 w-5" />
            <input type="search" x-model="draft" enterkeyhint="search" placeholder="Invoice, container or trip number…" autocomplete="off" autofocus aria-label="Search box photos">
            <span class="rounded-lg bg-[#fff6d6] px-2.5 py-1 text-[0.75rem] font-bold whitespace-nowrap text-[#8a6400]" x-show="waiting" x-cloak>Press Enter to search</span>
            @if ($q !== '')
                <button type="button" x-on:click="draft = ''; $wire.clearSearch()" class="ds-bp__clear" aria-label="Clear search">✕</button>
            @endif
            <span class="ds-bp__hint" x-show="! waiting">Type or scan</span>
            <button type="submit" class="h-10 shrink-0 rounded-xl px-4 text-[0.85rem] font-extrabold transition"
                    x-bind:class="draft.trim().length >= 3 ? 'bg-[#0e2433] text-white dark:bg-white dark:text-[#0e2433]' : 'bg-black/5 text-black/35 dark:bg-white/10 dark:text-white/40'">🔍 Search</button>
        </form>

        @if ($match === 'short')
            <section class="ds-bp__empty">
                <span class="grid size-12 place-items-center rounded-full bg-[#fff6d6] text-xl text-[#8a6400]">↵</span>
                <h2>Type at least 3 letters or numbers</h2>
                <p>Short searches would show almost every box. Finish the number, then press Enter.</p>
            </section>
        @elseif (trim($q) === '')
            <section class="ds-bp__empty">
                <span class="ds-bp__empty-icon"><x-filament::icon icon="heroicon-o-magnifying-glass" class="h-8 w-8" /></span>
                <h2>Search a box to see its photos</h2>
                <p>Type or scan an invoice, container or trip number, then press Enter. Photos stay hidden until you search.</p>
                @if ($recent)
                    <div class="ds-bp__recent">
                        <span>Recent</span>
                        @foreach ($recent as $r)
                            <button type="button" wire:click="searchFor(@js($r))">{{ $r }}</button>
                        @endforeach
                    </div>
                @endif
            </section>

            @if ($emails->isNotEmpty())
                <section class="ds-bp__panel">
                    <h3>Sent emails</h3>
                    <ul class="ds-bp__mails">
                        @foreach ($emails as $e)
                            <li>
                                <strong>{{ implode(', ', $e->recipients) }}</strong>
                                <span>{{ count($e->photo_ids) }} photos · {{ $e->status === 'sent' ? 'Sent' : 'Not sent' }}</span>
                                <small>{{ $e->user?->full_name }} · {{ $e->created_at->diffForHumans() }}</small>
                            </li>
                        @endforeach
                    </ul>
                </section>
            @endif
        @else
            <div class="ds-bp__pills" role="group" aria-label="Filters">
                <button type="button" wire:click="$set('place', '')" @class(['is-on' => $place === ''])>All places</button>
                @foreach ($places as $key => $label)
                    <button type="button" wire:click="$set('place', '{{ $key }}')" @class(['is-on' => $place === $key])>{{ $label }}</button>
                @endforeach
                <span class="ds-bp__sep" aria-hidden="true"></span>
                <button type="button" wire:click="$set('cond', '')" @class(['is-on' => $cond === ''])>Any condition</button>
                @foreach ($conditions as $key => $label)
                    <button type="button" wire:click="$set('cond', '{{ $key }}')" @class(['is-on' => $cond === $key])><i @class(['ds-bp__dot', 'is-'.$condColor[$key]])></i>{{ $label }}</button>
                @endforeach
            </div>

            @if ($boxes->isEmpty())
                <section class="ds-bp__empty is-small">
                    <h2>No photos found for “{{ $q }}”</h2>
                    <p>Check the number, or clear the filters. Photos appear here when staff add them while scanning, and when drivers deliver.</p>
                </section>
            @else
                {{-- Board 71: the photos as a gallery (rows that follow each photo), by box or all photos by day --}}
                <div class="flex flex-wrap items-center justify-between gap-3">
                    <p class="ds-bp__count">@if ($match)<span @class(['mr-1.5 rounded-full px-2 py-0.5 text-[0.7rem] font-extrabold', 'bg-[#fff6d6] text-[#8a6400]' => $match === 'like', 'bg-emerald-500/12 text-emerald-700 dark:text-emerald-300' => $match !== 'like'])>{{ ['exact' => 'Exact box', 'trip' => 'Trip', 'container' => 'Container', 'like' => 'Similar numbers'][$match] ?? '' }}</span>@endif{{ $boxes->count() }} {{ str('box')->plural($boxes->count()) }} · {{ $photoCount }} {{ str('photo')->plural($photoCount) }} · newest first</p>
                    <div class="flex items-center gap-2">
                        <span class="flex h-9 rounded-full bg-(--bp-surf) p-0.5 shadow-[inset_0_0_0_1px_var(--bp-line)]" role="group" aria-label="How to show the photos">
                            <button type="button" wire:click="$set('arrange', 'box')" @class(['rounded-full px-4 text-[0.8rem] font-bold', 'bg-(--bp-pill-on) text-(--bp-pill-on-text)' => $arrange !== 'all', 'text-(--bp-text)' => $arrange === 'all'])>By box</button>
                            <button type="button" wire:click="$set('arrange', 'all')" @class(['rounded-full px-4 text-[0.8rem] font-bold', 'bg-(--bp-pill-on) text-(--bp-pill-on-text)' => $arrange === 'all', 'text-(--bp-text)' => $arrange !== 'all'])>All photos</button>
                        </span>
                        <button type="button" x-on:click="picking = ! picking" class="h-9 rounded-full px-4 text-[0.8rem] font-extrabold transition"
                                x-bind:class="picking ? 'bg-(--bp-gold) text-[#0e2433]' : 'bg-(--bp-surf) text-(--bp-text) shadow-[inset_0_0_0_1px_var(--bp-line)]'"
                                x-text="picking ? 'Done' : '☑ Select'"></button>
                    </div>
                </div>

                @if ($arrange === 'all')
                    <div class="flex flex-col gap-5">
                        @foreach ($days as $day => $list)
                            <section class="flex flex-col gap-2" wire:key="day-{{ $day }}">
                                <h3 class="m-0 flex items-baseline gap-2 text-[0.95rem] font-extrabold">{{ $day }} <small class="text-[0.78rem] font-semibold text-(--bp-muted)">{{ $list->count() }} {{ str('photo')->plural($list->count()) }}</small></h3>
                                <div class="flex flex-wrap gap-2">
                                    @foreach ($list as $i)
                                        @include('filament.partials.box-photo-thumb', ['key' => $i['key'], 'i' => $i])
                                    @endforeach
                                    <span class="grow-[1000]" aria-hidden="true"></span>
                                </div>
                            </section>
                        @endforeach
                    </div>
                @else
                    <div class="flex flex-col gap-3.5">
                        @foreach ($boxes as $b)
                            @php($inv = $b['invoice'])
                            @php($scan = $b['items']->where('kind', 'scan'))
                            <article class="ds-bp__box" wire:key="box-{{ $inv->id }}">
                                <button type="button" class="ds-bp__boxhead" x-on:click="show(@js($b['items']->keys()->last()))">
                                    <span class="ds-bp__inv">{{ $inv->invoice }}</span>
                                    @if ($b['worst'])
                                        <span @class(['ds-bp__chip', 'is-'.$condColor[$b['worst']]])>{{ $conditions[$b['worst']] }}</span>
                                    @endif
                                    @if ($b['delivered'])
                                        <span class="ds-bp__chip is-ok">Delivered</span>
                                    @endif
                                    <span class="ds-bp__n">{{ $b['items']->count() }} {{ str('photo')->plural($b['items']->count()) }}</span>
                                    <span class="ds-bp__who">{{ collect([$inv->receiver_name, $inv->receiver_barangay, $inv->receiver_city])->filter()->map(fn ($p) => \Illuminate\Support\Str::title($p))->join(' · ') }}</span>
                                </button>

                                {{-- Part 45 (board 73): email or download the photos of this box in one tap --}}
                                <div class="flex flex-wrap gap-2">
                                    <button type="button" class="inline-flex h-9 items-center gap-1.5 rounded-full bg-[#f6be00] px-4 text-[0.8rem] font-extrabold text-[#0e2433]"
                                            x-on:click="$wire.mountAction('email', { keys: @js($b['items']->keys()->values()) })">✉ Email photos</button>
                                    <button type="button" class="inline-flex h-9 items-center gap-1.5 rounded-full bg-(--bp-raised) px-4 text-[0.8rem] font-bold text-(--bp-text) shadow-[inset_0_0_0_1px_var(--bp-line)]"
                                            x-on:click="$wire.downloadSelected(@js($b['items']->keys()->values()))">↓ Download</button>
                                </div>

                                <ol class="ds-bp__journey" aria-label="Where this box has been">
                                    @foreach ($b['journey'] as $j)
                                        @php($tone = $j['kind'] === 'delivered' ? ($j['condition'] === 'damaged' ? 'bad' : 'ok') : ($j['kind'] === 'not_delivered' ? 'warn' : ($condColor[$j['condition']] ?? 'none')))
                                        <li><i @class(['ds-bp__dot', 'is-'.$tone])></i>{{ $j['label'] }}{{ $j['kind'] === 'delivered' && $j['condition'] === 'damaged' ? ' · damaged' : '' }}</li>
                                    @endforeach
                                </ol>

                                @if ($scan->isNotEmpty())
                                    <div class="flex flex-col gap-2 rounded-2xl bg-(--bp-raised) p-2.5">
                                        <span class="flex items-center gap-2 px-0.5 text-[0.82rem]"><b>Scan photos</b><small class="text-(--bp-muted)">{{ $scan->count() }} {{ str('photo')->plural($scan->count()) }} · warehouse and hub</small></span>
                                        <div class="flex flex-wrap gap-2">
                                            @foreach ($scan as $key => $i)
                                                @include('filament.partials.box-photo-thumb', ['key' => $key, 'i' => $i])
                                            @endforeach
                                            <span class="grow-[1000]" aria-hidden="true"></span>
                                        </div>
                                    </div>
                                @endif

                                @foreach ($b['attempts'] as $a)
                                    <div class="ds-bp__card is-warn">
                                        <div class="ds-bp__cardhead">
                                            <span class="ds-bp__badge">!</span>
                                            <span><strong>Not delivered · {{ $a['reason'] }}</strong><small>{{ $a['at']?->format('d M Y · g:i A') }} · {{ $a['who'] ?? 'Driver' }}{{ $a['trip'] ? ' · Trip '.$a['trip'] : '' }}</small></span>
                                            <em>{{ count($a['keys']) }} {{ str('photo')->plural(count($a['keys'])) }}</em>
                                        </div>
                                        @if ($a['note'])<p class="ds-bp__cardnote">“{{ $a['note'] }}”</p>@endif
                                        @if ($a['keys'])
                                            <div class="flex flex-wrap gap-2">
                                                @foreach ($a['keys'] as $key)
                                                    @include('filament.partials.box-photo-thumb', ['key' => $key, 'i' => $b['items'][$key]])
                                                @endforeach
                                                <span class="grow-[1000]" aria-hidden="true"></span>
                                            </div>
                                        @endif
                                    </div>
                                @endforeach

                                @if ($d = $b['delivered'])
                                    <div class="ds-bp__card is-ok">
                                        <div class="ds-bp__cardhead">
                                            <span class="ds-bp__badge">✓</span>
                                            <span><strong>Delivered{{ ($d['signed']['damaged'] ?? false) ? ' · damaged' : '' }}</strong><small>{{ $d['at']?->format('d M Y · g:i A') }} · {{ $d['who'] ?? 'Driver' }}{{ $d['to'] ? ' · to '.\Illuminate\Support\Str::title($d['to']) : '' }}{{ $d['trip'] ? ' · Trip '.$d['trip'] : '' }}</small></span>
                                            <em>{{ count($d['keys']) }} {{ str('photo')->plural(count($d['keys'])) }}</em>
                                        </div>
                                        @if ($sg = $d['signed'] ?? null)
                                            <div class="flex flex-wrap items-center gap-x-3 gap-y-1 px-1 text-[0.8rem]">
                                                <span>✍ Signed on the phone by <b>{{ \Illuminate\Support\Str::title($sg['by']) }}</b>{{ $sg['rel'] ? ' ('.strtolower($sg['rel']).')' : '' }}{{ $sg['cant'] ? ' · could not sign' : '' }}</span>
                                                @if ($sg['damaged'])<span @class(['ds-bp__chip', 'is-bad'])>Damaged: {{ $sg['damage'] }}</span>@endif
                                                @if ($sg['paper'])<span class="text-(--bp-muted)">No paper receipt: {{ strtolower($sg['paper']) }}</span>@endif
                                                <a href="{{ $sg['link'] }}" target="_blank" rel="noopener" class="font-bold underline">📄 Signed receipt (PDF)</a>
                                            </div>
                                        @endif
                                        @if ($d['keys'])
                                            <div class="flex flex-wrap gap-2">
                                                @foreach ($d['keys'] as $key)
                                                    @include('filament.partials.box-photo-thumb', ['key' => $key, 'i' => $b['items'][$key]])
                                                @endforeach
                                                <span class="grow-[1000]" aria-hidden="true"></span>
                                            </div>
                                        @else
                                            <p class="ds-bp__cardnote">No delivery photo was taken.</p>
                                        @endif
                                    </div>
                                @endif
                            </article>
                        @endforeach
                    </div>
                @endif

                {{-- Board 71 C: full-screen viewer with a strip of the box's photos, slideshow, zoom, download --}}
                <div class="fixed inset-0 z-[60] flex flex-col bg-[#05090d] text-[#eef3f6]" x-show="open" x-cloak x-transition.opacity
                     x-effect="document.documentElement.style.overflow = open ? 'hidden' : ''" role="dialog" aria-modal="true" aria-label="Photo">
                    <div class="flex flex-wrap items-center gap-2 px-4 py-3 sm:px-6">
                        <span class="flex min-w-0 flex-1 flex-col">
                            <strong class="truncate text-[0.98rem]" x-text="it?.title"></strong>
                            <small class="truncate text-[0.78rem] text-white/65" x-text="[it?.ref, it?.when, it?.who].filter(Boolean).join(' · ')"></small>
                        </span>
                        <span class="ds-bp__chip" x-show="it?.condLabel" x-text="it?.condLabel" x-bind:class="{ 'is-ok': it?.cond === 'good', 'is-bad': it?.cond === 'damaged', 'is-wet': it?.cond === 'wet', 'is-warn': it?.cond === 'open' }"></span>
                        <span class="rounded-full bg-white/10 px-3 py-1 text-[0.75rem] font-extrabold tabular-nums" x-text="pos + ' / ' + strip.length"></span>
                        <button type="button" class="grid size-10 place-items-center rounded-full bg-white/10 hover:bg-white/20" x-on:click="zoom = zoom >= 2.5 ? 1 : zoom + 0.75" aria-label="Zoom">🔍</button>
                        <button type="button" class="h-10 rounded-full px-4 text-[0.8rem] font-extrabold" x-show="strip.length > 1" x-on:click="play(! playing)"
                                x-bind:class="playing ? 'bg-(--bp-gold) text-[#0e2433]' : 'bg-white/10 hover:bg-white/20'" x-text="playing ? '❚❚ Pause' : '▶ Slideshow'"></button>
                        <a class="grid size-10 place-items-center rounded-full bg-white/10 hover:bg-white/20" x-bind:href="it?.dl" x-bind:download="it?.name" aria-label="Download">⬇</a>
                        <button type="button" class="h-10 rounded-full bg-[#f6be00] px-4 text-[0.8rem] font-extrabold text-[#0e2433]" x-on:click="const k = cur; close(); $wire.mountAction('email', { keys: [k] })">✉ Email this photo</button>
                        <button type="button" class="h-10 rounded-full px-4 text-[0.8rem] font-extrabold" x-on:click="toggle(cur)"
                                x-bind:class="isSel(cur) ? 'bg-(--bp-gold) text-[#0e2433]' : 'bg-white/10 hover:bg-white/20'" x-text="isSel(cur) ? '✓ Selected' : 'Select'"></button>
                        <button type="button" class="grid size-10 place-items-center rounded-full bg-white/10 hover:bg-white/20" x-on:click="close()" aria-label="Close">✕</button>
                    </div>
                    <div class="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden px-3 sm:px-16"
                         x-data="{ sx: null }" x-on:touchstart="sx = $event.touches[0].clientX" x-on:touchend="if (sx !== null && zoom === 1) { const dx = $event.changedTouches[0].clientX - sx; if (Math.abs(dx) > 60) step(dx < 0 ? 1 : -1) } sx = null">
                        <img x-bind:src="it?.src" x-bind:alt="it?.name" x-on:dblclick="zoom = zoom > 1 ? 1 : 2.5"
                             class="max-h-full max-w-full select-none object-contain transition-transform duration-200" x-bind:style="'transform: scale(' + zoom + ')'" x-bind:class="zoom > 1 ? 'cursor-zoom-out' : 'cursor-zoom-in'">
                        <button type="button" class="absolute left-3 top-1/2 grid size-12 -translate-y-1/2 place-items-center rounded-full bg-white/12 text-2xl hover:bg-white/25" x-show="strip.length > 1" x-on:click="step(-1)" aria-label="Previous photo">‹</button>
                        <button type="button" class="absolute right-3 top-1/2 grid size-12 -translate-y-1/2 place-items-center rounded-full bg-white/12 text-2xl hover:bg-white/25" x-show="strip.length > 1" x-on:click="step(1)" aria-label="Next photo">›</button>
                        <span class="absolute inset-x-0 bottom-0 h-1 bg-white/10" x-show="playing"><span class="block h-full w-full origin-left animate-pulse bg-(--bp-gold)"></span></span>
                    </div>
                    <blockquote class="mx-4 my-0 rounded-lg border-l-3 border-(--bp-gold) bg-white/6 px-3 py-2 text-[0.85rem] italic sm:mx-6" x-show="it?.note" x-text="it?.note"></blockquote>
                    <div class="flex gap-2 overflow-x-auto px-4 py-3 sm:px-6" x-show="strip.length > 1">
                        <template x-for="k in strip" x-bind:key="k">
                            <button type="button" x-on:click="cur = k; zoom = 1" class="h-14 w-20 shrink-0 overflow-hidden rounded-md transition"
                                    x-bind:class="k === cur ? 'opacity-100 ring-3 ring-(--bp-gold)' : 'opacity-45 hover:opacity-80'"><img x-bind:src="items[k].src" alt="" class="size-full object-cover" loading="lazy"></button>
                        </template>
                    </div>
                    <div class="flex items-center justify-between gap-3 border-t border-white/10 px-4 py-2.5 text-[0.75rem] text-white/55 sm:px-6">
                        <span class="truncate font-mono" x-text="it?.name"></span>
                        <span class="hidden sm:inline">Swipe or ‹ › · double-tap or 🔍 to zoom · Esc to close</span>
                        @if (auth()->user()?->hasRole('super_admin'))
                            <button type="button" class="text-(--bp-bad) underline" x-show="it?.scan" x-on:click="close(); $wire.mountAction('delete', { key: cur })">Delete this photo</button>
                        @endif
                    </div>
                </div>
            @endif
        @endif

        <div class="ds-bp__dock" x-show="sel.length" x-cloak x-transition.opacity>
            <span class="ds-bp__dockn" x-text="sel.length"></span>
            <span class="ds-bp__docktext"><strong x-text="sel.length === 1 ? '1 photo selected' : sel.length + ' photos selected'"></strong><small x-text="'about ' + selSize"></small></span>
            <button type="button" class="is-ghost" x-on:click="sel = []">Clear</button>
            <button type="button" class="is-dark" wire:click="downloadSelected"><span x-text="sel.length > 1 ? '↓ Download ZIP' : '↓ Download'"></span></button>
            {{ $this->emailAction }}
        </div>
    </div>

    <x-filament-actions::modals />
</x-filament-panels::page>
