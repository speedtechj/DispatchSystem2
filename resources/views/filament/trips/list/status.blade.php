@php($s = \App\Filament\Tables\TripList::status($getRecord()))
<div class="ds-tl__status">
    <span class="ds-tl__pill is-{{ $s['tone'] }}">{{ $s['label'] }}</span>
    @if ($s['when'])<small>{{ $s['when'] }}</small>@endif
</div>
