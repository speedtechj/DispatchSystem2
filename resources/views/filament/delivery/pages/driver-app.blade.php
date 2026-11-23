@php
    $ring = fn (int $done, int $total, int $len = 289) => $len - ($total > 0 ? round($len * min($done, $total) / $total) : 0);
    $p = $progress ?? ['total' => 0, 'delivered' => 0, 'notDelivered' => 0, 'left' => 0];
    $user = auth()->user();
    $initials = mb_strtoupper(mb_substr($user?->first_name ?? '', 0, 1).mb_substr($user?->last_name ?? '', 0, 1)) ?: '·';
    $photoJs = "{ busy: false, failed: false, pct: 0,
        take() { this.failed = false; window.dispatchEvent(new CustomEvent('ds-scanner', { detail: { release: true } })); this.\$refs.file.value = ''; this.\$refs.file.click() },
        async send(e) {
            const files = [...e.target.files]; if (! files.length) return;
            for (const file of files) {
                this.busy = true; this.pct = 0; let out = file;
                out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
                await new Promise(done => \$wire.upload('upload', out, () => \$wire.savePhoto().then(done), () => { this.failed = true; done() }, (ev) => { this.pct = ev.detail.progress }));
            }
            this.busy = false;
        } }";
@endphp
<x-filament-panels::page>
<div class="ds-sa ds-dr" x-data x-on:driver-app-buzz.window="if (navigator.vibrate) navigator.vibrate($event.detail.ok ? 60 : [80, 60, 80])">
    {{-- Signal bar: drawn by driver-offline.js (shows "No signal", "waiting to send", "needs attention"). --}}
    <div id="ds-net" class="dso-net" wire:ignore aria-live="polite"></div>

    {{-- Truck tracking: location during trips, after the driver agrees once. --}}
    @include('filament.delivery.partials.tracking', ['tracking' => $tracking])

    {{-- ============================== today ============================== --}}
    @if ($screen === 'home')
        <section class="ds-sa__screen" wire:key="home">
            <header class="ds-sa__hello">
                <span>
                    <small>{{ $trip ? 'Trip '.$trip->trip_number.($trip->truck?->plate_no ? ' · Truck '.$trip->truck->plate_no : '') : now()->format('l, F j') }}</small>
                    <strong>{{ $greeting }}, {{ $user?->first_name }}</strong>
                </span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help')" aria-label="Help">?</button>
                <span class="ds-sa__avatar is-green">{{ $initials }}</span>
            </header>

            @if (\App\Support\Shipping\Shipments::ready() && ($portShip = \App\Support\Shipping\Shipments::forDriverPort($trip ?? null)))
                <a href="{{ \App\Filament\Delivery\Pages\AtPort::getUrl() }}" class="ds-fd__home"><span aria-hidden="true">🚢</span><span><b>At the port · {{ $portShip->code }}</b><small>{{ $portShip->port_count !== null ? 'Counted: '.$portShip->port_count.' boxes · tap to change' : 'Type the forwarder count and take a photo of the receipt' }}</small></span><span class="ds-sa__chev">›</span></a>
            @endif
            @if (\App\Support\Fuel\Fuel::ready())
                <a href="{{ \App\Filament\Delivery\Pages\Fuel::getUrl() }}" class="ds-fd__home"><span aria-hidden="true">⛽</span><span><b>Add fuel</b><small>Photo of the receipt and the odometer</small></span><span class="ds-sa__chev">›</span></a>
            @endif

            @if (! $trip && $closedTrip)
                <div class="ds-ts ds-ts--closed">
                    <small>Trip {{ $closedTrip->trip_number }} done · truck released</small>
                    <strong>{{ $closedDelivered ? 'All '.$closedDelivered.' boxes delivered' : 'Trip closed' }}</strong>
                    <span>Every box is delivered or returned. Thank you! Your next trip shows here when the office makes it.</span>
                </div>
            @elseif (! $trip)
                <div class="ds-sa__empty">
                    <span class="ds-sa__empty-icon">@include('filament.scan.icon', ['name' => 'truck'])</span>
                    <strong>You're not on a trip right now</strong>
                    <p>When the office puts you on a truck, today's boxes show up here. Pull down or reopen the app to refresh.</p>
                </div>
            @else
                @if ($stageCard)
                        <div class="ds-ts ds-ts--{{ $stage }}">
                            <small>{{ $stageCard[0] }}</small>
                            <strong>Trip {{ $trip->trip_number }}</strong>
                            <span>{{ $stageCard[1] }}</span>
                            @if ($canTake)
                                <button type="button" class="ds-sa__primary" wire:click="takeTrip" wire:confirm="Take trip {{ $trip->trip_number }} with {{ $p['total'] }} boxes?">I take the trip · {{ $p['total'] }} boxes</button>
                            @endif
                        </div>
                @endif
                @if ($nextTrip)
                    <div class="ds-ts ds-ts--next">
                        <small>Next trip waiting for this truck</small>
                        <strong>Trip {{ $nextTrip->trip_number }}</strong>
                        <span>It shows here as soon as trip {{ $trip->trip_number }} is closed.</span>
                    </div>
                @endif
                @if ($finished)
                    <div class="ds-dr__celebrate">
                        <span class="ds-sa__ring is-big"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="48" class="is-track"/><circle cx="55" cy="55" r="48" class="is-fill is-ok" style="stroke-dasharray: 302; stroke-dashoffset: 0"/></svg><span><i><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></i></span></span>
                        <strong>All {{ $p['total'] }} boxes delivered</strong>
                        <p>Great work. The office can see every delivery and photo.</p>
                    </div>
                @else
                    <div class="ds-sa__today">
                        <span class="ds-sa__ring is-mid">
                            <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill is-green" style="stroke-dashoffset: {{ $ring($p['delivered'], $p['total']) }}"/></svg>
                            <span><strong>{{ $p['delivered'] }}</strong><small>of {{ $p['total'] }} delivered</small></span>
                        </span>
                        <dl>
                            <dt>Delivered</dt><dd class="is-ok">{{ $p['delivered'] }}</dd>
                            <dt>Still on the truck</dt><dd>{{ $p['left'] }} left</dd>
                            <dt>Not delivered</dt><dd class="is-warn">{{ $p['notDelivered'] }}</dd>
                        </dl>
                    </div>

                    <button type="button" class="ds-sa__primary ds-dr__scanbtn" wire:click="go('scan')" x-on:click="window.dsWarmCamera && window.dsWarmCamera()">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg>
                        Scan a box to deliver
                    </button>
                    @if ($stage === 'road')
                        <button type="button" class="ds-sa__secondary" wire:click="backAtHub" wire:confirm="Back at the hub? Boxes not delivered ({{ $p['left'] }}) are given to the hub and scanned back.">Back at the hub</button>
                    @endif
                @endif

                @if ($priority->isNotEmpty())
                    <p class="ds-sa__label">Priority boxes</p>
                    <div class="ds-sa__list">
                        @foreach ($priority as $b)
                            <button type="button" class="ds-sa__row" wire:click="scan(@js($b['invoice']))"><span class="ds-sa__rowtext"><strong>{{ $b['invoice'] }} · {{ $b['name'] }}</strong><small>{{ $b['address'] }}</small></span><span class="ds-sa__chev">›</span></button>
                        @endforeach
                    </div>
                @endif

                @if ($problems->isNotEmpty())
                    <p class="ds-sa__label">Check before handing over</p>
                    <div class="ds-sa__list is-warn">
                        @foreach ($problems as $b)
                            <button type="button" class="ds-sa__row" wire:click="scan(@js($b['invoice']))"><span class="ds-sa__rowtext"><strong>{{ $b['invoice'] }} · {{ $b['issue'] }}</strong><small>{{ $b['name'] }}{{ $b['remarks'] ? ' · '.$b['remarks'] : '' }}</small></span><span class="ds-sa__chev">›</span></button>
                        @endforeach
                    </div>
                @endif

                @if ($stops->isNotEmpty())
                    @include('filament.delivery.partials.stops', ['stops' => $stops])
                @elseif ($areas->isNotEmpty())
                    <div class="ds-dr__labelrow"><p class="ds-sa__label">Where to go next</p><button type="button" wire:click="go('list')">All boxes ›</button></div>
                    <div class="ds-sa__list">
                        @foreach ($areas->take(6) as $a)
                            <button type="button" class="ds-sa__row" wire:click="area(@js($a['barangay'] ?: $a['city']))">
                                <span class="ds-sa__rowtext"><strong>{{ $a['barangay'] ? $a['barangay'].', ' : '' }}{{ $a['city'] }}</strong><small>{{ $a['boxes'] }} {{ str('box')->plural($a['boxes']) }} · {{ $a['stops']->count() }} {{ str('stop')->plural($a['stops']->count()) }}</small></span>
                                <span class="ds-sa__chev">›</span>
                            </button>
                        @endforeach
                    </div>
                @endif

                @if ($delivered->isNotEmpty())
                    <p class="ds-sa__label">Delivered today</p>
                    <div class="ds-sa__list">
                        @foreach ($delivered as $d)
                            <div class="ds-sa__row ds-dr__done">
                                @if ($d['photo'])<img src="{{ $d['photo'] }}" alt="" class="ds-dr__thumb">@endif
                                <span class="ds-sa__rowtext"><strong>{{ $d['invoice'] }} · {{ $d['name'] }}</strong><small>{{ $d['time'] }}</small></span>
                                @if ($d['undoMinutesLeft'])
                                    <button type="button" class="ds-dr__undo" wire:click="mountAction('undoDelivery', { tripinvoice: {{ $d['id'] }} })">Undo · {{ $d['undoMinutesLeft'] }} min left</button>
                                @else
                                    <span class="ds-dr__office">Office only</span>
                                @endif
                            </div>
                        @endforeach
                    </div>
                @endif

                @if ($crew->isNotEmpty())
                    <div class="ds-dr__crew">
                        @foreach ($crew as $c)
                            <span><i>{{ mb_strtoupper(mb_substr($c['name'], 0, 2)) }}</i>With {{ $c['name'] }}{{ $c['role'] ? ' ('.strtolower($c['role']).')' : '' }}</span>
                        @endforeach
                    </div>
                @endif
            @endif

            <footer class="ds-sa__foot">
                <span class="ds-sa__online"><i></i>Online · every delivery is saved</span>
                <span class="ds-sa__footlinks">
                    <button type="button" class="ds-pwa-install" onclick="window.dsInstallApp && window.dsInstallApp()">Install app</button>
                    <form method="POST" action="{{ filament()->getLogoutUrl() }}">@csrf<button type="submit">Sign out</button></form>
                </span>
            </footer>
        </section>
    @endif

    {{-- ============================== boxes ============================== --}}
    @if ($screen === 'list')
        <section class="ds-sa__screen" wire:key="list">
            <div class="ds-dr__listhead">
                <button type="button" class="ds-sa__back" wire:click="go('home')" aria-label="Back">‹</button>
                <strong>Boxes</strong>
                <button type="button" class="ds-dr__scanmini" wire:click="go('scan')" x-on:click="window.dsWarmCamera && window.dsWarmCamera()" aria-label="Scan a box"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></button>
            </div>
            <label class="ds-dr__search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
                <input type="search" wire:model.live.debounce.350ms="search" placeholder="Name, box number or barangay" aria-label="Search boxes">
            </label>
            @php($tabs = ['todo' => 'To deliver', 'delivered' => 'Delivered', 'missed' => 'Not delivered'])
            @php($ti = array_search($tab, array_keys($tabs), true) ?: 0)
            <div class="ds-sa__seg is-3">
                <span class="ds-sa__segthumb is-light" style="left: calc(4px + {{ $ti }} * (100% - 8px) / 3)"></span>
                @foreach ($tabs as $k => $l)
                    <button type="button" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k])>{{ $l }} · {{ $counts[$k] ?? 0 }}</button>
                @endforeach
            </div>
            <div class="ds-dr__rows">
                @forelse ($rows as $r)
                    @php($inv = $r->invdata)
                    <div class="ds-dr__card" wire:key="r-{{ $r->id }}">
                        <button type="button" class="ds-dr__cardmain" @if (! $r->is_delivered) wire:click="openBox({{ $r->id }})" @endif>
                            <span class="ds-dr__cardtop"><strong>{{ $r->invoice }}</strong>
                                @if ($r->is_delivered)
                                    <em class="is-ok">{{ ($r->delivered_at ?? $r->updated_at)?->format('g:i A') }}</em>
                                @elseif ($r->latestDeliveryAttempt)
                                    <em class="is-warn">{{ $r->latestDeliveryAttempt->reason->getLabel() }}</em>
                                @else
                                    <em>To deliver</em>
                                @endif
                            </span>
                            <span class="ds-dr__name">{{ \Illuminate\Support\Str::title($inv?->receiver_name) }}</span>
                            <small>{{ collect([$inv?->receiver_address, $inv?->receiver_barangay, $inv?->receiver_city])->filter()->map(fn ($x) => \Illuminate\Support\Str::title($x))->join(', ') }}</small>
                        </button>
                        @if ($inv?->receiver_mobile_no)
                            <a class="ds-dr__call" href="tel:{{ preg_replace('/[^0-9+]/', '', $inv->receiver_mobile_no) }}" aria-label="Call {{ $inv->receiver_name }}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2"/></svg></a>
                        @endif
                    </div>
                @empty
                    <div class="ds-sa__note">{{ $search !== '' ? 'No boxes match “'.$search.'”.' : 'Nothing here.' }}</div>
                @endforelse
            </div>
        </section>
    @endif

    {{-- ============================== scan ============================== --}}
    @if ($screen === 'scan')
        <section class="ds-sa__screen ds-sa__scan" wire:key="scan">
            <div class="ds-sa__cam" wire:ignore
                 x-data="barcodeScanner(@js(\App\Support\ScanModes::scanner('scan', 3000)))">
                <video x-ref="video" playsinline muted autoplay></video>
                <div class="ds-sa__frame" x-bind:class="{ 'is-hit': flash }"><i></i><i></i><i></i><i></i><span x-show="scanning" class="ds-sa__sweep"></span></div>
                <p class="ds-sa__camtext" x-show="loading" x-cloak>Starting camera…</p>
                <p class="ds-sa__camtext is-error" x-show="error" x-text="error" x-cloak></p>
                <p class="ds-sa__camtext is-hint" x-show="hint && ! error" x-text="hint" x-cloak></p>
                @include('filament.scan.cam-extras')
                <div class="ds-sa__controls">
                    <label class="ds-sa__type">
                        <input type="text" x-model="manualCode" x-on:keydown.enter.prevent="submitManual()" placeholder="Type a box number" autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="go" aria-label="Box number">
                        <button type="button" x-on:click="submitManual()" aria-label="Find">→</button>
                    </label>
                    <div class="ds-sa__buttons">
                        <button type="button" class="ds-sa__round" x-show="torchSupported && scanning" x-on:click="toggleTorch()" x-bind:class="{ 'is-on': torchOn }" aria-label="Flashlight" x-cloak><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h6l-1 6h-4zM10 8h4v12a2 2 0 0 1-4 0z"/></svg></button>
                        <button type="button" class="ds-sa__shutter" x-on:click="toggle()" x-bind:aria-label="scanning ? 'Stop camera' : 'Start camera'"><span x-bind:class="{ 'is-live': scanning }"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></span></button>
                        <button type="button" class="ds-sa__round" x-show="scanning && cameras.length > 1" x-on:click.stop="listCameras(true).then(() => camList = ! camList)" x-bind:class="{ 'is-on': camList }" aria-label="Switch camera" x-cloak><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><path d="M9.5 12.5a2.6 2.6 0 0 1 4.6-1.4M14.5 14a2.6 2.6 0 0 1-4.6 1.4"/><path d="m14.4 9.6-.1 1.7-1.6-.2M9.6 16.4l.1-1.7 1.6.2"/></svg></button>
                        <button type="button" class="ds-sa__round is-text" wire:click="go('list')" aria-label="Boxes"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/></svg></button>
                    </div>
                </div>
            </div>

            <header class="ds-sa__bar">
                <button type="button" class="ds-sa__back" wire:click="go('home')" aria-label="Back">‹</button>
                <span class="ds-sa__bartext"><small>Deliver</small><strong>{{ $trip ? 'Trip '.$trip->trip_number : 'No trip' }}</strong></span>
                <span class="ds-sa__ring is-tiny"><svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill is-green" style="stroke-dashoffset: {{ $ring($p['delivered'], $p['total']) }}"/></svg></span>
                <span class="ds-sa__count"><strong>{{ $p['delivered'] }}</strong><small>of {{ $p['total'] }}</small></span>
            </header>

            <span class="hidden" wire:key="pz-{{ $sheet ?? 'none' }}-{{ $boxId ?? 0 }}" x-init="$dispatch('ds-scanner', { paused: @js((bool) $sheet) })"></span>

            @if ($just)
                <div class="ds-dr__toast" wire:key="toast-{{ $just->id }}" x-data="{ left: 15 }" x-init="const t = setInterval(() => { left--; if (left <= 0) { clearInterval(t); $wire.set('justDelivered', null) } }, 1000)">
                    <span class="ds-sa__mark is-ok"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></span>
                    <span><strong>{{ $just->invoice }} delivered</strong><small>{{ $justPhotos }} {{ str('photo')->plural($justPhotos) }} saved · undo for <span x-text="left"></span> s</small></span>
                    <button type="button" wire:click="undoJust"><svg viewBox="0 0 40 40"><circle cx="20" cy="20" r="18" class="is-track"/><circle cx="20" cy="20" r="18" class="is-fill"/></svg>Undo</button>
                </div>
            @endif

            @if ($sheet === 'found' && $box)
                @php($inv = $box->invdata)
                @php($addr = collect([$inv?->receiver_address, $inv?->receiver_barangay, $inv?->receiver_city, $inv?->receiver_province])->filter()->map(fn ($x) => \Illuminate\Support\Str::title($x))->join(', '))
                <div class="ds-sa__sheet" wire:key="found-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-dr__tags"><span class="ds-dr__ontruck">On your truck</span><strong>{{ $box->invoice }}</strong>@if ($inv?->boxtype)<em>{{ $inv->boxtype }}</em>@endif</div>
                    <div class="ds-dr__receiver"><strong>{{ \Illuminate\Support\Str::title($inv?->receiver_name) }}</strong><span>{{ $addr }}</span></div>
                    <div class="ds-dr__two">
                        @if ($inv?->receiver_mobile_no)
                            <a href="tel:{{ preg_replace('/[^0-9+]/', '', $inv->receiver_mobile_no) }}"><svg viewBox="0 0 24 24" fill="none" stroke="#34c38f" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2"/></svg>Call</a>
                        @endif
                        <a href="https://www.google.com/maps/search/?api=1&query={{ urlencode($addr.', Philippines') }}" target="_blank" rel="noopener"><svg viewBox="0 0 24 24" fill="none" stroke="#5aa8ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m3 11 18-8-8 18-2-8z"/></svg>Directions</a>
                    </div>
                    <span class="ds-dr__meta">From {{ \Illuminate\Support\Str::title($inv?->sender_name) ?: 'sender' }}@if ($household && $household['count'] > 1) · {{ $household['count'] }} boxes for this house, {{ $household['delivered'] }} delivered @endif</span>
                    @if ($box->latestDeliveryAttempt)
                        <span class="ds-dr__prev">Tried before: {{ $box->latestDeliveryAttempt->reason->getLabel() }} · {{ $box->latestDeliveryAttempt->created_at->diffForHumans() }}</span>
                    @endif
                    @if ($risk && $risk['score'] >= 50)
                        <span class="ds-dr__risk"><b>Heads up · may not be delivered</b>{{ implode(' · ', $risk['reasons']) }}. {{ $inv?->receiver_mobile_no ? 'Call before you go.' : '' }}</span>
                    @endif
                    <button type="button" class="ds-sa__primary is-green" wire:click="startDeliver">Deliver this box</button>
                    <button type="button" class="ds-sa__secondary" wire:click="startMiss">Can't deliver</button>
                </div>
            @endif

            @if ($sheet === 'deliver' && $box)
                <div class="ds-sa__sheet" wire:key="deliver-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <span class="ds-dr__sheethead"><small>{{ $box->invoice }} · {{ \Illuminate\Support\Str::title($box->invdata?->receiver_name) }}</small><strong>Proof of delivery</strong><span>Take as many photos as you need: the house, the box at the door, the receiver.</span></span>
                    <div class="ds-dr__grid" x-data="{{ $photoJs }}">
                        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                        @foreach ($photoUrls as $i => $url)
                            <span class="ds-dr__proof" wire:key="ph-{{ $i }}-{{ md5($url) }}"><img src="{{ $url }}" alt="Photo {{ $i + 1 }}"><b>{{ $i + 1 }}</b><button type="button" wire:click="removePhoto({{ $i }})" aria-label="Remove photo {{ $i + 1 }}">✕</button></span>
                        @endforeach
                        <button type="button" class="ds-dr__add" x-on:click="take()" x-bind:disabled="busy">
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                            <span x-show="! busy">{{ $photoUrls ? 'Add another' : 'Take photo' }}</span>
                            <span x-show="busy" x-cloak>Saving… <span x-text="pct + '%'"></span></span>
                        </button>
                        <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                    </div>
                    <button type="button" @class(['ds-sa__primary', 'is-green' => $photoUrls, 'is-off' => ! $photoUrls]) wire:click="confirmDelivered" @disabled(! $photoUrls)>
                        {{ $photoUrls ? 'Delivered · '.count($photoUrls).' '.str('photo')->plural(count($photoUrls)) : 'Take at least 1 photo' }}
                    </button>
                    <button type="button" class="ds-dr__link" wire:click="backToBox">Back</button>
                </div>
            @endif

            @if ($sheet === 'miss' && $box)
                <div class="ds-sa__sheet is-warn" wire:key="miss-{{ $box->id }}">
                    <span class="ds-sa__grab"></span>
                    <span class="ds-dr__sheethead is-warn"><small>{{ $box->invoice }} · {{ \Illuminate\Support\Str::title($box->invdata?->receiver_name) }}</small><strong>Why couldn't you deliver it?</strong></span>
                    <div class="ds-dr__chips" role="group" aria-label="Reason">
                        @foreach ($reasons as $r)
                            <button type="button" wire:click="$set('reason', '{{ $r->value }}')" @class(['is-on' => $reason === $r->value])>{{ $r->getLabel() }}</button>
                        @endforeach
                    </div>
                    @if ($voiceOn)
                        <div class="ds-dr__voice" x-data="{
                            ok: !! (window.SpeechRecognition || window.webkitSpeechRecognition), on: false, busy: false, heard: '',
                            start() {
                                const R = window.SpeechRecognition || window.webkitSpeechRecognition; if (! R) return;
                                const r = new R(); r.lang = 'fil-PH'; r.interimResults = true; r.continuous = false;
                                this.heard = ''; this.on = true;
                                r.onresult = (e) => { this.heard = Array.from(e.results).map(x => x[0].transcript).join(' ') };
                                r.onerror = () => { this.on = false };
                                r.onend = () => { this.on = false; if (this.heard.trim()) { this.busy = true; $wire.voiceFill(this.heard).then(() => this.busy = false) } };
                                r.start(); this.rec = r;
                            },
                            stop() { this.rec && this.rec.stop() }
                        }" x-show="ok" x-cloak>
                            <button type="button" x-on:click="on ? stop() : start()" x-bind:class="{ 'is-on': on }" x-bind:disabled="busy" aria-label="Say what happened">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>
                            </button>
                            <span>
                                <b x-text="on ? 'Listening… tap to stop' : (busy ? 'Filling in…' : 'Say what happened')"></b>
                                <small x-text="heard || 'Tagalog, Bisaya or English. The reason and note are filled in for you.'"></small>
                            </span>
                        </div>
                    @endif
                    <input type="text" class="ds-sa__note-in" wire:model.blur="note" maxlength="500" placeholder="{{ $reasonCase?->notePrompt() ?? 'Note' }}{{ $reasonCase?->requiresNote() ? '' : ' (optional)' }}" aria-label="Note">
                    <div class="ds-sa__photos" x-data="{{ $photoJs }}">
                        <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                        @foreach ($photoUrls as $i => $url)
                            <span class="ds-sa__shot ds-dr__proof is-small"><img src="{{ $url }}" alt=""><button type="button" wire:click="removePhoto({{ $i }})" aria-label="Remove photo">✕</button></span>
                        @endforeach
                        @if (count($photoUrls) < 3)
                            <button type="button" class="ds-sa__addphoto" x-on:click="take()" x-bind:disabled="busy">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                                <span x-show="! busy">{{ $reasonCase?->requiresPhoto() ? 'Add photo (needed)' : 'Add photo' }}</span><span x-show="busy" x-cloak>Saving…</span>
                            </button>
                        @endif
                    </div>
                    <button type="button" class="ds-sa__primary is-amber" wire:click="saveMissed">Keep it on the truck</button>
                    <button type="button" class="ds-dr__link" wire:click="backToBox">Back</button>
                </div>
            @endif

            @if ($sheet === 'which' && $which)
                {{-- board 57: two boxes with one number on the truck; pick the receiver on the sticker --}}
                <div class="ds-sa__sheet ds-which" wire:key="which-{{ $whichCode }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-which__head"><span>{{ count($which) }}</span><span><strong>{{ count($which) }} boxes have number {{ $whichCode }}</strong><small>Which one? Look at the receiver on the sticker.</small></span></div>
                    @foreach ($which as $w)
                        <button type="button" class="ds-which__opt" wire:click="pickBox({{ $w['id'] }})" wire:key="w-{{ $w['id'] }}">
                            <span><strong>{{ $w['name'] }}</strong>@if ($w['place'])<small>{{ $w['place'] }}</small>@endif @if ($w['sender'])<em>from {{ $w['sender'] }}</em>@endif</span><b>›</b>
                        </button>
                    @endforeach
                    <button type="button" class="ds-sa__secondary" wire:click="closeSheet">Not this box · scan again</button>
                </div>
            @endif

            @if ($sheet === 'wrong')
                <div class="ds-sa__sheet is-bad" wire:key="wrong-{{ md5((string) $wrongText) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg></span>
                        <span><strong>Not this box</strong><small>Check the label</small></span>
                    </div>
                    <p class="ds-sa__msg">{{ $wrongText }}</p>
                    <button type="button" class="ds-sa__secondary" wire:click="closeSheet">Scan another box</button>
                </div>
            @endif
        </section>
    @endif
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
