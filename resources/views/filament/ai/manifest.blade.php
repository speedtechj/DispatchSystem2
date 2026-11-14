<x-filament-panels::page>
<div class="ds-ai">
    @include('filament.ai.paused', ['paused' => $paused])

    @if (! $rows)
        <form wire:submit="read" class="ds-ai__card ds-ai__upload">
            <label class="ds-gm__field"><span>Container (not unloaded yet)</span>
                <select wire:model="container">
                    <option value="">Pick a container…</option>
                    @foreach ($containers as $c)
                        <option value="{{ $c->id }}">{{ $c->container_no }} · {{ $c->consolidator?->company_name }} · {{ $c->invoices()->count() }} boxes so far</option>
                    @endforeach
                </select>
            </label>
            @error('container')<p class="ds-ai__err">{{ $message }}</p>@enderror
            <label class="ds-ai__drop">
                <input type="file" wire:model="file" accept=".pdf,.xlsx,.csv,.txt,image/*">
                <b>{{ $file ? $file->getClientOriginalName() : 'Choose the manifest file' }}</b>
                <small>PDF, Excel (.xlsx), CSV, or a photo of a printed list · any layout</small>
                <span wire:loading wire:target="file">Uploading…</span>
            </label>
            @error('file')<p class="ds-ai__err">{{ $message }}</p>@enderror
            @if ($error)<p class="ds-ai__err">{{ $error }}</p>@endif
            @if ($saved !== null)<p class="ds-ai__done is-fine">{{ $saved }} boxes were added. Read another manifest, or open the container to check them.</p>@endif
            <div class="ds-ai__two">
                <x-filament::button type="submit" wire:loading.attr="disabled" wire:target="read,file">
                    <span wire:loading.remove wire:target="read">Read with AI</span>
                    <span wire:loading wire:target="read">Reading… big PDFs can take 2 or 3 minutes</span>
                </x-filament::button>
            </div>
            <p class="ds-board__muted">The AI reads the boxes, splits the addresses, fixes misspelled places and picks the route area. Nothing is saved until you check the list and press Save.</p>
        </form>
    @else
        <section class="ds-ai__card">
            <div class="ds-ai__card-head">
                <span><b>{{ $fileName }}</b> <small class="ds-board__muted">{{ $consolidator ? 'Consolidator on the file: '.$consolidator : '' }}</small></span>
                <div class="ds-ai__seg is-small">
                    <button type="button" wire:click="$set('tab', 'all')" @class(['is-on' => $tab === 'all'])>All {{ $counts['all'] }}</button>
                    <button type="button" wire:click="$set('tab', 'fixed')" @class(['is-on' => $tab === 'fixed'])>Fixed by AI {{ $counts['fixed'] }}</button>
                    <button type="button" wire:click="$set('tab', 'check')" @class(['is-on' => $tab === 'check'])>To check {{ $counts['check'] }}</button>
                </div>
            </div>
            <div class="ds-ai__table">
                <div class="ds-ai__tr is-head"><span></span><span>Box</span><span>Receiver</span><span>Address</span><span>Phone</span><span>Route</span><span>Notes</span></div>
                @foreach ($shown as $i => $r)
                    <div wire:key="r-{{ $i }}" @class(['ds-ai__tr', 'is-off' => ! $r['save'], 'is-warn' => $r['blocking']])>
                        <span><input type="checkbox" @checked($r['save']) @disabled($r['blocking']) wire:click="toggle({{ $i }})" aria-label="Save box {{ $r['invoice'] }}"></span>
                        <b>{{ $r['invoice'] ?: '—' }}</b>
                        <span>{{ $r['receiver_name'] }}<small>from {{ $r['sender_name'] ?: '—' }}</small></span>
                        <span>{{ trim($r['receiver_address'].', '.$r['receiver_barangay'].', '.$r['receiver_city'].', '.$r['receiver_province'], ', ') }}</span>
                        <span>{{ $r['receiver_mobile_no'] ?: '—' }}</span>
                        <span>{{ $r['route_code'] ?: '—' }}</span>
                        <span class="ds-ai__notes">
                            @if ($r['fixed'])<i class="ds-ai__tag is-ok">Fixed: {{ $r['fixed'] }}</i>@endif
                            @if ($r['notes'])<i class="ds-ai__tag {{ $r['blocking'] ? 'is-damaged' : 'is-open' }}">{{ $r['notes'] }}</i>@endif
                        </span>
                    </div>
                @endforeach
            </div>
            <div class="ds-ai__foot">
                <span>{{ $counts['save'] }} of {{ $counts['all'] }} boxes will be saved. Untick a row to leave it out. Rows in amber can't be saved (duplicate or missing receiver).</span>
                <x-filament::button color="gray" wire:click="startOver">Start over</x-filament::button>
                <x-filament::button wire:click="save" wire:confirm="Save {{ $counts['save'] }} boxes into this container?">Save {{ $counts['save'] }} boxes</x-filament::button>
            </div>
        </section>
    @endif
</div>
</x-filament-panels::page>
