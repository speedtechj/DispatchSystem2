<x-filament-panels::page>
<div class="ds-fl ds-tk">
    @if ($backUrl)<a href="{{ $backUrl }}" class="ds-tk__back">‹ All trucks</a>@endif
    <section class="ds-cb__card ds-tk__head">
        <span class="ds-fl__truck is-big" style="--tc: {{ $t->is_active ? $card['color'] : '#c3ccd4' }}" aria-hidden="true"><i class="b"></i><i class="c"></i><i class="w"></i><i class="r1"></i><i class="r2"></i></span>
        <span class="ds-tk__id">
            <span class="ds-tk__line">
                <b class="ds-fl__plate is-big">{{ $t->plate_no }}</b>
                @if ($tripNow)<a href="{{ $tripUrl($tripNow) }}" class="ds-cb__pill is-{{ $stage }}">{{ $card['state'] }} ›</a>@else<span class="ds-cb__pill is-{{ $card['tone'] }}">{{ $card['state'] }}</span>@endif
                <span @class(['ds-cb__pill', 'is-rent' => $card['rental'], 'is-own' => ! $card['rental']])>{{ $card['rental'] ? 'Rental' : 'Own' }}</span>
            </span>
            <small>{{ collect([$t->category ?: $t->description, $t->make_model, $t->registration_no ? 'registration '.$t->registration_no : null, $t->fuel_type])->filter()->join(' · ') }}</small>
        </span>
        @if ($editUrl)<a href="{{ $editUrl }}" class="ds-tk__btn">Edit</a>@endif
    </section>

    <div class="ds-fl__seg" role="tablist">
        @foreach (array_filter(['overview' => 'Overview', 'crew' => 'Crew', 'details' => 'Details', 'trips' => 'Trips', 'rental' => $t->isRental() ? 'Rental' : null]) as $k => $l)
            <button type="button" role="tab" aria-selected="{{ $tab === $k ? 'true' : 'false' }}" wire:click="setTab('{{ $k }}')" @class(['is-on' => $tab === $k])>{{ $l }}</button>
        @endforeach
    </div>

    @if ($tab === 'overview')
        <div class="ds-tk__tiles">
            @foreach ($tiles as [$label, $value, $sub])
                <span class="ds-cb__card"><small class="ds-cb__label">{{ $label }}</small><b class="ds-tk__big">{{ $value }}</b><small class="ds-cb__label">{{ $sub }}</small></span>
            @endforeach
        </div>
        <div class="ds-tk__two">
            <section class="ds-cb__card">
                <b>Today</b>
                @if ($tripNow)
                    <a href="{{ $tripUrl($tripNow) }}" class="ds-cb__person"><span><b>{{ $tripNow->trip_number }}{{ $tripNow->destination ? ' → '.$tripNow->destination->hub_name : '' }}</b><small>{{ $card['loadLabel'] }}</small></span><span class="ds-cb__pill is-{{ $stage }}">{{ \App\Support\TripFlow::STAGES[$stage][0] }}</span></a>
                    @if ($next)<a href="{{ $tripUrl($next) }}" class="ds-cb__next">Next trip waiting: <b>{{ $next->trip_number }}</b> · starts when {{ $tripNow->trip_number }} closes ›</a>@endif
                @else
                    <p class="ds-cb__muted">{{ $t->is_active ? 'Not on a trip.' : 'Inactive: hidden from trips.' }}</p>
                @endif
            </section>
            <section class="ds-cb__card">
                <b>Needs a look</b>
                @forelse ($look as [$tone, $text])
                    <span class="ds-fl__note is-{{ $tone }}">{{ $text }}</span>
                @empty
                    <p class="ds-cb__muted">✓ Nothing right now.</p>
                @endforelse
            </section>
        </div>
    @elseif ($tab === 'crew')
        <section class="ds-cb__card ds-tk__narrow">
            <header><b>Truck team</b><small class="ds-cb__label">Copied onto each new trip</small></header>
            @forelse ($crew as $c)
                <span @class(['ds-cb__person', 'is-inactive' => ! $c->member->is_active]) wire:key="c-{{ $c->crew }}">
                    <span><b>{{ $c->member->full_name }}</b><small>{{ $c->member->workposition?->position_description ?? 'Crew' }}{{ $c->member->is_active ? '' : ' · inactive' }}</small></span>
                    <button type="button" wire:click="removeCrew({{ $c->crew }})" aria-label="Take {{ $c->member->full_name }} off">✕</button>
                </span>
            @empty
                <p class="ds-cb__none">No crew on this truck.</p>
            @endforelse
            @if ($addable)
                <select class="ds-cb__add" wire:change="addCrew($event.target.value)" aria-label="Add someone">
                    <option value="">+ Add someone… (active crew only)</option>
                    @foreach ($addable as $uid => $name)<option value="{{ $uid }}">{{ $name }}</option>@endforeach
                </select>
            @endif
        </section>
    @elseif ($tab === 'details')
        <section class="ds-cb__card ds-tk__details">
            @foreach ([
                'Plate' => $t->plate_no, 'Registration no.' => $t->registration_no, 'Registration expires' => $t->date_expired?->format('M j, Y'),
                'Kind' => $t->category ?: $t->description, 'Make and model' => $t->make_model, 'Fuel' => $t->fuel_type,
                'Cargo inside (cm)' => $t->cargo_length_cm ? $t->cargo_length_cm.' × '.$t->cargo_width_cm.' × '.$t->cargo_height_cm : null,
                'Fill %' => $t->fill_pct ? $t->fill_pct.'%' : null, 'Space' => 'about '.\App\Support\TruckSpace::usable($t).' boxes',
            ] as $label => $value)
                <span class="ds-tk__field"><small>{{ $label }}</small><b>{{ $value ?: '—' }}</b></span>
            @endforeach
            <span class="ds-tk__row"><span><b>Who owns it</b><small>{{ $t->isRental() ? 'Rental · '.($t->rentalCompany?->name ?? '—').($rateText ? ' · '.$rateText : '') : 'Own truck' }}</small></span>@if ($editUrl)<a href="{{ $editUrl }}" class="ds-tk__btn">Edit</a>@endif</span>
            <span class="ds-tk__row"><span><b>Active</b><small>Off = hidden from trip lists, the AI and the crew board (for repair or sold)</small></span>
                <button type="button" role="switch" aria-checked="{{ $t->is_active ? 'true' : 'false' }}" wire:click="toggleActive" @class(['ds-tk__switch', 'is-on' => $t->is_active])><i></i></button></span>
        </section>
    @elseif ($tab === 'trips')
        <section class="ds-cb__card ds-tk__table">
            <span class="ds-tk__tr is-head"><span>Date</span><span>Trip</span><span>Crew</span><span>Boxes</span><span>Result</span></span>
            @forelse ($history as $h)
                <a href="{{ $h['url'] }}" class="ds-tk__tr"><span>{{ $h['date'] }}</span><b>{{ $h['trip']->trip_number }}{{ $h['trip']->destination ? ' → '.$h['trip']->destination->hub_name : '' }}</b><span>{{ $h['crew'] }}</span><span>{{ $h['boxes'] }}</span><span @class(['is-ok' => $h['ok']])>{{ $h['result'] }}{{ $h['cost'] ? ' · ₱'.number_format($h['cost']) : '' }}</span></a>
            @empty
                <p class="ds-cb__muted">No trips yet.</p>
            @endforelse
        </section>
    @elseif ($tab === 'rental')
        <div class="ds-tk__two">
            <section class="ds-cb__card">
                <b>Rental</b>
                <span class="ds-tk__field"><small>Company</small><b>{{ $t->rentalCompany?->name ?? '—' }}{{ $t->rentalCompany?->phone ? ' · '.$t->rentalCompany->phone : '' }}</b></span>
                <span class="ds-tk__field"><small>How they charge</small><b>{{ $rateText ?: '—' }}</b></span>
                <span class="ds-tk__field"><small>Rental driver</small><b>{{ $t->rental_driver ?: '—' }}</b></span>
                <small class="ds-cb__label">Our leadman rides along and uses the driver app. Change these with Edit.</small>
            </section>
            <section class="ds-cb__card">
                <header><b>Booked days</b><span class="ds-tk__month"><button type="button" wire:click="shiftMonth(-1)" aria-label="Previous month">‹</button>{{ $monthDate->format('F Y') }}<button type="button" wire:click="shiftMonth(1)" aria-label="Next month">›</button></span></header>
                <span class="ds-tk__cal">
                    @foreach (['M', 'T', 'W', 'T', 'F', 'S', 'S'] as $d)<small>{{ $d }}</small>@endforeach
                    @for ($i = 1; $i < $monthDate->dayOfWeekIso; $i++)<span></span>@endfor
                    @for ($d = $monthDate->copy(); $d->month === $monthDate->month; $d->addDay())
                        <button type="button" wire:click="toggleDay('{{ $d->toDateString() }}')" @class(['is-on' => in_array($d->toDateString(), $booked, true), 'is-today' => $d->isToday()])>{{ $d->day }}</button>
                    @endfor
                </span>
                <small class="ds-cb__label">Click a day to book or free it. On days not booked, this truck does not show in trip lists, the AI or the crew board.</small>
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
