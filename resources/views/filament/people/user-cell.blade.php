@php($u = $getRecord())
@php($look = \App\Support\People\People::look($u->panelcategory))
<div class="ds-us__person">
    @if ($u->profile_picture)
        <img src="{{ \Illuminate\Support\Facades\Storage::disk('public')->url($u->profile_picture) }}" alt="" class="ds-us__av">
    @else
        <span class="ds-us__av" style="background: {{ \App\Support\People\People::colour($u) }}">{{ \App\Support\People\People::initials($u) }}</span>
    @endif
    <span class="ds-us__who">
        <span><b>{{ \App\Support\People\People::name($u, true) }}</b>@if ($u->is_admin)<i class="ds-us__admin">Admin</i>@endif</span>
        <small>{{ $u->email }}</small>
    </span>
</div>
