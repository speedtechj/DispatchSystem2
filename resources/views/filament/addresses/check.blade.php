<x-filament-panels::page>
<div class="ds-fl ds-ad">
@if ($box)
    @php($f = $box['f'])
    <button type="button" class="ds-tk__back" wire:click="closeBox">‹ Addresses to check</button>
    <span class="ds-te__title"><h1>{{ \Illuminate\Support\Str::title($box['i']->receiver_name) }} · box {{ $box['label'] }}</h1>
        <small>{{ $f->status === 'check' ? 'The AI is not sure. Pick the barangay; we remember it for this receiver next time.' : 'Pick the barangay; we remember it for this receiver next time.' }}</small></span>
    <div class="ds-ad__one">
        <div class="ds-ad__col">
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Address as written on the manifest</b>
                <span class="ds-ad__addr">{!! collect($box['marked'])->map(fn ($p) => $p[1] ? '<mark class="ds-ad__mark is-'.e(\Illuminate\Support\Str::slug($p[1])).'">'.e($p[0]).'</mark>' : e($p[0]))->join('') !!}, {{ \Illuminate\Support\Str::title($box['i']->receiver_city) }}, {{ \Illuminate\Support\Str::title($box['i']->receiver_province) }}@if ($box['i']->receiver_mobile_no) · {{ $box['i']->receiver_mobile_no }}@endif</span>
                <small class="ds-te__hint">@if ($f->clues)Clues the AI used: {!! collect($f->clues)->map(fn ($c) => '<span class="ds-ad__mark is-'.e(\Illuminate\Support\Str::slug($c['kind'] ?? 'clue')).'">'.e($c['kind'] ?? 'clue').'</span>')->unique()->join(' ') !!}. @endif The original address is never changed.</small>
            </section>
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Pick the barangay</b>
                @forelse ($box['cands'] as $n => $c)
                    <button type="button" wire:click="pick(@js($c['name']))" @class(['ds-ad__opt', 'is-on' => $chosen === $c['name'] && $search === ''])>
                        <i class="ds-te__radio" aria-hidden="true"></i>
                        <span><b>{{ $c['name'] }}</b><small>{{ $c['why'] }}</small></span>
                        <span @class(['ds-cb__pill', 'is-own' => $n === 0, 'is-muted' => $n > 0])>{{ $c['pct'] }}% likely</span>
                    </button>
                @empty
                    <small class="ds-te__hint">No suggestion. Type the barangay below.</small>
                @endforelse
                <input type="text" list="brgy-known" wire:model.live.debounce.300ms="search" class="ds-te__input" placeholder="🔍 Another barangay in {{ \Illuminate\Support\Str::title($box['i']->receiver_city) }}…">
                <datalist id="brgy-known">@foreach ($box['known'] as $k)<option value="{{ $k }}">@endforeach</datalist>
                <span class="ds-ad__use">
                    <button type="button" class="ds-te__btn is-main ds-ad__go" wire:click="useChosen" @disabled($chosen === '' && trim($search) === '')>Use {{ trim($search) !== '' ? \Illuminate\Support\Str::title($search) : ($chosen ?: '…') }}</button>
                    @if ($box['others'])<label class="ds-ad__also"><input type="checkbox" wire:model="alsoSame"> Also use for {{ $box['first'] }}'s other {{ $box['others'] }} {{ \Illuminate\Support\Str::plural('box', $box['others']) }}</label>@endif
                </span>
            </section>
        </div>
        <section class="ds-cb__card ds-ad__card">
            <b class="ds-ad__h">Map</b>
            @if ($box['place'])
                @php($p = $box['place'])
                <iframe class="ds-ad__map" title="Map" loading="lazy" src="https://www.openstreetmap.org/export/embed.html?bbox={{ $p->lng - 0.012 }}%2C{{ $p->lat - 0.008 }}%2C{{ $p->lng + 0.012 }}%2C{{ $p->lat + 0.008 }}&layer=mapnik&marker={{ $p->lat }}%2C{{ $p->lng }}"></iframe>
                <small class="ds-te__hint">The pin is where the map service found “{{ \Illuminate\Support\Str::limit($p->clean ?: $p->raw, 80) }}”{{ $p->exact ? '' : ' (area only)' }}. <a href="https://www.google.com/maps/search/?api=1&query={{ $p->lat }},{{ $p->lng }}" target="_blank" rel="noopener" class="ds-te__link">Open in Google Maps ›</a></small>
            @else
                <span class="ds-ad__nomap">📍 No pin yet: the map could not find this address{{ \App\Support\Maps\MapSettings::provider() === 'none' ? ' (no map key in Settings → Maps & routes)' : '' }}.</span>
            @endif
        </section>
    </div>
