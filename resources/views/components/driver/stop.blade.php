{{-- One stop: receiver, address, box count and a big call button. --}}
@props(['stop', 'tone' => 'plain', 'label' => null])

<div {{ $attributes->class(['ds-stop', "ds-stop--{$tone}"]) }}>
    <div class="ds-stop__text">
        @if ($label)
            <span class="ds-stop__label">{{ $label }}</span>
        @endif
        <span class="ds-stop__invoice">{{ $stop['invoices'] ?? $stop['invoice'] }}</span>
        <span class="ds-stop__name">{{ $stop['name'] }}</span>
        @if ($stop['address'])
            <span class="ds-stop__address">{{ $stop['address'] }}</span>
        @endif
        @if (($stop['count'] ?? 1) > 1)
            <span class="ds-stop__count">{{ $stop['count'] }} boxes — same household</span>
        @endif
        {{ $slot }}
    </div>
    @if ($stop['tel'])
        <a href="{{ $stop['tel'] }}" class="ds-stop__call" aria-label="Call {{ $stop['name'] }}">
            <x-filament::icon icon="heroicon-o-phone" class="h-5 w-5" />
        </a>
    @endif
</div>
