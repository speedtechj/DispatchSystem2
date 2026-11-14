// Truck tracking map: OpenStreetMap (Leaflet, free) or Google Maps when a browser key is saved.
(function () {
    const COLORS = { ok: '#0e2433', warn: '#9a6400', bad: '#b3261e' };
    const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
    let googleLoading = null;
    function loadGoogle(key) {
        if (window.google && window.google.maps) return Promise.resolve();
        if (!googleLoading) {
            googleLoading = new Promise((ok, fail) => {
                window.__dsGoogleReady = ok;
                const s = document.createElement('script');
                s.src = 'https://maps.googleapis.com/maps/api/js?key=' + encodeURIComponent(key) + '&callback=__dsGoogleReady';
                s.async = true; s.onerror = fail; document.head.appendChild(s);
            });
        }
        return googleLoading;
    }

    function leaflet(el) {
        const L = window.L;
        const map = L.map(el, { scrollWheelZoom: false });
        L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '&copy; OpenStreetMap' }).addTo(map);
        const layer = L.layerGroup().addTo(map);
        let ghost = null;
        return {
            clear() { layer.clearLayers(); ghost = null; },
            line(pts, color, dash, w) { if (pts.length > 1) L.polyline(pts.map((p) => [p[0], p[1]]), { color, weight: w || 5, opacity: 0.7, dashArray: dash ? '8 7' : null }).addTo(layer); },
            dot(p, html, cls, size, tip, onClick) {
                const m = L.marker([p[0], p[1]], { icon: L.divIcon({ className: 'ds-tm__pin ' + cls, html, iconSize: size }) }).addTo(layer);
                if (tip) m.bindTooltip(tip);
                if (onClick) m.on('click', onClick);
                return m;
            },
            fit(pts) { if (pts.length) map.fitBounds(pts.map((p) => [p[0], p[1]]), { padding: [40, 40], maxZoom: 15 }); else map.setView([12.3, 122.9], 6); },
            move(p) { if (!ghost) ghost = this.dot(p, '🚚', 'is-ghost', [34, 34]); else ghost.setLatLng([p[0], p[1]]); },
            size() { setTimeout(() => map.invalidateSize(), 150); },
        };
    }

    function gmaps(el) {
        const g = window.google.maps;
        const map = new g.Map(el, { center: { lat: 12.3, lng: 122.9 }, zoom: 6, mapTypeControl: false, streetViewControl: false, fullscreenControl: true });
        let items = [];
        let ghost = null;
        const icon = (bg, w, h) => ({ url: 'data:image/svg+xml;charset=UTF-8,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect x="1" y="1" width="${w - 2}" height="${h - 2}" rx="${h / 2 - 1}" fill="${bg}" stroke="#fff" stroke-width="2"/></svg>`), anchor: new g.Point(w / 2, h / 2), labelOrigin: new g.Point(w / 2, h / 2) });
        return {
            clear() { items.forEach((i) => i.setMap(null)); items = []; ghost = null; },
            line(pts, color, dash, w) {
                if (pts.length < 2) return;
                const path = pts.map((p) => ({ lat: p[0], lng: p[1] }));
                items.push(new g.Polyline(dash
                    ? { map, path, strokeOpacity: 0, icons: [{ icon: { path: 'M 0,-1 0,1', strokeOpacity: 0.7, strokeColor: color, scale: 3 }, offset: '0', repeat: '14px' }] }
                    : { map, path, strokeColor: color, strokeOpacity: 0.7, strokeWeight: w || 5 }));
            },
            dot(p, html, cls, size, tip, onClick) {
                const bg = cls.includes('is-done') ? '#17895e' : cls.includes('is-warn') ? COLORS.warn : cls.includes('is-bad') ? COLORS.bad : cls.includes('is-mark') ? '#f0a93b' : '#0e2433';
                const text = String(html).replace(/<[^>]+>/g, '');
                const w = Math.max(size[0], text.length * 8 + 18);
                const m = new g.Marker({ map, position: { lat: p[0], lng: p[1] }, icon: icon(bg, w, size[1]), label: { text, color: '#fff', fontWeight: '800', fontSize: '12px' }, title: tip || '', zIndex: cls.includes('is-truck') ? 10 : 1 });
                if (onClick) m.addListener('click', onClick);
                items.push(m);
                return m;
            },
            fit(pts) {
                if (!pts.length) return;
                const b = new g.LatLngBounds(); pts.forEach((p) => b.extend({ lat: p[0], lng: p[1] }));
                map.fitBounds(b, 40); if (pts.length === 1) map.setZoom(15);
            },
            move(p) { if (!ghost) ghost = this.dot(p, '🚚', 'is-ghost', [34, 26]); else ghost.setPosition({ lat: p[0], lng: p[1] }); },
            size() {},
        };
    }

    window.dsTruckMap = function (el, data, googleKey) {
        let api = null;
        let pending = data;
        let fitted = false;
        let replay = [];
        function draw(d) {
            if (!api) { pending = d; return; }
            api.clear();
            const pts = [];
            if (d.start) { api.dot([d.start.lat, d.start.lng], 'WH', 'is-start', [40, 24], d.start.name); pts.push([d.start.lat, d.start.lng]); }
            api.line(d.done || [], '#17895e', false, 6);
            (d.done || []).forEach((p) => pts.push(p));
            const left = (d.stops || []).filter((s) => !s.done);
            if (d.from && left.length) api.line([d.from].concat(left.map((s) => [s.lat, s.lng])), '#0e2433', true, 3);
            (d.stops || []).forEach((s) => { api.dot([s.lat, s.lng], s.done ? '✓' : String(s.no), s.done ? 'is-done' : 'is-stop', [26, 26], s.no + '. ' + s.name); pts.push([s.lat, s.lng]); });
            (d.marks || []).forEach((m) => api.dot([m.lat, m.lng], '⏸', 'is-mark', [26, 26], m.label));
            (d.trucks || []).forEach((t) => {
                if (t.lat == null) return;
                api.dot([t.lat, t.lng], '🚚 ' + esc(t.plate), 'is-truck is-' + t.kind + (t.sel ? ' is-sel' : ''), [96, 28], t.state,
                    () => el.dispatchEvent(new CustomEvent('truck-pick', { detail: t.id, bubbles: true })));
                if (t.sel || (d.trucks.length > 1)) pts.push([t.lat, t.lng]);
            });
            replay = d.replay || [];
            if (replay.length) { api.line(replay, '#1f6fa5', false, 5); replay.forEach((p) => pts.push(p)); api.move(replay[replay.length - 1]); }
            if (!fitted || d.refit) { api.fit(pts); fitted = true; }
            api.size();
        }
        const ready = googleKey ? loadGoogle(googleKey).then(() => { api = gmaps(el); }).catch(() => { api = leaflet(el); }) : Promise.resolve().then(() => { api = leaflet(el); });
        ready.then(() => draw(pending));
        return { draw: (d) => draw(d), at: (i) => { if (api && replay[i]) api.move(replay[i]); } };
    };
})();