@else
    <div class="ds-ad__top">
        <span class="ds-te__title"><h1>Addresses to check</h1><small>Boxes with no barangay. Trips still go by city; the barangay only sets the stop order.</small></span>
        <select wire:model.live="container" class="ds-te__input ds-ad__pick" aria-label="Container">
            <option value="">All containers</option>
            @foreach ($containers as $c)<option value="{{ $c->id }}">{{ $c->container_no }}</option>@endforeach
        </select>
    </div>
    <div class="ds-tk__tiles">
        @foreach ($tiles as [$l, $v, $sub, $ring])
            <span @class(['ds-cb__card', 'ds-ad__tile', 'is-ring' => $ring && $v])><small class="ds-cb__label">{{ $l }}</small><b class="ds-ad__big num">{{ number_format($v) }}</b><small class="ds-cb__label">{{ $sub }}</small></span>
        @endforeach
    </div>
    @if ($pending)
        <span class="ds-ad__pending"><span>⏳ {{ $pending }} {{ \Illuminate\Support\Str::plural('box', $pending) }} waiting to be filled in (it runs by itself every 15 minutes).</span><button type="button" class="ds-te__btn" wire:click="fillNow" wire:loading.attr="disabled">Fill in now</button></span>
    @endif
    <div class="ds-fl__chips" role="group" aria-label="Show">
        @foreach ($chips as $k => [$l, $n])
            <button type="button" wire:click="setShow('{{ $k }}')" @class(['ds-fl__chip', 'is-on' => $show === $k])>{{ $l }} <span>{{ $n }}</span></button>
        @endforeach
    </div>
    <section class="ds-cb__card ds-ad__table">
        <span class="ds-ad__row is-head"><span>Receiver · box</span><span>Address as written</span><span>Suggested barangay</span><span>How we know</span><span></span></span>
        @forelse ($rows as $f)
            @php($i = $f->invoice)
            @php($alt = collect($f->candidates ?? [])->pluck('name')->reject(fn ($n) => $n === $f->barangay)->first())
            <span class="ds-ad__row" wire:key="r-{{ $f->id }}">
                <span class="ds-ad__who"><b>{{ \Illuminate\Support\Str::title($i?->receiver_name) }}</b><small>{{ $i ? \App\Filament\Shared\Addresses\AddressesToCheckPage::boxLabel($i) : '' }}</small></span>
                <span class="ds-ad__as">{{ $i?->receiver_address ?: '(no street)' }}<small>{{ \Illuminate\Support\Str::title(trim($i?->receiver_city.', '.$i?->receiver_province, ', ')) }}</small></span>
                <span class="ds-ad__who"><b @class(['is-empty' => ! $f->barangay])>{{ $f->barangay ? $f->barangay.($f->status === 'check' ? '?' : '') : '—' }}</b><small>{{ $f->status === 'none' ? 'Stays in the '.\Illuminate\Support\Str::title($i?->receiver_city).' group' : ($alt ? 'or '.$alt : '') }}</small></span>
                <span class="ds-ad__how">
                    <span @class(['ds-cb__pill', 'is-own' => in_array($f->status, ['used', 'checked'], true), 'is-warn' => $f->status === 'check', 'is-muted' => $f->status === 'none'])>{{ ['used' => 'Sure · used', 'checked' => 'Checked · used', 'check' => 'Not sure · check', 'none' => 'No clues'][$f->status] ?? $f->status }}</span>
                    <small>{{ $f->status === 'checked' ? 'Checked by the office '.$f->checked_at?->format('M j') : ($f->clue ?: (\App\Support\Maps\Barangays::SOURCES[$f->source] ?? '')) }}</small>
                </span>
                <span class="ds-ad__act">
                    @if ($f->status === 'check')
                        <button type="button" class="ds-te__btn is-main ds-ad__sm" wire:click="ok({{ $f->id }})">✓ OK</button>
                        <button type="button" class="ds-te__btn ds-ad__sm" wire:click="openBox({{ $f->id }})">Change</button>
                    @else
                        <small @class(['ds-ad__done', 'is-muted' => $f->status === 'none'])>{{ $f->status === 'none' ? 'Driver uses the full address' : ($f->status === 'checked' ? '✓ Saved for next time' : '✓ Used automatically') }}</small>
                    @endif
                </span>
            </span>
        @empty
            <p class="ds-cb__muted ds-ad__empty">{{ $show === 'check' ? '✓ Nothing to check. Every box with no barangay was filled in or stays in its city group.' : 'No boxes here.' }}</p>
        @endforelse
        @if ($more)<button type="button" class="ds-te__link ds-ad__moreb" wire:click="$set('limit', {{ $rows->count() + 40 }})">Show more</button>@endif
    </section>
@endif
</div>
</x-filament-panels::page>
