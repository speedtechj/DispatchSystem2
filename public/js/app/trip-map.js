// Stops of a trip on an OpenStreetMap map (Leaflet). Used by "Stops & loading order".
window.dsTripMap = function (el, data) {
    const L = window.L;
    const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
    const map = L.map(el, { scrollWheelZoom: false });
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
    }).addTo(map);
    const layer = L.layerGroup().addTo(map);

    function draw(d) {
        layer.clearLayers();
        const line = [];
        if (d.start) {
            L.marker([d.start.lat, d.start.lng], { icon: L.divIcon({ className: 'ds-map__pin is-start', html: 'WH', iconSize: [40, 24] }) })
                .bindTooltip(esc(d.start.name)).addTo(layer);
            line.push([d.start.lat, d.start.lng]);
        }
        (d.stops || []).forEach((s) => {
            if (s.lat == null || s.lng == null) return;
            L.marker([s.lat, s.lng], { icon: L.divIcon({ className: 'ds-map__pin is-' + s.kind, html: String(s.no), iconSize: [28, 28] }) })
                .bindPopup('<b>' + s.no + '. ' + esc(s.name) + '</b><br>' + esc(s.address) + '<br>' + s.boxes + (s.boxes > 1 ? ' boxes' : ' box') + ' · ' + esc(s.zone))
                .addTo(layer);
            line.push([s.lat, s.lng]);
        });
        if (line.length > 1) L.polyline(line, { color: '#0e2433', weight: 3, opacity: 0.7, dashArray: '8 6' }).addTo(layer);
        if (line.length) map.fitBounds(line, { padding: [30, 30], maxZoom: 15 });
        else map.setView([12.3, 122.9], 5);
    }

    draw(data);
    setTimeout(() => map.invalidateSize(), 200);

    return { draw };
};
