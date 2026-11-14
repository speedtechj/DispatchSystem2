@php
    $peso = fn ($n, $d = 2) => '₱'.number_format((float) $n, $d);
    $photoJs = "{ busy: false, failed: false, pct: 0,
        take() { this.failed = false; this.\$refs.file.value = ''; this.\$refs.file.click() },
        async send(e) {
            const file = e.target.files[0]; if (! file) return;
            this.busy = true; this.pct = 0;
            const out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
            await new Promise(done => \$wire.upload('upload', out, () => \$wire.savePhoto().then(done), () => { this.failed = true; done() }, (ev) => { this.pct = ev.detail.progress }));
            this.busy = false;
        } }";
    $placeJs = "{ init() { if (navigator.geolocation) navigator.geolocation.getCurrentPosition(p => \$wire.setPlace(p.coords.latitude, p.coords.longitude), () => {}, { enableHighAccuracy: true, timeout: 15000, maximumAge: 120000 }) } }";
@endphp
<x-filament-panels::page>
<div class="ds-sa ds-dr ds-fd" x-data="{{ $placeJs }}">
    <section class="ds-sa__screen" wire:key="fuel-{{ $step }}">
        <header class="ds-fd__top">
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-fd__back" aria-label="Back to today">‹</a>
            <span><small>{{ $truck ? 'Truck '.$truck->plate_no.($truck->fuel_type ? ' · '.ucfirst($truck->fuel_type) : '') : 'No truck yet' }}</small><strong>Add fuel</strong></span>
            <span class="ds-fd__dots" aria-hidden="true">
                @foreach (['receipt', 'check', 'odometer'] as $s)<i @class(['is-on' => $step === $s, 'is-done' => array_search($step, ['receipt', 'check', 'odometer', 'done']) > $loop->index])></i>@endforeach
            </span>
        </header>

        @if ($cash && ! $cash->settled_at)
            <div class="ds-fd__cash">💵 Fuel cash for this trip <b>{{ $peso($cash->given, 0) }}</b> · left <b>{{ $peso($cash->left(), 0) }}</b><small>Use the fuel card first. Cash only if the card can't be used.</small></div>
        @endif

        {{-- ============ 1. receipt ============ --}}
        @if ($step === 'receipt')
            <div class="ds-fd__intro">
                <span class="ds-fd__big" aria-hidden="true">🧾</span>
                <strong>Take a photo of the receipt</strong>
                <p>Lay it flat, all of it in the photo: station, liters, price, total, VAT.{{ $aiOn ? ' The numbers are read for you.' : '' }}</p>
                @if ($companyTin)<p class="ds-fd__tin">For ₱1,000 and up, show the cashier the company card so they write <b>{{ $companyName ?: 'the company name' }}</b> and <b>TIN {{ $companyTin }}</b> on the receipt.</p>@endif
            </div>
            <div x-data="{{ $photoJs }}" class="ds-fd__actions">
                <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                <button type="button" class="ds-sa__primary" x-on:click="take()" x-bind:disabled="busy">
                    <span x-show="! busy">📷 Take receipt photo</span>
                    <span x-show="busy" x-cloak>{{ $aiOn ? 'Reading the receipt…' : 'Saving…' }} <span x-text="pct < 100 ? pct + '%' : ''"></span></span>
                </button>
                <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                @error('upload')<p class="ds-sa__err">{{ $message }}</p>@enderror
                <button type="button" class="ds-dr__link" wire:click="noReceiptPhoto">No receipt · type it in</button>
            </div>
        @endif

        {{-- ============ 2. check ============ --}}
        @if ($step === 'check')
            @if ($receiptUrl)
                <a href="{{ $receiptUrl }}" target="_blank" rel="noopener" class="ds-fd__thumb"><img src="{{ $receiptUrl }}" alt="Receipt"><span>{{ $aiRead ? '✨ Read from the photo · check it' : 'Type what the receipt says' }}</span></a>
            @endif
            @if ($wrongFuel)
                <div class="ds-fd__warn is-bad">⛽ This truck uses <b>{{ $truck->fuel_type }}</b>, the receipt says <b>{{ $f['fuel_type'] }}</b>. Check the receipt, or tell the office right away.</div>
            @endif
            @foreach ($problems as $p)<div class="ds-fd__warn">⚠ {{ $p }} Check the numbers.</div>@endforeach

            <div class="ds-fd__seg" role="radiogroup" aria-label="Fuel">
                @foreach (\App\Support\Fuel\Fuel::TYPES as $k => $label)
                    <button type="button" role="radio" aria-checked="{{ $f['fuel_type'] === $k ? 'true' : 'false' }}" wire:click="$set('f.fuel_type', '{{ $k }}')" @class(['is-on' => $f['fuel_type'] === $k])>{{ $label }}</button>
                @endforeach
            </div>
            @error('f.fuel_type')<p class="ds-sa__err">{{ $message }}</p>@enderror

            <div class="ds-fd__form">
                <label class="is-wide"><small>Station</small><input type="text" wire:model.blur="f.station" placeholder="Petron Imus"></label>
                <label class="is-wide"><small>Product</small><input type="text" wire:model.blur="f.product" placeholder="Diesel Max"></label>
                <label><small>Liters</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.liters" placeholder="0.00"></label>
                <label><small>Price per liter</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.price_per_liter" placeholder="₱"></label>
                <label class="is-wide is-total"><small>Total</small><input type="text" inputmode="decimal" wire:model.live.debounce.600ms="f.total" placeholder="₱"></label>
                @error('f.liters')<p class="ds-sa__err">{{ $message }}</p>@enderror
                @error('f.total')<p class="ds-sa__err">{{ $message }}</p>@enderror
                <label><small>VATable sales</small><input type="text" inputmode="decimal" wire:model.blur="f.vatable" placeholder="₱"></label>
                <label><small>VAT 12%</small><input type="text" inputmode="decimal" wire:model.blur="f.vat" placeholder="₱"></label>
                <label><small>Invoice no.</small><input type="text" wire:model.blur="f.invoice_no"></label>
                <label><small>Date and time</small><input type="datetime-local" wire:model.blur="f.filled_at"></label>
            </div>

            @if ($needTin)
                <div class="ds-fd__ask">
                    <span>Is <b>TIN {{ $companyTin }}</b> written on the receipt?</span>
                    <span class="ds-fd__seg is-small">
                        <button type="button" wire:click="$set('f.buyer_tin_ok', '1')" @class(['is-on' => $f['buyer_tin_ok'] === '1'])>Yes</button>
                        <button type="button" wire:click="$set('f.buyer_tin_ok', '0')" @class(['is-on' => $f['buyer_tin_ok'] === '0'])>No</button>
                    </span>
                </div>
            @endif

            <div class="ds-fd__ask">
                <span>Paid with</span>
                <span class="ds-fd__seg is-small">
                    <button type="button" wire:click="$set('f.paid_with', 'card')" @class(['is-on' => $f['paid_with'] === 'card'])>💳 Fuel card</button>
                    <button type="button" wire:click="$set('f.paid_with', 'cash')" @class(['is-on' => $f['paid_with'] === 'cash'])>💵 Cash</button>
                </span>
            </div>
            @if ($f['paid_with'] === 'cash' && $cash && (float) $f['total'] > $cash->left() + 0.5)
                <div class="ds-fd__warn">This is more than the fuel cash left ({{ $peso($cash->left(), 0) }}).</div>
            @endif

            <button type="button" class="ds-sa__primary" wire:click="toOdometer">Next · odometer</button>
            <button type="button" class="ds-dr__link" wire:click="back">Take the receipt photo again</button>
        @endif

        {{-- ============ 3. odometer ============ --}}
        @if ($step === 'odometer')
            <div class="ds-fd__intro">
                <span class="ds-fd__big" aria-hidden="true">🚚</span>
                <strong>Photo of the odometer</strong>
                <p>The total km on the dashboard (not the trip meter). It shows how far the truck goes on a liter.</p>
            </div>
            <div x-data="{{ $photoJs }}" class="ds-fd__actions">
                <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                @if ($odometerUrl)<img src="{{ $odometerUrl }}" alt="Odometer" class="ds-fd__odo">@endif
                <button type="button" class="{{ $odometerUrl ? 'ds-sa__secondary' : 'ds-sa__primary' }}" x-on:click="take()" x-bind:disabled="busy">
                    <span x-show="! busy">📷 {{ $odometerUrl ? 'Take again' : 'Take odometer photo' }}</span>
                    <span x-show="busy" x-cloak>Saving… <span x-text="pct < 100 ? pct + '%' : ''"></span></span>
                </button>
                <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
            </div>
            <div class="ds-fd__form">
                <label class="is-wide is-total"><small>Odometer (km)</small><input type="text" inputmode="numeric" wire:model.live.debounce.600ms="f.odometer" placeholder="{{ $prevOdo ? 'last fill '.number_format($prevOdo) : '123456' }}"></label>
                @error('f.odometer')<p class="ds-sa__err">Type the km as a number.</p>@enderror
            </div>
            @if ($kmSince)
                <div class="ds-fd__kml"><span><small>Since the last fill</small><b>{{ number_format($kmSince) }} km</b></span><span><small>km per liter</small><b>{{ $kml }}</b></span></div>
            @elseif ($prevOdo && (int) $f['odometer'] > 0)
                <div class="ds-fd__warn">The last fill was at {{ number_format($prevOdo) }} km. Check the number.</div>
            @endif
            <button type="button" class="ds-sa__primary is-green" wire:click="save" wire:loading.attr="disabled">Save fill</button>
            <button type="button" class="ds-dr__link" wire:click="back">Back</button>
        @endif

        {{-- ============ done ============ --}}
        @if ($step === 'done' && $saved)
            <div class="ds-fd__intro">
                <span class="ds-fd__big is-ok" aria-hidden="true">✓</span>
                <strong>Fill saved</strong>
                <p>{{ rtrim(rtrim(number_format($saved->liters, 2), '0'), '.') }} L {{ $saved->fuel_type }} · {{ $peso($saved->total) }} · {{ $saved->paid_with === 'cash' ? 'cash' : 'fuel card' }}{{ $saved->km_per_liter ? ' · '.$saved->km_per_liter.' km/L' : '' }}</p>
                <p>Keep the paper receipt and give it to the office.</p>
            </div>
            <a href="{{ \App\Filament\Delivery\Pages\Dashboard::getUrl() }}" class="ds-sa__primary ds-fd__btn">Back to today</a>
            <button type="button" class="ds-dr__link" wire:click="another">Add another fill</button>
        @endif
    </section>
</div>
</x-filament-panels::page>
