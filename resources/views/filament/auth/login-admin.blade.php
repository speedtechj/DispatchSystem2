{{-- Admin sign-in: navy story panel on the left, form on the right. --}}
<div class="ds-auth ds-auth--admin">
    <section class="ds-auth-admin__story">
        <x-auth.company tone="dark">
            <span class="ds-company__sub ds-company__sub--accent">Admin</span>
        </x-auth.company>

        <div class="ds-auth-admin__pitch">
            <h1>Every box, from container to doorstep.</h1>
            <p>Manage containers, trips, trucks and staff for every hub.</p>
        </div>

        <div class="ds-auth-admin__foot">Dispatch &amp; delivery system</div>
        <div class="ds-auth-admin__ribs" aria-hidden="true"></div>
    </section>

    <section class="ds-auth__form-side">
        <div class="ds-auth__form">
            <span class="ds-auth__chip">Admin</span>
            <h2 class="ds-auth__title">Sign in</h2>
            <p class="ds-auth__lead">Use the email your administrator set up for you.</p>

            {{ $this->content }}

            <p class="ds-auth__help">Trouble signing in? Ask your administrator to check your account is active.</p>
        </div>
    </section>
</div>
