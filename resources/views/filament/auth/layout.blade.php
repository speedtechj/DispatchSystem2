{{-- Full-screen layout for the sign-in pages (no card wrapper, no topbar). --}}
<x-filament-panels::layout.base :livewire="$livewire">
    {{-- Keep the sign-in pages light, even when the device is in dark mode. --}}
    <script>
        (() => {
            const root = document.documentElement;
            const forceLight = () => root.classList.contains('dark') && root.classList.remove('dark');
            forceLight();
            new MutationObserver(forceLight).observe(root, { attributes: true, attributeFilter: ['class'] });
        })();
    </script>

    <main id="fi-main-content" class="ds-auth-main">
        {{ $slot }}
    </main>
</x-filament-panels::layout.base>
