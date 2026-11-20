@php($g = \App\Filament\Tables\TripList::goes($getRecord()))
<div class="ds-tl__goes">
    <span><i style="background: {{ $g['dot'] }}"></i><b>{{ $g['to'] }}</b></span>
    <small>{{ $g['cities'] }}</small>
</div>
