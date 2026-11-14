{{-- Delivery history for one box (newest first): failed attempts and undone deliveries. --}}
<ol class="ds-attempts">
    @foreach ($attempts as $attempt)
        @php($isUndo = $attempt instanceof \App\Models\DeliveryReversal)
        <li @class(['ds-attempts__item', 'ds-attempts__item--undo' => $isUndo])>
            <div class="ds-attempts__head">
                @if ($isUndo)
                    <x-filament::badge color="warning" icon="heroicon-m-arrow-uturn-left">
                        Delivery undone · {{ $attempt->reason->getLabel() }}
                    </x-filament::badge>
                @else
                    <x-filament::badge :color="$attempt->reason->getColor()" :icon="$attempt->reason->getIcon()">
                        {{ $attempt->reason->getLabel() }}
                    </x-filament::badge>
                @endif
                <span class="ds-attempts__when">{{ $attempt->created_at->format('M j, Y · g:i A') }}</span>
            </div>

            <p class="ds-attempts__who">
                @if ($isUndo)
                    Undone by {{ $attempt->user?->full_name }} {{ $attempt->by_office ? '(office)' : '(driver)' }}
                    @if ($attempt->delivered_at)
                        · was marked delivered {{ $attempt->delivered_at->format('M j, g:i A') }}
                        @if ($attempt->deliverer) by {{ $attempt->deliverer->full_name }} @endif
                    @endif
                @else
                    {{ $attempt->user?->full_name }}
                @endif
                @if ($attempt->deliverylog)
                    · Trip {{ $attempt->deliverylog->trip_number }}
                @endif
            </p>

            @if ($attempt->note)
                <p class="ds-attempts__note">“{{ $attempt->note }}”</p>
            @endif

            @if ($attempt->photos)
                <div class="ds-attempts__photos">
                    @foreach ($attempt->photos as $photo)
                        <a href="{{ Storage::disk('public')->url($photo) }}" target="_blank" rel="noopener">
                            <img src="{{ Storage::disk('public')->url($photo) }}" alt="Photo from this delivery">
                        </a>
                    @endforeach
                </div>
            @endif
        </li>
    @endforeach
</ol>
