<div class="ds-et__tiles">
    @foreach ($tiles as $t)
        <span class="ds-cb__card ds-et__tile is-{{ $t['tone'] }}"><small>{{ $t['l'] }}</small><b>{{ $t['v'] }}</b></span>
    @endforeach
</div>
