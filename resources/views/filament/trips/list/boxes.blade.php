@php($r = $getRecord())
@php($t = (int) ($r->boxes_total ?? 0))
@php($l = (int) ($r->boxes_loaded ?? 0))
@php($d = (int) ($r->boxes_done ?? 0))
<div class="ds-tl__boxes">
    <span class="ds-tl__bar"><i style="width: {{ $t ? round($d / $t * 100) : 0 }}%"></i><i class="is-l" style="width: {{ $t ? round(max(0, $l - $d) / $t * 100) : 0 }}%"></i></span>
    <small>{{ $t ? $d.' delivered · '.$l.' loaded · '.$t.' '.Str::plural('box', $t) : 'No boxes yet' }}</small>
</div>
