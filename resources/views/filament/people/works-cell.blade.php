@php($u = $getRecord())
@php($look = \App\Support\People\People::look($u->panelcategory))
<div class="ds-us__works">
    <span class="ds-us__chip" style="background: {{ $look['bg'] }}; color: {{ $look['fg'] }}">{{ $look['label'] }}</span>
    <small>{{ $u->workposition?->position_description ?? '—' }}@if ($u->is_crew) · crew @endif</small>
</div>
