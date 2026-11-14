@php
    $peso = fn ($n, $d = 2) => '₱'.number_format((float) $n, $d);
    $lit = fn ($n) => rtrim(rtrim(number_format((float) $n, 1), '0'), '.').' L';
    $cardFills = $fills->where('paid_with', 'card');
    $cashFills = $fills->where('paid_with', 'cash');
@endphp
<x-filament-panels::page>
<div class="ds-fu">
    <div class="ds-fu__steps">
        {{-- 1. the estimate --}}
        <section class="ds-board__panel ds-fu__step">
            <h3><span class="ds-fu__num">1</span> Estimate</h3>
            <dl class="ds-fu__calc">
                <dt>Trip</dt><dd>{{ $est['km'] ? rtrim(rtrim(number_format($est['km'], 1), '0'), '.').' km' : 'not known yet' }}</dd>
                <dt>Truck</dt><dd>{{ $est['kml'] }} km/L <small>{{ $est['kmlFrom'] }}</small></dd>
                <dt>Liters</dt><dd>{{ $est['liters'] ? $lit($est['liters']) : '—' }}</dd>
                <dt>{{ ucfirst($est['type']) }} this week</dt><dd>{{ $est['price'] ? $peso($est['price']).'/L' : '—' }} <small>{{ $est['priceFrom'] }}</small></dd>
                <dt>Buffer</dt><dd>+{{ $est['buffer'] }}%</dd>
            </dl>
            <p class="ds-fu__big">{{ $est['amount'] ? $peso($est['amount'], 0) : '—' }}</p>
            @if (! $est['km'])
                <p class="ds-board__muted">Open <b>Stops &amp; loading</b> first so the route (km) is worked out.</p>
            @elseif (! $est['price'])
                <p class="ds-board__muted">No {{ $est['type'] }} price yet this week. Set it in Fuel → Prices, or wait for the first receipt.</p>
            @endif
            @if ($est['short'])
                <p class="ds-fu__hint">Short trip (under {{ $minKm }} km): the fuel card should be enough. Cash is a backup.</p>
            @endif
        </section>

        {{-- 2. give the cash --}}
        <section class="ds-board__panel ds-fu__step">
            <h3><span class="ds-fu__num">2</span> Cash given</h3>
            @if ($cash)
                <p class="ds-fu__big">{{ $peso($cash->given, 0) }}</p>
                <p class="ds-board__muted">{{ $cash->given_at->format('M j, g:i A') }} · by {{ $cash->givenBy?->full_name ?? '—' }}{{ $cash->estimate && abs($cash->estimate - $cash->given) >= 1 ? ' · estimate was '.$peso($cash->estimate, 0) : '' }}</p>
                @if ($cash->note)<p class="ds-board__muted">“{{ $cash->note }}”</p>@endif
                @if (! $cash->settled_at && $cash->given_at->gt(now()->subHour()))
                    <x-filament::button color="gray" size="sm" wire:click="undoCash" wire:confirm="Remove this fuel cash?">Undo</x-filament::button>
                @endif
            @else
                <form wire:submit="giveCash" class="ds-fu__form is-stack">
                    <label><small>Amount</small><input type="text" inputmode="decimal" wire:model="give" placeholder="₱" aria-label="Cash amount"></label>
                    <label><small>Note (optional)</small><input type="text" wire:model="note" maxlength="200" placeholder="e.g. toll and fuel"></label>
                    <x-filament::button type="submit">Give cash</x-filament::button>
                </form>
                <p class="ds-board__muted">The driver sees the cash in the Driver app and pays with it only when the card can't be used.</p>
            @endif
        </section>

        {{-- 3. fills on the trip --}}
        <section class="ds-board__panel ds-fu__step">
            <h3><span class="ds-fu__num">3</span> Fills on this trip</h3>
            @forelse ($fills as $f)
                <div class="ds-fu__line">
                    <span><b>{{ $f->filled_at->format('g:i A') }} · {{ $f->station ?: 'Station' }}</b> <small>{{ $lit($f->liters) }} {{ $f->product }}</small></span>
                    <span>{{ $peso($f->total) }}</span>
                    <em>{{ $f->paid_with === 'cash' ? '💵 cash' : '💳 card' }}</em>
                </div>
            @empty
                <p class="ds-board__muted">No fills yet. The driver adds each fill in the Driver app: ⛽ Add fuel.</p>
            @endforelse
            @if ($fills->isNotEmpty())
                <p class="ds-board__muted">Card {{ $peso($cardFills->sum('total')) }} · Cash {{ $peso($cashFills->sum('total')) }}</p>
            @endif
        </section>

        {{-- 4. settle --}}
        <section class="ds-board__panel ds-fu__step">
            <h3><span class="ds-fu__num">4</span> Settle</h3>
            @if (! $cash)
                <p class="ds-board__muted">No cash given for this trip.</p>
            @else
                <dl class="ds-fu__calc">
                    <dt>Given</dt><dd>{{ $peso($cash->given) }}</dd>
                    <dt>Cash receipts</dt><dd>− {{ $peso($cash->spent()) }}</dd>
                    <dt><b>Change to return</b></dt><dd><b>{{ $peso($cash->left()) }}</b></dd>
                </dl>
                @if ($cash->settled_at)
                    @php($short = round($cash->given - $cash->spent() - $cash->returned, 2))
                    <p @class(['ds-fu__hint', 'is-ok' => abs($short) < 1, 'is-bad' => abs($short) >= 1])>
                        ✓ Settled {{ $cash->settled_at->format('M j, g:i A') }} · {{ $peso($cash->returned) }} returned
                        @if (abs($short) >= 1)· {{ $short > 0 ? $peso($short).' missing' : $peso(-$short).' over' }}@endif
                    </p>
                @else
                    <form wire:submit="settle" class="ds-fu__form is-stack">
                        <label><small>Change returned by the driver</small><input type="text" inputmode="decimal" wire:model="returned" placeholder="{{ number_format($cash->left(), 2) }}"></label>
                        <x-filament::button type="submit" color="success">Settle</x-filament::button>
                    </form>
                @endif
            @endif
        </section>
    </div>
</div>
</x-filament-panels::page>
