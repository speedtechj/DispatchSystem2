{{-- Warehouse sign-in: the ribbed side of a container, one card in the middle. --}}
<div class="ds-auth ds-auth--warehouse">
    <div class="ds-auth-warehouse__stripe" aria-hidden="true"></div>

    <x-auth.company tone="dark" size="lg" class="ds-auth-warehouse__brand" />

    <div class="ds-auth-warehouse__card">
        <div class="ds-auth-warehouse__tab" aria-hidden="true"></div>
        <x-auth.company size="sm">
            <span class="ds-company__sub">Warehouse</span>
        </x-auth.company>

        <h2 class="ds-auth__title">Warehouse sign in</h2>

        {{ $this->content }}
    </div>
</div>
