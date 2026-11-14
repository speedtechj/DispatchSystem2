{{-- iPhone install tip, no-signal screen and the small script that runs the app part. --}}
<div class="ds-pwa-sheet" id="ds-pwa-ios" hidden role="dialog" aria-modal="true" aria-labelledby="ds-pwa-ios-title">
    <div class="ds-pwa-sheet__backdrop" data-pwa-close></div>
    <div class="ds-pwa-sheet__panel">
        <span class="ds-pwa-sheet__grip" aria-hidden="true"></span>
        <div class="ds-pwa-sheet__head">
            <img src="{{ url("/pwa/{$panel}/icon-180.png?v={$version}") }}" alt="" width="56" height="56">
            <span>
                <strong id="ds-pwa-ios-title">Put {{ $name }} on your Home Screen</strong>
                <span>Opens full screen, straight to your trip.</span>
            </span>
        </div>
        <ol class="ds-pwa-sheet__steps">
            <li><span>1</span> <span>Tap <strong>Share</strong> <span class="ds-pwa-share" aria-hidden="true">⇧</span> at the bottom of Safari</span></li>
            <li><span>2</span> <span>Choose <strong>Add to Home Screen</strong></span></li>
            <li><span>3</span> <span>Tap <strong>Add</strong>, then open it from your Home Screen</span></li>
        </ol>
        <button type="button" class="ds-pwa-sheet__close" data-pwa-close>Not now</button>
    </div>
</div>

<div class="ds-pwa-offline" id="ds-pwa-offline" hidden role="alertdialog" aria-labelledby="ds-pwa-offline-title">
    <div class="ds-pwa-offline__body">
        <span class="ds-pwa-offline__icon" aria-hidden="true">
            <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 8.8a15 15 0 0 1 4.2-2.6M10.5 5.1A15 15 0 0 1 22 8.8M5 12.9a10 10 0 0 1 3.4-2M15.5 11a10 10 0 0 1 3.5 1.9M8.5 16.4a5 5 0 0 1 7 0M12 20h.01M3 3l18 18"/></svg>
        </span>
        <h2 id="ds-pwa-offline-title">No signal right now</h2>
        <p>This page comes back by itself when your phone is online again.</p>
        <ul>
            <li><span class="is-ok" aria-hidden="true">✓</span> Boxes you already marked are saved</li>
            <li><span class="is-ok" aria-hidden="true">✓</span> Nothing is lost while you wait</li>
            <li><span class="is-warn" aria-hidden="true">!</span> Marking a box delivered needs a signal</li>
        </ul>
        <button type="button" data-pwa-retry>Try again</button>
    </div>
</div>

<script data-navigate-once>
(() => {
    if (window.dsInstallApp) return;

    const html = document.documentElement;
    const ua = navigator.userAgent;
    const ios = /iphone|ipad|ipod/i.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    const standalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
    let installPrompt = null;

    const installable = (on) => html.toggleAttribute('data-pwa-installable', on);

    if ('serviceWorker' in navigator) {
        navigator.serviceWorker.register('/sw.js', { scope: @js('/'.$panel) }).catch(() => {});
    }

    addEventListener('beforeinstallprompt', (event) => {
        event.preventDefault();
        installPrompt = event;
        installable(true);
    });

    addEventListener('appinstalled', () => {
        installPrompt = null;
        installable(false);
    });

    if (ios && ! standalone) installable(true);

    const sheet = () => document.getElementById('ds-pwa-ios');

    const openSheet = () => {
        const el = sheet();
        if (! el) return;
        el.hidden = false;
        el.querySelector('.ds-pwa-sheet__close')?.focus();
    };

    window.dsInstallApp = async () => {
        if (installPrompt) {
            installPrompt.prompt();
            await installPrompt.userChoice;
            installPrompt = null;
            installable(false);
        } else if (ios) {
            openSheet();
        }
    };

    document.addEventListener('click', (event) => {
        if (event.target.closest('[data-pwa-close]')) {
            sheet().hidden = true;
            try { localStorage.setItem('ds-pwa-ios-tip', '1'); } catch (e) {}
        }

        const retry = event.target.closest('[data-pwa-retry]');
        if (retry) {
            retry.disabled = true;
            retry.textContent = 'Checking connection…';
            fetch('/pwa/offline', { method: 'HEAD', cache: 'no-store' })
                .then(() => showOffline(false))
                .catch(() => {})
                .finally(() => setTimeout(() => { retry.disabled = false; retry.textContent = 'Try again'; }, 600));
        }
    });

    document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && sheet() && ! sheet().hidden) sheet().hidden = true;
    });

    const showOffline = (on) => {
        const el = document.getElementById('ds-pwa-offline');
        // The Driver app keeps working without signal (driver-offline.js), so it needs no "No signal" cover.
        if (el) el.hidden = ! on || !! document.getElementById('ds-net');
    };

    addEventListener('offline', () => showOffline(true));
    addEventListener('online', () => showOffline(false));

    document.addEventListener('livewire:navigated', () => {
        showOffline(! navigator.onLine);

        // iPhone: show the install tip once.
        let seen = '1';
        try { seen = localStorage.getItem('ds-pwa-ios-tip'); } catch (e) {}
        if (ios && ! standalone && ! seen) {
            setTimeout(openSheet, 1500);
        }

        // "Scan a box" shortcut: open the camera scanner.
        if (new URLSearchParams(location.search).get('scan') === '1') {
            setTimeout(() => document.querySelector('.bb-scanner [x-on\\:click="toggle()"]')?.click(), 500);
        }
    });

})();
</script>
