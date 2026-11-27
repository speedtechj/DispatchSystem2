/*
 * Part 44 · The receiver signs on the driver's phone (boards 70, 70b).
 * x-data="dsSignPad(damaged)": draw with a finger; each stroke sends the signature (PNG) to the page.
 */
window.dsSignPad = function (damaged) {
    return {
        damaged: !!damaged,
        empty: true,
        init() {
            const c = this.$refs.pad;
            const ctx = c.getContext('2d');
            const fit = () => {
                const r = window.devicePixelRatio || 1;
                const w = c.clientWidth || 320;
                const h = c.clientHeight || 170;
                if (c.width === Math.round(w * r)) return;
                c.width = Math.round(w * r); c.height = Math.round(h * r);
                ctx.setTransform(r, 0, 0, r, 0, 0);
                ctx.lineWidth = 3.4; ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.strokeStyle = '#0e2433';
            };
            fit();
            let last = null;
            const at = (e) => { const b = c.getBoundingClientRect(); return { x: e.clientX - b.left, y: e.clientY - b.top }; };
            c.addEventListener('pointerdown', (e) => { e.preventDefault(); c.setPointerCapture(e.pointerId); last = at(e); ctx.beginPath(); ctx.arc(last.x, last.y, 1.2, 0, 7); ctx.fillStyle = '#0e2433'; ctx.fill(); });
            c.addEventListener('pointermove', (e) => {
                if (!last) return;
                const p = at(e);
                ctx.beginPath(); ctx.moveTo(last.x, last.y);
                ctx.quadraticCurveTo(last.x, last.y, (last.x + p.x) / 2, (last.y + p.y) / 2); ctx.lineTo(p.x, p.y); ctx.stroke();
                last = p; this.empty = false;
            });
            const end = () => {
                if (!last) return;
                last = null; this.empty = false;
                this.$wire.set('signature', this.png());
            };
            c.addEventListener('pointerup', end);
            c.addEventListener('pointercancel', end);
            window.addEventListener('resize', fit);
            // where it was signed (only when the phone allows it; never asks twice)
            if (navigator.geolocation) {
                navigator.geolocation.getCurrentPosition((p) => { this.$wire.set('signLat', p.coords.latitude, false); this.$wire.set('signLng', p.coords.longitude, false); }, () => {}, { maximumAge: 120000, timeout: 8000 });
            }
        },
        /** A small PNG: the strokes on white, at most 600 px wide. */
        png() {
            const c = this.$refs.pad;
            const k = Math.min(1, 600 / c.width);
            const o = document.createElement('canvas');
            o.width = Math.round(c.width * k); o.height = Math.round(c.height * k);
            const x = o.getContext('2d');
            x.fillStyle = '#fff'; x.fillRect(0, 0, o.width, o.height);
            x.drawImage(c, 0, 0, o.width, o.height);
            return o.toDataURL('image/png');
        },
        clear() {
            const c = this.$refs.pad;
            c.getContext('2d').clearRect(0, 0, c.width, c.height);
            this.empty = true;
            this.$wire.set('signature', null);
        },
    };
};
