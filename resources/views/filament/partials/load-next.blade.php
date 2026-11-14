{{-- What to load next: last stops first (front, next to the cab), first stops last (at the door). --}}
@php($where = ['front' => 'deep inside, toward the cab', 'middle' => 'in the middle', 'back' => 'near the door'])
<div @class(['ds-ld__next', 'is-dark' => $dark ?? false]) wire:key="load-next-{{ $next['stop'] }}">
    <small>Load next · {{ $where[$next['zone']] ?? '' }} <b class="is-{{ $next['zone'] }}">{{ \App\Models\Maps\TripStop::ZONES[$next['zone']] ?? '' }}</b></small>
    <strong>Stop {{ $next['stop'] }}{{ $next['place'] ? ' · '.$next['place'] : '' }}</strong>
    <span>{{ $next['name'] }} · {{ count($next['boxes']) }} {{ str('box')->plural(count($next['boxes'])) }}{{ $next['boxes'] ? ' · '.collect($next['boxes'])->take(4)->join(', ').(count($next['boxes']) > 4 ? '…' : '') : '' }}</span>
    <span class="ds-ld__bar" aria-hidden="true">
        @foreach ($next['stops'] as $s)
            <i @class(['is-done' => $s['done'], 'is-now' => $s['now']]) title="Stop {{ $s['no'] }}"></i>
        @endforeach
    </span>
    <span class="ds-ld__ends"><span>cab · stop {{ $next['total'] }}</span><span>stop 1 · door</span></span>
</div>
