{{-- Partner hub sign-in: form on the left, the hub's four steps on a yellow panel. --}}
<div class="ds-auth ds-auth--company">
    <section class="ds-auth__form-side ds-auth__form-side--white">
        <x-auth.company>
            <span class="ds-company__sub">Partner hub</span>
        </x-auth.company>

        <div class="ds-auth__form">
            <h2 class="ds-auth__title ds-auth__title--xl">Welcome back</h2>
            <p class="ds-auth__lead">Sign in to your partner hub.</p>

            {{ $this->content }}
        </div>

        <p class="ds-auth__help">Accounts are created by your {{ \App\Support\Branding::companyName() }} administrator.</p>
    </section>

    <section class="ds-auth-company__story" aria-label="How your hub works">
        <h1>Your hub, your trips, your deliveries.</h1>
        <ol class="ds-auth-company__steps">
            @foreach ([
                ['Receive', 'Boxes arrive at your hub from the main hub.'],
                ['Assign', 'Put them on one of your own delivery trips.'],
                ['Load', 'Scan every box onto your truck.'],
                ['Deliver', 'Your driver scans, takes a photo, done.'],
            ] as [$title, $text])
                <li>
                    <span class="ds-auth-company__num">{{ $loop->iteration }}</span>
                    <div>
                        <strong>{{ $title }}</strong>
                        <span>{{ $text }}</span>
                    </div>
                </li>
            @endforeach
        </ol>
    </section>
</div>
