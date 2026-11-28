@php
    $pill = 'w-fit rounded-full px-2.5 py-0.5 text-[11.5px] font-extrabold';
    $stCls = fn ($s) => match ($s) {
        'saved' => 'bg-[#17895e]/12 text-[#17895e]', 'hold', 'trip', 'ready' => 'bg-[#e8f1fb] text-[#2f6fb0]',
        'skipped', 'cancelled', 'undone' => 'bg-slate-100 text-slate-500', 'needs_mapping', 'refused' => 'bg-[#d64236]/12 text-[#d64236]',
        default => 'bg-[#fff6d6] text-[#8a6400]',
    };
    $stT = fn ($s) => ['saved' => 'Saved', 'hold' => 'In 10-min hold', 'trip' => 'Waits for the trip', 'ready' => 'Ready', 'skipped' => 'Skipped', 'cancelled' => 'Cancelled',
        'undone' => 'Undone', 'needs_mapping' => 'Needs mapping', 'refused' => 'Refused', 'not_found' => 'Waiting · not in their CMS', 'sent' => 'Sent',
        'failed' => 'Will retry', 'retry' => 'Will retry', 'busy' => 'Will retry'][$s] ?? $s;
@endphp
<x-filament-panels::page>
<div class="flex flex-col gap-5 text-[#0e2433] dark:text-white">
    <div class="flex flex-wrap items-end gap-3">
        <form wire:submit="findBox" class="flex gap-2">
            <label class="flex flex-col gap-1"><b class="text-[13px]">A box</b>
                <input type="text" wire:model="box" placeholder="0110457" aria-label="Box number" class="h-11 w-52 rounded-xl border-0 bg-white px-3.5 font-mono text-[15px] ring-1 ring-slate-200 dark:bg-white/5"></label>
            <x-filament::button type="submit" class="self-end">Show</x-filament::button>
        </form>
        <form wire:submit="findContainer" class="flex gap-2">
            <label class="flex flex-col gap-1"><b class="text-[13px]">A container (every box)</b>
                <input type="text" wire:model="container" placeholder="MSKU 482 7716" aria-label="Container number" class="h-11 w-56 rounded-xl border-0 bg-white px-3.5 font-mono text-[15px] ring-1 ring-slate-200 dark:bg-white/5"></label>
            <x-filament::button type="submit" color="gray" class="self-end">Show</x-filament::button>
        </form>
    </div>
    @if ($notice)<span class="rounded-lg bg-[#fff6d6] px-3 py-2 text-[13px] text-[#8a6400]">{{ $notice }}</span>@endif

    @if ($theirs)
        @php($last = collect($theirs['rows'])->first())
        <div class="flex flex-col gap-4 rounded-2xl bg-white p-6 shadow-[0_30px_60px_-34px_rgb(14_36_51/.45)] ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            <span class="flex flex-wrap items-center gap-3">
                <span class="grid size-11 place-items-center rounded-xl bg-[#0e2433] text-[14px] font-black text-white">{{ $theirs['code'] }}</span>
                <span class="flex flex-1 flex-col"><b class="text-[18px]">Box {{ $theirs['box'] }} · {{ $theirs['consolidator'] }}</b><small class="text-[12.5px] text-slate-500">{{ $theirs['receiver'] }}{{ $last ? ' · their newest: '.$last['status'].' ('.$last['date'].')' : '' }}</small></span>
                @if ($theirs['ok'] && $theirs['found'])
                    <span class="{{ $pill }} bg-[#17895e]/12 text-[#17895e]">In their CMS · {{ count($theirs['rows']) }} rows</span>
                @elseif ($theirs['ok'])
                    <span class="{{ $pill }} bg-[#fff6d6] text-[#8a6400]">Not in their CMS</span>
                @endif
            </span>
            @if ($theirs['offline'])
                <span class="rounded-xl bg-[#fff6d6] px-4 py-3 text-[13.5px] text-[#8a6400] ring-1 ring-[#f6be00]/40">Their connector is not answering ({{ $theirs['message'] }}). {{ $theirs['read_at'] ? 'Showing what it said last time, at '.$theirs['read_at'].'.' : '' }} Our statuses still wait safely in the Outbox.</span>
            @elseif (! $theirs['ok'])
                <span class="rounded-xl bg-[#f6f8fa] px-4 py-3 text-[13.5px] text-slate-600 ring-1 ring-slate-200">{{ $theirs['message'] }}</span>
            @endif
            <div class="grid gap-5 lg:grid-cols-2">
                <div class="flex flex-col gap-2">
                    <span class="flex items-center justify-between"><b class="text-[14.5px]">Their tracking ({{ $theirs['consolidator'] }} CMS)</b>
                        <small class="text-[12px] text-slate-500">{{ $theirs['read_at'] ? 'read '.$theirs['read_at'].' · ' : '' }}<button type="button" wire:click="refresh" class="font-bold text-[#0e2433] dark:text-white">↻ Refresh</button></small></span>
                    @forelse ($theirs['rows'] as $r)
                        <div @class(['flex flex-col gap-0.5 rounded-xl px-4 py-2.5 ring-1', 'bg-[#e8f1fb]/60 ring-[#2f6fb0]/20' => ($r['by'] ?? '') === 'dispatch', 'bg-white ring-slate-200 dark:bg-white/5' => ($r['by'] ?? '') !== 'dispatch', 'opacity-70' => $r['abroad'] ?? false])>
                            <span class="flex items-center justify-between gap-3"><b class="text-[14px]">{{ $r['status'] ?? '#'.$r['status_id'] }}</b><small class="text-[12px] text-slate-500">{{ $r['date'] }}</small></span>
                            <small class="text-[12.5px] text-slate-600">{{ $r['by_name'] ?? (($r['by'] ?? '') === 'dispatch' ? 'Dispatch System' : 'their staff') }}{{ filled($r['location'] ?? null) ? ' · '.$r['location'] : '' }}{{ ($r['abroad'] ?? false) ? ' · abroad' : '' }}</small>
                            @if (filled($r['remarks'] ?? null))<small class="text-[12px] italic text-slate-500">"{{ $r['remarks'] }}"</small>@endif
                        </div>
                    @empty
                        <p class="rounded-xl bg-[#f6f8fa] px-4 py-4 text-[13px] text-slate-500 dark:bg-white/5">Nothing to show.</p>
                    @endforelse
                </div>
                <div class="flex flex-col gap-2">
                    <b class="text-[14.5px]">Ours (Dispatch System)</b>
                    @forelse ($theirs['ours'] as $o)
                        <div class="flex flex-col gap-0.5 rounded-xl bg-[#f6f8fa] px-4 py-2.5 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
                            <span class="flex items-center justify-between gap-3"><b class="text-[14px]">{{ $o['t'] }}</b><small class="text-[12px] text-slate-500">{{ $o['at'] }}</small></span>
                            <small class="text-[12.5px] text-slate-600">{{ $o['who'] ?: '—' }}</small>
                            <span class="flex flex-wrap items-center gap-2"><span class="{{ $pill }} {{ $stCls($o['state']) }}">{{ $stT($o['state']) }}</span><small class="text-[11.5px] text-slate-500">{{ $o['msg'] ?: ($o['row'] ? 'row '.$o['row'] : '') }}</small></span>
                        </div>
                    @empty
                        <p class="rounded-xl bg-[#f6f8fa] px-4 py-4 text-[13px] text-slate-500 dark:bg-white/5">Nothing sent from Dispatch System for this box yet.</p>
                    @endforelse
                </div>
            </div>
            <small class="text-[12.5px] text-slate-500">Read only. Only statuses, dates, places, remarks and who updated (their switch "Share staff names" can hide the names). Blue rows were added by Dispatch System.</small>
        </div>
    @endif

    @if ($cont)
        <div class="flex flex-col gap-3 rounded-2xl bg-white p-6 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            <span class="flex flex-wrap items-center gap-3"><b class="flex-1 text-[16px]">{{ $cont['no'] }} · {{ number_format($cont['total']) }} boxes · their newest status</b><small class="text-[12px] text-slate-500">asked {{ number_format($cont['total']) }} at once · {{ $cont['took'] }} s</small></span>
            @if ($cont['message'])<span class="rounded-lg bg-[#fff6d6] px-3 py-2 text-[13px] text-[#8a6400]">{{ $cont['message'] }}</span>@endif
            @foreach ($cont['groups'] as $i => $g)
                @php($k = $g['kind'].'|'.$g['t'])
                @php($w = (int) (round($g['n'] / max(1, $cont['total']) * 20) * 5))
                <div wire:key="grp-{{ $i }}" @class(['flex flex-col gap-1.5 rounded-xl px-4 py-2.5 ring-1', 'ring-2 ring-[#0e2433]' => $open === $k, 'ring-slate-200 dark:ring-white/10' => $open !== $k])>
                    <button type="button" wire:click="openGroup(@js($k))" class="flex flex-col gap-1.5 text-left" aria-expanded="{{ $open === $k ? 'true' : 'false' }}">
                        <span class="flex w-full items-center justify-between gap-3"><b class="text-[13.5px]">{{ $g['t'] }}</b><b class="text-[14px]">{{ number_format($g['n']) }}</b></span>
                        {{-- w-[0%] w-[5%] w-[10%] w-[15%] w-[20%] w-[25%] w-[30%] w-[35%] w-[40%] w-[45%] w-[50%] w-[55%] w-[60%] w-[65%] w-[70%] w-[75%] w-[80%] w-[85%] w-[90%] w-[95%] w-[100%] --}}
                        <span class="h-2 w-full overflow-hidden rounded-full bg-slate-100 dark:bg-white/10"><span class="block h-full rounded-full w-[{{ max(5, $w) }}%] {{ match ($g['kind']) { 'status' => 'bg-[#17895e]', 'mismatch' => 'bg-[#d64236]', 'missing' => 'bg-[#e0a100]', default => 'bg-slate-400' } }}"></span></span>
                    </button>
                    @if ($open === $k)
                        <span class="flex flex-wrap gap-1.5 pt-1">
                            @foreach (array_slice($g['boxes'], 0, 200) as $b)
                                <button type="button" wire:click="showBox(@js($b))" class="rounded-md bg-[#f6f8fa] px-2 py-0.5 font-mono text-[12.5px] ring-1 ring-slate-200 hover:bg-[#e8f1fb] dark:bg-white/5">{{ $b }}</button>
                            @endforeach
                            @if (count($g['boxes']) > 200)<small class="text-[12px] text-slate-500">… and {{ count($g['boxes']) - 200 }} more</small>@endif
                        </span>
                    @endif
                </div>
            @endforeach
            <small class="text-[12.5px] text-slate-500">Click a group to see its boxes, and a box to open it. "Their staff changed it after us": their newest row was typed by their staff after the last status we saved.</small>
        </div>
    @endif
</div>
</x-filament-panels::page>
