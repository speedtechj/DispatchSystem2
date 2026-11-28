<x-filament-panels::page>
<div class="grid items-start gap-6 text-[#0e2433] 2xl:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_minmax(0,0.9fr)] xl:grid-cols-2 dark:text-white">

    {{-- A · Boxes --}}
    <section class="flex flex-col gap-3">
        <b class="text-base">A · Boxes <span class="font-normal text-slate-500">· {{ $panelName }} · {{ $scopeName }}</span></b>
        <div class="flex flex-col gap-3 rounded-2xl bg-white p-5 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            <form wire:submit="addScan" class="flex gap-2">
                <input type="text" wire:model="scan" autofocus placeholder="Scan or type a box number, press Enter" aria-label="Box number" class="h-11 flex-1 rounded-xl border-0 bg-[#f6f8fa] px-3.5 font-mono text-[15px] ring-1 ring-slate-200 focus:ring-2 focus:ring-[#f6be00] dark:bg-white/5">
                <x-filament::button type="submit">Add</x-filament::button>
            </form>
            <form wire:submit="addFrom" class="flex flex-wrap gap-2">
                @foreach (['trip' => 'From a trip…', 'container' => 'From a container…'] as $k => $l)
                    <button type="button" wire:click="$set('fromKind', '{{ $k }}')" @class(['h-10 rounded-lg px-3 text-[13px] font-bold', 'bg-[#0e2433] text-white' => $fromKind === $k, 'bg-[#f6f8fa] ring-1 ring-slate-200 dark:bg-white/5' => $fromKind !== $k])>{{ $l }}</button>
                @endforeach
                <input type="text" wire:model="from" placeholder="{{ $fromKind === 'container' ? 'Container no.' : 'Trip no.' }}" aria-label="{{ $fromKind === 'container' ? 'Container number' : 'Trip number' }}" class="h-10 w-44 rounded-lg border-0 bg-[#f6f8fa] px-3 font-mono text-[13.5px] ring-1 ring-slate-200 dark:bg-white/5">
                <x-filament::button type="submit" color="gray" size="sm">Add its boxes</x-filament::button>
            </form>
            @if ($notice)
                <span class="rounded-lg bg-[#fff6d6] px-3 py-2 text-[13px] text-[#8a6400]">{{ $notice }}</span>
            @endif

            @forelse ($list as $loc => $rows)
                @php($g = $groups[$loc] ?? null)
                <div class="flex flex-col gap-1.5" wire:key="g-{{ $loc }}">
                    <span class="flex items-center gap-2 pt-1">
                        <span class="grid size-8 place-items-center rounded-lg bg-[#0e2433] text-[12px] font-black text-white">{{ $loc }}</span>
                        <b class="text-[14px]">{{ $g['name'] ?? $loc }}</b>
                        <small class="text-[12px] text-slate-500">{{ $rows->count() }} boxes · {{ ($g['connected'] ?? false) ? 'connector ✓' : 'no connector: left out' }}</small>
                    </span>
                    @foreach ($rows as $b)
                        <div class="flex items-center gap-3 rounded-xl bg-[#f6f8fa] px-3 py-2 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10" wire:key="b-{{ $b['id'] }}">
                            <b class="font-mono text-[14px]">{{ $b['no'] }}</b>
                            <span class="flex min-w-0 flex-1 flex-col"><small class="truncate text-[12.5px] text-slate-600">{{ $b['who'] }}</small><small class="truncate text-[11.5px] text-slate-500">Now: {{ $b['last'] }}</small></span>
                            <button type="button" wire:click="removeBox({{ $b['id'] }})" aria-label="Remove {{ $b['no'] }}" class="grid size-8 place-items-center rounded-lg text-slate-500 hover:bg-white">✕</button>
                        </div>
                    @endforeach
                </div>
            @empty
                <p class="rounded-xl bg-[#f6f8fa] px-4 py-6 text-center text-[13.5px] text-slate-500 dark:bg-white/5">No boxes yet. Scan them, type them (several with spaces), or add a whole trip or container.</p>
            @endforelse
            @if ($list->isNotEmpty())
                <button type="button" wire:click="clearBoxes" class="w-fit text-[12.5px] font-bold text-slate-500 underline">Clear the list</button>
            @endif
        </div>
    </section>

    {{-- B · Status and time --}}
    <section class="flex flex-col gap-3">
        <b class="text-base">B · Status and time</b>
        <div class="flex flex-col gap-4 rounded-2xl bg-white p-5 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            @foreach ($codes as $group => $items)
                <div class="flex flex-col gap-1.5">
                    <small class="text-[11.5px] font-extrabold text-slate-400">{{ $group }}</small>
                    <div class="flex flex-wrap gap-1.5">
                        @foreach ($items as $c)
                            <button type="button" wire:click="pickCode('{{ $c['k'] }}')" @class(['rounded-lg px-3 py-1.5 text-left text-[13px] font-bold', 'bg-[#0e2433] text-white' => $code === $c['k'], 'bg-[#f6f8fa] ring-1 ring-slate-200 dark:bg-white/5' => $code !== $c['k']])>{{ $c['t'] }}</button>
                        @endforeach
                    </div>
                </div>
            @endforeach
            @if ($places)
                <label class="flex flex-col gap-1"><b class="text-[13px]">Place (optional)</b>
                    <select wire:model.live="place" class="h-10 rounded-lg border-0 bg-[#f6f8fa] px-3 text-[13.5px] ring-1 ring-slate-200 dark:bg-white/5">
                        <option value="">Any place</option>
                        @foreach ($places as $p)<option value="{{ $p }}">{{ $p }}</option>@endforeach
                    </select></label>
            @endif
            <label class="flex flex-col gap-1"><b class="text-[13px]">When it really happened</b>
                <input type="datetime-local" wire:model="at" class="h-10 w-64 rounded-lg border-0 bg-[#f6f8fa] px-3 text-[13.5px] ring-1 ring-slate-200 dark:bg-white/5">
                <small class="text-[12px] text-slate-500">Not "now" if it was earlier.</small>
                @error('at')<small class="text-[12.5px] text-[#d64236]">{{ $message }}</small>@enderror</label>
            <label class="flex flex-col gap-1"><b class="text-[13px]">Note for the customer (optional)</b>
                <input type="text" wire:model="note" maxlength="300" placeholder="e.g. Received by family" class="h-10 rounded-lg border-0 bg-[#f6f8fa] px-3 text-[13.5px] ring-1 ring-slate-200 dark:bg-white/5">
                <small class="text-[12px] text-slate-500">Goes to their tracking page.</small></label>
            <label class="flex flex-col gap-1"><b class="text-[13px]">Why manual (staff only, required)</b>
                <input type="text" wire:model="reason" maxlength="200" placeholder="Driver phone broken, delivered on paper" class="h-10 rounded-lg border-0 bg-[#f6f8fa] px-3 text-[13.5px] ring-1 ring-slate-200 dark:bg-white/5">
                <small class="text-[12px] text-slate-500">Kept in the logs, never shown to the customer.</small>
                @error('reason')<small class="text-[12.5px] text-[#d64236]">{{ $message }}</small>@enderror</label>
        </div>
    </section>

    {{-- C · What their customers will see --}}
    <section class="flex flex-col gap-3">
        <b class="text-base">C · What their customers will see</b>
        <div class="flex flex-col gap-3 rounded-2xl bg-white p-5 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            @forelse ($groups as $loc => $g)
                <div class="flex flex-col gap-1 rounded-xl px-4 py-3 ring-1 {{ $g['connected'] ? 'bg-[#f6f8fa] ring-slate-200 dark:bg-white/5' : 'bg-slate-50 ring-slate-200 opacity-70' }}">
                    <span class="flex items-center justify-between gap-2"><b class="text-[14px]">{{ $g['name'] }}</b><small class="text-[12px] text-slate-500">{{ $g['n'] }} boxes</small></span>
                    @if ($g['connected'])
                        <span class="text-[13.5px]"><b>{{ $g['their'] }}</b></span>
                        <small class="text-[12.5px] text-slate-500">{{ $at ? \Illuminate\Support\Carbon::parse($at)->format('M j · g:i A') : '' }}{{ $note ? ' · "'.$note.'"' : '' }}</small>
                    @else
                        <small class="text-[12.5px] text-slate-500">No connector for this consolidator: left out.</small>
                    @endif
                </div>
            @empty
                <p class="text-[13px] text-slate-500">Add boxes to see what goes to each consolidator.</p>
            @endforelse
            <div class="flex flex-col gap-1 rounded-xl bg-[#f6f8fa] px-4 py-3 text-[12.5px] text-slate-600 ring-1 ring-slate-200 dark:bg-white/5">
                <b class="text-[12.5px]">Kept for staff (Dispatch, connector log, their activity_log)</b>
                <span>Manual · {{ auth()->user()?->full_name }} · {{ $panelName }}{{ $reason ? ' · "'.$reason.'"' : '' }}</span>
            </div>
            @if ($done)
                <span class="rounded-lg bg-[#17895e]/10 px-3 py-2 text-[13px] text-[#0f6e4a]">✓ {{ $done }}</span>
            @endif
            <button type="button" wire:click="send" wire:loading.attr="disabled" @disabled(! $total)
                @if ($confirm) wire:confirm="Send this status for {{ count($boxes) }} boxes? Are you sure?" @endif
                class="h-12 rounded-xl bg-[#f6be00] px-4 text-[15px] font-extrabold text-[#0a1219] disabled:opacity-40">{{ $total ? 'Put '.$total.' statuses in the Outbox' : 'Add boxes first' }}</button>
            @error('boxes')<small class="text-[12.5px] text-[#d64236]">Add at least one box.</small>@enderror
            <small class="text-[12px] text-slate-500">Who may use it: admins, and users with "Send status manually" on (Settings → Users). Never drivers.</small>
        </div>
    </section>
</div>
</x-filament-panels::page>
