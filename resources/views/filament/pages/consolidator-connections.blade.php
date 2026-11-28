@php
    $stCls = fn ($s) => match ($s) {
        'Online', 'Paired' => 'bg-[#17895e]/12 text-[#17895e]',
        'Paused', 'Offline' => 'bg-[#d64236]/12 text-[#d64236]',
        'Off' => 'bg-slate-200 text-slate-600',
        default => 'bg-slate-100 text-slate-500',
    };
    $evCls = [
        'hold' => ['In 10-min hold', 'bg-[#e8f1fb] text-[#2f6fb0]'], 'trip' => ['Waits for the trip to leave', 'bg-[#e8f1fb] text-[#2f6fb0]'],
        'ready' => ['Ready', 'bg-[#e8f1fb] text-[#2f6fb0]'], 'sent' => ['Sent · no answer yet', 'bg-[#fff6d6] text-[#8a6400]'],
        'saved' => ['Saved', 'bg-[#17895e]/12 text-[#17895e]'], 'skipped' => ['Skipped', 'bg-slate-100 text-slate-500'],
        'refused' => ['Refused', 'bg-[#d64236]/12 text-[#d64236]'], 'needs_mapping' => ['Needs mapping', 'bg-[#d64236]/12 text-[#d64236]'],
        'not_found' => ['Waiting · box not in their CMS', 'bg-[#fff6d6] text-[#8a6400]'], 'failed' => ['Will retry (their side)', 'bg-[#fff6d6] text-[#8a6400]'],
        'busy' => ['Will retry', 'bg-[#fff6d6] text-[#8a6400]'], 'retry' => ['Will retry', 'bg-[#fff6d6] text-[#8a6400]'],
        'cancelled' => ['Cancelled', 'bg-slate-100 text-slate-500'],
    ];
    $paired = $link?->isPaired();
