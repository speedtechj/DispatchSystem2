{{-- Service worker for the Driver app. Registered with scope /delivery, so it only looks after Delivery panel pages. --}}
// Dispatch service worker {{ $version }}
// - Opens fast: keeps the app's CSS, JavaScript, fonts and logo on the phone.
// - No signal: shows a friendly offline page instead of the browser error.
// - Never stores signed-in pages or form posts, so no one sees stale or someone else's data.
const VERSION = 'ds-{{ $version }}-1';
const OFFLINE_URL = '/pwa/offline';
// The Driver app without signal: a small page that works from the phone's saved trip.
const DRIVER_SHELL = '/delivery-offline';
const DRIVER_SCRIPT = @json($driverScript ?? null);
const BRAND_FILES = @json(array_values(array_filter([$logoPath ?? null, $faviconPath ?? null])));

self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(VERSION)
            .then((cache) => cache.addAll([new Request(OFFLINE_URL, { cache: 'reload' }), ...BRAND_FILES]))
            .then(() => caches.open(VERSION))
            .then((cache) => /\/delivery\/?$/.test(self.registration.scope)
                ? cache.addAll([new Request(DRIVER_SHELL, { cache: 'reload' }), ...(DRIVER_SCRIPT ? [DRIVER_SCRIPT] : [])])
                : null)
            .catch(() => {})
            .then(() => self.skipWaiting()),
    );
});

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys()
            .then((keys) => Promise.all(keys.filter((key) => key.startsWith('ds-') && key !== VERSION).map((key) => caches.delete(key))))
            .then(() => self.clients.claim()),
    );
});

function isAppFile(url) {
    if (url.origin === self.location.origin) {
        return /^\/(build|css|js|fonts|vendor)\//.test(url.pathname)
            || /^\/pwa\/[a-z]+\/icon(-\d+\.png|\/\d+)$/.test(url.pathname)
            || BRAND_FILES.includes(url.pathname)
            || url.pathname === '/favicon.svg';
    }

    return /(^|\.)fonts\.(bunny\.net|googleapis\.com|gstatic\.com)$/.test(url.hostname);
}

self.addEventListener('fetch', (event) => {
    const request = event.request;

    if (request.method !== 'GET') {
        return;
    }

    if (request.mode === 'navigate') {
        const path = new URL(request.url).pathname;
        const driver = path === '/delivery' || path.startsWith('/delivery/') || path === DRIVER_SHELL;

        event.respondWith(fetch(request).catch(async () => (driver && await caches.match(DRIVER_SHELL)) || caches.match(OFFLINE_URL)));

        return;
    }

    const url = new URL(request.url);

    if (! isAppFile(url)) {
        return;
    }

    // Use the stored copy straight away and refresh it in the background.
    event.respondWith(
        caches.open(VERSION).then(async (cache) => {
            const stored = await cache.match(request);
            const fresh = fetch(request)
                .then((response) => {
                    if (response.ok || response.type === 'opaque') {
                        cache.put(request, response.clone());
                    }

                    return response;
                })
                .catch(() => stored);

            return stored || fresh;
        }),
    );
});
