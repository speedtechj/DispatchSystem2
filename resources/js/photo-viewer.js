/*
 * Part 42 · Check photos (board 68), in every app.
 *
 * window.dsPhotoViewer.open(list, index, opts)  full screen: zoom (pinch, double-tap, button),
 *     swipe or ‹ › for the next, ✕ to go back. opts.onDelete(i) / opts.onRetake(i) add the buttons.
 * window.dsPhotoCheck(file, { auto })  the photo big, right after it is taken: Retake or Use photo
 *     (used by itself after `auto` seconds, 0 = wait for a tap). Resolves 'use' or 'retake'.
 * Any <img data-ds-photo> inside [data-ds-gallery] opens the viewer for that gallery on a tap.
 * While a viewer is open, the barcode scanner rests (it never reads a box behind the photo).
 */
(function () {
    if (window.dsPhotoViewer) return;

    const css = `
.dspv{position:fixed;inset:0;z-index:90;background:#05090d;color:#eef3f6;display:flex;flex-direction:column;font-family:Archivo,system-ui,sans-serif;touch-action:none;-webkit-tap-highlight-color:transparent}
.dspv__top{display:flex;align-items:center;justify-content:space-between;gap:.6rem;padding:max(.8rem,env(safe-area-inset-top)) 1rem .6rem}
.dspv__x{width:2.6rem;height:2.6rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:1.15rem;color:#fff}
.dspv__pill{padding:.25rem .7rem;border-radius:99px;background:rgb(255 255 255/.12);font-size:.8rem;font-weight:800}
.dspv__stage{position:relative;flex:1;overflow:hidden;display:flex;align-items:center;justify-content:center}
.dspv__img{max-width:100%;max-height:100%;object-fit:contain;transform-origin:center;transition:transform .15s ease-out;user-select:none;-webkit-user-drag:none}
.dspv__img.is-moving{transition:none}
.dspv__nav{position:absolute;top:50%;margin-top:-1.4rem;width:2.8rem;height:2.8rem;border-radius:99px;background:rgb(0 0 0/.45);color:#fff;font-size:1.4rem}
.dspv__nav.is-prev{left:.6rem}.dspv__nav.is-next{right:.6rem}
.dspv__hint{position:absolute;left:0;right:0;bottom:.7rem;text-align:center;font-size:.75rem;color:#cfd8de;pointer-events:none}
.dspv__cd{position:absolute;top:.7rem;right:.7rem;padding:.25rem .7rem;border-radius:99px;background:rgb(0 0 0/.55);font-size:.8rem;font-weight:800}
.dspv__bar{display:grid;gap:.5rem;padding:.7rem 1rem max(1rem,env(safe-area-inset-bottom))}
.dspv__bar.is-3{grid-template-columns:repeat(3,1fr)}.dspv__bar.is-4{grid-template-columns:repeat(4,1fr)}
.dspv__strip{display:flex;gap:.45rem;overflow-x:auto;padding:.55rem 1rem 0}.dspv__strip button{flex:none;width:4.2rem;height:3.1rem;border-radius:.45rem;overflow:hidden;opacity:.45;padding:0}.dspv__strip button.is-on{opacity:1;box-shadow:0 0 0 3px #f6be00}.dspv__strip img{width:100%;height:100%;object-fit:cover}
.dspv__btn.is-on{background:#f6be00;color:#0a1219}a.dspv__btn{display:flex;align-items:center;justify-content:center;text-decoration:none}.dspv__bar.is-2{grid-template-columns:1fr 1.4fr}.dspv__bar.is-1{grid-template-columns:1fr}
.dspv__btn{height:3.3rem;border-radius:1rem;background:rgb(255 255 255/.1);color:#fff;font-weight:800;font-size:1rem}
.dspv__btn.is-use{background:#3ddc97;color:#0a1219}.dspv__btn.is-del{background:rgb(200 55 45/.28);color:#ff8a80}
[data-ds-photo]{cursor:zoom-in}`;

    let root = null;
    let keyHandler = null;
    let wasPaused = null;

    function scanner(paused) {
        window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { paused } }));
    }
    /** The scanner rests while a photo is open, and goes back to how it was after. */
    function rest() {
        wasPaused = window.dsScanner ? !!window.dsScanner.paused : null;
        scanner(true);
    }

    function el(tag, cls, html) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (html != null) e.innerHTML = html;
        return e;
    }

    function close() {
        if (!root) return;
        root.remove();
        root = null;
        if (keyHandler) document.removeEventListener('keydown', keyHandler);
        keyHandler = null;
        document.documentElement.style.overflow = '';
        if (wasPaused === false) scanner(false);
        wasPaused = null;
    }

    /** Pinch, drag and double-tap zoom on one image; swipe calls onSwipe(-1|1) when not zoomed. */
    function zoomable(img, stage, onSwipe, onZoom) {
        let z = 1, x = 0, y = 0;
        const pts = new Map();
        let start = null;
        let lastTap = 0;
        const apply = () => { img.style.transform = `translate(${x}px, ${y}px) scale(${z})`; onZoom && onZoom(z); };
        const set = (nz) => { z = Math.min(4, Math.max(1, nz)); if (z === 1) { x = 0; y = 0; } apply(); };
        stage.addEventListener('pointerdown', (e) => {
            stage.setPointerCapture && stage.setPointerCapture(e.pointerId);
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            img.classList.add('is-moving');
            if (pts.size === 1) {
                start = { x: e.clientX, y: e.clientY, ox: x, oy: y, t: Date.now() };
                if (Date.now() - lastTap < 300) { set(z > 1 ? 1 : 2.5); lastTap = 0; } else lastTap = Date.now();
            } else if (pts.size === 2) {
                const [a, b] = [...pts.values()];
                start = { d: Math.hypot(a.x - b.x, a.y - b.y), z };
            }
        });
        stage.addEventListener('pointermove', (e) => {
            if (!pts.has(e.pointerId) || !start) return;
            pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
            if (pts.size === 2 && start.d) {
                const [a, b] = [...pts.values()];
                z = Math.min(4, Math.max(1, start.z * Math.hypot(a.x - b.x, a.y - b.y) / start.d));
                apply();
            } else if (pts.size === 1 && z > 1) {
                x = start.ox + e.clientX - start.x; y = start.oy + e.clientY - start.y; apply();
            }
        });
        const up = (e) => {
            const p = pts.get(e.pointerId);
            pts.delete(e.pointerId);
            img.classList.remove('is-moving');
            if (pts.size === 0 && start && start.x != null && z === 1 && p) {
                const dx = p.x - start.x;
                if (Math.abs(dx) > 60 && Date.now() - start.t < 600 && onSwipe) onSwipe(dx < 0 ? 1 : -1);
            }
            if (pts.size === 0) { start = null; if (z <= 1.05) set(1); }
        };
        stage.addEventListener('pointerup', up);
        stage.addEventListener('pointercancel', up);
        return { zoomStep() { set(z >= 3 ? 1 : z + 1); }, reset() { set(1); } };
    }

    function mount() {
        if (!document.getElementById('dspv-css')) {
            const s = el('style'); s.id = 'dspv-css'; s.textContent = css; document.head.appendChild(s);
        }
        close();
        root = el('div', 'dspv');
        root.setAttribute('role', 'dialog');
        root.setAttribute('aria-modal', 'true');
        document.body.appendChild(root);
        document.documentElement.style.overflow = 'hidden';
        return root;
    }

    window.dsPhotoViewer = {
        /** list: [{ src, label? }] or [src, …] */
        open(list, index = 0, opts = {}) {
            const items = (list || []).map((p) => (typeof p === 'string' ? { src: p } : p)).filter((p) => p && p.src);
            if (!items.length) return;
            let i = Math.min(Math.max(0, index), items.length - 1);
            const r = mount();
            rest();
            const top = el('div', 'dspv__top');
            const x = el('button', 'dspv__x', '✕'); x.type = 'button'; x.setAttribute('aria-label', 'Close');
            const count = el('b');
            const zl = el('span', 'dspv__pill', 'Fit');
            top.append(x, count, zl);
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo'; img.draggable = false;
            const prev = el('button', 'dspv__nav is-prev', '‹'); prev.type = 'button'; prev.setAttribute('aria-label', 'Previous photo');
            const next = el('button', 'dspv__nav is-next', '›'); next.type = 'button'; next.setAttribute('aria-label', 'Next photo');
            const hint = el('span', 'dspv__hint', 'Pinch or double-tap to zoom' + (items.length > 1 ? ' · swipe for the next' : ''));
            stage.append(img, prev, next, hint);
            // Board 71: in galleries (no Retake/Delete) the viewer also plays a slideshow and downloads the photo
            const gallery = !opts.onRetake && !opts.onDelete;
            let timer = null;
            const btns = [['🔍 Zoom', '', () => z.zoomStep()]];
            if (gallery && items.length > 1) btns.push(['▶ Slideshow', 'is-play', (e) => {
                const b = e.currentTarget;
                if (timer) { clearInterval(timer); timer = null; b.textContent = '▶ Slideshow'; b.classList.remove('is-on'); return; }
                timer = setInterval(() => { if (!r.isConnected) { clearInterval(timer); timer = null; return; } i = (i + 1) % items.length; show(); }, 3000);
                b.textContent = '❚❚ Pause'; b.classList.add('is-on');
            }]);
            if (gallery) btns.push(['⬇ Save', 'is-dl', null]);
            if (opts.onRetake) btns.push(['↺ Retake', '', () => { const k = i; close(); opts.onRetake(k); }]);
            if (opts.onDelete) btns.push(['🗑 Delete', 'is-del', () => { const k = i; close(); opts.onDelete(k); }]);
            const bar = el('div', 'dspv__bar is-' + btns.length);
            let dl = null;
            btns.forEach(([t, c, f]) => {
                if (!f) { dl = el('a', 'dspv__btn ' + c, t); dl.setAttribute('download', ''); bar.appendChild(dl); return; }
                const b = el('button', 'dspv__btn ' + c, t); b.type = 'button'; b.addEventListener('click', f); bar.appendChild(b);
            });
            const strip = el('div', 'dspv__strip');
            const thumbs = items.length > 1 ? items.map((p, k) => {
                const b = el('button'); b.type = 'button'; b.setAttribute('aria-label', 'Photo ' + (k + 1));
                const im = el('img'); im.src = p.src; im.alt = ''; im.loading = 'lazy'; b.appendChild(im);
                b.addEventListener('click', () => { i = k; show(); });
                strip.appendChild(b); return b;
            }) : [];
            const stop = () => { if (timer) clearInterval(timer); timer = null; };
            if (thumbs.length) r.append(top, stage, strip, bar); else r.append(top, stage, bar);

            const show = () => {
                img.src = items[i].src;
                count.textContent = items.length > 1 ? `${i + 1} of ${items.length}` : (items[i].label || 'Photo');
                prev.style.display = i > 0 ? '' : 'none';
                next.style.display = i < items.length - 1 ? '' : 'none';
                if (timer) { prev.style.display = ''; next.style.display = ''; }
                thumbs.forEach((b, k) => b.classList.toggle('is-on', k === i));
                if (thumbs[i]) thumbs[i].scrollIntoView({ block: 'nearest', inline: 'nearest' });
                if (dl) dl.href = items[i].src;
                z && z.reset();
            };
            const go = (d) => { const n = i + d; if (n >= 0 && n < items.length) { i = n; show(); } };
            const z = zoomable(img, stage, go, (v) => { zl.textContent = v > 1.05 ? `Zoom ${v.toFixed(1)}×` : 'Fit'; });
            prev.addEventListener('click', (e) => { e.stopPropagation(); go(-1); });
            next.addEventListener('click', (e) => { e.stopPropagation(); go(1); });
            prev.addEventListener('pointerdown', (e) => e.stopPropagation());
            next.addEventListener('pointerdown', (e) => e.stopPropagation());
            x.addEventListener('click', () => { stop(); close(); opts.onClose && opts.onClose(); });
            keyHandler = (e) => { if (e.key === 'Escape') { stop(); close(); opts.onClose && opts.onClose(); } else if (e.key === 'ArrowLeft') go(-1); else if (e.key === 'ArrowRight') go(1); };
            document.addEventListener('keydown', keyHandler);
            show();
        },
        close,
    };

    /** The photo big, right after it is taken: Retake or Use photo (used by itself after `auto` seconds). */
    window.dsPhotoCheck = function (file, opts = {}) {
        return new Promise((resolve) => {
            const r = mount();
            rest();
            const url = URL.createObjectURL(file);
            let left = Math.max(0, parseInt(opts.auto ?? 3, 10) || 0);
            let timer = null;
            const done = (what) => { clearInterval(timer); URL.revokeObjectURL(url); close(); resolve(what); };
            const top = el('div', 'dspv__top');
            top.append(el('b', '', opts.title || 'Check the photo'), el('span', 'dspv__pill', 'Pinch to zoom'));
            const stage = el('div', 'dspv__stage');
            const img = el('img', 'dspv__img'); img.alt = 'Photo you took'; img.src = url; img.draggable = false;
            const cd = el('span', 'dspv__cd');
            stage.append(img, cd);
            const bar = el('div', 'dspv__bar is-2');
            const re = el('button', 'dspv__btn', '↺ Retake'); re.type = 'button';
            const use = el('button', 'dspv__btn is-use', '✓ Use photo'); use.type = 'button';
            bar.append(re, use);
            r.append(top, stage, bar);
            zoomable(img, stage, null, (v) => { if (v > 1.05 && timer) { clearInterval(timer); timer = null; cd.textContent = 'Waiting for you'; } });
            re.addEventListener('click', () => done('retake'));
            use.addEventListener('click', () => done('use'));
            keyHandler = (e) => { if (e.key === 'Escape') done('retake'); if (e.key === 'Enter') done('use'); };
            document.addEventListener('keydown', keyHandler);
            if (left > 0) {
                cd.textContent = `Uses it in ${left} s`;
                timer = setInterval(() => { left -= 1; if (left <= 0) done('use'); else cd.textContent = `Uses it in ${left} s`; }, 1000);
            } else {
                cd.style.display = 'none';
            }
        });
    };

    // Any photo marked data-ds-photo opens the viewer with the photos of its gallery.
    document.addEventListener('click', (e) => {
        const t = e.target.closest && e.target.closest('[data-ds-photo]');
        if (!t || e.metaKey || e.ctrlKey || e.shiftKey) return;
        const g = t.closest('[data-ds-gallery]') || t.parentElement;
        const all = [...g.querySelectorAll('[data-ds-photo]')];
        const src = (n) => n.getAttribute('data-ds-photo') || n.getAttribute('href') || n.getAttribute('src') || (n.querySelector('img') && n.querySelector('img').src);
        e.preventDefault();
        window.dsPhotoViewer.open(all.map((n) => ({ src: src(n) })), all.indexOf(t), { onClose: () => g.dispatchEvent(new CustomEvent('ds-viewer-closed', { bubbles: true })) });
    });
})();
