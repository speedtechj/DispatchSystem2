<x-filament-panels::page>
<form wire:submit="save" class="ds-mp">
    <div class="ds-mp__two">
        <section class="ds-board__panel ds-tm__form">
            <div class="ds-board__panel-head"><h2>Your company on the receipt</h2></div>
            <label><span>Company name (as registered)</span><input type="text" wire:model="values.company_name" maxlength="120"></label>
            <label><span>Company TIN</span><input type="text" wire:model="values.company_tin" placeholder="123-456-789-000" inputmode="numeric"></label>
            @error('values.company_tin')<p class="ds-fu__err">{{ $message }}</p>@enderror
            <p class="ds-board__muted">To claim the 12% VAT on fuel, receipts of ₱1,000 and up need your company name and TIN. Give each driver a small card with both to show the cashier. The Fuel page flags receipts without it.</p>
        </section>
        <section class="ds-board__panel ds-tm__form">
            <div class="ds-board__panel-head"><h2>Fuel card and cash</h2></div>
            <label><span>Fuel card you use</span><select wire:model="values.card_brand">@foreach (\App\Support\Fuel\Fuel::PROVIDERS as $k => $n)<option value="{{ $k }}">{{ $n }}</option>@endforeach</select></label>
            <label><span>Give fuel cash for trips from (km)</span><input type="number" wire:model="values.cash_min_km" min="0"></label>
            <label><span>Buffer on the cash estimate (%)</span><input type="number" wire:model="values.buffer_pct" min="0" max="50"></label>
            <label><span>km per liter for a truck with no fills yet</span><input type="number" step="0.1" wire:model="values.default_kml" min="1"></label>
            <p class="ds-board__muted">The fleet card is used first. Cash is a backup for long trips or stations that don't take the card.
                Reading receipts with AI: {!! $aiOn ? '<b class="is-ok">on</b>' : '<b>off</b> · switch on "Read fuel receipts" in Settings → AI' !!}.</p>
        </section>
    </div>
    <section class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>Trucks</h2></div>
        <div class="ds-fu__tr is-head is-set"><span>Truck</span><span>Fuel</span><span>Tank (L)</span><span>Fuel card · last 4</span></div>
        @foreach ($list as $t)
            <div class="ds-fu__tr is-set" wire:key="ft-{{ $t->id }}">
                <span><b>{{ $t->plate_no }}</b> <small>{{ $t->description ?: $t->category }}</small></span>
                <span><select wire:model="trucks.{{ $t->id }}.fuel_type" aria-label="Fuel for {{ $t->plate_no }}"><option value="">—</option><option value="diesel">Diesel</option><option value="gasoline">Gasoline</option></select></span>
                <span><input type="number" wire:model="trucks.{{ $t->id }}.tank_liters" min="10" aria-label="Tank liters"></span>
                <span><input type="text" wire:model="trucks.{{ $t->id }}.fuel_card_last4" maxlength="4" inputmode="numeric" placeholder="1234" aria-label="Card last 4"></span>
            </div>
            @error('trucks.'.$t->id.'.fuel_card_last4')<p class="ds-fu__err">{{ $t->plate_no }}: {{ $message }}</p>@enderror
        @endforeach
        <p class="ds-board__muted">Fuel: the Driver app and Fuel page warn when a receipt says the other fuel. Tank: a fill bigger than the tank is flagged. Card: matches the fuel card statement to the truck.</p>
    </section>
    <div><x-filament::button type="submit">Save</x-filament::button></div>
</form>
</x-filament-panels::page>
