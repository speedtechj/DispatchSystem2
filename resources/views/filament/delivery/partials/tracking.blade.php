@if ($tracking['trip'] && ! $tracking['consent'])
    <div class="ds-trk__ask" wire:key="track-ask">
        <span class="ds-trk__pin">📍</span>
        <strong>Share your location during trips</strong>
        <p>The office sees where the truck is, so they can answer customers and help when something goes wrong.</p>
        <ul>
            <li><b>✓</b>Only while you are on an active trip</li>
            <li><b>✓</b>Stops by itself when the trip is finished</li>
            <li><b>✓</b>Seen only by your office and hub</li>
            <li><i>i</i>Kept {{ \App\Support\Tracking\TrackSettings::int('keep_days') }} days, then deleted</li>
        </ul>
        <small>Your phone will ask once. Choose "Allow while using the app".</small>
        <button type="button" class="ds-sa__primary" wire:click="agreeTracking">I agree · turn on location</button>
    </div>
@elseif ($tracking['trip'] && $tracking['consent'])
    <div wire:key="track-on-{{ $tracking['trip'] }}" wire:ignore x-data="{
            state: 'starting', secure: window.isSecureContext, last: null, ago: '', trip: @js($tracking['trip']), every: {{ max(10, (int) $tracking['interval']) }} * 1000,
            q: [], watch: null, timer: null, sentAt: 0,
            init() {
                try { this.q = JSON.parse(localStorage.getItem('ds.track.q') || '[]') } catch (e) { this.q = [] }
                this.start();
                this.timer = setInterval(() => { this.send(); this.tick() }, 5000);
            },
            start() {
                if (! navigator.geolocation || ! window.isSecureContext) { this.state = 'off'; return }
                this.watch = navigator.geolocation.watchPosition((p) => {
                    this.state = 'on';
                    const c = p.coords, now = Date.now();
                    if (! this.q.length || now - this.q[this.q.length - 1].at >= this.every - 1000) {
                        this.q.push({ lat: c.latitude, lng: c.longitude, speed: c.speed, heading: c.heading, accuracy: c.accuracy, at: now });
                        this.q = this.q.slice(-300); this.keep();
                    }
                }, () => { this.state = 'off' }, { enableHighAccuracy: true, maximumAge: 10000, timeout: 30000 });
            },
            keep() { try { localStorage.setItem('ds.track.q', JSON.stringify(this.q)) } catch (e) {} },
            async send() {
                if (! this.q.length || ! navigator.onLine || Date.now() - this.sentAt < this.every - 1000) return;
                const points = this.q.slice(0, 300);
                try {
                    const r = await fetch(@js(route('track.driver')), { method: 'POST', credentials: 'same-origin',
                        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json', 'X-CSRF-TOKEN': @js(csrf_token()) },
                        body: JSON.stringify({ points }) });
                    if (! r.ok) return;
                    const d = await r.json();
                    this.q = this.q.slice(points.length); this.keep();
                    this.sentAt = Date.now(); this.last = Date.now();
                    if (d.interval) this.every = d.interval * 1000;
                    if (d.tracking === false) { this.state = 'stopped'; navigator.geolocation.clearWatch(this.watch); clearInterval(this.timer) }
                } catch (e) {}
            },
            tick() { this.ago = this.last ? Math.max(1, Math.round((Date.now() - this.last) / 1000)) + ' s ago' : '' },
            retry() { if (this.watch) navigator.geolocation.clearWatch(this.watch); this.start() },
        }" x-show="state !== 'stopped'">
        <button type="button" class="ds-trk__bar" x-bind:class="state === 'off' ? 'is-off' : ''" x-on:click="state === 'off' && retry()">
            <i></i>
            <span x-show="state !== 'off'"><b x-text="'Sharing location · trip ' + trip"></b><small x-text="(ago ? 'Sent ' + ago : 'Getting your location…') + ' · stops when the trip ends'"></small></span>
            <span x-show="state === 'off'" x-cloak><b>Location off · the office can't see the truck</b><small x-text="secure ? 'Tap to turn on (allow location for this app)' : 'Location needs the https:// address of the app'"></small></span>
        </button>
    </div>
@endif
