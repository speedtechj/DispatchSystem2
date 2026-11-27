{{-- Part 44 (board 69): boxes that could not be delivered, so none is forgotten. --}}
<x-filament-panels::page>
    <div class="flex flex-col gap-4">
        <p class="m-0 max-w-3xl text-sm text-gray-500 dark:text-gray-400">
            Boxes that came back. The reason sets the next try: no one home → the next working day, asked for another day → the day they picked,
            wrong address, phone, refused or damaged → the office first. After {{ \App\Support\Deliveries\NextTry::MAX_TRIES }} tries the office decides.
        </p>

        <div class="flex flex-wrap gap-2" role="tablist" aria-label="Which boxes">
            @foreach ($tabs as $k => $label)
                <button type="button" role="tab" wire:click="setTab('{{ $k }}')" aria-selected="{{ $tab === $k ? 'true' : 'false' }}"
                    @class([
                        'inline-flex h-9 items-center gap-2 rounded-full px-4 text-sm font-bold transition',
                        'bg-gray-900 text-white dark:bg-white dark:text-gray-900' => $tab === $k,
                        'bg-white text-gray-800 ring-1 ring-gray-950/10 hover:bg-gray-50 dark:bg-white/5 dark:text-gray-200 dark:ring-white/10' => $tab !== $k,
                    ])>
                    {{ $label }}
                    <span @class([
                        'rounded-full px-1.5 text-xs tabular-nums',
                        'bg-amber-400 text-gray-900' => $counts[$k] > 0 && in_array($k, ['today', 'overdue', 'office'], true),
                        'bg-gray-100 text-gray-500 dark:bg-white/10 dark:text-gray-400' => ! ($counts[$k] > 0 && in_array($k, ['today', 'overdue', 'office'], true)),
                    ])>{{ $counts[$k] }}</span>
                </button>
            @endforeach
        </div>

        @if ($rows->isEmpty())
            <div class="rounded-2xl bg-white px-6 py-12 text-center ring-1 ring-gray-950/5 dark:bg-white/5 dark:ring-white/10">
                <p class="m-0 text-lg font-bold">Nothing here</p>
                <p class="m-0 mt-1 text-sm text-gray-500">{{ ['today' => 'No box is due for another try today.', 'overdue' => 'No box missed its next try.', 'hold' => 'No box waits for a later day.', 'office' => 'No box needs the office.'][$tab] }}</p>
            </div>
        @else
            <div class="overflow-x-auto rounded-2xl bg-white ring-1 ring-gray-950/5 dark:bg-white/5 dark:ring-white/10">
                <table class="w-full min-w-[56rem] text-left text-sm">
                    <thead class="text-xs text-gray-500 dark:text-gray-400">
                        <tr class="border-b border-gray-950/5 dark:border-white/10">
                            <th class="px-4 py-3 font-semibold">Box</th>
                            <th class="px-4 py-3 font-semibold">Receiver · area</th>
                            <th class="px-4 py-3 font-semibold">Tries</th>
                            <th class="px-4 py-3 font-semibold">Last reason</th>
                            <th class="px-4 py-3 font-semibold">Next try</th>
                            <th class="px-4 py-3"><span class="sr-only">Actions</span></th>
                        </tr>
                    </thead>
                    <tbody>
                        @foreach ($rows as $a)
                            @php($n = (int) ($tries[$a->invoice_id] ?? 1))
                            <tr class="border-b border-gray-950/5 align-top last:border-0 dark:border-white/5" wire:key="rd-{{ $a->id }}">
                                <td class="px-4 py-3"><b class="font-mono text-[0.95rem]">{{ $a->invoice?->invoice }}</b><br><small class="text-gray-500">Trip {{ $a->deliverylog?->trip_number ?? '—' }}</small></td>
                                <td class="px-4 py-3">
                                    <span class="font-semibold">{{ \Illuminate\Support\Str::title($a->invoice?->receiver_name) }}</span><br>
                                    <small class="text-gray-500">{{ collect([$a->invoice?->receiver_barangay, $a->invoice?->receiver_city])->filter()->map(fn ($x) => \Illuminate\Support\Str::title($x))->join(', ') }}</small>
                                    @if ($a->invoice?->receiver_mobile_no)<br><a class="text-xs font-semibold text-primary-600" href="tel:{{ preg_replace('/[^0-9+]/', '', $a->invoice->receiver_mobile_no) }}">📞 {{ $a->invoice->receiver_mobile_no }}</a>@endif
                                </td>
                                <td class="px-4 py-3">
                                    <span @class(['inline-flex rounded-full px-2 py-0.5 text-xs font-bold', 'bg-red-50 text-red-700 dark:bg-red-500/15 dark:text-red-300' => $n >= \App\Support\Deliveries\NextTry::MAX_TRIES, 'bg-amber-50 text-amber-800 dark:bg-amber-500/15 dark:text-amber-300' => $n < \App\Support\Deliveries\NextTry::MAX_TRIES])>{{ $n }} of {{ \App\Support\Deliveries\NextTry::MAX_TRIES }}</span>
                                </td>
                                <td class="px-4 py-3">
                                    <span class="font-semibold">{{ $a->reason->getLabel() }}</span><br>
                                    <small class="text-gray-500">{{ $a->created_at->format('M j, g:i A') }}{{ filled($a->user?->full_name) ? ' · '.$a->user->full_name : '' }}</small>
                                    @if ($a->note)<br><q class="text-xs italic text-gray-600 dark:text-gray-300">{{ \Illuminate\Support\Str::limit($a->note, 90) }}</q>@endif
                                </td>
                                <td class="px-4 py-3">
                                    @if ($a->needs_office || ! $a->next_try_on)
                                        <span class="inline-flex rounded-full bg-amber-400 px-2 py-0.5 text-xs font-extrabold text-gray-900">Office decides</span>
                                    @else
                                        @php($d = \Carbon\Carbon::parse($a->next_try_on))
                                        <span @class(['font-bold', 'text-red-600' => $d->lt(today()), 'text-emerald-600' => $d->isToday()])>{{ $d->isToday() ? 'Today' : $d->format('D M j') }}</span>
                                        @if ($d->lt(today()))<br><small class="text-red-600">{{ $d->diffInDays(today()) }} {{ str('day')->plural($d->diffInDays(today())) }} late</small>@endif
                                    @endif
                                </td>
                                <td class="px-4 py-3">
                                    <div class="flex flex-wrap justify-end gap-1.5" x-data="{ open: false }">
                                        <button type="button" x-on:click="open = ! open" class="h-8 rounded-lg bg-gray-900 px-3 text-xs font-bold text-white dark:bg-white dark:text-gray-900">Set next try</button>
                                        @if (! $a->needs_office)
                                            <button type="button" wire:click="toOffice({{ $a->id }})" class="h-8 rounded-lg px-3 text-xs font-bold ring-1 ring-gray-950/10 dark:ring-white/15">To office</button>
                                        @endif
                                        <button type="button" wire:click="close({{ $a->id }})" wire:confirm="Take {{ $a->invoice?->invoice }} off the redelivery list? (returned to the sender, picked up or cancelled)" class="h-8 rounded-lg px-3 text-xs font-bold text-gray-500 hover:text-red-600">Close</button>
                                        <div class="flex w-full flex-wrap justify-end gap-1.5" x-show="open" x-cloak>
                                            @foreach ($choices as $day => $label)
                                                <button type="button" wire:click="setDay({{ $a->id }}, '{{ $day }}')" x-on:click="open = false" class="h-8 rounded-full bg-gray-100 px-3 text-xs font-semibold hover:bg-amber-100 dark:bg-white/10">{{ $label }}</button>
                                            @endforeach
                                        </div>
                                    </div>
                                </td>
                            </tr>
                        @endforeach
                    </tbody>
                </table>
            </div>
        @endif
    </div>
</x-filament-panels::page>
