@php
    $peso = fn ($n, $d = 0) => '₱'.number_format((float) $n, $d);
    $lit = fn ($n) => rtrim(rtrim(number_format((float) $n, 2), '0'), '.').' L';
    $t = $totals;
@endphp
<x-filament-panels::page>
<div class="ds-fu">
    <div class="ds-fu__top">
        <span class="ds-tm__tabs" role="tablist">
            @foreach (['trucks' => 'Trucks', 'fills' => 'Fills', 'alerts' => 'Alerts'.(count($alerts) ? ' · '.count($alerts) : ''), 'cards' => 'Fuel cards', 'prices' => 'Prices', 'vat' => 'VAT'] as $k => $label)
                <button type="button" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k]) role="tab" aria-selected="{{ $tab === $k ? 'true' : 'false' }}">{{ $label }}</button>
            @endforeach
        </span>
        <select wire:model.live="month" class="ds-fu__month" aria-label="Month">
            @foreach ($months as $k => $label)<option value="{{ $k }}">{{ $label }}</option>@endforeach
        </select>
    </div>

    <div class="ds-tm__stats is-five">
        <span class="ds-board__panel"><small>Spent</small><b>{{ $peso($t['spent']) }}</b><em>{{ $t['fills'] }} {{ str('fill')->plural($t['fills']) }}</em></span>
        <span class="ds-board__panel"><small>Liters</small><b>{{ $lit($t['liters']) }}</b><em>Diesel {{ $lit($t['diesel']) }} · Gasoline {{ $lit($t['gasoline']) }}</em></span>
        <span class="ds-board__panel"><small>VAT 12% on fuel</small><b>{{ $peso($t['vat']) }}</b><em @class(['is-bad' => $t['vatNoTin'] > 0])>{{ $t['vatNoTin'] > 0 ? '⚠ '.$peso($t['vatNoTin'], 2).' without your TIN' : 'from the receipts' }}</em></span>
        <span class="ds-board__panel"><small>Paid with</small><b>{{ 100 - $t['cashPct'] }}% card</b><em>{{ $t['cashPct'] }}% cash{{ $t['unsettled'] ? ' · '.$t['unsettled'].' cash not settled' : '' }}</em></span>
        <span class="ds-board__panel"><small>Fuel per box delivered</small><b>{{ $t['perBox'] ? $peso($t['perBox'], 2) : '—' }}</b><em>{{ number_format($t['boxes']) }} boxes · {{ $t['kml'] ? $t['kml'].' km/L' : 'km/L after 2 fills with odometer' }}</em></span>
    </div>

    {{-- ============================== trucks ============================== --}}
    @if ($tab === 'trucks')
        @if (count($alerts))
            <button type="button" class="ds-fu__alertbar" wire:click="setTab('alerts')">⚠ {{ count($alerts) }} {{ str('thing')->plural(count($alerts)) }} to check · {{ $alerts[0]['title'] }} <span aria-hidden="true">›</span></button>
        @endif
        <section class="ds-board__panel ds-fu__table">
            <div class="ds-fu__tr is-head is-trucks"><span>Truck</span><span>Liters</span><span>Spent</span><span>km per liter</span><span>₱ per km</span><span>Last fill</span></div>
            @forelse ($rows as $r)
                <button type="button" class="ds-fu__tr is-trucks" wire:click="showTruck({{ $r['truck']->id }})" wire:key="tr-{{ $r['truck']->id }}">
                    <span><b>{{ $r['truck']->plate_no }}</b> <small>{{ $r['truck']->description ?: $r['truck']->category }}{{ $r['truck']->fuel_type ? ' · '.$r['truck']->fuel_type : '' }}</small></span>
                    <span>{{ $r['fills'] ? $lit($r['liters']) : '—' }}</span>
                    <span>{{ $r['fills'] ? $peso($r['spent']) : '—' }}</span>
                    <span><b>{{ $r['kml'] ?? '—' }}</b>@if ($r['change'] !== null && abs($r['change']) >= 3) <em @class(['ds-fu__chg', 'is-bad' => $r['change'] <= -10])>{{ $r['change'] > 0 ? '▲' : '▼' }} {{ abs($r['change']) }}%</em>@endif</span>
                    <span>{{ $r['perKm'] ? $peso($r['perKm'], 2) : '—' }}</span>
                    <span><small>{{ $r['last'] ?? 'no fills this month' }}</small></span>
                </button>
            @empty
                <p class="ds-board__muted">No fills this month yet. Drivers add each fill in the Driver app: ⛽ Add fuel.</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== fills ============================== --}}
    @if ($tab === 'fills')
        @if ($truckName)
            <p class="ds-fu__filter">Showing <b>{{ $truckName }}</b> · <button type="button" wire:click="$set('truck', null)">show all trucks</button></p>
        @endif
        <section class="ds-fu__fills">
            @forelse ($fills as $f)
                <article class="ds-board__panel ds-fu__fill" wire:key="fill-{{ $f->id }}">
                    @if ($f->receiptUrl())<a href="{{ $f->receiptUrl() }}" target="_blank" rel="noopener" class="ds-fu__photo"><img src="{{ $f->receiptUrl() }}" alt="Receipt" loading="lazy"></a>@else<span class="ds-fu__photo is-none">no photo</span>@endif
                    <span class="ds-fu__fillmain">
                        <b>{{ $f->truck?->plate_no }} · {{ $f->station ?: 'Station not read' }}</b>
                        <small>{{ $f->filled_at->format('M j, g:i A') }} · {{ $f->driver?->full_name ?? '—' }}{{ $f->trip ? ' · trip '.$f->trip->trip_number : '' }}</small>
                        <span class="ds-fu__chips">
                            <em @class(['is-bad' => $f->truck?->fuel_type && $f->fuel_type && $f->truck->fuel_type !== $f->fuel_type])>⛽ {{ $f->fuel_type ? ucfirst($f->fuel_type) : 'fuel ?' }}{{ $f->product ? ' · '.$f->product : '' }}</em>
                            <em>{{ $f->paid_with === 'cash' ? '💵 cash' : '💳 card'.($f->card_last4 ? ' ****'.$f->card_last4 : '') }}</em>
                            @if ($f->gps_ok === true)<em class="is-ok">📍 with the truck</em>@elseif ($f->gps_ok === false)<em class="is-bad">📍 {{ number_format($f->gps_distance_m / 1000, 1) }} km from the truck</em>@endif
                            @if ($f->km_per_liter)<em>{{ $f->km_since }} km · {{ $f->km_per_liter }} km/L</em>@endif
                            @if ($f->buyer_tin_ok === false)<em class="is-bad">⚠ your TIN missing</em>@elseif ($f->buyer_tin_ok === true)<em class="is-ok">✓ your TIN</em>@endif
                            @if ($f->ai_read)<em>✨ read by AI</em>@endif
                        </span>
                    </span>
                    <span class="ds-fu__fillnums">
                        <b>{{ $peso($f->total, 2) }}</b>
                        <small>{{ $lit($f->liters) }} × {{ $f->price_per_liter ? $peso($f->price_per_liter, 2) : '—' }}</small>
                        @if ($f->vat !== null)<small>VAT {{ $peso($f->vat, 2) }}</small>@endif
                        @if ($f->odometer)<small>Odo {{ number_format($f->odometer) }}</small>@endif
                    </span>
                </article>
            @empty
                <p class="ds-board__muted">No fills this month.</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== alerts ============================== --}}
    @if ($tab === 'alerts')
        <section class="ds-fu__alerts">
            @forelse ($alerts as $a)
                <div @class(['ds-fu__alert', 'is-red' => $a['kind'] === 'red']) wire:key="al-{{ $loop->index }}">
                    <span class="ds-fu__alerticon" aria-hidden="true">{{ $a['icon'] }}</span>
                    <span><b>{{ $a['title'] }}</b><small>{{ $a['text'] }}</small></span>
                    <small class="ds-fu__when">{{ $a['when'] }}</small>
                </div>
            @empty
                <p class="ds-board__muted">Nothing to check this month. 👍</p>
            @endforelse
        </section>
    @endif

    {{-- ============================== fuel cards ============================== --}}
    @if ($tab === 'cards')
        <div class="ds-fu__two">
            <section class="ds-board__panel ds-fu__import">
                <h3>Import the fuel card statement</h3>
                <p class="ds-board__muted">Download the transactions from your fuel card website as <b>CSV</b> (Excel: File → Save As → CSV) and add the file here. Each charge is matched to a fill in the Driver app: same truck (by the card's last 4 digits or the plate), within 3 hours, same liters.</p>
                <ul class="ds-fu__where">
                    <li><b>Petron Fleet Card</b> · fleet.petron.com → statements</li>
                    <li><b>Shell Fleet Card</b> · Shell Fleet Hub → transactions</li>
                    <li><b>Caltex StarCard</b> · StarCard Online → reports</li>
                    <li><b>SEAOIL</b> · PriceLOCQ for Business → export</li>
                </ul>
                <form wire:submit="importStatement" class="ds-fu__form">
                    <select wire:model="provider" aria-label="Fuel card">
                        @foreach (\App\Support\Fuel\Fuel::PROVIDERS as $k => $label)<option value="{{ $k }}">{{ $label }}</option>@endforeach
                    </select>
                    <input type="file" wire:model="statementFile" accept=".csv,text/csv,text/plain">
                    <x-filament::button type="submit" wire:loading.attr="disabled" wire:target="statementFile,importStatement">Import</x-filament::button>
                </form>
                @error('statementFile')<p class="ds-fu__err">{{ $message }}</p>@enderror
                <p class="ds-board__muted">Set each truck's card (last 4 digits) in {{ $isAdmin ? 'Settings → Fuel' : 'Admin → Settings → Fuel' }}, so charges find their truck.</p>
            </section>
            <section class="ds-board__panel">
                @if ($statement)
                    <h3>{{ \App\Support\Fuel\Fuel::PROVIDERS[$statement->provider] ?? 'Statement' }} · {{ $statement->from?->format('M j') }}–{{ $statement->to?->format('M j') }} · {{ $statement->lines }} charges</h3>
                    <span class="ds-fu__counts">
                        <button type="button" wire:click="$set('lineStatus', '')" @class(['is-on' => $lineStatus === ''])>All</button>
                        @foreach (\App\Support\Fuel\FuelStatements::STATUS as $k => $label)
                            @if (($lineCounts[$k] ?? 0) > 0)
                                <button type="button" wire:click="$set('lineStatus', '{{ $k }}')" @class(['is-on' => $lineStatus === $k, 'is-bad' => $k !== 'matched'])>{{ $label }} · {{ $lineCounts[$k] }}</button>
                            @endif
                        @endforeach
                    </span>
                    <div class="ds-fu__lines">
                        @foreach ($lines as $l)
                            <div class="ds-fu__line" wire:key="ln-{{ $l->id }}">
                                <span><b>{{ $l->truck?->plate_no ?? ($l->plate ?: $l->card ?: '—') }}</b> <small>{{ $l->charged_at?->format('M j g:i A') }} · {{ $l->station }} · {{ $l->product }}</small></span>
                                <span>{{ $l->liters ? $lit($l->liters) : '' }} · {{ $peso($l->amount, 2) }}</span>
                                <em @class(['is-ok' => $l->status === 'matched', 'is-bad' => $l->status !== 'matched'])>{{ \App\Support\Fuel\FuelStatements::STATUS[$l->status] ?? $l->status }}{{ $l->status === 'liters_differ' && $l->fuelFill ? ' (app '.$lit($l->fuelFill->liters).')' : '' }}</em>
                            </div>
                        @endforeach
                    </div>
                    @if ($statements->count() > 1)
                        <p class="ds-board__muted">Earlier: @foreach ($statements as $s)@if ($s->id !== $statement->id)<button type="button" class="ds-fu__link" wire:click="$set('statementId', {{ $s->id }})">{{ $s->created_at->format('M j') }} ({{ $s->lines }})</button> @endif @endforeach</p>
                    @endif
                @else
                    <h3>No statement imported yet</h3>
                    <p class="ds-board__muted">After the first import, the charges and how they matched show here.</p>
                @endif
            </section>
        </div>
    @endif

    {{-- ============================== prices ============================== --}}
    @if ($tab === 'prices')
        <div class="ds-fu__two">
            <section class="ds-board__panel">
                <h3>This week's price · from {{ \App\Support\Fuel\Fuel::weekStart()->format('M j') }}</h3>
                <p class="ds-board__muted">The middle price of the receipts your drivers sent this week. Prices change every Tuesday. Used for the fuel cash estimate of a trip.</p>
                <div class="ds-fu__prices">
                    @foreach (['diesel' => 'Diesel', 'gasoline' => 'Gasoline'] as $k => $label)
                        <span><small>{{ $label }}</small><b>{{ $prices[$k]['price'] ? $peso($prices[$k]['price'], 2) : '—' }}</b><em>{{ $prices[$k]['from'] }}</em></span>
                    @endforeach
                </div>
                @if ($isAdmin)
                    <form wire:submit="savePrices" class="ds-fu__form">
                        <input type="text" inputmode="decimal" wire:model="priceDiesel" placeholder="Diesel ₱/L" aria-label="Diesel price">
                        <input type="text" inputmode="decimal" wire:model="priceGasoline" placeholder="Gasoline ₱/L" aria-label="Gasoline price">
                        <x-filament::button type="submit" color="gray">Set this week's price</x-filament::button>
                    </form>
                    <p class="ds-board__muted">Only needed when there are no receipts yet this week. Leave a box empty to use the receipts again.</p>
                @endif
            </section>
            <section class="ds-board__panel ds-fu__table">
                <div class="ds-fu__tr is-head is-weeks"><span>Week of</span><span>Diesel</span><span>Gasoline</span></div>
                @foreach ($weeks as $i => $w)
                    @php($prev = $weeks[$i + 1] ?? null)
                    <div class="ds-fu__tr is-weeks">
                        <span><b>{{ $w['week']->format('M j') }}</b></span>
                        @foreach (['diesel', 'gasoline'] as $k)
                            <span>{{ $w[$k] ? $peso($w[$k], 2) : '—' }}@if ($w[$k] && $prev && $prev[$k] && abs($w[$k] - $prev[$k]) >= 0.01) <em @class(['ds-fu__chg', 'is-bad' => $w[$k] > $prev[$k], 'is-ok' => $w[$k] < $prev[$k]])>{{ $w[$k] > $prev[$k] ? '▲' : '▼' }} {{ number_format(abs($w[$k] - $prev[$k]), 2) }}</em>@endif</span>
                        @endforeach
                    </div>
                @endforeach
            </section>
        </div>
    @endif

    {{-- ============================== VAT ============================== --}}
    @if ($tab === 'vat')
        @php($noTin = $fills->filter(fn ($f) => $f->buyer_tin_ok === false))
        <div class="ds-fu__vat">
            <span class="ds-board__panel"><small>VAT on fuel</small><b>{{ $peso($fills->sum('vat'), 2) }}</b><em>{{ $fills->whereNotNull('vat')->count() }} receipts · VATable {{ $peso($fills->sum('vatable'), 2) }}</em></span>
            <span class="ds-board__panel is-ok"><small>Can be claimed</small><b>{{ $peso($fills->sum('vat') - $noTin->sum('vat'), 2) }}</b><em>{{ $companyTin ? 'your company TIN on the receipt (or under ₱1,000)' : 'set your company TIN in Settings → Fuel' }}</em></span>
            <span @class(['ds-board__panel', 'is-bad' => $noTin->isNotEmpty()])><small>Company TIN missing</small><b>{{ $peso($noTin->sum('vat'), 2) }}</b><em>{{ $noTin->count() }} receipts of ₱1,000+ without your TIN</em></span>
            <a href="{{ $vatUrl }}" class="ds-fu__export">⬇ Excel for the accountant</a>
        </div>
        <section class="ds-board__panel ds-fu__table">
            <div class="ds-fu__tr is-head is-vat"><span>Date</span><span>Station · TIN</span><span>Invoice no.</span><span>VATable</span><span>VAT 12%</span><span>Total</span><span>Your TIN</span></div>
            @forelse ($fills as $f)
                <div class="ds-fu__tr is-vat" wire:key="vat-{{ $f->id }}">
                    <span>{{ $f->filled_at->format('M j') }}</span>
                    <span><b>{{ $f->station ?: '—' }}</b><small>{{ $f->station_tin ? 'TIN '.$f->station_tin : '' }}</small></span>
                    <span>{{ $f->invoice_no ?: '—' }}</span>
                    <span>{{ $f->vatable !== null ? $peso($f->vatable, 2) : '—' }}</span>
                    <span><b>{{ $f->vat !== null ? $peso($f->vat, 2) : '—' }}</b></span>
                    <span>{{ $peso($f->total, 2) }}</span>
                    <span>@if ($f->buyer_tin_ok === true)<em class="is-ok">✓ on receipt</em>@elseif ($f->buyer_tin_ok === false)<em class="is-bad">⚠ missing</em>@else<small>{{ $f->total < 1000 ? 'not needed' : '—' }}</small>@endif</span>
                </div>
            @empty
                <p class="ds-board__muted">No receipts this month.</p>
            @endforelse
        </section>
        <p class="ds-board__muted">Keep the paper receipts: card statements alone are not enough to claim VAT. Check the rules with your accountant.</p>
    @endif
</div>
</x-filament-panels::page>
