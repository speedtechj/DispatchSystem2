{{-- Scan app sign-in: phones first. Warehouse, partner hub and office accounts all sign in here. --}}
<div class="ds-auth ds-auth--delivery ds-auth--scan">
    <section class="ds-auth-delivery__top">
        <x-auth.company size="sm">
            <span class="ds-company__sub">Scan app</span>
        </x-auth.company>
        <h1>Load and unload, box by box.</h1>
    </section>

    <section class="ds-auth-delivery__form">
        <h2 class="ds-auth__title">Welcome back</h2>
        <p class="ds-auth__lead">Sign in with your warehouse or partner hub account.</p>

        {{ $this->content }}
    </section>
</div>