@endphp
<x-filament-panels::page>
<div class="grid items-start gap-6 text-[#0e2433] xl:grid-cols-[360px_minmax(0,1fr)]">

    {{-- A · every consolidator --}}
    <section class="flex flex-col gap-3">
        <b class="text-base">A · Consolidators</b>
        @foreach ($cards as $c)
            <button type="button" wire:click="pickCon({{ $c['id'] }})" wire:key="card-{{ $c['id'] }}"
                @class(['flex flex-col gap-2 rounded-2xl bg-white p-4 text-left ring-1 dark:bg-white/5', 'ring-2 ring-[#f6be00]' => $c['id'] === $cur?->id, 'ring-slate-200 dark:ring-white/10' => $c['id'] !== $cur?->id])>
                <span class="flex items-center gap-3">
                    <span @class(['grid size-10 shrink-0 place-items-center rounded-xl text-[14px] font-black', 'bg-[#0e2433] text-white' => $c['link']?->isPaired(), 'bg-slate-100 text-slate-500' => ! $c['link']?->isPaired()])>{{ $c['code'] }}</span>
                    <span class="flex min-w-0 flex-1 flex-col"><b class="truncate text-[15px] dark:text-white">{{ $c['name'] }}</b><small class="truncate text-[12.5px] text-slate-500">{{ $c['sub'] }}</small></span>
                    <span class="shrink-0 rounded-full px-2.5 py-0.5 text-[11.5px] font-extrabold {{ $stCls($c['state']) }}">{{ $c['state'] }}</span>
                </span>
                @if ($c['link']?->isPaired())
                    <span class="grid grid-cols-4 gap-2 text-center">
                        @foreach ($c['nums'] as [$v, $t, $cls])
                            <span class="flex flex-col rounded-lg bg-[#f6f8fa] py-1.5 dark:bg-white/5"><b @class(['text-[16px] dark:text-white', 'text-[#b97412]' => $cls === 'is-warn', 'text-[#d64236]' => $cls === 'is-bad'])>{{ number_format($v) }}</b><small class="text-[11px] text-slate-500">{{ $t }}</small></span>
                        @endforeach
                    </span>
                @endif
            </button>
        @endforeach
        @if ($cards->isEmpty())
            <p class="rounded-2xl bg-white p-4 text-[13.5px] text-slate-500 ring-1 ring-slate-200">No consolidators yet. Add them in Consolidators first.</p>
        @endif

        <div class="flex flex-col gap-2 rounded-2xl bg-white p-4 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            <b class="text-[14px] dark:text-white">Rules (all consolidators)</b>
            @foreach (\App\Support\Connectors\Rules::ALL as $k => [$t, $d])
                <button type="button" wire:click="toggleRule('{{ $k }}')" wire:key="rule-{{ $k }}" role="switch" aria-checked="{{ ($rules[$k] ?? false) ? 'true' : 'false' }}"
                    class="flex items-center gap-3 rounded-xl bg-[#f6f8fa] px-3.5 py-2.5 text-left ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
                    <span class="flex flex-1 flex-col"><b class="text-[13.5px] dark:text-white">{{ $t }}</b><small class="text-[12px] text-slate-500">{{ $d }}</small></span>
                    <span @class(['relative h-6 w-11 shrink-0 rounded-full', 'bg-[#17895e]' => $rules[$k] ?? false, 'bg-slate-300' => ! ($rules[$k] ?? false)])><span @class(['absolute top-0.5 size-5 rounded-full bg-white shadow', 'left-[22px]' => $rules[$k] ?? false, 'left-0.5' => ! ($rules[$k] ?? false)])></span></span>
                </button>
            @endforeach
            <small class="text-[12px] text-slate-500">Load on truck goes when the trip leaves (the driver takes the trip), not at each scan. Remarks on their tracking page stay plain: only a note for the customer. Names, trips and reasons are kept for staff.</small>
            @unless ($scheduleOk)
                <small class="rounded-lg bg-[#fff6d6] px-3 py-2 text-[12px] text-[#8a6400]">The scheduler has not run in the last 10 minutes, so the Outbox is not sent by itself. Check the cron job (php artisan schedule:run every minute).</small>
            @endunless
        </div>
    </section>

    {{-- B · one consolidator --}}
    <section class="flex min-w-0 flex-col gap-3">
        @if ($cur)
        <b class="text-base">B · {{ $cur->company_name }} <span class="font-normal text-slate-500">· location code {{ $cur->code }}</span></b>
        <div class="flex flex-col gap-5 rounded-2xl bg-white p-6 shadow-[0_30px_60px_-34px_rgb(14_36_51/.45)] ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            <nav class="flex flex-wrap gap-2" aria-label="Connection tabs">
                @foreach (['conn' => ['Connection', null], 'map' => ['Status mapping', $needs ?: null], 'outbox' => ['Outbox', null]] as $k => [$label, $badge])
                    <button type="button" wire:click="setTab('{{ $k }}')" @class(['flex h-10 items-center gap-2 rounded-xl px-4 text-[14px] font-bold', 'bg-[#0e2433] text-white' => $tab === $k, 'bg-[#f6f8fa] text-[#0e2433] ring-1 ring-slate-200' => $tab !== $k])>
                        {{ $label }}@if ($badge)<span class="rounded-full bg-[#d64236] px-2 text-[11.5px] font-extrabold text-white">{{ $badge }}</span>@endif
                    </button>
                @endforeach
            </nav>

            {{-- ============================================================ Connection --}}
            @if ($tab === 'conn')
                <div class="grid gap-5 lg:grid-cols-2">
                    <div class="flex flex-col gap-4">
                        <label class="flex flex-col gap-1.5"><b class="text-[13.5px]">Connector address (on their server)</b>
                            <input type="url" wire:model="url" placeholder="https://connector.theircompany.com" class="h-11 rounded-xl border-0 bg-[#f6f8fa] px-3.5 font-mono text-[14px] ring-1 ring-slate-200 focus:ring-2 focus:ring-[#f6be00] dark:bg-white/5">
                            @error('url')<small class="text-[12.5px] text-[#d64236]">{{ $message }}</small>@enderror
                        </label>
                        <div class="flex flex-col gap-1.5"><b class="text-[13.5px]">How the statuses go</b>
                            <div class="grid gap-2 sm:grid-cols-2">
                                @foreach (['push' => ['Push (webhook)', 'We send at once · their connector has an HTTPS address'], 'pull' => ['Pull', 'Their connector asks every few minutes · nothing open on their server']] as $k => [$t, $d])
                                    <button type="button" wire:click="$set('mode', '{{ $k }}')" @class(['flex flex-col rounded-xl px-4 py-3 text-left ring-1', 'bg-[#fff6d6] ring-2 ring-[#f6be00]' => $mode === $k, 'bg-white ring-slate-200 dark:bg-white/5' => $mode !== $k])>
                                        <b class="text-[14px]">{{ $t }}</b><small class="text-[12px] text-slate-500">{{ $d }}</small>
                                    </button>
                                @endforeach
                            </div>
                            <small class="text-[12px] text-slate-500">The connector's own setting (CONNECTOR_MODE) decides; pairing reads it from there.</small>
                        </div>
                        <div><x-filament::button color="gray" wire:click="saveConnection">Save address</x-filament::button></div>
                    </div>

                    <div class="flex flex-col gap-3 rounded-xl bg-[#f6f8fa] p-4 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
                        <b class="text-[14px]">Pairing</b>
                        @if (! $paired)
                            <small class="text-[13px] text-slate-600">On their server: <code class="rounded bg-white px-1.5 py-0.5 dark:bg-black/30">php artisan connector:install</code>, or in the connector's Admin → Pairing and tokens → New pairing code. It shows a code, valid 10 minutes.</small>
                            <div class="flex gap-2">
                                <input type="text" wire:model="code" placeholder="K7Q-29M" maxlength="20" aria-label="Pairing code" class="h-11 w-40 rounded-xl border-0 bg-white px-3.5 font-mono text-[18px] font-black tracking-[0.2em] uppercase ring-1 ring-slate-300 focus:ring-2 focus:ring-[#f6be00] dark:bg-white/5">
                                <x-filament::button wire:click="pair" wire:loading.attr="disabled">Pair</x-filament::button>
                            </div>
                            @error('code')<small class="text-[12.5px] text-[#d64236]">{{ $message }}</small>@enderror
                        @else
                            <p class="flex items-center gap-2 text-[14px]"><span class="grid size-6 place-items-center rounded-full bg-[#17895e] text-[13px] font-black text-white">✓</span><b>Paired</b><span class="text-slate-500">· {{ $link->paired_at?->format('M j, Y g:i A') }} · token and secret exchanged by themselves (never shown)</span></p>
                            <div class="flex flex-wrap gap-2">
                                <x-filament::button color="gray" size="sm" wire:click="checkHealth">Check now</x-filament::button>
                                <x-filament::button color="gray" size="sm" wire:click="toggleOff">{{ $link->state === 'off' ? 'Start sending again' : 'Stop sending' }}</x-filament::button>
                                <x-filament::button color="danger" outlined size="sm" wire:click="revoke" wire:confirm="Revoke the pairing? Nothing more is sent until you pair again with a new code.">Revoke</x-filament::button>
                            </div>
                            <small class="text-[12px] text-slate-500">New token: make a new pairing code on their connector and press Revoke, then Pair again.</small>
                        @endif
                    </div>
                </div>

                @if ($paired)
                    @php($h = $link->health ?? [])
                    <div @class(['flex flex-col gap-3 rounded-xl p-4 ring-1', 'bg-[#fff6d6] ring-[#e7c766]' => in_array($link->state, ['offline', 'paused'], true), 'bg-[#17895e]/6 ring-[#17895e]/25' => ! in_array($link->state, ['offline', 'paused'], true)])>
                        <b class="text-[14px]">
                            @if (in_array($link->state, ['offline', 'paused'], true))
                                ⚠ {{ $link->stateLabel() }} · {{ $link->last_error }}
                            @elseif ($link->state === 'off')
                                Sending stopped by you
                            @else
                                ● Online · last seen {{ $link->last_seen_at?->diffForHumans() ?? 'never' }}
                            @endif
                        </b>
                        <div class="grid gap-3 text-[13px] sm:grid-cols-2 xl:grid-cols-4">
                            <span class="flex flex-col"><small class="text-slate-500">Connector</small><b>{{ $link->connector_name ?: '—' }} · {{ $link->version ?: '?' }}</b></span>
                            <span class="flex flex-col"><small class="text-slate-500">Their database</small><b>{{ ($h['cms']['ok'] ?? null) === true ? '✓ connected'.(filled($h['cms']['dispatch_user'] ?? null) ? ' · user "'.$h['cms']['dispatch_user'].'"' : '') : (($h['cms']['ok'] ?? null) === false ? '✗ '.($h['cms']['problem'] ?? 'not connected') : '—') }}</b></span>
                            <span class="flex flex-col"><small class="text-slate-500">Location code on their side</small><b @class(['text-[#d64236]' => filled($link->location_code) && $link->location_code !== $cur->code])>{{ $link->location_code ?: '—' }}{{ filled($link->location_code) && $link->location_code !== $cur->code ? ' ≠ '.$cur->code.' (fix it)' : '' }}</b></span>
                            <span class="flex flex-col"><small class="text-slate-500">Their statuses (Philippines, active)</small><b>{{ count($this->theirStatuses()) }} · read {{ $link->statuses_at?->diffForHumans() ?? 'never' }}</b></span>
                        </div>
                        @foreach (array_slice((array) ($h['warnings'] ?? []), 0, 4) as $w)
                            <small class="text-[12.5px] text-[#8a6400]">⚠ {{ is_array($w) ? ($w['text'] ?? json_encode($w)) : $w }}</small>
                        @endforeach
                    </div>

                    <div class="flex flex-col gap-2">
                        <b class="text-[14px]">Check one box in their CMS (reads only, writes nothing)</b>
                        <div class="flex gap-2">
                            <input type="text" wire:model="testBox" wire:keydown.enter="checkBox" placeholder="0110457" aria-label="Box number" class="h-11 w-48 rounded-xl border-0 bg-[#f6f8fa] px-3.5 font-mono text-[15px] ring-1 ring-slate-200 dark:bg-white/5">
                            <x-filament::button color="gray" wire:click="checkBox">Check</x-filament::button>
                        </div>
                        @error('testBox')<small class="text-[12.5px] text-[#d64236]">{{ $message }}</small>@enderror
                        @if ($testResult)
                            <span @class(['rounded-lg px-3 py-2 text-[13px]', 'bg-[#17895e]/10 text-[#0f6e4a]' => $testResult['ok'], 'bg-[#fff6d6] text-[#8a6400]' => ! $testResult['ok']])>{{ $testResult['ok'] ? '✓ ' : '' }}{{ $testResult['text'] }}</span>
                        @endif
                    </div>
                @endif
            @endif

            {{-- ============================================================ Status mapping (board 77) --}}
            @if ($tab === 'map')
                @if (! $link?->statuses)
                    <p class="rounded-xl bg-[#f6f8fa] p-4 text-[14px] text-slate-600">Pair first: the connector reads their own status list, then you map ours to theirs here.</p>
                @else
                    <div class="flex flex-wrap items-center gap-2">
                        <span class="rounded-full bg-[#17895e]/12 px-3 py-1 text-[12.5px] font-extrabold text-[#17895e]">{{ $nMapped }} mapped</span>
                        <span class="rounded-full bg-[#d64236]/12 px-3 py-1 text-[12.5px] font-extrabold text-[#d64236]">{{ $nEmpty }} need mapping</span>
                        <span class="rounded-full bg-slate-100 px-3 py-1 text-[12.5px] font-extrabold text-slate-500">{{ $nSkip }} not sent</span>
                        <span class="ml-auto flex flex-wrap gap-2">
                            <x-filament::button color="gray" size="sm" wire:click="refreshStatuses">↻ Read their statuses</x-filament::button>
                            <x-filament::button color="gray" size="sm" wire:click="suggestAll">✨ Suggest all empty</x-filament::button>
                            <x-filament::button color="gray" size="sm" wire:click="clearAll" wire:confirm="Clear the whole mapping? Nothing is saved until you press Save.">Clear all</x-filament::button>
                            <x-filament::button size="sm" wire:click="saveMapping">Save mapping{{ $draftChanged ? ' •' : '' }}</x-filament::button>
                        </span>
                    </div>
                    <small class="text-[12.5px] text-slate-500">1) Tap a row on the left. 2) Tap their status on the right, or a ✨ suggestion. A place row left empty uses the "any place" row. "Needs mapping": those statuses wait at the connector and nothing is lost; they go when you save.</small>

                    <div class="grid items-start gap-5 2xl:grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)]">
                        <div class="overflow-hidden rounded-xl ring-1 ring-slate-200 dark:ring-white/10">
                            <div class="grid grid-cols-[1.25fr_0.8fr_1.55fr_104px] bg-[#f6f8fa] px-4 py-2.5 text-[12px] font-bold text-slate-500 dark:bg-white/5"><span>In Dispatch System</span><span>Place</span><span>Their status</span><span></span></div>
                            <div class="max-h-[720px] overflow-y-auto">
                                @foreach ($groups as $g => $rows)
                                    <div class="border-t border-slate-100 bg-white px-4 pt-3 pb-1 text-[11.5px] font-extrabold tracking-wide text-slate-400 dark:bg-transparent">{{ $g }}</div>
                                    @foreach ($rows as $r)
                                        <button type="button" wire:click="selectRow('{{ $r['key'] }}')" wire:key="m-{{ $r['key'] }}"
                                            @class(['grid w-full grid-cols-[1.25fr_0.8fr_1.55fr_104px] items-center gap-2 border-t border-slate-100 px-4 py-2 text-left text-[13px] dark:border-white/5',
                                                'bg-[#fff6d6] ring-2 ring-inset ring-[#f6be00]' => $sel && $sel['key'] === $r['key'],
                                                'bg-[#d64236]/4' => ! ($sel && $sel['key'] === $r['key']) && ! $r['set'] && ! $r['place']])>
                                            <b>{{ $r['label'] }}</b>
                                            <span class="text-slate-500">{{ $r['place'] ?? 'any' }}</span>
                                            <span @class(['truncate', 'text-[#d64236]' => ! $r['set'] && ! $r['place'], 'text-slate-400' => ! $r['set'] && $r['place'], 'text-slate-500 line-through' => $r['skip']])>{{ $r['their'] ?? ($r['place'] ? '(same as any place)' : '— choose their status —') }}</span>
                                            <span class="flex justify-end">@if ($r['set'] || ! $r['place'])<span @class(['whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-extrabold',
                                                'bg-[#fff6d6] text-[#8a6400]' => $r['tag'] === 'Suggested',
                                                'bg-[#17895e]/12 text-[#17895e]' => $r['tag'] === 'Saved' || $r['tag'] === 'On their side',
                                                'bg-[#e8f1fb] text-[#2f6fb0]' => $r['tag'] === 'Changed',
                                                'bg-[#d64236]/12 text-[#d64236]' => $r['tag'] === 'Needs mapping',
                                                ])>{{ $r['tag'] }}</span>@endif</span>
                                        </button>
                                    @endforeach
                                @endforeach
                            </div>
                        </div>

                        <div class="flex flex-col gap-3 rounded-xl bg-[#f6f8fa] p-4 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10 2xl:sticky 2xl:top-20">
                            @if (! $sel)
                                <b class="text-[14px]">Their statuses</b>
                                <p class="text-[13px] text-slate-500">Tap a row on the left to choose their status for it.</p>
                            @else
                                <b class="text-[14px]">Choosing for: <span class="text-[#2f6fb0]">{{ $sel['label'] }}{{ $sel['place'] ? ' · '.$sel['place'] : '' }}</span></b>
                                @if ($suggest->isNotEmpty())
                                    <div class="flex flex-col gap-1.5">
                                        <small class="text-[12px] font-bold text-slate-500">✨ Suggested (names that match)</small>
                                        @foreach ($suggest as $s)
                                            <button type="button" wire:click="pickStatus({{ $s['id'] }})" class="flex items-center gap-2 rounded-lg bg-[#fff6d6] px-3 py-2 text-left text-[13px] ring-1 ring-[#e7c766]">
                                                <b class="flex-1">#{{ $s['id'] }} {{ $s['name'] }}</b><small class="font-bold text-[#8a6400]">{{ $s['pct'] }}%</small>
                                            </button>
                                        @endforeach
                                    </div>
                                @endif
                                <input type="search" wire:model.live.debounce.250ms="statusSearch" placeholder="Search their statuses" aria-label="Search their statuses" class="h-10 rounded-lg border-0 bg-white px-3 text-[13.5px] ring-1 ring-slate-200 dark:bg-white/5">
                                <div class="flex max-h-[430px] flex-col gap-1 overflow-y-auto">
                                    @foreach ($statuses as $s)
                                        @php($on = ($draft[$sel['key']]['id'] ?? null) === $s['id'])
                                        <button type="button" wire:click="pickStatus({{ $s['id'] }})" wire:key="s-{{ $s['id'] }}" @class(['flex items-center gap-2 rounded-lg px-3 py-1.5 text-left text-[13px]', 'bg-[#0e2433] text-white' => $on, 'bg-white hover:bg-[#e8f1fb] dark:bg-white/5' => ! $on])>
                                            <span class="w-10 shrink-0 font-mono text-[12px] opacity-70">#{{ $s['id'] }}</span><span class="flex-1">{{ $s['name'] }}</span>@if ($s['code'])<small class="font-mono text-[11px] opacity-60">{{ $s['code'] }}</small>@endif
                                        </button>
                                    @endforeach
                                </div>
                                <div class="flex gap-2">
                                    <x-filament::button color="gray" size="sm" wire:click="skipRow">Don't send this one</x-filament::button>
                                    <x-filament::button color="gray" size="sm" wire:click="clearRow">Clear</x-filament::button>
                                </div>
                                <small class="text-[12px] text-slate-500">Only their Philippines statuses that are on are listed. Abroad and customs stay theirs.</small>
                            @endif
                        </div>
                    </div>
                @endif
            @endif

            {{-- ============================================================ Outbox (board 79) --}}
            @if ($tab === 'outbox')
                @if (! $paired)
                    <p class="rounded-xl bg-[#f6f8fa] p-4 text-[14px] text-slate-600">Not paired yet. Statuses of {{ $cur->company_name }} are not kept until the connector is paired.</p>
                @else
                    @if ($link->state === 'paused')
                        <div class="flex flex-wrap items-center gap-3 rounded-xl bg-[#d64236]/8 px-4 py-3 ring-1 ring-[#d64236]/25">
                            <b class="text-[#a5281f]">⏸ Paused by itself</b>
                            <span class="flex-1 text-[13.5px] text-[#a5281f]">{{ \App\Support\Connectors\Rules::PAUSE_AFTER }} tries in a row failed ({{ $link->last_error }}). Nothing is lost: the statuses wait here. It tries again every {{ \App\Support\Connectors\Rules::RETRY_MINUTES }} minutes{{ $link->mailed_at ? '; the admins were emailed' : '' }}.</span>
                            <button type="button" wire:click="tryNow" class="h-9 rounded-lg bg-white px-3 text-[13px] font-bold ring-1 ring-[#d64236]/30">↻ Try now</button>
                        </div>
                    @endif
                    <div class="flex flex-wrap items-center gap-2">
                        @foreach ($filters as $f)
                            <button type="button" wire:click="setFilter('{{ $f['k'] }}')" @class(['h-9 rounded-full px-3.5 text-[13px] font-bold', 'bg-[#0e2433] text-white' => $filter === $f['k'], 'bg-[#f6f8fa] text-[#0e2433] ring-1 ring-slate-200' => $filter !== $f['k']])>{{ $f['t'] }} <span class="ml-1 opacity-70">{{ $f['n'] }}</span></button>
                        @endforeach
                        <span class="ml-auto flex flex-wrap gap-2">
                            <input type="search" wire:model.live.debounce.400ms="boxSearch" placeholder="Box number" aria-label="Find a box" class="h-9 w-36 rounded-lg border-0 bg-[#f6f8fa] px-3 text-[13px] ring-1 ring-slate-200 dark:bg-white/5">
                            <button type="button" wire:click="sendNow" wire:loading.attr="disabled" class="h-9 rounded-lg bg-[#f6be00] px-3.5 text-[13px] font-extrabold text-[#0a1219]">▶ Send now</button>
                            <button type="button" wire:click="resendFailed" class="h-9 rounded-lg bg-white px-3.5 text-[13px] font-bold ring-1 ring-slate-200 dark:bg-white/5">↻ Resend failed</button>
                        </span>
                    </div>
                    <div class="overflow-x-auto rounded-xl ring-1 ring-slate-200 dark:ring-white/10">
                        <div class="min-w-[820px]">
                            <div class="grid grid-cols-[70px_82px_1.5fr_1.15fr_1fr_1.3fr_78px] bg-[#f6f8fa] px-4 py-2.5 text-[12px] font-bold text-slate-500 dark:bg-white/5"><span>Made</span><span>Box</span><span>Status → their status</span><span>Who · where</span><span>State</span><span>Answer from the connector</span><span></span></div>
                            @forelse ($rows as $r)
                                @php([$stT, $stC] = $evCls[$r['state']] ?? [$r['state'], 'bg-slate-100 text-slate-500'])
                                @php($act = match (true) {
                                    in_array($r['state'], ['hold', 'trip', 'ready'], true) => ['Cancel', 'bg-white ring-1 ring-slate-200'],
                                    $r['state'] === 'needs_mapping' => ['Map it', 'bg-[#d64236] text-white'],
                                    $r['state'] === 'saved' && ! $r['undo'] && ! $r['undone'] => ['Undo', 'bg-white ring-1 ring-slate-200'],
                                    in_array($r['state'], ['failed', 'retry', 'busy', 'not_found', 'refused'], true) => ['Resend', 'bg-white ring-1 ring-slate-200'],
                                    default => null,
                                })
                                <div class="grid grid-cols-[70px_82px_1.5fr_1.15fr_1fr_1.3fr_78px] items-center gap-2 border-t border-slate-100 px-4 py-2.5 text-[13px] dark:border-white/5" wire:key="ev-{{ $r['id'] }}">
                                    <span class="text-slate-500">{{ $r['at']->isToday() ? $r['at']->format('g:i A') : $r['at']->format('M j g:i A') }}</span>
                                    <b class="font-mono">{{ $r['box'] }}</b>
                                    <span class="flex flex-col"><b>{{ $r['prio'] ? '⚡ ' : '' }}{{ $r['ev'] }}</b><small class="text-[12px] text-slate-500">{{ $r['their'] }}</small></span>
                                    <span class="text-slate-600">{{ $r['who'] ?: '—' }}</span>
                                    <span class="flex flex-col gap-0.5"><span class="w-fit rounded-full px-2.5 py-0.5 text-[11.5px] font-extrabold {{ $stC }}">{{ $r['undone'] ? 'Undone' : $stT }}</span>
                                        @if ($r['sends'])<small class="text-[11.5px] text-slate-500">sends {{ $r['sends']->format('g:i A') }}</small>@endif</span>
                                    <span class="line-clamp-2 text-[12.5px] text-slate-600" title="{{ $r['msg'] }}">{{ $r['msg'] ?: ($r['row'] ? 'row '.$r['row'] : '—') }}{{ $r['ms'] ? ' · '.number_format($r['ms'] / 1000, 1).' s' : '' }}</span>
                                    <span class="flex justify-end">@if ($act)<button type="button" wire:click="rowAction({{ $r['id'] }})" @if ($act[0] === 'Undo') wire:confirm="Undo this status in their CMS? The connector removes its own row and the box goes back to its last status." @endif class="h-8 rounded-lg px-2.5 text-[12px] font-bold {{ $act[1] }}">{{ $act[0] }}</button>@endif</span>
                                </div>
                            @empty
                                <p class="border-t border-slate-100 px-4 py-6 text-[13.5px] text-slate-500">Nothing here in the last 7 days.</p>
                            @endforelse
                        </div>
                    </div>
                    <small class="text-[12.5px] text-slate-500">Each status has its own ID, so sending it twice never makes two rows. Order: oldest first; with "Delivered and undo first" on, those (⚡) jump the line. Last 7 days, at most 150 rows.</small>
                @endif
            @endif
        </div>
        @endif
    </section>
</div>
</x-filament-panels::page>
