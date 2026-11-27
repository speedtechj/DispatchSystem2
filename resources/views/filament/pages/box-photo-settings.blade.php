<x-filament-panels::page>
    <form wire:submit="save" class="ds-tp ds-gm">
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Where staff can add photos</h2><span>photos so far</span></div>
            @foreach ($steps as $key => $label)
                <label class="ds-gm__check ds-ps__row" wire:key="pl-{{ $key }}">
                    <input type="checkbox" wire:model="places.{{ $key }}">
                    <span><b>{{ $label }}</b></span>
                    <small class="ds-board__muted">{{ number_format($byStep[$key] ?? 0) }}</small>
                </label>
            @endforeach
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Reminders and storage</h2></div>
            <div class="ds-gm__grid">
                <label class="ds-gm__field"><span>Batch photo reminder every … boxes (0 = off)</span><input type="number" min="0" wire:model="batchEvery"></label>
                <label class="ds-gm__field"><span>Keep photos for … months (0 = keep forever)</span><input type="number" min="0" wire:model="keepMonths"></label>
                <label class="ds-gm__field"><span>Scan app: use the photo by itself after … seconds (0 = wait for Use photo)</span><input type="number" min="0" max="10" wire:model="autoUse"></label>
            </div>
            <p class="ds-board__muted">Used now: {{ number_format($count) }} photos · {{ number_format($bytes / 1048576, 1) }} MB. Photos are made smaller (about 200 KB) before upload. Photos of a box with an open Invoice Issue are never deleted.</p>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Who sees the photos</h2></div>
            <p>Admin and warehouse staff: all photos. Partner hubs: photos of boxes sent to their hub, and photos they took.</p>
        </section>

        <div class="ds-gm__save"><x-filament::button type="submit">Save</x-filament::button></div>
    </form>
</x-filament-panels::page>
