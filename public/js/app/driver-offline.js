/*
 * Driver app without signal.
 *
 * - Keeps today's trip on the phone (IndexedDB) while there is signal.
 * - Without signal: shows its own screens (find a box, deliver with photos, can't deliver)
 *   and keeps each one on the phone in a queue.
 * - When the signal is back: sends the queue by itself, oldest first, with the real time.
 *   Anything the office changed meanwhile is not forced through: it shows as "Needs attention".
 *
 * Runs on the Driver app home page (/delivery) and on the offline page (/delivery-offline).
 */
(function () {
    /*
     * Make a phone photo smaller before it is sent: longest side 1600 px, JPEG 80%.
     * A 3 MB iPhone photo becomes about 300 KB. Two ways, because iPhone Safari does not
     * always manage the first one; if both fail the photo is sent as it is (the server
     * makes it smaller then). Used by every photo button (window.dsShrinkPhoto).
     */
    async function shrinkPhoto(file, maxSide = 1600, quality = 0.8) {
        if (!file || (file.type && !/^image\//.test(file.type))) return file;
        const draw = (src, w, h) => {
            const s = Math.min(1, maxSide / Math.max(w, h));
            const c = document.createElement('canvas');
            c.width = Math.max(1, Math.round(w * s));
            c.height = Math.max(1, Math.round(h * s));
            c.getContext('2d').drawImage(src, 0, 0, c.width, c.height);
            return new Promise((r) => c.toBlob(r, 'image/jpeg', quality));
        };
        const ways = [
            async () => {
                const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' });
                try { return await draw(bmp, bmp.width, bmp.height); } finally { if (bmp.close) bmp.close(); }
            },
            async () => {
                // iPhone: a plain image keeps the photo the right way up when drawn
                const url = URL.createObjectURL(file);
                try {
                    const img = new Image();
                    img.src = url;
                    if (img.decode) await img.decode();
                    else await new Promise((ok, no) => { img.onload = ok; img.onerror = no; });
                    return await draw(img, img.naturalWidth, img.naturalHeight);
                } finally { URL.revokeObjectURL(url); }
            },
        ];
        for (const way of ways) {
            try {
                const blob = await way();
                if (blob && blob.size > 0) {
                    return blob.size < file.size ? new File([blob], 'photo.jpg', { type: 'image/jpeg', lastModified: Date.now() }) : file;
                }
            } catch (e) { /* try the next way */ }
        }
        return file;
    }
    window.dsShrinkPhoto = window.dsShrinkPhoto || shrinkPhoto;

    if (window.dsDriverOffline) return;

    const TRIP_URL = '/delivery-offline/trip';
    const SYNC_URL = '/delivery-offline/sync';
    const DB_NAME = 'ds-driver';
    const MAX_PHOTO_SIDE = 1600;

    // ------------------------------------------------------------------ storage (IndexedDB)

    let dbPromise = null;
    function db() {
        if (!dbPromise) {
            dbPromise = new Promise((resolve, reject) => {
                const req = indexedDB.open(DB_NAME, 1);
                req.onupgradeneeded = () => {
                    const d = req.result;
                    if (!d.objectStoreNames.contains('kv')) d.createObjectStore('kv');
                    if (!d.objectStoreNames.contains('queue')) d.createObjectStore('queue', { keyPath: 'uuid' });
                };
                req.onsuccess = () => resolve(req.result);
                req.onerror = () => reject(req.error);
            });
        }
        return dbPromise;
    }
    async function tx(store, mode, fn) {
        const d = await db();
        return new Promise((resolve, reject) => {
            const t = d.transaction(store, mode);
            const s = t.objectStore(store);
            const out = fn(s);
            t.oncomplete = () => resolve(out && 'result' in out ? out.result : out);
            t.onerror = () => reject(t.error);
        });
    }
    const kvGet = (k) => tx('kv', 'readonly', (s) => s.get(k));
    const kvSet = (k, v) => tx('kv', 'readwrite', (s) => s.put(v, k));
    const qAll = async () => ((await tx('queue', 'readonly', (s) => s.getAll())) || []).sort((a, b) => a.at.localeCompare(b.at));
    const qPut = (item) => tx('queue', 'readwrite', (s) => s.put(item));
    const qDel = (uuid) => tx('queue', 'readwrite', (s) => s.delete(uuid));

    // ------------------------------------------------------------------ helpers

    const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0; return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    }));
    const timeOf = (iso) => new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    const norm = (code) => String(code || '').trim().toUpperCase().replace(/[\x00-\x1F\x7F]+/g, '');
    const buzz = (ok) => { try { navigator.vibrate && navigator.vibrate(ok ? 60 : [80, 60, 80]); } catch (e) {} };

    async function shrink(file) {
        return shrinkPhoto(file, MAX_PHOTO_SIDE);
    }

    // ------------------------------------------------------------------ state

    const state = {
        snapshot: null,      // { trip, boxes, reasons, driver, saved_at }
        queue: [],
        online: navigator.onLine,
        sending: false,
        sent: 0,
        forced: false,       // offline screens shown even with signal (the offline page)
        view: 'home',        // home, box, deliver, miss, queue, camera
        box: null,
        photos: [],          // { blob, url }
        reason: null,
        note: '',
        search: '',
        toast: null,
        authProblem: false,
    };

    async function load() {
        state.snapshot = (await kvGet('snapshot')) || null;
        state.queue = await qAll();
    }

    /** Ask the server for today's boxes (and a fresh security token). */
    async function refreshTrip() {
        const res = await fetch(TRIP_URL, { credentials: 'same-origin', headers: { Accept: 'application/json' }, cache: 'no-store' });
        if (res.status === 401) { state.authProblem = true; throw new Error('auth'); }
        if (!res.ok) throw new Error('http ' + res.status);
        const data = await res.json();
        state.authProblem = false;
        const previous = state.snapshot;
        if (previous && previous.driver && data.driver && previous.driver.id !== data.driver.id) {
            // another driver signed in on this phone: keep only their own queue items
            state.queue = state.queue.filter((q) => q.driver_id === data.driver.id);
        }
        state.snapshot = data;
        await kvSet('snapshot', { ...data, csrf: undefined });
        return data.csrf;
    }

    // ------------------------------------------------------------------ sending

    async function flush() {
        if (state.sending || !navigator.onLine) return false;
        const waiting = state.queue.filter((q) => q.status === 'wait');
        if (!waiting.length) return false;

        state.sending = true; state.sent = 0; render();
        let csrf;
        try { csrf = await refreshTrip(); } catch (e) { state.sending = false; render(); return false; }

        let changed = false;
        for (const item of waiting) {
            const form = new FormData();
            form.append('uuid', item.uuid);
            form.append('type', item.type);
            form.append('tripinvoice_id', item.box_id);
            form.append('at', item.at);
            if (item.reason) form.append('reason', item.reason);
            if (item.note) form.append('note', item.note);
            (item.photos || []).forEach((b, i) => form.append('photos[]', b, `photo-${i + 1}.jpg`));
            try {
                const res = await fetch(SYNC_URL, { method: 'POST', body: form, credentials: 'same-origin', headers: { Accept: 'application/json', 'X-CSRF-TOKEN': csrf } });
                if (res.status === 401 || res.status === 419) { state.authProblem = true; break; }
                if (res.status === 422) {
                    const body = await res.json().catch(() => ({}));
                    item.status = 'fail'; item.message = body.message || 'The office could not save this one.';
                } else if (!res.ok) {
                    break; // server problem: try again later
                } else {
                    const body = await res.json();
                    item.status = body.status === 'saved' ? 'sent' : 'fail';
                    item.message = body.message || null;
                }
                if (item.status !== 'wait') { item.photos = []; item.photoCount = item.photoCount || 0; item.done_at = new Date().toISOString(); }
                await qPut(item);
                state.sent++; changed = true; render();
            } catch (e) {
                break; // signal dropped again
            }
        }
        state.queue = await qAll();
        state.sending = false;
        try { await refreshTrip(); } catch (e) {}
        render();
        if (changed) document.dispatchEvent(new CustomEvent('ds-offline-sent'));
        return changed;
    }

    // ------------------------------------------------------------------ boxes on the phone

    function boxes() {
        const list = (state.snapshot && state.snapshot.boxes) || [];
        const queued = new Map(state.queue.filter((q) => q.status !== 'fail').map((q) => [q.box_id, q.type]));
        return list.map((b) => ({ ...b, local: queued.get(b.id) || null }));
    }
    function counts() {
        const all = boxes();
        const delivered = all.filter((b) => b.delivered || b.local === 'deliver').length;
        return { total: all.length, delivered, left: all.length - delivered, waiting: state.queue.filter((q) => q.status === 'wait').length,
            attention: state.queue.filter((q) => q.status === 'fail').length };
    }
    /** Stops still to visit (Maps & routes), in order. A stop drops off once all its boxes are delivered. */
    function stops() {
        const left = new Map(boxes().filter((b) => !b.delivered && b.local !== 'deliver').map((b) => [b.id, b]));
        return ((state.snapshot && state.snapshot.stops) || []).map((s) => {
            const mine = (s.boxes || []).map((id) => left.get(id)).filter(Boolean);
            return mine.length ? { ...s, count: mine.length, first: mine[0].invoice } : null;
        }).filter(Boolean);
    }
    const IOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    function navUrl(app, s) {
        const to = encodeURIComponent(s.go);
        if (app === 'waze') return s.lat !== null ? 'https://waze.com/ul?ll=' + to + '&navigate=yes' : 'https://waze.com/ul?q=' + to + '&navigate=yes';
        if (app === 'apple') return 'https://maps.apple.com/?daddr=' + to + '&dirflg=d';
        return 'https://www.google.com/maps/dir/?api=1&destination=' + to + '&travelmode=driving';
    }
    function telOf(p) { return p ? 'tel:' + String(p).replace(/[^0-9+]/g, '') : ''; }
    function findBox(code) {
        const c = norm(code);
        return boxes().find((b) => (b.codes || [b.invoice]).some((x) => norm(x) === c));
    }

    // ------------------------------------------------------------------ actions

    function openBox(code) {
        const b = findBox(code);
        if (!b) { toast('bad', `${norm(code)} is not in today's saved list`, 'Keep it aside. Check again when you have signal.'); buzz(false); return; }
        if (b.delivered || b.local === 'deliver') { toast('bad', `${b.invoice} is already delivered`, b.local ? 'Saved on this phone, waiting to send.' : ''); buzz(false); return; }
        state.box = b; state.view = 'box'; state.photos = []; state.note = ''; state.reason = null; buzz(true); render();
    }

    async function addPhotos(files) {
        for (const f of files) {
            if (state.view === 'miss' && state.photos.length >= 3) break;
            const blob = await shrink(f);
            state.photos.push({ blob, url: URL.createObjectURL(blob) });
        }
        render();
    }

    async function save(type) {
        const b = state.box;
        if (!b) return;
        if (type === 'deliver' && !state.photos.length) { toast('bad', 'Take at least one photo', ''); return; }
        const r = type === 'miss' ? reasons().find((x) => x.value === state.reason) : null;
        if (type === 'miss') {
            if (!r) { toast('bad', 'Pick a reason', ''); return; }
            if (r.note && !state.note.trim()) { toast('bad', 'Please add a note for this reason', ''); return; }
            if (r.photo && !state.photos.length) { toast('bad', 'Please add a photo for this reason', ''); return; }
        }
        const item = {
            uuid: uuid(), type, box_id: b.id, invoice: b.invoice, name: b.name, at: new Date().toISOString(),
            reason: r ? r.value : null, reasonLabel: r ? r.label : null, note: state.note.trim() || null,
            photos: state.photos.map((p) => p.blob), photoCount: state.photos.length, status: 'wait',
            driver_id: state.snapshot && state.snapshot.driver ? state.snapshot.driver.id : null,
        };
        await qPut(item);
        state.queue = await qAll();
        state.photos.forEach((p) => URL.revokeObjectURL(p.url));
        state.photos = []; state.box = null; state.view = 'home';
        buzz(true);
        toast('saved', type === 'deliver' ? `${item.invoice} saved on this phone` : `${item.invoice} kept on the truck`,
            'It will send by itself when the signal is back.', item.uuid);
        if (navigator.onLine) flush();
    }

    async function undo(id) {
        const item = state.queue.find((q) => q.uuid === id);
        if (!item || item.status !== 'wait') return;
        await qDel(id);
        state.queue = await qAll();
        state.toast = null;
        render();
    }

    async function clearDone() {
        for (const q of state.queue.filter((x) => x.status === 'sent')) await qDel(q.uuid);
        state.queue = await qAll(); render();
    }

    async function dismiss(id) { await qDel(id); state.queue = await qAll(); render(); }

    const reasons = () => (state.snapshot && state.snapshot.reasons) || [];

    let toastTimer = null;
    function toast(kind, title, sub, undoId) {
        state.toast = { kind, title, sub, undoId };
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => { state.toast = null; render(); }, 6000);
        render();
    }

    // ------------------------------------------------------------------ camera (phones with a built-in barcode reader)

    let camStream = null; let camLoop = null;
    async function startCamera() {
        if (!('BarcodeDetector' in window)) return;
        state.view = 'camera'; render();
        try {
            const detector = new window.BarcodeDetector();
            camStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false });
            const video = document.querySelector('#dso-video');
            if (!video) return stopCamera();
            video.srcObject = camStream; await video.play();
            camLoop = setInterval(async () => {
                try {
                    const found = await detector.detect(video);
                    if (found && found[0]) { const code = found[0].rawValue; stopCamera(); openBox(code); }
                } catch (e) {}
            }, 350);
        } catch (e) {
            stopCamera(); toast('bad', 'The camera could not start', 'Type the box number instead.');
        }
    }
    function stopCamera() {
        clearInterval(camLoop); camLoop = null;
        if (camStream) camStream.getTracks().forEach((t) => t.stop());
        camStream = null;
        if (state.view === 'camera') { state.view = 'home'; render(); }
    }

    // ------------------------------------------------------------------ rendering

    function shown() { return state.forced || !state.online; }

    function netBar() {
        const c = counts();
        let cls, title, sub;
        if (!state.online) { cls = 'is-off'; title = 'No signal'; sub = c.waiting ? `${c.waiting} waiting to send · kept on this phone` : 'You can keep scanning and delivering'; }
        else if (state.sending) { cls = 'is-send'; title = 'Back online · sending'; sub = `${state.sent} of ${c.waiting + state.sent} sent`; }
        else if (state.authProblem && c.waiting) { cls = 'is-warn'; title = 'Sign in again to send'; sub = `${c.waiting} waiting on this phone`; }
        else if (c.attention) { cls = 'is-warn'; title = `Online · ${c.attention} needs attention`; sub = 'Tap to see why'; }
        else if (c.waiting) { cls = 'is-send'; title = 'Online'; sub = `${c.waiting} waiting to send`; }
        else { cls = 'is-on'; title = 'Online'; sub = 'Every delivery is saved'; }
        return { cls, title, sub, n: c.waiting + c.attention };
    }

    /** The small signal bar shown on the online Driver app. */
    function renderBar() {
        const el = document.getElementById('ds-net');
        if (!el) return;
        const n = netBar();
        el.className = 'dso-net ' + n.cls + (n.n || !state.online ? ' is-shown' : '');
        el.innerHTML = `<i></i><span><strong>${esc(n.title)}</strong><small>${esc(n.sub)}</small></span>${n.n ? `<button type="button" data-dso="queue">${n.n} ›</button>` : ''}`;
    }

    function photoGrid(max) {
        const tiles = state.photos.map((p, i) => `<span class="dso-proof"><img src="${p.url}" alt="Photo ${i + 1}"><b>${i + 1}</b><button type="button" data-dso="rmphoto" data-i="${i}" aria-label="Remove photo">✕</button></span>`).join('');
        const can = !max || state.photos.length < max;
        return `<div class="dso-grid">${tiles}${can ? `<label class="dso-add"><input type="file" accept="image/*" capture="environment" multiple data-dso="photos" hidden><span>📷</span>${state.photos.length ? 'Add another' : 'Take photo'}</label>` : ''}</div>`;
    }

    function screenHtml() {
        const s = state.snapshot;
        const c = counts();
        const n = netBar();
        const bar = `<div class="dso-net ${n.cls} is-shown"><i></i><span><strong>${esc(n.title)}</strong><small>${esc(n.sub)}</small></span>${n.n ? `<button type="button" data-dso="queue">${n.n} ›</button>` : ''}</div>`;
        const toastHtml = state.toast ? `<div class="dso-toast is-${state.toast.kind}"><span>${state.toast.kind === 'bad' ? '!' : '⏳'}</span><span><strong>${esc(state.toast.title)}</strong>${state.toast.sub ? `<small>${esc(state.toast.sub)}</small>` : ''}</span>${state.toast.undoId ? `<button type="button" data-dso="undo" data-id="${esc(state.toast.undoId)}">Undo</button>` : ''}</div>` : '';

        if (!s) {
            return `${bar}<section class="dso-screen"><div class="dso-empty"><strong>Today's trip is not on this phone yet</strong><p>Open the Driver app once with signal (at the warehouse is best). After that it works without signal.</p></div></section>`;
        }
        if (!s.trip) {
            return `${bar}<section class="dso-screen"><div class="dso-empty"><strong>You're not on a trip</strong><p>When the office puts you on a truck, today's boxes are saved here.</p></div></section>`;
        }

        if (state.view === 'nav' && state.stop) {
            const st = state.stop;
            const off = !state.online;
            const app = (key, letter, name, good, bad, dim) => `<button type="button" class="dso-app${dim ? ' is-dim' : ''}" data-dso="go" data-app="${key}"><i class="is-${key}">${letter}</i><span><b>${name}</b><small class="${dim ? 'dso-amber' : 'is-ok'}">${dim ? bad : good}</small></span>›</button>`;
            return `${bar}<section class="dso-screen"><div class="dso-sheet">
                <div class="dso-sheethead"><small>Stop ${st.no}${off ? ' · no signal' : ''}</small><strong>${esc(st.name)}</strong><span>${esc(st.address || st.place)} · ${st.lat !== null ? (st.exact ? '📍 exact pin' : '📍 area pin') : 'no pin'} · ${st.count} ${st.count > 1 ? 'boxes' : 'box'}</span></div>
                ${off ? `<p class="dso-navtip">${st.lat !== null ? 'No signal: use a map app with your area downloaded. It finds the pin and drives you there offline.' : 'This stop has no pin, so the map app has to search the address. That needs signal.'}</p>` : ''}
                ${app('google', 'G', 'Google Maps', off ? '✓ works offline with a downloaded map' : 'Best street and address detail', '', false)}
                ${IOS ? app('apple', 'A', 'Apple Maps', off ? '✓ works offline with a downloaded map' : 'Already on your iPhone', '', false) : ''}
                ${app('waze', 'W', 'Waze', 'Best for traffic and shortcuts', 'needs signal · may not open the route', off)}
                ${off ? '<p class="dso-note">Tip: download your area once on office Wi-Fi. Google Maps: profile → Offline maps. Apple Maps: profile → Offline Maps.</p>' : ''}
                <div class="dso-two">${st.phone ? `<a class="dso-ghostbtn" href="${esc(telOf(st.phone))}">Call ${esc(String(st.name).split(' ')[0])}</a>` : ''}<button type="button" class="dso-primary is-green" style="height:3rem" data-dso="open" data-code="${esc(st.first)}">I'm here · deliver</button></div>
                <button type="button" class="dso-link" data-dso="home">Close</button>
            </div></section>${toastHtml}`;
        }

        if (state.view === 'queue') {
            const rows = state.queue.slice().reverse().map((q) => {
                const st = q.status === 'wait' ? ['⏳', 'Waiting', 'is-wait'] : q.status === 'sent' ? ['✓', 'Sent', 'is-ok'] : ['!', 'Needs attention', 'is-warn'];
                const what = q.type === 'deliver' ? 'Delivered' : `Can't deliver · ${q.reasonLabel || ''}`;
                return `<div class="dso-q ${st[2]}"><span class="dso-qi">${st[0]}</span><span class="dso-qt"><strong>${esc(q.invoice)} <small>${esc(what)}</small></strong><small>${esc(q.name || '')} · ${q.photoCount || 0} photo(s) · ${timeOf(q.at)}</small>${q.message ? `<em>${esc(q.message)}</em>` : ''}</span><span class="dso-qs">${st[1]}${q.status === 'wait' ? `<button type="button" data-dso="undo" data-id="${esc(q.uuid)}">Remove</button>` : q.status === 'fail' ? `<button type="button" data-dso="dismiss" data-id="${esc(q.uuid)}">OK</button>` : ''}</span></div>`;
            }).join('') || '<p class="dso-muted">Nothing waiting.</p>';
            return `${bar}<section class="dso-screen"><div class="dso-head"><button type="button" class="dso-back" data-dso="home">‹</button><strong>Waiting to send</strong></div>
                ${state.sending ? `<div class="dso-sending"><span>Sending… ${state.sent} sent</span><i style="width:${Math.min(100, state.sent / Math.max(1, c.waiting + state.sent) * 100)}%"></i></div>` : ''}
                ${rows}
                ${state.queue.some((q) => q.status === 'sent') ? '<button type="button" class="dso-link" data-dso="cleardone">Clear sent ones</button>' : ''}
                ${state.online && c.waiting && !state.sending ? '<button type="button" class="dso-primary" data-dso="send">Send now</button>' : ''}
                <div class="dso-warn"><b>!</b><span>Don't clear the browser or remove the app until everything is sent. On iPhone, open the app when you have signal so it can send.</span></div>
                ${state.forced && state.online ? '<a class="dso-primary is-ghost" href="/delivery">Open the full Driver app</a>' : ''}</section>${toastHtml}`;
        }

        if (state.view === 'camera') {
            return `<section class="dso-camera"><video id="dso-video" playsinline muted></video><div class="dso-frame"></div><button type="button" class="dso-primary is-ghost" data-dso="stopcam">Close camera</button></section>`;
        }

        if (state.box && ['box', 'deliver', 'miss'].includes(state.view)) {
            const b = state.box;
            let body = '';
            if (state.view === 'box') {
                body = `<div class="dso-tags"><span class="dso-tag is-ok">On your truck</span><strong>${esc(b.invoice)}</strong><span class="dso-tag is-blue">From saved list</span></div>
                    <div class="dso-who"><strong>${esc(b.name)}</strong><span>${esc(b.address)}</span></div>
                    ${b.phone ? `<a class="dso-ghostbtn" href="tel:${esc(String(b.phone).replace(/[^0-9+]/g, ''))}">📞 Call ${esc(b.phone)}</a>` : ''}
                    ${b.attempted ? '<small class="dso-amber">Tried before</small>' : ''}
                    <button type="button" class="dso-primary is-green" data-dso="deliver">Deliver this box</button>
                    <button type="button" class="dso-secondary" data-dso="miss">Can't deliver</button>
                    <button type="button" class="dso-link" data-dso="home">Back</button>`;
            } else if (state.view === 'deliver') {
                body = `<div class="dso-sheethead"><small>${esc(b.invoice)} · ${esc(b.name)}</small><strong>Proof of delivery</strong><span>Take as many photos as you need.</span></div>
                    ${photoGrid(0)}
                    <button type="button" class="dso-primary ${state.photos.length ? 'is-green' : 'is-off'}" data-dso="savedeliver">${state.photos.length ? `Delivered · save on phone (${state.photos.length})` : 'Take at least 1 photo'}</button>
                    <button type="button" class="dso-link" data-dso="box">Back</button>`;
            } else {
                const r = reasons().find((x) => x.value === state.reason);
                body = `<div class="dso-sheethead"><small>${esc(b.invoice)} · ${esc(b.name)}</small><strong>Why couldn't you deliver it?</strong></div>
                    <div class="dso-chips">${reasons().map((x) => `<button type="button" data-dso="reason" data-v="${esc(x.value)}" class="${x.value === state.reason ? 'is-on' : ''}">${esc(x.label)}</button>`).join('')}</div>
                    <input type="text" class="dso-input" data-dso="note" maxlength="500" value="${esc(state.note)}" placeholder="${esc(r ? r.prompt : 'Note')}${r && r.note ? '' : ' (optional)'}">
                    ${photoGrid(3)}
                    <button type="button" class="dso-primary is-amber" data-dso="savemiss">Keep it on the truck</button>
                    <button type="button" class="dso-link" data-dso="box">Back</button>`;
            }
            return `${bar}<section class="dso-screen"><div class="dso-sheet ${state.view === 'miss' ? 'is-warn' : ''}">${body}</div></section>${toastHtml}`;
        }

        const q = norm(state.search);
        const list = boxes().filter((b) => !b.delivered && b.local !== 'deliver')
            .filter((b) => !q || norm(b.invoice).includes(q) || norm(b.name).includes(q) || norm(b.address).includes(q)).slice(0, 80);
        const pct = c.total ? Math.round(c.delivered / c.total * 289) : 0;
        return `${bar}<section class="dso-screen">
            <div class="dso-hello"><small>Trip ${esc(s.trip.number)}${s.trip.plate ? ' · Truck ' + esc(s.trip.plate) : ''}</small><strong>Hi, ${esc(s.driver ? s.driver.first_name : '')}</strong></div>
            <div class="dso-today"><span class="dso-ring"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="t"/><circle cx="55" cy="55" r="46" class="f" style="stroke-dashoffset:${289 - pct}"/></svg><span><strong>${c.delivered}</strong><small>of ${c.total}</small></span></span>
                <dl><dt>Delivered</dt><dd class="is-ok">${c.delivered}</dd><dt>Waiting to send</dt><dd class="is-blue">${c.waiting}</dd><dt>Still on the truck</dt><dd>${c.left}</dd></dl></div>
            <form class="dso-find" data-dso="find"><input type="text" name="code" placeholder="Type a box number" autocomplete="off" autocapitalize="characters" enterkeyhint="go" aria-label="Box number"><button type="submit">Find</button></form>
            ${'BarcodeDetector' in window ? '<button type="button" class="dso-primary" data-dso="camera">Scan with camera</button>' : ''}
            <p class="dso-note">Today's ${c.total} boxes are saved on this phone (${esc(s.saved_at ? timeOf(s.saved_at) : '')}). You can deliver without signal.</p>
            ${stopsHtml()}
            <input type="search" class="dso-input" data-dso="search" value="${esc(state.search)}" placeholder="Search name or barangay">
            <div class="dso-list">${list.map((b) => `<button type="button" class="dso-row" data-dso="open" data-code="${esc(b.invoice)}"><strong>${esc(b.invoice)}${b.local === 'miss' ? ' <em>kept · waiting</em>' : ''}</strong><span>${esc(b.name)}</span><small>${esc(b.address)}</small></button>`).join('') || '<p class="dso-muted">No boxes left to deliver.</p>'}</div>
            ${state.forced && state.online ? '<a class="dso-primary is-ghost" href="/delivery">Signal is back · open the full Driver app</a>' : ''}
        </section>${toastHtml}`;
    }

    function stopsHtml() {
        const list = stops();
        if (!list.length) return '';
        const next = list[0];
        const row = (st) => `<div class="dso-stop"><span class="dso-no${st.priority ? ' is-prio' : ''}">${st.no}</span><span class="dso-stopt"><strong>${esc(st.name)}</strong><small>${esc(st.place)} · ${st.count} ${st.count > 1 ? 'boxes' : 'box'}${st.priority ? ' · priority' : ''}</small>${st.lat === null ? '<em>no pin · needs signal to find</em>' : ''}</span><button type="button" class="dso-go${st.lat === null && !state.online ? ' is-dim' : ''}" data-dso="nav" data-id="${st.id}">Navigate</button></div>`;
        return `<p class="dso-label">Your stops <span>· saved on this phone</span></p>
            <div class="dso-next"><span><small>Next · stop ${next.no}</small><strong>${esc(next.name)}</strong><em>${esc(next.place)} · ${next.count} ${next.count > 1 ? 'boxes' : 'box'}</em></span><button type="button" data-dso="nav" data-id="${next.id}">Navigate</button></div>
            <div class="dso-stops">${list.slice(1, 12).map(row).join('')}</div>`;
    }

    function render() {
        renderBar();
        let root = document.getElementById('dso-root');
        if (!shown()) { if (root) root.hidden = true; return; }
        if (!root) { root = document.createElement('div'); root.id = 'dso-root'; document.body.appendChild(root); }
        root.hidden = false;
        const active = document.activeElement;
        const keep = active && active.dataset && active.dataset.dso && root.contains(active) ? { k: active.dataset.dso, pos: active.selectionStart } : null;
        root.innerHTML = screenHtml();
        if (keep) {
            const el = root.querySelector(`[data-dso="${keep.k}"]`);
            if (el && el.focus) { el.focus(); try { el.setSelectionRange(keep.pos, keep.pos); } catch (e) {} }
        }
    }

    // ------------------------------------------------------------------ events

    document.addEventListener('click', (e) => {
        const t = e.target.closest('[data-dso]');
        if (!t) return;
        const a = t.dataset.dso;
        const actions = {
            queue: () => { state.view = 'queue'; if (!shown()) state.forced = true; render(); },
            home: () => { state.view = 'home'; state.box = null; if (state.online && !document.getElementById('dso-shell')) state.forced = false; render(); },
            open: () => openBox(t.dataset.code),
            nav: () => { state.stop = stops().find((x) => String(x.id) === t.dataset.id) || null; if (state.stop) { state.view = 'nav'; render(); } },
            go: () => { const url = navUrl(t.dataset.app, state.stop); try { localStorage.setItem('ds.navApp', t.dataset.app); } catch (err) {} window.open(url, '_blank') || (window.location.href = url); },
            deliver: () => { state.view = 'deliver'; render(); },
            miss: () => { state.view = 'miss'; state.reason = state.reason || (reasons()[0] || {}).value; render(); },
            box: () => { state.view = 'box'; render(); },
            reason: () => { state.reason = t.dataset.v; render(); },
            rmphoto: () => { const i = +t.dataset.i; URL.revokeObjectURL(state.photos[i].url); state.photos.splice(i, 1); render(); },
            savedeliver: () => save('deliver'),
            savemiss: () => save('miss'),
            undo: () => undo(t.dataset.id),
            dismiss: () => dismiss(t.dataset.id),
            cleardone: () => clearDone(),
            send: () => flush(),
            camera: () => startCamera(),
            stopcam: () => stopCamera(),
        };
        if (actions[a]) { e.preventDefault(); actions[a](); }
    });
    document.addEventListener('change', (e) => {
        if (e.target.dataset && e.target.dataset.dso === 'photos') addPhotos([...e.target.files]);
    });
    document.addEventListener('input', (e) => {
        const d = e.target.dataset && e.target.dataset.dso;
        if (d === 'note') state.note = e.target.value;
        if (d === 'search') { state.search = e.target.value; render(); }
    });
    document.addEventListener('submit', (e) => {
        if (e.target.dataset && e.target.dataset.dso === 'find') {
            e.preventDefault();
            const v = e.target.querySelector('input').value; if (v.trim()) openBox(v);
        }
    });

    window.addEventListener('offline', () => { state.online = false; render(); watchBack(); });
    window.addEventListener('online', async () => {
        state.online = true; render();
        const changed = await flush();
        // back on the full app: reload it so its numbers include what was just sent
        if (!document.getElementById('dso-shell') && changed) setTimeout(() => location.reload(), 900);
        else render();
    });

    // ------------------------------------------------------------------ start

    async function start() {
        state.forced = !!document.getElementById('dso-shell');
        try { await load(); } catch (e) {}
        render();
        if (navigator.onLine) {
            try { await refreshTrip(); } catch (e) {}
            await flush();
            render();
        }
        // keep the saved list fresh while the app is open
        setInterval(async () => { if (navigator.onLine && !state.sending) { try { await refreshTrip(); render(); } catch (e) {} } }, 5 * 60 * 1000);
        setInterval(() => { if (navigator.onLine) flush(); }, 30 * 1000);
    }

    window.dsDriverOffline = { state, flush, refreshTrip, render, openBox, save };

    const boot = () => {
        if (document.getElementById('ds-net') || document.getElementById('dso-shell')) start();
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
    document.addEventListener('livewire:navigated', () => render());

    // The phone says it has signal but a tap on the full app could not reach the office:
    // check once, and if the office really can't be reached, switch to the screens without signal.
    async function reachable() {
        try {
            const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 6000);
            const res = await fetch(TRIP_URL, { credentials: 'same-origin', cache: 'no-store', signal: ctl.signal, headers: { Accept: 'application/json' } });
            clearTimeout(t); return res.status < 500;
        } catch (e) { return false; }
    }
    let hooked = false;
    function hookLivewire() {
        if (hooked || !window.Livewire || !window.Livewire.hook) return;
        hooked = true;
        window.Livewire.hook('request', ({ fail }) => {
            fail(async ({ status, preventDefault }) => {
                if (!document.getElementById('ds-net')) return; // only the Driver app
                if (status && status < 500) return;
                preventDefault && preventDefault();
                if (!(await reachable())) { state.online = false; render(); watchBack(); }
            });
        });
    }
    if (window.Livewire) hookLivewire(); else document.addEventListener('livewire:init', hookLivewire);
    let backTimer = null;
    function watchBack() {
        clearInterval(backTimer);
        backTimer = setInterval(async () => {
            if (navigator.onLine && await reachable()) {
                clearInterval(backTimer);
                window.dispatchEvent(new Event('online'));
            }
        }, 15000);
    }

    // ------------------------------------------------------------------ look (same style as the Driver app)

    const css = `
#dso-root{position:fixed;inset:0;z-index:45;overflow:auto;color:#eef3f6;font-family:Archivo,system-ui,sans-serif;background:radial-gradient(120% 70% at 0% 0%,#15293a 0%,#0a1219 55%);-webkit-tap-highlight-color:transparent}
#dso-root[hidden]{display:none}
#dso-root button{font:inherit;cursor:pointer;border:0;background:none;color:inherit}
.dso-net{position:fixed;top:calc(env(safe-area-inset-top) + .6rem);left:1rem;right:1rem;z-index:46;max-width:32rem;margin:0 auto;display:none;align-items:center;gap:.65rem;padding:.55rem .6rem .55rem .9rem;border-radius:1rem;color:#eef3f6;font-family:Archivo,system-ui,sans-serif;backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px)}
.dso-net.is-shown{display:flex}
.dso-net i{width:.6rem;height:.6rem;border-radius:50%;flex:none}
.dso-net>span{flex:1;min-width:0;display:flex;flex-direction:column}
.dso-net strong{font-size:.85rem}.dso-net small{font-size:.72rem;opacity:.8}
.dso-net button{height:2rem;padding:0 .7rem;border-radius:.6rem;background:rgb(255 255 255/.12);color:#eef3f6;font-weight:800;font-size:.8rem;border:0}
.dso-net.is-off{background:rgb(30 40 52/.94);box-shadow:inset 0 0 0 1px rgb(140 196 255/.3)}.dso-net.is-off i{background:#ff6b5e;box-shadow:0 0 0 4px rgb(255 107 94/.2)}
.dso-net.is-send{background:rgb(15 43 35/.95);box-shadow:inset 0 0 0 1px rgb(52 195 143/.4)}.dso-net.is-send i{background:#34c38f}
.dso-net.is-warn{background:rgb(34 26 12/.95);box-shadow:inset 0 0 0 1px rgb(240 169 59/.4)}.dso-net.is-warn i{background:#f0a93b}
.dso-net.is-on{background:rgb(255 255 255/.06)}.dso-net.is-on i{background:#34c38f}
.dso-screen{max-width:34rem;margin:0 auto;padding:calc(env(safe-area-inset-top) + 5rem) 1.35rem calc(env(safe-area-inset-bottom) + 2rem);display:flex;flex-direction:column;gap:1rem}
.dso-hello{display:flex;flex-direction:column;gap:.2rem}.dso-hello small{color:#7f93a1;font-size:.85rem}.dso-hello strong{font-size:1.75rem;letter-spacing:-.025em}
.dso-today{display:flex;align-items:center;gap:1rem;padding:1rem;border-radius:1.5rem;background:rgb(255 255 255/.045);box-shadow:inset 0 0 0 1px rgb(255 255 255/.07)}
.dso-today dl{flex:1;display:grid;grid-template-columns:1fr auto;gap:.5rem .75rem;margin:0;font-size:.88rem}.dso-today dt{color:#7f93a1}.dso-today dd{margin:0;font-weight:700}
.dso-today .is-ok{color:#6fd6ad}.dso-today .is-blue{color:#8cc4ff}
.dso-ring{position:relative;width:5.5rem;height:5.5rem;flex:none}.dso-ring svg{width:100%;height:100%;transform:rotate(-90deg)}
.dso-ring circle{fill:none;stroke-width:9}.dso-ring .t{stroke:rgb(255 255 255/.08)}.dso-ring .f{stroke:#34c38f;stroke-linecap:round;stroke-dasharray:289}
.dso-ring>span{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center}.dso-ring strong{font-size:1.4rem}.dso-ring small{font-size:.65rem;color:#7f93a1}
.dso-find{display:flex;gap:.5rem}.dso-find input,.dso-input{-webkit-appearance:none;appearance:none;box-sizing:border-box;font-family:inherit;flex:1;min-width:0;height:3.1rem;padding:0 1rem;border:0;border-radius:1rem;background:rgb(255 255 255/.06);color:#eef3f6;font-size:1rem;box-shadow:inset 0 0 0 1px rgb(255 255 255/.08);outline:0}
.dso-find button{height:3.1rem;padding:0 1.2rem;border-radius:1rem;background:#f6be00!important;color:#0a1219!important;font-weight:800}
.dso-primary{display:flex;align-items:center;justify-content:center;height:3.5rem;border-radius:1.1rem;background:#f6be00!important;color:#0a1219!important;font-weight:800;font-size:1.02rem;text-decoration:none}
.dso-primary.is-green{background:#34c38f!important}.dso-primary.is-amber{background:#f0a93b!important}.dso-primary.is-off{background:rgb(255 255 255/.08)!important;color:#7f93a1!important}
.dso-primary.is-ghost{background:rgb(255 255 255/.08)!important;color:#eef3f6!important;font-weight:700}
.dso-secondary{height:3rem;border-radius:1rem;background:rgb(255 255 255/.06)!important;font-weight:600}
.dso-link{height:2.6rem;color:#7f93a1!important;font-weight:600}
.dso-note{margin:0;font-size:.82rem;color:#a9b8c2;line-height:1.5}.dso-muted{color:#7f93a1;font-size:.88rem}
.dso-list{display:flex;flex-direction:column;gap:.5rem}
.dso-row{display:flex;flex-direction:column;align-items:flex-start;gap:.1rem;padding:.8rem 1rem;border-radius:1.1rem;background:rgb(255 255 255/.045)!important;box-shadow:inset 0 0 0 1px rgb(255 255 255/.07);text-align:left}
.dso-row strong{font-size:.98rem}.dso-row em{font-style:normal;font-size:.7rem;color:#8cc4ff;margin-left:.35rem}.dso-row span{font-size:.88rem}.dso-row small{font-size:.75rem;color:#7f93a1}
.dso-sheet{display:flex;flex-direction:column;gap:.9rem;padding:1.1rem;border-radius:1.6rem;background:rgb(15 24 32/.98);box-shadow:0 20px 50px rgb(0 0 0/.4),inset 0 1px 0 rgb(255 255 255/.08)}
.dso-sheet.is-warn{background:rgb(34 26 12/.98)}
.dso-tags{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap}.dso-tags strong{color:#c9d5dc}
.dso-tag{padding:.25rem .65rem;border-radius:999px;font-size:.72rem;font-weight:700}.dso-tag.is-ok{background:rgb(52 195 143/.14);color:#6fd6ad}.dso-tag.is-blue{background:rgb(140 196 255/.14);color:#8cc4ff;margin-left:auto}
.dso-who{display:flex;flex-direction:column;gap:.25rem}.dso-who strong{font-size:1.55rem;letter-spacing:-.02em}.dso-who span{color:#a9b8c2;font-size:.9rem}
.dso-ghostbtn{display:flex;align-items:center;justify-content:center;height:3rem;border-radius:.9rem;background:rgb(255 255 255/.06);color:#eef3f6;text-decoration:none;font-weight:600}
.dso-amber{color:#f3c98a}
.dso-sheethead{display:flex;flex-direction:column;gap:.2rem}.dso-sheethead small{color:#7f93a1;font-size:.8rem}.dso-sheethead strong{font-size:1.4rem;letter-spacing:-.02em}.dso-sheethead span{color:#a9b8c2;font-size:.88rem}
.dso-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:.55rem}
.dso-proof{position:relative;aspect-ratio:1;border-radius:1rem;overflow:hidden}.dso-proof img{width:100%;height:100%;object-fit:cover}
.dso-proof b{position:absolute;left:.4rem;bottom:.4rem;padding:0 .45rem;border-radius:999px;background:rgb(10 18 25/.75);font-size:.7rem}
.dso-proof button{position:absolute;right:.3rem;top:.3rem;width:1.6rem;height:1.6rem;border-radius:50%;background:rgb(10 18 25/.7)!important;color:#fff;font-size:.7rem}
.dso-add{aspect-ratio:1;border-radius:1rem;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:.3rem;background:rgb(255 255 255/.05);box-shadow:inset 0 0 0 1.5px rgb(255 255 255/.18);font-size:.8rem;font-weight:600;cursor:pointer}
.dso-add span{font-size:1.4rem}
.dso-chips{display:flex;flex-wrap:wrap;gap:.4rem}.dso-chips button{height:2.3rem;padding:0 .8rem;border-radius:999px;background:rgb(255 255 255/.07)!important;font-size:.8rem;font-weight:700}
.dso-chips button.is-on{background:#f0a93b!important;color:#0a1219}
.dso-head{display:flex;align-items:center;gap:.7rem}.dso-head strong{font-size:1.5rem;letter-spacing:-.02em}
.dso-back{width:2.5rem;height:2.5rem;border-radius:50%;background:rgb(255 255 255/.06)!important;font-size:1.3rem}
.dso-q{display:flex;align-items:flex-start;gap:.7rem;padding:.85rem;border-radius:1.1rem;background:rgb(255 255 255/.045);box-shadow:inset 0 0 0 1px rgb(255 255 255/.07)}
.dso-q.is-warn{box-shadow:inset 0 0 0 1px rgb(240 169 59/.45)}
.dso-qi{display:grid;place-items:center;width:2rem;height:2rem;border-radius:50%;flex:none;font-weight:900;color:#0a1219;background:#8cc4ff}
.dso-q.is-ok .dso-qi{background:#34c38f}.dso-q.is-warn .dso-qi{background:#f0a93b}
.dso-qt{flex:1;min-width:0;display:flex;flex-direction:column;gap:.15rem}.dso-qt strong{font-size:.95rem}.dso-qt strong small{font-weight:500;color:#7f93a1;font-size:.75rem}.dso-qt>small{font-size:.75rem;color:#a9b8c2}
.dso-qt em{font-style:normal;font-size:.78rem;color:#f3c98a;line-height:1.4}
.dso-qs{display:flex;flex-direction:column;align-items:flex-end;gap:.35rem;font-size:.72rem;font-weight:700;color:#8cc4ff;white-space:nowrap}
.dso-q.is-ok .dso-qs{color:#34c38f}.dso-q.is-warn .dso-qs{color:#f0a93b}
.dso-qs button{padding:.25rem .55rem;border-radius:.5rem;background:rgb(255 255 255/.08)!important;color:#eef3f6;font-size:.72rem}
.dso-sending{display:flex;flex-direction:column;gap:.4rem;padding:.8rem 1rem;border-radius:1rem;background:rgb(52 195 143/.1)}.dso-sending i{display:block;height:6px;border-radius:999px;background:#34c38f;transition:width .4s}
.dso-warn{display:flex;gap:.6rem;padding:.75rem .9rem;border-radius:1rem;background:rgb(255 107 94/.08);box-shadow:inset 0 0 0 1px rgb(255 107 94/.25);font-size:.8rem;color:#f3c3bd;line-height:1.45}.dso-warn b{color:#ff8a7e}
.dso-empty{display:flex;flex-direction:column;gap:.5rem;padding:2.5rem 1.2rem;border-radius:1.5rem;background:rgb(255 255 255/.045);text-align:center}.dso-empty strong{font-size:1.15rem}.dso-empty p{margin:0;color:#7f93a1;line-height:1.5}
.dso-toast{position:fixed;top:calc(env(safe-area-inset-top) + 4.8rem);left:1rem;right:1rem;z-index:47;max-width:32rem;margin:0 auto;display:flex;align-items:center;gap:.7rem;padding:.7rem .7rem .7rem .9rem;border-radius:1.1rem;background:rgb(20 36 56/.97);box-shadow:0 16px 40px rgb(0 0 0/.4),inset 0 0 0 1px rgb(140 196 255/.4);animation:dso-in .3s ease-out}
.dso-toast.is-bad{background:rgb(40 18 20/.97);box-shadow:0 16px 40px rgb(0 0 0/.4),inset 0 0 0 1px rgb(255 107 94/.4)}
.dso-toast>span:first-child{display:grid;place-items:center;width:2rem;height:2rem;border-radius:50%;background:#8cc4ff;color:#0a1219;font-weight:900;flex:none}
.dso-toast.is-bad>span:first-child{background:#ff6b5e;color:#fff}
.dso-toast>span:nth-child(2){flex:1;display:flex;flex-direction:column}.dso-toast small{font-size:.75rem;opacity:.8}
.dso-toast button{height:2.3rem;padding:0 .8rem;border-radius:.7rem;background:rgb(255 255 255/.1)!important;font-weight:700}
.dso-label{margin:.2rem 0 -.4rem;font-size:.85rem;font-weight:700}.dso-label span{font-weight:400;color:#7f93a1}
.dso-next{display:flex;align-items:center;gap:.7rem;padding:.85rem .9rem;border-radius:1.1rem;background:rgb(246 190 0/.1);box-shadow:inset 0 0 0 1px rgb(246 190 0/.35)}
.dso-next>span{flex:1;min-width:0;display:flex;flex-direction:column}.dso-next small{font-size:.75rem;color:#f6d36b;font-weight:700}.dso-next strong{font-size:1.02rem}.dso-next em{font-style:normal;font-size:.8rem;color:#a9b8c2}
.dso-next button{height:2.6rem;padding:0 1rem;border-radius:.75rem;background:#f6be00!important;color:#0a1219!important;font-weight:800}
.dso-stops{display:flex;flex-direction:column;border-radius:1.1rem;background:rgb(255 255 255/.045);overflow:hidden}
.dso-stop{display:flex;align-items:center;gap:.65rem;padding:.7rem .8rem;border-top:1px solid rgb(255 255 255/.06)}.dso-stop:first-child{border-top:0}
.dso-no{width:1.9rem;height:1.9rem;flex:none;border-radius:50%;display:grid;place-items:center;font-weight:900;font-size:.82rem;background:rgb(255 255 255/.1)}.dso-no.is-prio{box-shadow:0 0 0 2px #d9534a}
.dso-stopt{flex:1;min-width:0;display:flex;flex-direction:column}.dso-stopt strong{font-size:.92rem}.dso-stopt small{font-size:.75rem;color:#a9b8c2}.dso-stopt em{font-style:normal;font-size:.72rem;color:#f3c98a}
.dso-go{height:2.1rem;padding:0 .7rem;border-radius:.6rem;background:rgb(140 196 255/.14)!important;color:#8cc4ff!important;font-size:.8rem;font-weight:800}.dso-go.is-dim{background:rgb(255 255 255/.06)!important;color:#7f93a1!important}
.dso-navtip{margin:0;padding:.6rem .75rem;border-radius:.75rem;background:rgb(140 196 255/.1);font-size:.82rem;color:#c9e2ff;line-height:1.45}
.dso-app{display:flex;align-items:center;gap:.75rem;height:3.6rem;padding:0 .9rem;border-radius:.9rem;background:rgb(255 255 255/.07)!important;text-align:left;font-size:1.2rem}
.dso-app.is-dim{background:rgb(255 255 255/.03)!important;color:#7f93a1}
.dso-app>span{flex:1;display:flex;flex-direction:column;font-size:1rem}.dso-app small{font-size:.75rem}.dso-app small.is-ok{color:#6fd6ad}
.dso-app i{width:2.4rem;height:2.4rem;flex:none;border-radius:.7rem;display:grid;place-items:center;font-style:normal;font-weight:900;font-size:1.1rem}
.dso-app .is-google{background:#fff;color:#1a73e8}.dso-app .is-apple{background:#e9eef2;color:#0e2433}.dso-app .is-waze{background:#33ccff;color:#0a1219}.dso-app.is-dim .is-waze{opacity:.45}
.dso-two{display:grid;grid-template-columns:1fr 1fr;gap:.5rem}
@keyframes dso-in{from{transform:translateY(-60%);opacity:0}to{transform:none;opacity:1}}
.dso-camera{position:fixed;inset:0;background:#000;display:flex;flex-direction:column;justify-content:flex-end;padding:1.5rem}
.dso-camera video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.dso-frame{position:absolute;left:12%;right:12%;top:30%;height:22%;border:3px solid #fff;border-radius:1rem;box-shadow:0 0 0 999px rgb(0 0 0/.35)}
.dso-camera .dso-primary{position:relative}
`;
    const style = document.createElement('style');
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
})();
