{{-- "Install app" in the user menu. Shown only when the browser can install the app (or on iPhone, where it opens the tip). --}}
<x-filament::dropdown.list class="ds-pwa-install">
    <x-filament::dropdown.list.item
        tag="button"
        icon="heroicon-m-arrow-down-tray"
        x-on:click="typeof close === 'function' && close(); window.dsInstallApp && window.dsInstallApp()"
    >
        Install app
    </x-filament::dropdown.list.item>
</x-filament::dropdown.list>
