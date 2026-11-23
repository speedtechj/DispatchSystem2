@php($u = $getRecord())
<span @class(['ds-us__status', 'is-off' => ! $u->is_active])><i></i>{{ $u->is_active ? 'Active' : 'Turned off' }}</span>
