{{-- Who can use AI (board 48) --}}
@php($picked = $access['mode'] === 'picked')
@php($byId = $users->keyBy('id'))
<div class="ds-aa">
    <div class="ds-aa__main">
        <section class="ds-board__panel ds-aa__card">
            <span class="ds-aa__h"><b>Who can use AI · for all helpers</b><small>A helper can still have its own list below. People not picked see the page without its AI parts.</small></span>
            <span class="ds-aa__modes">
                <button type="button" wire:click="setMode('all')" @class(['is-on' => ! $picked])><b>Everyone</b><small>every user with the page</small></button>
                <button type="button" wire:click="setMode('picked')" @class(['is-on' => $picked])><b>Picked people only</b><small>choose users or positions</small></button>
            </span>
            @if ($picked)
                <span class="ds-aa__chips">
                    @forelse ($accessUsers as $id)
                        @php($u = $byId[$id] ?? null)
                        @if ($u)<span class="ds-aa__chip">{{ $who($u) }} <small>{{ $role($u) }}</small><button type="button" wire:click="removeUser({{ $id }})" aria-label="Remove {{ $who($u) }}">✕</button></span>@endif
                    @empty
                        <small class="ds-aa__warn">Nobody picked yet: no one can use the AI helpers that follow this list.</small>
                    @endforelse
                </span>
                <span class="ds-aa__add">
                    <small>Add people · pick a name, or add a whole position or panel</small>
                    <select class="ds-aa__sel" x-data x-on:change="$wire.addUser(Number($event.target.value)); $event.target.value = ''">
                        <option value="">+ Add a person…</option>
                        @foreach ($users->reject(fn ($u) => in_array($u->id, $accessUsers, true)) as $u)<option value="{{ $u->id }}">{{ $who($u) }} · {{ $role($u) }}</option>@endforeach
                    </select>
                    <span class="ds-aa__groups">@foreach ($groups as $g)<button type="button" wire:click="addGroup('{{ $g['key'] }}')">+ {{ $g['name'] }}</button>@endforeach</span>
                </span>
            @endif
        </section>

        <section class="ds-board__panel ds-aa__list">
            <div class="ds-aa__row ds-aa__head"><span>AI helper</span><span>Where</span><span>Who can use it</span></div>
            @foreach ($features as $key => [$title, $text, $where])
                @php($o = $access['over'][$key] ?? null)
                @php($mode = $o === 'all' ? 'all' : (is_array($o) ? 'own' : 'same'))
                <div class="ds-aa__row" wire:key="aa-{{ $key }}">
                    <span class="ds-aa__f"><b>{{ $title }}</b>@if (in_array($key, $auto, true))<small>Runs by itself for the whole company</small>@endif</span>
                    <small class="ds-aa__where">{{ $where }}</small>
                    <span class="ds-aa__who">
                        @if (in_array($key, $auto, true))
                            <span class="ds-aa__fixed">Everyone (runs by itself)</span>
                        @else
                            <select wire:change="setWho('{{ $key }}', $event.target.value)" @class(['ds-aa__sel', 'is-'.$mode])>
                                <option value="same" @selected($mode === 'same')>Same as above{{ $picked ? ' · '.count($accessUsers).' people' : ' · everyone' }}</option>
                                <option value="all" @selected($mode === 'all')>Everyone</option>
                                <option value="own" @selected($mode === 'own')>Own list</option>
                            </select>
                            @if ($mode === 'own')
                                <span class="ds-aa__chips is-small">
                                    @foreach ($o as $id)@if ($u = $byId[$id] ?? null)<span class="ds-aa__chip">{{ $who($u) }}<button type="button" wire:click="removeUser({{ $id }}, '{{ $key }}')" aria-label="Remove">✕</button></span>@endif @endforeach
                                    <select class="ds-aa__sel is-mini" x-data x-on:change="$wire.addUser(Number($event.target.value), '{{ $key }}'); $event.target.value = ''"><option value="">+ add</option>@foreach ($users->reject(fn ($u) => in_array($u->id, $o, true)) as $u)<option value="{{ $u->id }}">{{ $who($u) }}</option>@endforeach</select>
                                </span>
                            @endif
                        @endif
                    </span>
                </div>
            @endforeach
        </section>
        <div class="ds-ai-set__save"><x-filament::button type="button" wire:click="saveAccess">Save who can use AI</x-filament::button></div>
    </div>

    <aside class="ds-aa__side">
        <section class="ds-board__panel ds-aa__card">
            <b>Preview · what this person sees</b>
            <select class="ds-aa__sel" wire:model.live="previewUser">@foreach ($users as $u)<option value="{{ $u->id }}">{{ $who($u) }} · {{ $role($u) }}</option>@endforeach</select>
            @if ($prev)
                @php($n = collect($features)->keys()->filter(fn ($k) => $can($k, $prev))->count())
                @php($trips = $can('trips', $prev))
                <span @class(['ds-aa__verdict', 'is-ok' => $trips])>{{ $who($prev) }}{{ $role($prev) ? ' ('.$role($prev).')' : '' }} can use {{ $n }} of {{ count($features) }} AI helpers.{{ $trips ? '' : ' No AI in Plan trips.' }}</span>
                <span class="ds-aa__h"><b>Plan trips</b></span>
                @if ($trips)
                    <span class="ds-aa__prev is-ai"><small><b>✦ What matters today?</b></small><span>Oldest boxes first · Tarlac first · Keep a truck free</span><em>Or type it: “Tarlac first, keep one truck”</em></span>
                @else
                    <span class="ds-aa__prev">No AI box: the trips are planned with the system rules (oldest boxes first). Create this trip and Create all work as usual.</span>
                @endif
                <span class="ds-aa__h"><b>Other pages</b></span>
                @foreach (['ask' => 'Ask the system', 'manifest' => 'Read a manifest (Containers)', 'risky' => 'Risky deliveries', 'insights' => 'Insights', 'help_ask' => 'Help answers'] as $k => $l)
                    <span class="ds-aa__spot"><span>{{ $l }}</span><b @class(['is-ok' => $can($k, $prev)])>{{ $can($k, $prev) ? 'Shown' : 'Hidden' }}</b></span>
                @endforeach
            @endif
            <small class="ds-board__muted">The preview uses the choices on this page, before you save.</small>
        </section>
        <small class="ds-board__muted">Alerts, AI photo check, address cleaning and the customer chat run for the whole company. Turning a helper off in AI helpers still turns it off for everyone.</small>
    </aside>
</div>
