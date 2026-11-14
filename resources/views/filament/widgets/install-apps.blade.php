<x-filament-widgets::widget>
    <x-filament::section>
        <x-slot name="heading">Install the apps on your phone</x-slot>
        <x-slot name="afterHeader">
            <button type="button" wire:click="hide" class="ds-qr__hide">Hide</button>
        </x-slot>
        @include('filament.partials.install-apps', ['compact' => true])
    </x-filament::section>
</x-filament-widgets::widget>
