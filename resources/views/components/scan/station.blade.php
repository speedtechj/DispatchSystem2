{{--
    Layout for a scan station: scanner card on the left, live result on the right.
    Slots: form (Filament form), progress, result, aside.
--}}
@props(['heading' => 'Scan', 'description' => null, 'icon' => 'heroicon-o-qr-code'])

<div class="ds-station">
    <section class="ds-station__panel">
        <div class="ds-station__title">
            <span class="ds-station__badge"><x-filament::icon :icon="$icon" class="h-6 w-6" /></span>
            <div>
                <h2>{{ $heading }}</h2>
                @if ($description)
                    <p>{{ $description }}</p>
                @endif
            </div>
        </div>

        {{ $form ?? '' }}

        {{ $progress ?? '' }}
    </section>

    <section class="ds-station__result" aria-live="polite">
        @if (isset($result) && trim($result) !== '')
            {{ $result }}
        @else
            <div class="ds-empty">
                <x-filament::icon icon="heroicon-o-viewfinder-circle" class="h-12 w-12" />
                <p class="ds-empty__title">Ready to scan</p>
                <p class="ds-empty__text">Use a handheld scanner, type the invoice number, or tap “Scan with camera”.</p>
            </div>
        @endif

        {{ $aside ?? '' }}
    </section>
</div>
