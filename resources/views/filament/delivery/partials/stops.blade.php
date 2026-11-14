{{--
    Your stops, in the order the office sorted them. Navigate opens Waze, Google Maps
    or Apple Maps with the route from where you are to the receiver's pin.
--}}
@php($next = $stops->first())
<div class="ds-nav" wire:key="stops-{{ $stops->pluck('id')->join('-') }}" x-data="{
        open: null, back: null, remember: true, far: null, pinning: false,
        app: (() => { try { return localStorage.getItem('ds.navApp') } catch (e) { return null } })(),
        ios: /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1),
        stops: @js($stops->keyBy('id')),
        url(app, s) {
            const to = encodeURIComponent(s.go);
            if (app === 'waze') return s.lat !== null ? 'https://waze.com/ul?ll=' + to + '&navigate=yes' : 'https://waze.com/ul?q=' + to + '&navigate=yes';
            if (app === 'apple') return 'https://maps.apple.com/?daddr=' + to + '&dirflg=d';
            return 'https://www.google.com/maps/dir/?api=1&destination=' + to + '&travelmode=driving';
        },
        tap(id) { const s = this.stops[id]; if (this.app && (this.app !== 'apple' || this.ios)) { this.go(this.app, s) } else { this.open = s } },
        go(app, s) {
            if (this.remember) { try { localStorage.setItem('ds.navApp', app) } catch (e) {} this.app = app }
            this.open = null; this.back = s; this.far = null;
            window.open(this.url(app, s), '_blank') || (window.location.href = this.url(app, s));
        },
        forget() { try { localStorage.removeItem('ds.navApp') } catch (e) {} this.app = null },
        where() {
            const s = this.back; if (! s || s.lat === null || ! navigator.geolocation) return;
            navigator.geolocation.getCurrentPosition((p) => {
                const r = Math.PI / 180, dLat = (s.lat - p.coords.latitude) * r, dLng = (s.lng - p.coords.longitude) * r;
                const h = Math.sin(dLat / 2) ** 2 + Math.cos(p.coords.latitude * r) * Math.cos(s.lat * r) * Math.sin(dLng / 2) ** 2;
                this.far = Math.round(12742000 * Math.asin(Math.min(1, Math.sqrt(h))));
            }, () => {}, { enableHighAccuracy: true, timeout: 8000 });
        },
        pin() {
            if (! navigator.geolocation) return; this.pinning = true;
            navigator.geolocation.getCurrentPosition((p) => { $wire.suggestPin(this.back.id, p.coords.latitude, p.coords.longitude); this.pinning = false },
                () => { this.pinning = false; alert('Turn on location for this app, then try again.') }, { enableHighAccuracy: true, timeout: 10000 });
        },
    }" x-on:visibilitychange.document="if (document.visibilityState === 'visible' && back) where()">

    {{-- back from the map --}}
    <template x-if="back">
        <div class="ds-nav__back">
            <small x-text="far !== null ? (far < 150 ? 'You\'re near stop ' + back.no + ' · ' + far + ' m away' : 'Stop ' + back.no + ' · ' + (far >= 1000 ? (far / 1000).toFixed(1) + ' km' : far + ' m') + ' away') : 'Going to stop ' + back.no"></small>
            <strong x-text="back.name + ' · ' + back.count + (back.count > 1 ? ' boxes' : ' box')"></strong>
            <span x-text="back.invoices"></span>
            <button type="button" class="ds-sa__primary" x-on:click="$wire.scan(back.invoice); back = null">I'm here · start delivery</button>
            <div class="ds-nav__two">
                <a x-show="back.tel" x-bind:href="back.tel" class="ds-nav__soft">Call</a>
                <button type="button" class="ds-nav__soft is-warn" x-on:click="pin()" x-bind:disabled="pinning" x-text="pinning ? 'Getting your location…' : 'Can\'t find it · pin where it is'"></button>
            </div>
            <button type="button" class="ds-nav__link" x-on:click="back = null">Close</button>
        </div>
    </template>

    <div class="ds-dr__labelrow"><p class="ds-sa__label">Your stops</p><button type="button" wire:click="go('list')">All boxes ›</button></div>

    <div class="ds-nav__next">
        <span><small>Next · stop {{ $next['no'] }}</small><strong>{{ $next['name'] }}</strong><em>{{ $next['place'] }} · {{ $next['count'] }} {{ str('box')->plural($next['count']) }}</em></span>
        <button type="button" x-on:click="tap({{ $next['id'] }})">Navigate</button>
    </div>

    <div class="ds-sa__list">
        @foreach ($stops->take(12) as $s)
            <div class="ds-sa__row ds-nav__row" wire:key="stop-{{ $s['id'] }}">
                <span @class(['ds-nav__no', 'is-next' => $loop->first, 'is-prio' => $s['priority']])>{{ $s['no'] }}</span>
                <button type="button" class="ds-sa__rowtext ds-nav__who" x-on:click="tap({{ $s['id'] }})">
                    <strong>{{ $s['name'] }}</strong>
                    <small>{{ $s['place'] }} · {{ $s['count'] }} {{ str('box')->plural($s['count']) }}@if ($s['priority']) · priority @endif @if (! $s['lat']) · approximate @endif</small>
                </button>
                <button type="button" class="ds-nav__go" x-on:click="tap({{ $s['id'] }})">Navigate</button>
            </div>
        @endforeach
    </div>
    <p class="ds-nav__hint">The boxes for the next stop are nearest the door. <button type="button" x-show="app" x-on:click="forget()" x-cloak>Change map app</button></p>

    {{-- choose the map app --}}
    <template x-if="open">
        <div class="ds-nav__veil" x-on:click.self="open = null">
            <div class="ds-nav__sheet">
                <span class="ds-sa__grab"></span>
                <small x-text="'Stop ' + open.no + ' of {{ $stops->last()['no'] }}'"></small>
                <strong x-text="open.name"></strong>
                <span class="ds-nav__addr" x-text="open.address"></span>
                <span class="ds-nav__chips">
                    <em x-text="open.lat !== null ? (open.exact ? '📍 exact pin' : '📍 area pin') : 'no pin · uses the address'"></em>
                    <em x-text="open.count + (open.count > 1 ? ' boxes' : ' box')"></em>
                </span>
                <b class="ds-nav__ask">Get directions from where you are now with</b>
                <button type="button" class="ds-nav__app" x-on:click="go('waze', open)"><i class="is-waze">W</i><span><b>Waze</b><small>Best for traffic and shortcuts</small></span>›</button>
                <button type="button" class="ds-nav__app" x-on:click="go('google', open)"><i class="is-google">G</i><span><b>Google Maps</b><small>Best street and address detail</small></span>›</button>
                <button type="button" class="ds-nav__app" x-show="ios" x-on:click="go('apple', open)"><i class="is-apple">A</i><span><b>Apple Maps</b><small>Already on your iPhone</small></span>›</button>
                <label class="ds-nav__remember"><input type="checkbox" x-model="remember"> Remember my choice (next time it opens right away)</label>
                <div class="ds-nav__two">
                    <a x-show="open.tel" x-bind:href="open.tel" class="ds-nav__soft">Call</a>
                    <button type="button" class="ds-nav__soft" x-on:click="navigator.clipboard && navigator.clipboard.writeText(open.address)">Copy address</button>
                </div>
            </div>
        </div>
    </template>
</div>
