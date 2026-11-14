<x-filament-panels::page>
    <form wire:submit="save" class="ds-board__panel" style="max-width: 36rem">
        <div class="ds-board__panel-head"><h2>Bulk print of receipts</h2></div>
        <label class="ds-gm__field">
            <span>Most receipts in one print (1–100)</span>
            <input type="number" min="1" max="100" step="1" wire:model="bulkLimit">
        </label>
        @error('bulkLimit')<p class="ds-ai__err">{{ $message }}</p>@enderror
        <p class="ds-board__muted">Used by <b>Print selected</b> in Delivery Log, Warehouse Delivery and the partner hubs' Delivery Log. Each receipt is about 2 pages; 15 is a good number for most printers. Bigger numbers take longer to open.</p>
        <div><x-filament::button type="submit">Save</x-filament::button></div>
    </form>
</x-filament-panels::page>
