<x-filament-panels::page>
    <div class="ds-icons-preview" aria-label="How it looks now">
        <div class="ds-icons-preview__tab">
            <img src="{{ $faviconUrl }}" alt="Current favicon" width="16" height="16">
            <span>{{ \App\Support\Branding::companyName() }}</span>
        </div>
        @foreach ($apps as $app)
            <div class="ds-icons-preview__phone" title="{{ $app['what'] }}">
                <img src="{{ $app['icon'] }}" alt="Current {{ $app['what'] }} icon" width="64" height="64">
                <span>{{ $app['name'] }}</span>
            </div>
        @endforeach
        <p>
            New uploads apply straight away in the browser.
            On Android, the new name and icon are offered the next time the app is opened (in Chrome's ⋮ menu → Review app update).
            iPhone keeps the old icon: remove the app from the Home Screen and add it again.
        </p>
    </div>

    {{ $this->form }}

    <section class="ds-board__panel ds-qr-set" id="install-qr">
        <div class="ds-board__panel-head"><h2>Install QR codes</h2><span>for the phones of your staff and drivers</span></div>
        <form wire:submit="saveInstallBase" class="ds-qr-set__base">
            <label class="ds-gm__field">
                <span>Address phones use to open the apps (leave empty to use the app's own address: {{ $installAuto }})</span>
                <input type="url" wire:model="installBase" placeholder="https://app.your-company.com" autocomplete="off">
            </label>
            <x-filament::button type="submit">Save address</x-filament::button>
        </form>
        @error('installBase')<p class="ds-ai__err">{{ $message }}</p>@enderror
        @if (! \App\Support\InstallLinks::problem())
            <p class="ds-qr__ok">✓ Phones can open {{ \App\Support\InstallLinks::base() }} and install the apps.</p>
        @endif
        @include('filament.partials.install-apps', ['compact' => false])
    </section>
</x-filament-panels::page>
