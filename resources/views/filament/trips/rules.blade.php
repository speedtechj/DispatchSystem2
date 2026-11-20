<x-filament-panels::page>
<div class="ds-fl ds-wc">
    <span class="ds-te__title"><small>Settings › Trip rules</small><h1>Trip rules and who can bypass</h1><small>Click the level of each rule. Every bypass is saved with who and why (Overrides).</small></span>
    <div class="ds-tr__grid">
        <section class="ds-cb__card ds-ad__table">
            <span class="ds-tr__row is-head"><span>Rule</span><span>Who can bypass</span></span>
            @foreach ($rules as $r)
                <span class="ds-tr__row" wire:key="r-{{ $r['key'] }}">
                    <span class="ds-ad__who"><b>{{ $r['title'] }}</b><small>{{ $r['sub'] }}</small></span>
                    <span class="ds-fl__seg">@foreach ($levels as $lk => $ll)<button type="button" wire:click="setLevel('{{ $r['key'] }}', '{{ $lk }}')" @class(['is-on' => $r['level'] === $lk])>{{ $ll }}</button>@endforeach</span>
                </span>
            @endforeach
            <small class="ds-te__hint ds-tr__note">Off: the check still shows, anyone can go on without a reason. Anyone with a reason: they pick a reason. Office only: the crew asks, the office approves in the bell or in Overrides.</small>
        </section>
        <div class="ds-ad__col">
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Reasons the crew can pick</b>
                @foreach ($reasons as $i => $r)
                    <span class="ds-tr__reason"><span>{{ $r }}</span><button type="button" class="ds-te__link is-bad" wire:click="removeReason({{ $i }})" aria-label="Remove {{ $r }}">✕</button></span>
                @endforeach
                <form wire:submit="addReason" class="ds-wc__form"><input type="text" wire:model="newReason" class="ds-te__input" placeholder="+ Add a reason"><button type="submit" class="ds-te__btn">Add</button></form>
            </section>
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Lock the trip</b>
                <span class="ds-hs__switch"><span>Lock by itself when the lead man takes the trip</span><button type="button" role="switch" aria-checked="{{ $autoLock ? 'true' : 'false' }}" wire:click="toggleAutoLock" @class(['ds-hs__sw', 'is-on' => $autoLock])><i></i></button></span>
                <span class="ds-te__hint">The office locks a trip on the Trip page. With this on, the trip also locks when the lead man taps “I take the trip” in the Driver app, if every check is green: all boxes loaded, truck here, lead man set.</span>
            </section>
            <section class="ds-cb__card ds-ad__card">
                <b class="ds-ad__h">Who is “the office”</b>
                <span class="ds-te__hint">Users who are <b>Admin</b> or <b>Super admin</b>. They get each request in the bell and approve it with one click in Overrides.</span>
            </section>
        </div>
    </div>
</div>
</x-filament-panels::page>
