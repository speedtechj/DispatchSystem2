<x-filament-panels::page>

    <x-filament::section icon="heroicon-o-qr-code" collapsible>
        <x-slot name="heading">Scan box to deliver</x-slot>

        {{-- Camera stops after each scan so it won't scan again behind the photo form --}}
        <div wire:ignore>
            <x-barcode-scanner method="scanInvoice" />
        </div>

    </x-filament::section>

    {{ $this->table }}
</x-filament-panels::page>
