{{-- Board 58: two boxes with the scanned number still to do. Pick the receiver on the sticker. --}}
@php($opts = $which['options'] ?? [])
@if ($phone ?? false)
    <div class="ds-sa__sheet ds-which" wire:key="which-{{ $which['code'] }}-{{ count($opts) }}">
        <span class="ds-sa__grab"></span>
        <div class="ds-which__head"><span>{{ count($opts) }}</span><span><strong>{{ count($opts) }} boxes have number {{ $which['code'] }}</strong><small>Which one? Look at the receiver on the sticker.</small></span></div>
        @foreach ($opts as $w)
            <button type="button" class="ds-which__opt" wire:click="{{ $choose }}({{ $w['id'] }})" wire:key="wo-{{ $w['id'] }}">
                <span><strong>{{ $w['name'] }}</strong>@if ($w['place'])<small>{{ $w['place'] }}</small>@endif @if ($w['sender'])<em>from {{ $w['sender'] }}</em>@endif</span><b>›</b>
            </button>
        @endforeach
        <button type="button" class="ds-sa__secondary" wire:click="{{ $cancel }}">Not this box · scan again</button>
    </div>
@else
    <div class="ds-which-desk" wire:key="which-{{ $which['code'] }}-{{ count($opts) }}"
        x-data x-on:keydown.window="if (['INPUT', 'TEXTAREA', 'SELECT'].includes($event.target.tagName)) return; const n = parseInt($event.key); const o = @js(array_column($opts, 'id')); if (n >= 1 && n <= o.length) { $wire.{{ $choose }}(o[n - 1]); } else if ($event.key === 'Escape') { $wire.{{ $cancel }}(); }">
        <div class="ds-which-desk__head"><span>{{ count($opts) }}</span><span><strong>{{ count($opts) }} boxes have number {{ $which['code'] }} · Which one?</strong><small>Look at the receiver on the sticker.</small></span></div>
        <div class="ds-which-desk__grid">
            @foreach ($opts as $i => $w)
                <button type="button" class="ds-which-desk__opt" wire:click="{{ $choose }}({{ $w['id'] }})" wire:key="wd-{{ $w['id'] }}">
                    <kbd>{{ $i + 1 }}</kbd><strong>{{ $w['name'] }}</strong>@if ($w['place'])<small>{{ $w['place'] }}</small>@endif @if ($w['sender'])<em>from {{ $w['sender'] }}</em>@endif
                </button>
            @endforeach
        </div>
        <small class="ds-which-desk__hint">Click the name, or press {{ count($opts) > 2 ? '1 to '.count($opts) : '1 or 2' }} on the keyboard. Esc: not this box.</small>
    </div>
@endif
