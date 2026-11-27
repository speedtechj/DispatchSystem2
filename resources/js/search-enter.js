/*
 * Part 45 (board 72): table searches wait for Enter. Filament's "search on blur" field updates when it
 * loses focus; Enter (typed, or sent by a barcode scanner after the code) does that, then the cursor comes back.
 */
(function () {
    if (window.dsSearchEnter) return;
    window.dsSearchEnter = true;
    document.addEventListener('keydown', (e) => {
        const t = e.target;
        if (e.key !== 'Enter' || !t || !t.matches || !t.matches('.fi-ta-search-field input')) return;
        e.preventDefault();
        t.blur();
        setTimeout(() => { try { t.focus({ preventScroll: true }); t.select(); } catch (err) {} }, 250);
    });
})();
