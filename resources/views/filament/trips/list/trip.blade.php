@php($r = $getRecord())
@php($k = \App\Filament\Tables\TripList::madeKey($r))
@php($page = collect(\Filament\Facades\Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => is_subclass_of($p, \App\Filament\Shared\Trips\TripPage::class)))
<div class="ds-tl__trip">
    @if ($page)<a href="{{ $page::getUrl(['trip' => $r->id]) }}" x-on:click.stop class="ds-tl__no" title="Open the trip">{{ $r->trip_number }}</a>@else<b>{{ $r->trip_number }}</b>@endif
    <span class="ds-tl__made is-{{ $k }}">{{ \App\Filament\Tables\TripList::MADE[$k][0] }}</span>
    <small>{{ $r->user?->first_name ?? '—' }} · {{ $r->created_at?->isToday() ? $r->created_at->format('g:i A') : $r->created_at?->format('M j') }}</small>
</div>
