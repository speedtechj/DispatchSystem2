{{-- Browser tab icon for every panel, from Admin → App icon & favicon. Replaces the panel's built-in one. --}}
<link rel="icon" href="{{ $url }}{{ str_contains($url, '?') ? '&' : '?' }}v={{ $version }}" data-ds-favicon>
<script data-navigate-once>
(() => {
    const keepOurs = () => document.querySelectorAll('link[rel~="icon"]:not([data-ds-favicon])').forEach((link) => link.remove());
    keepOurs();
    document.addEventListener('livewire:navigated', keepOurs);
})();
</script>
