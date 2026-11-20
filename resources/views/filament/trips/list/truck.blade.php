@php($r = $getRecord())
@php($crew = \App\Filament\Tables\TripList::crew($r))
@php($lead = $crew->first())
<div class="ds-tl__truck">
    <i>{{ $lead ? collect(explode(' ', (string) $lead->user?->full_name))->map(fn ($w) => mb_substr($w, 0, 1))->take(2)->join('') : '—' }}</i>
    <span><b>{{ $r->truck?->plate_no ?? 'No truck yet' }}</b><small>{{ $crew->isNotEmpty() ? $crew->map(fn ($c) => Str::before((string) $c->user?->full_name, ' '))->filter()->join(' · ') : 'No crew yet' }}</small></span>
</div>
