<x-filament-panels::page>
<div class="ds-te" x-data="{ dirty: false }" x-on:input="dirty = true" x-on:change="dirty = true">
    <div class="ds-te__top">
        <span class="ds-te__title">
            <small>@if ($fleetUrl)<a href="{{ $fleetUrl }}">Trucks</a>@else Trucks @endif @if ($t) › {{ $t->plate_no }}@endif</small>
            <h1>{{ $t ? 'Edit '.$t->plate_no : 'Add a truck' }}</h1>
        </span>
        <span class="ds-te__actions">
            <small class="ds-te__dirty" x-show="dirty" x-cloak>● Not saved yet</small>
            @if ($cancelUrl)<a href="{{ $cancelUrl }}" class="ds-te__btn">Cancel</a>@endif
            <button type="button" wire:click="save" wire:loading.attr="disabled" class="ds-te__btn is-main">
                <span wire:loading.remove wire:target="save">{{ $t ? 'Save changes' : 'Add truck' }}</span><span wire:loading wire:target="save">Saving…</span>
            </button>
        </span>
    </div>

    @if ($errors->any())
        <div class="ds-te__errors">Please fix {{ $errors->count() === 1 ? 'one thing' : $errors->count().' things' }} below.</div>
    @endif

    <div class="ds-te__grid">
        {{-- Left: live preview, photo, active --}}
        <div class="ds-te__side">
            <section class="ds-cb__card ds-te__card">
                <small class="ds-te__muted">How it shows on the Trucks page</small>
                <span class="ds-te__stage">
                    <span class="ds-te__truck" style="--bw: {{ $bw }}px; --tc: {{ $color }}" aria-hidden="true"><i class="b"></i><i class="c"></i><i class="w"></i><i class="r1"></i><i class="r2"></i></span>
                </span>
                <span class="ds-te__id">
                    <span><b @class(['ds-te__plate', 'is-empty' => blank($d['plate_no'])])>{{ filled($d['plate_no']) ? $plateSaved : 'New truck' }}</b><small class="ds-te__muted">{{ $kindLine }}</small></span>
                    <span class="ds-fl__tags">
                        <span @class(['ds-cb__pill', 'is-rent' => $rental, 'is-own' => ! $rental])>{{ $rental ? 'Rental' : 'Own' }}</span>
                        <span @class(['ds-cb__pill', 'is-muted' => $d['is_active'], 'is-bad' => ! $d['is_active']])>{{ $d['is_active'] ? 'Active' : 'Inactive' }}</span>
                    </span>
                </span>
                <span class="ds-te__facts">
                    @foreach ($facts as [$l, $v, $tone])
                        <span class="{{ $tone }}"><span>{{ $l }}</span><b>{{ $v }}</b></span>
                    @endforeach
                </span>
            </section>

            <section class="ds-cb__card ds-te__card">
                <b>Photo</b>
                <label class="ds-te__drop">
                    <input type="file" accept="image/*" wire:model="photo" class="sr-only">
                    @if ($photoUrl)
                        <img src="{{ $photoUrl }}" alt="Truck photo">
                    @else
                        <span class="ds-te__drop-icon">📷</span>
                        <span><b>Add a photo</b> or drop it here</span>
                        <small>JPG or PNG · we shrink it for you</small>
                    @endif
                    <span wire:loading wire:target="photo" class="ds-te__muted">Uploading…</span>
                </label>
                @if ($photoUrl)
                    <span class="ds-te__photo-tools">
                        <label class="ds-te__link">Change<input type="file" accept="image/*" wire:model="photo" class="sr-only"></label>
                        <button type="button" class="ds-te__link is-bad" wire:click="$set('photo', null); $set('removePhoto', true)" x-on:click="dirty = true">Remove</button>
                    </span>
                @endif
                @error('photo')<small class="ds-te__err">{{ $message }}</small>@enderror
            </section>

            <section class="ds-cb__card ds-te__card ds-te__active">
                <span><b>Active</b><small class="ds-te__muted">Off = hidden from trip lists, the AI and the crew board (repair or sold)</small></span>
                <button type="button" role="switch" aria-checked="{{ $d['is_active'] ? 'true' : 'false' }}" aria-label="Active" wire:click="toggleActive" x-on:click="dirty = true" @class(['ds-te__switch', 'is-on' => $d['is_active']])><i></i></button>
            </section>
        </div>

        {{-- Right: the form --}}
        <div class="ds-te__form">
            <section class="ds-cb__card ds-te__sec">
                <span class="ds-te__head"><b>The truck</b><small>What the crew sees on trips and in the driver app</small></span>
                <div class="ds-te__cols3">
                    <label class="ds-te__field">Plate number
                        <input type="text" wire:model.live.debounce.400ms="data.plate_no" placeholder="ABC 1234" @class(['ds-te__input', 'is-clash' => $same, 'is-free' => ! $same && strlen($plateSaved) > 3 && ! $t]) autocomplete="off">
                        @if (filled($d['plate_no']) && $plateSaved !== $d['plate_no'])<small class="ds-te__hint">Saved as <b>{{ $plateSaved }}</b> (capitals, one space)</small>@endif
                        @error('data.plate_no')<small class="ds-te__err">{{ $message }}</small>@enderror
                    </label>
                    <label class="ds-te__field">Registration no.
                        <input type="text" wire:model="data.registration_no" placeholder="From the OR/CR" class="ds-te__input" autocomplete="off">
                        @error('data.registration_no')<small class="ds-te__err">{{ $message }}</small>@enderror
                    </label>
                    <label class="ds-te__field">Hub
                        @if ($hubs)
                            <select wire:model="data.logistichub_id" class="ds-te__input">
                                <option value="">Pick a hub…</option>
                                @foreach ($hubs as $id => $name)<option value="{{ $id }}">{{ $name }}</option>@endforeach
                            </select>
                        @else
                            <span class="ds-te__input is-fixed">{{ $hubName ?? '—' }}</span>
                        @endif
                        @error('data.logistichub_id')<small class="ds-te__err">{{ $message }}</small>@enderror
                    </label>
                </div>
                @if ($same)
                    @if ($same->is_active)
                        <span class="ds-te__exists">
                            <span class="ds-te__exists-icon">⚠️</span>
                            <span><b>{{ $same->plate_no }} is already a truck{{ $same->logistichub ? ' at '.$same->logistichub->hub_name : '' }}</b><small>{{ collect([$same->category, $same->make_model, $sameStats.' '.Str::plural('trip', $sameStats)])->filter()->join(' · ') }}. You can’t save the same plate twice.</small></span>
                            @if ($sameUrl)<a href="{{ $sameUrl }}" class="ds-te__btn is-main">Open {{ $same->plate_no }} ›</a>@else<small>Ask the admin: it is in another hub.</small>@endif
                        </span>
                    @else
                        <span class="ds-te__exists is-info">
                            <span class="ds-te__exists-icon">💤</span>
                            <span><b>{{ $same->plate_no }} is already here, but inactive</b><small>Hidden since {{ $same->updated_at?->format('M j') }}. Turn it back on instead of adding it again.</small></span>
                            @if ($sameMine)
                                <button type="button" class="ds-te__btn is-main" wire:click="reactivate({{ $same->id }})">Make it active again</button>
                                @if ($sameUrl)<a href="{{ $sameUrl }}" class="ds-te__btn">Open it ›</a>@endif
                            @else<small>Ask the admin: it is in another hub.</small>@endif
                        </span>
                    @endif
                @elseif (! $t && strlen($plateSaved) > 3)
                    <span class="ds-te__okline">✓ No truck has this plate yet.</span>
                @endif
                <div class="ds-te__field">Kind
                    <span class="ds-te__kinds">
                        @foreach ($kinds as $k => [$label, $sub, $usual, $len])
                            <button type="button" wire:click="pickKind('{{ $k }}')" x-on:click="dirty = true" @class(['ds-te__kind', 'is-on' => $d['kind'] === $k]) aria-pressed="{{ $d['kind'] === $k ? 'true' : 'false' }}">
                                <span class="ds-te__mini" aria-hidden="true"><i style="width: {{ $len }}px; background: {{ ['van' => '#7a4fb0', '4w' => '#c97a00', '6w' => '#17895e', '10w' => '#1d6fb8', 'other' => '#6b7b88'][$k] }}"></i><i></i></span>
                                <b>{{ $label }}</b><small>{{ $sub }}</small>
                            </button>
                        @endforeach
                    </span>
                    @if ($d['kind'] === 'other')
                        <input type="text" wire:model.live.debounce.400ms="data.category" placeholder="e.g. Closed van, Wing van, Pickup" class="ds-te__input">
                        @error('data.category')<small class="ds-te__err">{{ $message }}</small>@enderror
                    @endif
                </div>
                <div class="ds-te__cols12">
                    <label class="ds-te__field">Make and model
                        <input type="text" wire:model.live.debounce.400ms="data.make_model" placeholder="Isuzu Elf" class="ds-te__input">
                    </label>
                    <label class="ds-te__field">Description
                        <input type="text" wire:model="data.description" placeholder="White, blue stripe…" class="ds-te__input">
                        <small class="ds-te__hint">Colour or anything that helps the crew spot it</small>
                    </label>
                </div>
            </section>

            <section class="ds-cb__card ds-te__sec">
                <span class="ds-te__head"><b>Who owns it</b><small>Rental trucks show only on the days you book them</small></span>
                <div class="ds-te__owners">
                    @foreach (['own' => ['🏠', 'Our truck', 'We pay fuel and crew. Cost per box from fuel.'], 'rental' => ['🤝', 'Rental', 'From a rental company. Pay per trip, day or km.']] as $k => [$icon, $label, $sub])
                        <button type="button" wire:click="setOwnership('{{ $k }}')" x-on:click="dirty = true" @class(['ds-te__owner', 'is-on' => $d['ownership'] === $k]) aria-pressed="{{ $d['ownership'] === $k ? 'true' : 'false' }}">
                            <span class="ds-te__owner-icon">{{ $icon }}</span>
                            <span><b>{{ $label }}</b><small>{{ $sub }}</small></span>
                            <i class="ds-te__radio"></i>
                        </button>
                    @endforeach
                </div>
                @if ($rental)
                    <div class="ds-te__cols-r">
                        <div class="ds-te__field">Rental company
                            <span class="ds-te__row">
                                <select wire:model.live="data.rental_company_id" class="ds-te__input">
                                    <option value="">Pick a company…</option>
                                    @foreach ($companies as $c)<option value="{{ $c->id }}">{{ $c->name }}{{ $c->contact_name || $c->phone ? ' · '.collect([$c->contact_name, $c->phone])->filter()->join(' · ') : '' }}</option>@endforeach
                                </select>
                                <button type="button" class="ds-te__btn" x-on:click="$refs.newco.classList.toggle('hidden')">+ New</button>
                            </span>
                            <span x-ref="newco" class="ds-te__row hidden">
                                <input type="text" wire:model="data.newCompany" placeholder="Company name" class="ds-te__input">
                                <input type="text" wire:model="data.newCompanyPhone" placeholder="Phone" class="ds-te__input">
                                <button type="button" class="ds-te__btn is-main" wire:click="addCompany" x-on:click="$refs.newco.classList.add('hidden')">Add</button>
                            </span>
                            @error('data.rental_company_id')<small class="ds-te__err">{{ $message }}</small>@enderror
                        </div>
                        <label class="ds-te__field">Rental driver
                            <input type="text" wire:model="data.rental_driver" placeholder="Their driver's name" class="ds-te__input">
                            <small class="ds-te__hint">Their driver. Our leadman rides along with the driver app.</small>
                        </label>
                    </div>
                    <div class="ds-te__field">How they charge
                        <span class="ds-te__charge">
                            <span class="ds-fl__seg">
                                @foreach ($rates as $k => [$label])
                                    <button type="button" wire:click="setRateWay('{{ $k }}')" x-on:click="dirty = true" @class(['is-on' => $d['rate_way'] === $k])>{{ $label }}</button>
                                @endforeach
                            </span>
                            <span class="ds-te__money"><span>₱</span><input type="number" min="0" step="0.01" wire:model.live.debounce.400ms="data.rate" placeholder="0"><small>{{ $rates[$d['rate_way']][1] }}</small></span>
                            <small class="ds-te__hint">{{ $rates[$d['rate_way']][2] }}</small>
                        </span>
                        @error('data.rate')<small class="ds-te__err">{{ $message }}</small>@enderror
                    </div>
                    @if ($t)
                        <span class="ds-te__booked">
                            <span>📅 Booked days: <b>{{ $booked->isNotEmpty() ? $booked->join(', ') : 'none this month' }}</b>@if ($next) · next booking {{ $next->isToday() ? 'today' : ($next->isTomorrow() ? 'tomorrow' : $next->format('M j')) }}@endif</span>
                            @if ($rentalTabUrl)<a href="{{ $rentalTabUrl }}"><b>Pick days on the Rental tab ›</b></a>@endif
                        </span>
                    @else
                        <span class="ds-te__booked"><span>📅 After you add it, book its days on the truck's Rental tab.</span></span>
                    @endif
                @endif
            </section>

            <div class="ds-te__pair">
                <section class="ds-cb__card ds-te__sec">
                    <span class="ds-te__head"><b>Papers</b><small>We remind you 30 days before it expires</small></span>
                    <div class="ds-te__cols2">
                        <label class="ds-te__field">Registered
                            <input type="date" wire:model.live="data.date_registered" class="ds-te__input">
                            @error('data.date_registered')<small class="ds-te__err">{{ $message }}</small>@enderror
                        </label>
                        <label class="ds-te__field">Expires
                            <input type="date" wire:model.live="data.date_expired" class="ds-te__input">
                            @error('data.date_expired')<small class="ds-te__err">{{ $message }}</small>@enderror
                        </label>
                    </div>
                    <span class="ds-te__note is-{{ $expNote[1] }}">{{ $expNote[0] }}</span>
                </section>
                <section class="ds-cb__card ds-te__sec">
                    <span class="ds-te__head"><b>Space</b><small>Used to plan trips and top up loads</small></span>
                    <span class="ds-te__stepper">
                        <button type="button" wire:click="stepSpace(-5)" x-on:click="dirty = true" aria-label="5 less">−</button>
                        <span><b @class(['num', 'is-empty' => ! $d['capacity']])>{{ $d['capacity'] ?: $usual }}</b><small>boxes</small></span>
                        <button type="button" wire:click="stepSpace(5)" x-on:click="dirty = true" aria-label="5 more">+</button>
                        <small class="ds-te__hint">Usual for a {{ $kindName }}: about {{ $usual }}. Empty = 50.</small>
                    </span>
                    @error('data.capacity')<small class="ds-te__err">{{ $message }}</small>@enderror
                    @if ($spaceReady)
                        <button type="button" class="ds-te__link" wire:click="$toggle('showSize')">{{ $showSize ? '− Hide cargo size' : '+ Know the cargo size? We work out the boxes for you' }}</button>
                        @if ($showSize)
                            <span class="ds-te__size">
                                <input type="number" min="1" wire:model.live.debounce.400ms="data.cargo_length_cm" placeholder="L" class="ds-te__input" aria-label="Length cm">×
                                <input type="number" min="1" wire:model.live.debounce.400ms="data.cargo_width_cm" placeholder="W" class="ds-te__input" aria-label="Width cm">×
                                <input type="number" min="1" wire:model.live.debounce.400ms="data.cargo_height_cm" placeholder="H" class="ds-te__input" aria-label="Height cm">cm · fill
                                <input type="number" min="10" max="100" wire:model.live.debounce.400ms="data.fill_pct" placeholder="85" class="ds-te__input is-pct" aria-label="Fill %">%
                            </span>
                            @if ($spaceGuess)<small class="ds-te__hint">That fits about <b>{{ $spaceGuess }}</b> normal boxes. <button type="button" class="ds-te__link" wire:click="$set('data.capacity', {{ $spaceGuess }})">Use {{ $spaceGuess }}</button></small>@endif
                        @endif
                    @endif
                </section>
            </div>

            <section class="ds-cb__card ds-te__sec">
                <span class="ds-te__head"><b>Note</b><small>Only the office sees this</small></span>
                <textarea wire:model="data.note" rows="3" placeholder="Anything the office should remember…" class="ds-te__input ds-te__text"></textarea>
            </section>
        </div>
    </div>
</div>
</x-filament-panels::page>
