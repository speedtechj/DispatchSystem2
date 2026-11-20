@php
    $ring = fn (int $done, int $total, int $len = 289) => $len - ($total > 0 ? round($len * min($done, $total) / $total) : 0);
    $condOrder = array_keys($conditions);
@endphp
<x-filament-panels::page>
<div class="ds-sa" x-data x-on:scan-app-result.window="if (navigator.vibrate) navigator.vibrate($event.detail.status === 'success' ? 60 : [80, 60, 80])">

    {{-- ============================== start ============================== --}}
    @if ($screen === 'home')
        <section class="ds-sa__screen ds-sa__home" wire:key="home">
            <header class="ds-sa__hello">
                <span><small>{{ $place }}</small><strong>{{ $greeting }}, {{ $firstName }}</strong></span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: 'scan-tips' })" aria-label="Help">?</button>
                <span class="ds-sa__avatar">{{ $initials }}</span>
            </header>

            <div class="ds-sa__today">
                <span class="ds-sa__ring">
                    <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring(min($today['scans'], 500), 500) }}"/></svg>
                    <span><strong>{{ $today['scans'] }}</strong><small>today</small></span>
                </span>
                <dl>
                    <dt>Boxes scanned</dt><dd>{{ number_format($today['scans']) }}</dd>
                    <dt>Photos</dt><dd>{{ number_format($today['photos']) }}</dd>
                    <dt>Problems</dt><dd class="is-bad">{{ $today['problems'] }}</dd>
                </dl>
            </div>

            @if ($modes)
                <p class="ds-sa__label">Start scanning</p>
                <div class="ds-sa__list">
                    @foreach ($modes as $key => $m)
                        <button type="button" class="ds-sa__row" wire:click="open('{{ $key }}')">
                            <span class="ds-sa__chip">@include('filament.scan.icon', ['name' => $m['icon']])</span>
                            <span class="ds-sa__rowtext"><strong>{{ $m['label'] }}</strong><small>{{ $m['sub'] }}</small></span>
                            @php($w = $waiting[$key] ?? 0)
                            <span @class(['ds-sa__waiting', 'is-none' => ! $w])>{{ $w ? $w.' waiting' : 'All done' }}</span>
                            <span class="ds-sa__chev" aria-hidden="true">›</span>
                        </button>
                    @endforeach
                </div>
            @else
                <div class="ds-sa__note">Your account can't scan here. Ask the office to set your account to Warehouse or Company.</div>
            @endif

            <footer class="ds-sa__foot">
                <span class="ds-sa__online"><i></i>Online · every scan is saved</span>
                <span class="ds-sa__footlinks">
                    <button type="button" class="ds-pwa-install" onclick="window.dsInstallApp && window.dsInstallApp()">Install app</button>
                    <form method="POST" action="{{ filament()->getLogoutUrl() }}">@csrf<button type="submit">Sign out</button></form>
                </span>
            </footer>
        </section>
    @endif

    {{-- ============================== pick ============================== --}}
    @if ($screen === 'pick' && $def)
        <section class="ds-sa__screen ds-sa__pick" wire:key="pick-{{ $this->mode }}">
            <button type="button" class="ds-sa__pill" wire:click="home"><span aria-hidden="true">‹</span> Back</button>
            <header class="ds-sa__title ds-sa__title--help"><span><small>{{ $def['label'] }}</small><strong>Choose the {{ $def['kind'] }}</strong></span><button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: '{{ \App\Support\Help\Help::forScanMode($this->mode) }}' })" aria-label="Help">?</button></header>

            @forelse ($choices as $i => $c)
                <button type="button" @class(['ds-sa__choice', 'is-finished' => $c['finished']]) style="animation-delay: {{ $i * 50 }}ms" wire:click="pick({{ $c['id'] }})" wire:key="c-{{ $c['id'] }}">
                    <span class="ds-sa__choicetext">
                        <strong>{{ $c['name'] }}</strong>
                        @if ($c['sub'])<small>{{ $c['sub'] }}</small>@endif
                        <small class="is-num">{{ $c['done'] }} of {{ $c['total'] }} scanned{{ $c['finished'] ? (($c['active'] ?? true) ? ' · finished' : ' · closed') : '' }}</small>
                    </span>
                    <span class="ds-sa__ring is-small">
                        <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring($c['done'], $c['total']) }}"/></svg>
                        <span><b>{{ $c['total'] ? round($c['done'] / $c['total'] * 100) : 0 }}%</b></span>
                    </span>
                </button>
            @empty
                <div class="ds-sa__note">Nothing left to scan for {{ strtolower($def['label']) }}. Everything open is 100% scanned.</div>
            @endforelse

            @if ($finishedCount)
                <button type="button" class="ds-sa__more" wire:click="toggleFinished">
                    {{ $showFinished ? 'Hide finished' : 'Show finished ('.$finishedCount.')' }}
                </button>
            @endif
        </section>
    @endif

    {{-- ============================== scan ============================== --}}
    @if ($screen === 'scan' && $def)
        <section class="ds-sa__screen ds-sa__scan" wire:key="scan-{{ $this->mode }}-{{ $choice }}">
            @if ($aiFlag)
                <div class="ds-sa__aiflag" wire:key="aiflag-{{ $aiFlag->id }}">
                    <span class="ds-sa__aibadge">AI</span>
                    <span><b>{{ $aiFlag->invoice }} looks {{ strtolower($aiFlag->label()) }}?</b><small>{{ $aiFlag->note }}</small></span>
                    <button type="button" wire:click="aiFlagAnswer({{ $aiFlag->id }}, true)">Yes, mark it</button>
                    <button type="button" class="is-plain" wire:click="aiFlagAnswer({{ $aiFlag->id }}, false)">It's fine</button>
                </div>
            @elseif ($aiPending)
                <span wire:poll.8s class="hidden"></span>
            @endif
            <div class="ds-sa__cam" wire:ignore
                 x-data="barcodeScanner(@js(['method' => 'scan', 'formats' => ['code_128', 'code_39', 'ean_13', 'ean_8', 'upc_a', 'itf', 'qr_code'], 'autoStart' => true, 'continuous' => true, 'cooldown' => 2500, 'beep' => true]))">
                <video x-ref="video" playsinline muted autoplay></video>
                <div class="ds-sa__frame" x-bind:class="{ 'is-hit': flash }"><i></i><i></i><i></i><i></i><span x-show="scanning" class="ds-sa__sweep"></span></div>
                <p class="ds-sa__camtext" x-show="loading" x-cloak>Starting camera…</p>
                <p class="ds-sa__camtext" x-show="! scanning && ! loading && ! error">Camera is off · tap the round button</p>
                <p class="ds-sa__camtext is-error" x-show="error" x-text="error" x-cloak></p>
                <p class="ds-sa__camtext is-hint" x-show="hint && ! error" x-text="hint" x-cloak></p>

                <div class="ds-sa__controls">
                    <label class="ds-sa__type">
                        <input type="text" x-model="manualCode" x-on:keydown.enter.prevent="submitManual()" placeholder="Type or use a handheld scanner" autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="go" aria-label="Box number">
                        <button type="button" x-on:click="submitManual()" aria-label="Find">→</button>
                    </label>
                    <div class="ds-sa__buttons">
                        <button type="button" class="ds-sa__round" x-show="torchSupported && scanning" x-on:click="toggleTorch()" x-bind:class="{ 'is-on': torchOn }" aria-label="Flashlight" x-cloak>
                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h6l-1 6h-4zM10 8h4v12a2 2 0 0 1-4 0z"/></svg>
                        </button>
                        <button type="button" class="ds-sa__shutter" x-on:click="toggle()" x-bind:aria-label="scanning ? 'Stop camera' : 'Start camera'">
                            <span x-bind:class="{ 'is-live': scanning }"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3M7 12h10"/></svg></span>
                        </button>
                        <button type="button" class="ds-sa__round is-text" wire:click="finish">Done</button>
                    </div>
                </div>
            </div>

            <header class="ds-sa__bar">
                <button type="button" class="ds-sa__back" wire:click="back" aria-label="Back">‹</button>
                <span class="ds-sa__bartext"><small>{{ $def['label'] }}</small><strong>{{ $target['name'] ?? '' }}{{ ! empty($target['sub']) ? ' · '.$target['sub'] : '' }}</strong></span>
                <span class="ds-sa__ring is-tiny">
                    <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="46" class="is-track"/><circle cx="55" cy="55" r="46" class="is-fill" style="stroke-dashoffset: {{ $ring($progress['loaded'] ?? 0, $progress['total'] ?? 0) }}"/></svg>
                </span>
                <span class="ds-sa__count"><strong>{{ $progress['loaded'] ?? 0 }}</strong><small>of {{ $progress['total'] ?? 0 }}</small>@if ($space)<small class="ds-sa__space">{{ \App\Support\BoxSizes::fmt($space['loaded']) }}{{ $space['cap'] ? ' / '.$space['cap'] : '' }} space</small>@endif</span>
                <button type="button" class="ds-sa__help" x-on:click="$dispatch('open-help', { slug: '{{ \App\Support\Help\Help::forScanMode($this->mode) }}' })" aria-label="Help">?</button>
            </header>

            @if (count($team) > 1)
                <div class="ds-sx__team" aria-label="Who scanned">
                    @foreach (array_slice($team, 0, 4) as $m)<span @class(['is-me' => $m['me']])>{{ $m['name'] }} <b>{{ $m['n'] }}</b></span>@endforeach
                </div>
            @endif

            @if ($this->mode === 'unload' && $trucks)
                @foreach ($trucks as $tk)
                    <div class="ds-sx__here"><b>🚚 Truck to {{ $tk['to'] }} is here</b><span>{{ $tk['onTruck'] }} on truck</span></div>
                @endforeach
            @endif

            @if (! $status && $loadNext && $loadNext['stop'])
                @include('filament.partials.load-next', ['next' => $loadNext, 'dark' => true])
            @endif

            @if (! $status && ! $bypass && $cityTopUp)
                <div class="ds-sx__citytop" wire:key="citytop-{{ $cityTopUp['key'] }}">
                    <b>✦ Room for {{ $cityTopUp['room'] }} more boxes</b>
                    <span>{{ $cityTopUp['same'] ? 'Same way' : 'Next province' }}: <b>{{ $cityTopUp['city'] }}, {{ $cityTopUp['province'] }}</b> · {{ $cityTopUp['boxes'] }} {{ Str::plural('box', $cityTopUp['boxes']) }}{{ $cityTopUp['days'] ? ', '.$cityTopUp['days'].' '.Str::plural('day', $cityTopUp['days']).' old' : '' }}.@if ($cityTopUp['section']) In section <b>{{ $cityTopUp['section'] }}</b>.@endif</span>
                    <button type="button" class="ds-sa__primary" wire:click="cityTopUpAdd(@js($cityTopUp['key']))">Scan them now</button>
                    <button type="button" class="ds-sa__secondary" wire:click="cityTopUpSkip">No thanks, lock the trip</button>
                </div>
            @endif

            @if ($bypass)
                <div class="ds-sa__sheet is-warn" wire:key="bypass-{{ $bypass['code'] }}">
                    <span class="ds-sa__grab"></span>
                    @if ($bypass['need'] === 'office')
                        <p class="ds-sa__msg"><b>{{ $bypass['title'] }}: office only.</b> Ask the office to allow {{ $bypass['code'] }}. Keep the box aside until they answer.</p>
                        <button type="button" class="ds-sa__primary" wire:click="askOffice">Ask the office</button>
                    @else
                        <span class="ds-sa__hit"><span><small class="ds-ld__kicker">{{ $bypass['title'] }} · load anyway</small><strong>{{ $bypass['code'] }}</strong></span></span>
                        <p class="ds-sa__msg"><b>Why? (the office sees this)</b></p>
                        <div class="ds-sx__reasons">@foreach ($bypassReasons as $r)<button type="button" wire:click="bypassWith(@js($r))">{{ $r }}</button>@endforeach</div>
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="cancelBypass">Cancel</button>
                </div>
            @elseif ($status === 'success' && $box)
                <div class="ds-sa__sheet is-ok" wire:key="ok-{{ $invoiceId }}-{{ $sessionScans }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-ok"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></span>
                        <span><strong>{{ $box->invoice }}</strong><small>{{ $def['ok'] }}</small></span>
                        @if ($boxSize && $boxSize['space'] != 1)<em class="ds-sa__size">{{ $boxSize['name'] }} · takes {{ \App\Support\BoxSizes::fmt($boxSize['space']) }} space</em>@elseif ($box->boxtype)<em>{{ $box->boxtype }}</em>@endif
                    </div>
                    @if ($this->mode === 'count')<p class="ds-sa__msg">{{ $message }}</p>@endif
                    @if ($route)
                        <div @class(['ds-sx__tile', 'is-truck' => ($route['kind'] ?? '') === 'truck']) style="--sx: {{ $route['color'] ?? '#1d6fb8' }}">
                            <small>{{ match ($route['kind'] ?? '') { 'truck' => 'Carry this box to', 'wrong' => 'Careful', default => 'Put this box in' } }}</small>
                            <strong>{{ ($route['kind'] ?? '') === 'truck' ? 'TRUCK' : $route['code'] }}</strong>
                            <span>{{ ($route['kind'] ?? '') === 'truck' ? $route['name'].(! empty($route['plate']) ? ' · '.$route['plate'] : '') : $route['name'] }}</span>
                            @if (($route['kind'] ?? '') === 'truck')<em>✓ Already loaded on trip {{ $route['trip'] }}. No need to scan it again.</em>@endif
                            @if (! empty($route['why']))<em>{{ $route['why'] }}</em>@endif
                            @if (! empty($route['pending']))<em>Then scan the QR on section {{ $route['code'] }}.</em>@endif
                        </div>
                        @if (($route['kind'] ?? '') === 'truck')
                            <button type="button" class="ds-sx__link" wire:click="putInSection">Put in section instead</button>
                        @endif
                    @endif
                    @if ($setInfo)
                        <div @class(['ds-sx__set', 'is-'.$setInfo['kind']])>
                            <span><b>{{ $setInfo['name'] }}</b> · box {{ $setInfo['n'] }} of {{ $setInfo['of'] }}</span>
                            <span class="ds-sx__dots">@for ($i = 1; $i <= min(12, $setInfo['of']); $i++)<i @class(['is-on' => $i <= $setInfo['n']])></i>@endfor</span>
                            <small>{{ $setInfo['text'] }}</small>
                            @if (! empty($setInfo['rows']))
                                <ul class="ds-sx__setrows">@foreach ($setInfo['rows'] as $sr)<li><span>{{ $sr['i'] }}</span>{{ $sr['t'] }}</li>@endforeach</ul>
                            @endif
                            @foreach ($setInfo['add'] ?? [] as $sa)
                                <button type="button" class="ds-sx__setadd" wire:click="addSetBox({{ $sa['id'] }})">Bring {{ $sa['invoice'] }} from section {{ $sa['section'] ?? '?' }} · add to truck</button>
                            @endforeach
                        </div>
                    @endif
                    @if ($spot)
                        <div class="ds-ld__spot is-{{ $spot['zone'] }}"><strong>{{ \App\Models\Maps\TripStop::ZONES[$spot['zone']] ?? '' }}</strong><span>{{ ! empty($spot['hub']) ? $spot['hub'].' (stop '.$spot['stop'].')' : 'Stop '.$spot['stop'] }} · {{ ['front' => 'deep inside, next to the cab', 'middle' => 'in the middle', 'back' => 'near the door'][$spot['zone']] ?? '' }}</span></div>
                    @endif
                    <div class="ds-sa__who">
                        <span>{{ mb_strtoupper(mb_substr($box->receiver_name ?? '?', 0, 2)) }}</span>
                        <span><strong>{{ \Illuminate\Support\Str::title($box->receiver_name) }}</strong><small>{{ collect([$box->receiver_barangay, $box->receiver_city])->filter()->map(fn ($p) => \Illuminate\Support\Str::title($p))->join(', ') }}</small></span>
                    </div>

                    @if ($this->photosOn())
                        @php($ci = max(0, (int) array_search($condition ?? 'good', $condOrder, true)))
                        <div class="ds-sa__seg" role="group" aria-label="How does the box look?">
                            <span class="ds-sa__segthumb is-{{ $condition ?? 'good' }}" style="left: calc(4px + {{ $ci }} * (100% - 8px) / 4)"></span>
                            @foreach ($conditions as $key => $label)
                                <button type="button" wire:click="setCondition('{{ $key }}')" @class(['is-on' => ($condition ?? 'good') === $key]) aria-pressed="{{ ($condition ?? 'good') === $key ? 'true' : 'false' }}"><i class="is-{{ $key }}"></i>{{ $label }}</button>
                            @endforeach
                        </div>
                        @if (in_array($condition, ['damaged', 'wet', 'open'], true))
                            <input type="text" class="ds-sa__note-in" wire:model.blur="note" maxlength="250" placeholder="What is wrong? (optional)" aria-label="What is wrong?">
                        @endif

                        <div class="ds-sa__photos"
                             x-data="{ busy: false, failed: false, pct: 0,
                                take() { this.failed = false; this.$refs.file.value = ''; this.$refs.file.click() },
                                async send(e) {
                                    const file = e.target.files[0]; if (! file) return;
                                    this.busy = true; this.pct = 0; let out = file;
                                    out = window.dsShrinkPhoto ? await window.dsShrinkPhoto(file) : file;
                                    $wire.upload('boxPhoto', out, () => $wire.saveBoxPhoto().then(() => { this.busy = false }), () => { this.busy = false; this.failed = true }, (ev) => { this.pct = ev.detail.progress });
                                } }">
                            <input type="file" accept="image/*" capture="environment" x-ref="file" class="hidden" x-on:change="send($event)">
                            @foreach ($shots as $shot)
                                <a href="{{ $shot->url() }}" target="_blank" class="ds-sa__shot"><img src="{{ $shot->url() }}" alt="Photo {{ $loop->iteration }}"></a>
                            @endforeach
                            <button type="button" class="ds-sa__addphoto" x-on:click="take()" x-bind:disabled="busy">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>
                                <span x-show="! busy">{{ $shots->isEmpty() ? 'Add photo · optional' : 'Add another' }}</span>
                                <span x-show="busy" x-cloak>Saving… <span x-text="pct + '%'"></span></span>
                            </button>
                            <p class="ds-sa__err" x-show="failed" x-cloak>The photo did not upload. Try again.</p>
                        </div>
                    @endif
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">Scan next box</button>
                </div>
            @elseif ($status === 'success' && $route)
                <div class="ds-sa__sheet is-ok" wire:key="placed-{{ $sessionScans }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sx__tile" style="--sx: {{ $route['color'] ?? '#1d6fb8' }}"><small>Saved in</small><strong>{{ $route['code'] }}</strong><span>{{ $route['name'] }}</span></div>
                    <p class="ds-sa__msg">{{ $message }}</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">Scan next box</button>
                </div>
            @elseif ($status === 'warning' && $wrongHub)
                <div class="ds-sa__sheet is-bad" wire:key="wronghub-{{ $sessionScans }}-{{ $wrongHub['code'] }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad">⛔</span>
                        <span><small class="ds-ld__kicker">{{ ['city' => 'Other city', 'wh' => 'Not for '.($wrongHub['trip'] ?? ''), 'full' => 'Truck full', 'hub' => 'Not for this trip'][$wrongHub['kind'] ?? ''] ?? 'Wrong hub' }}</small><strong>{{ ($wrongHub['kind'] ?? null) === 'full' ? $wrongHub['code'].' does not fit' : $wrongHub['code'].' is for '.$wrongHub['for'] }}</strong></span>
                    </div>
                    @if (($wrongHub['kind'] ?? null) === 'full')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }}. This box takes {{ $wrongHub['space'] }} space: it waits for the next {{ $wrongHub['province'] }} trip. Put it back{{ $wrongHub['section'] !== '—' ? ' in section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">It still fits · load anyway</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'wh')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }} is delivered from {{ $wrongHub['home'] }}. Not loaded: it stays here{{ $wrongHub['section'] !== '—' ? ', section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">The office says load it</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'hub')
                        <p class="ds-sa__msg">{{ $wrongHub['for'] }} goes {{ str_contains($wrongHub['home'], 'own trucks') ? 'with '.$wrongHub['home'] : 'to '.$wrongHub['home'] }}. Not loaded on {{ $wrongHub['trip'] }}: put it back{{ $wrongHub['section'] !== '—' ? ' in section '.$wrongHub['section'] : '' }}.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Deliver it on this trip anyway</button>
                    @elseif (($wrongHub['kind'] ?? null) === 'city')
                        <p class="ds-sa__msg">This trip goes to {{ $wrongHub['trip'] }}. Not loaded. Put it back in section {{ $wrongHub['section'] }}; it goes on a trip to its own city.</p>
                        <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                        <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Add it to this trip anyway</button>
                    @else
                    <p class="ds-sa__msg">This trip goes to {{ $wrongHub['trip'] }}. Not loaded. Put it back in section {{ $wrongHub['section'] }} and tell the office.</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put it back</button>
                    <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">The office says load it</button>
                    @endif
                </div>
            @elseif ($status === 'warning' && $early)
                <div class="ds-sa__sheet is-warn" wire:key="early-{{ $sessionScans }}-{{ $early['code'] }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-warn">!</span>
                        <span><small class="ds-ld__kicker">Too early</small><strong>{{ $early['code'] }} is for stop {{ $early['stop'] }}{{ $early['place'] ? ' ('.$early['place'].')' : '' }}</strong></span>
                    </div>
                    <p class="ds-sa__msg">It's delivered earlier, so it goes in later, {{ $early['zone'] === 'back' ? 'at the door' : 'in the middle' }}. Put it aside and load stop {{ $early['nextStop'] }} now.</p>
                    <button type="button" class="ds-sa__primary" wire:click="dismiss">OK, put aside</button>
                    <button type="button" class="ds-sa__secondary" wire:click="loadAnyway">Load it anyway</button>
                </div>
            @elseif ($status === 'warning')
                <div class="ds-sa__sheet is-warn" wire:key="warn-{{ $sessionScans }}-{{ md5($message) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit">
                        <span class="ds-sa__mark is-warn">!</span>
                        <span><strong>{{ $box?->invoice ?? 'Check this box' }}</strong><small>{{ $message }}</small></span>
                    </div>
                    <button type="button" class="ds-sa__secondary" wire:click="dismiss">OK, scan next</button>
                </div>
            @elseif ($status === 'danger')
                <div class="ds-sa__sheet is-bad" wire:key="bad-{{ $sessionScans }}-{{ md5($message) }}">
                    <span class="ds-sa__grab"></span>
                    <div class="ds-sa__hit is-shake">
                        <span class="ds-sa__mark is-bad"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg></span>
                        <span><strong>{{ $missing ?? $box?->invoice ?? 'Wrong box' }}</strong><small>Not on this {{ $def['kind'] }}</small></span>
                    </div>
                    <p class="ds-sa__msg">{{ $message }}</p>
                    @if ($missing && $this->mode === 'unload')
                        {{ $this->unmanifestedAction }}
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="dismiss">Keep it aside, scan next</button>
                </div>
            @endif
        </section>
    @endif

    {{-- ============================== done ============================== --}}
    @if ($screen === 'done' && $def)
        <section class="ds-sa__screen ds-sa__done" wire:key="done">
            <span class="ds-sa__ring is-big">
                <svg viewBox="0 0 110 110"><circle cx="55" cy="55" r="48" class="is-track"/><circle cx="55" cy="55" r="48" class="is-fill is-ok" style="stroke-dasharray: 302; stroke-dashoffset: {{ $ring($progress['loaded'] ?? 0, $progress['total'] ?? 0, 302) }}"/></svg>
                <span><i><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg></i></span>
            </span>
            @php($complete = ($progress['total'] ?? 0) > 0 && ($progress['loaded'] ?? 0) >= $progress['total'])
            <h2>{{ $complete ? $def['done'] : ($progress['loaded'] ?? 0).' of '.($progress['total'] ?? 0).' scanned' }}</h2>
            <p>{{ $target['name'] ?? '' }}{{ ! empty($target['sub']) ? ' · '.$target['sub'] : '' }}</p>
            <div class="ds-sa__totals">
                <span><strong>{{ $sessionScans }}</strong><small>scanned now</small></span>
                <span><strong>{{ $today['photos'] }}</strong><small>photos today</small></span>
                <span><strong class="is-bad">{{ $today['problems'] }}</strong><small>problems today</small></span>
            </div>
            <p class="ds-sa__note">{{ $complete ? 'Everything on this '.$def['kind'].' is scanned. The office sees it right away.' : 'You can come back and finish later; every scan is already saved.' }}</p>
            @if ($topUp && $topUp['room'] >= 1)
                <div class="ds-sx__topup">
                    <strong>Room for about {{ \App\Support\BoxSizes::fmt($topUp['room']) }} more on the truck</strong>
                    @forelse ($topUp['boxes'] as $tb)
                        <div class="ds-sx__toprow" wire:key="tu-{{ $tb['id'] }}">
                            <span><b>{{ $tb['invoice'] }} · {{ $tb['name'] }}</b><small>{{ $tb['place'] }}{{ $tb['section'] ? ' · section '.$tb['section'] : '' }}{{ $tb['space'] != 1 ? ' · takes '.\App\Support\BoxSizes::fmt($tb['space']) : '' }}</small></span>
                            <button type="button" wire:click="topUpAdd({{ $tb['id'] }})">Add</button>
                        </div>
                    @empty
                        <small>No waiting boxes for these provinces.</small>
                    @endforelse
                    <small>Waiting boxes for the same provinces, oldest and priority first. Add one, then scan it onto the truck.</small>
                </div>
            @endif
            @if ($receiveResult)
                <div class="ds-sx__open">
                    <strong>{{ $receiveResult['got'] }} of {{ $receiveResult['of'] }} boxes received</strong>
                    @if (count($receiveResult['missing']))
                        <span>{{ $receiveResult['of'] - $receiveResult['got'] }} not scanned:</span>
                        @foreach ($receiveResult['missing'] as $rm)
                            <span class="ds-sx__miss"><span>{{ $rm['code'] }} <small>{{ $rm['sub'] }}</small></span></span>
                        @endforeach
                        <small>Look in the truck once more. Found it? Keep scanning.</small>
                    @else
                        <span>✓ Every box arrived.</span>
                    @endif
                    @if ($receiveResult['finished'])
                        <span>✓ Receiving finished.</span>
                    @else
                        <button type="button" class="ds-sa__secondary" wire:click="finishReceiving" wire:confirm="Finish receiving? Boxes not scanned get a Missing box issue each.">Finish receiving{{ ! empty($receiveResult['next']) ? ' · pass on to '.$receiveResult['next'] : '' }}</button>
                    @endif
                </div>
            @endif
            @if ($countResult)
                <div class="ds-sx__open">
                    <strong>Section {{ $countResult['code'] }}: {{ $countResult['found'] }} found{{ $countResult['moved'] ? ' · '.$countResult['moved'].' moved in' : '' }}</strong>
                    @if (count($countResult['missing']))
                        <span>{{ count($countResult['missing']) }} missing: {{ implode(', ', array_slice($countResult['missing'], 0, 12)) }}{{ count($countResult['missing']) > 12 ? '…' : '' }}</span>
                    @else
                        <span>✓ Nothing missing.</span>
                    @endif
                    <button type="button" class="ds-sa__secondary" wire:click="closeCount" wire:confirm="Close the count of section {{ $countResult['code'] }}?">Close the count</button>
                </div>
            @endif
            @if (count($openSets))
                @if ($noReason)<p class="ds-sx__stop">⛔ Not ready to leave: {{ $noReason }} {{ $noReason === 1 ? 'customer has' : 'customers have' }} boxes left behind with no reason.</p>@endif
                <div class="ds-sx__open">
                    <strong>{{ count($openSets) }} {{ count($openSets) === 1 ? 'customer is' : 'customers are' }} missing boxes</strong>
                    @foreach ($openSets as $os)
                        <div class="ds-sx__openrow" wire:key="os-{{ $os['key'] }}">
                            <span><b>{{ $os['name'] }}</b> · {{ $os['have'] }} of {{ $os['of'] }} on the truck</span>
                            @foreach ($os['missing'] as $mb)
                                <span class="ds-sx__miss"><span>{{ $mb['invoice'] }} <small>{{ $mb['where'] }}</small></span>
                                    <span class="ds-sx__why">@foreach ($splitReasons as $rk => $rl)<button type="button" wire:click="splitReason({{ $mb['id'] }}, '{{ $rk }}')" @class(['is-on' => $mb['reason'] === $rk])>{{ $rl }}</button>@endforeach</span>
                                </span>
                            @endforeach
                        </div>
                    @endforeach
                    <small>Find the boxes, or pick why each one stays behind. The office sees it on the trip.</small>
                </div>
            @endif
            <button type="button" class="ds-sa__primary" wire:click="pick({{ $choice }})">Keep scanning</button>
            <button type="button" class="ds-sa__secondary" wire:click="home">Back to start</button>
        </section>
    @endif
</div>
<x-filament-actions::modals />
</x-filament-panels::page>
