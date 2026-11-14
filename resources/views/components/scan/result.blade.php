@props([
    'invoice' => null,        // App\Models\Invoice (or anything with the same fields)
    'status' => null,         // success | warning | danger
    'title' => null,
    'meta' => [],             // extra label => value pairs
])

@php($status = $status ?: 'success')

@if ($invoice)
    <div {{ $attributes->class(['ds-result', "ds-result--{$status}"]) }}>
        <div class="ds-result__head">
            <div class="ds-result__icon">
                <x-filament::icon
                    :icon="match ($status) { 'danger' => 'heroicon-o-x-circle', 'warning' => 'heroicon-o-exclamation-triangle', default => 'heroicon-o-check-circle' }"
                    class="h-7 w-7"
                />
            </div>
            <div class="min-w-0">
                <p class="ds-result__eyebrow">{{ $title ?? 'Last scanned' }}</p>
                <p class="ds-result__invoice">{{ $invoice->invoice }}</p>
            </div>
            @if ($invoice->boxtype)
                <span class="ds-result__chip">{{ $invoice->boxtype }}</span>
            @endif
        </div>

        <dl class="ds-result__grid">
            <div>
                <dt>Receiver</dt>
                <dd class="ds-result__strong">{{ \Illuminate\Support\Str::title($invoice->receiver_name) }}</dd>
            </div>
            <div>
                <dt>Sender</dt>
                <dd>{{ \Illuminate\Support\Str::title($invoice->sender_name) }}</dd>
            </div>
            <div class="sm:col-span-2">
                <dt>Address</dt>
                <dd>
                    {{ collect([$invoice->receiver_address, $invoice->receiver_barangay, $invoice->receiver_city, $invoice->receiver_province])->filter()->map(fn ($part) => \Illuminate\Support\Str::title($part))->join(', ') }}
                </dd>
            </div>
            @if ($invoice->receiver_mobile_no)
                <div>
                    <dt>Mobile</dt>
                    <dd>{{ $invoice->receiver_mobile_no }}</dd>
                </div>
            @endif
            @foreach ($meta as $label => $value)
                @if (filled($value))
                    <div>
                        <dt>{{ $label }}</dt>
                        <dd>{{ $value }}</dd>
                    </div>
                @endif
            @endforeach
        </dl>

        {{ $slot }}
    </div>
@elseif ($title)
    <div {{ $attributes->class(['ds-result', "ds-result--{$status}", 'ds-result--compact']) }}>
        <div class="ds-result__head">
            <div class="ds-result__icon">
                <x-filament::icon
                    :icon="match ($status) { 'danger' => 'heroicon-o-x-circle', 'warning' => 'heroicon-o-exclamation-triangle', default => 'heroicon-o-check-circle' }"
                    class="h-7 w-7"
                />
            </div>
            <div class="min-w-0">
                <p class="ds-result__eyebrow">Last scan</p>
                <p class="ds-result__message">{{ $title }}</p>
            </div>
        </div>
    </div>
@endif
