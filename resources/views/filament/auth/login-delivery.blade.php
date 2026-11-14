{{-- Driver sign-in: built for phones first. --}}
<div class="ds-auth ds-auth--delivery">
    <section class="ds-auth-delivery__top">
        <x-auth.company size="sm">
            <span class="ds-company__sub">Driver app</span>
        </x-auth.company>
        <h1>Today's deliveries start here.</h1>
    </section>

    <section class="ds-auth-delivery__form">
        <h2 class="ds-auth__title">Welcome back</h2>
        <p class="ds-auth__lead">Sign in to see the boxes on your truck.</p>

        {{ $this->content }}
    </section>
</div>
