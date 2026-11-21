@php($k = \App\Filament\Tables\TripList::madeKey($trip))
@php($st = \App\Filament\Tables\TripList::status($trip))
@php($g = \App\Filament\Tables\TripList::goes($trip))
@php($crew = \App\Filament\Tables\TripList::crew($trip))
@php($rows = \App\Support\TripFlow::boxes($trip))
@php($total = (clone $rows)->count())
@php($loaded = (clone $rows)->where(fn ($q) => $q->where('is_loaded', true)->orWhere('is_loaded_hub', true))->count())
@php($done = (clone $rows)->where('is_delivered', true)->count())
@php($page = collect(\Filament\Facades\Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => is_subclass_of($p, \App\Filament\Shared\Trips\TripPage::class)))
<div class="ds-tl__det">
    <span class="ds-tl__detpills"><span class="ds-tl__pill is-{{ $st['tone'] }}">{{ $st['label'] }}</span><span class="ds-tl__made is-{{ $k }}">{{ \App\Filament\Tables\TripList::MADE[$k][0] }}</span></span>
    <div @class(['ds-tl__how', 'is-manual' => $k === 'manual'])>
        <b>How this trip was made</b>
        @foreach (\App\Filament\Tables\TripList::how($trip) as [$i, $t])<span><em>{{ $i }}</em><span>{{ $t }}</span></span>@endforeach
    </div>
    <div class="ds-tl__facts">
        @foreach ([
            'Made by' => ($trip->user?->first_name ?? '—').' · '.($trip->created_at?->format('M j g:i A') ?? ''),
            'Going to' => $g['to'],
            'Truck' => $trip->truck?->plate_no ?? 'No truck yet',
            'Crew' => $crew->isNotEmpty() ? $crew->map(fn ($c) => Str::before((string) $c->user?->full_name, ' '))->filter()->join(' · ') : 'No crew yet',
            'Boxes' => $total.' · '.$loaded.' loaded',
            'Delivered' => $done.' of '.$total,
            'When' => $st['when'] ?: '—',
            'Waybill' => $trip->waybill_number ?: '—',
        ] as $label => $value)
            <span><small>{{ $label }}</small><b>{{ $value }}</b></span>
        @endforeach
    </div>
    @if ($names = \App\Filament\Tables\TripList::cityNames($trip))
        <div class="ds-tl__cities"><b>Cities and municipalities</b><ul>@foreach ($names as $c)<li>{{ $c }}</li>@endforeach</ul></div>
    @endif
    <span class="ds-tl__btns">
        @if ($page)<x-filament::button tag="a" :href="$page::getUrl(['trip' => $trip->id])" icon="heroicon-m-arrow-top-right-on-square">Open the trip</x-filament::button>@endif
        @php($stops = collect(\Filament\Facades\Filament::getCurrentPanel()?->getPages() ?? [])->first(fn ($p) => class_basename($p) === 'TripStops'))
        @if ($stops)<x-filament::button tag="a" color="gray" :href="$stops::getUrl(['trip' => $trip->id])" icon="heroicon-m-map">Stops & loading</x-filament::button>@endif
        @if (! empty($editUrl))<x-filament::button tag="a" color="gray" :href="$editUrl" icon="heroicon-m-pencil-square">Boxes and edit</x-filament::button>@endif
    </span>
    <small class="ds-tl__hint">Lock, crew, release and edit are on the trip’s page.</small>
</div>
