<x-filament-panels::page>
<div class="ds-ai">
    @include('filament.ai.paused', ['paused' => $paused])
    <div class="ds-ai__split">
        <section class="ds-ai__card ds-ai__list">
            <div class="ds-ai__card-head"><b>Boxes on active trips that may fail · {{ $list->count() }}</b></div>
            @forelse ($list as $r)
                @php($b = $r['box'])
                <button type="button" wire:key="b-{{ $b->id }}" wire:click="pick({{ $b->id }})" @class(['ds-ai__row', 'is-sel' => $cur && $cur['box']->id === $b->id])>
                    <span @class(['ds-ai__score', 'is-high' => $r['risk']['score'] >= 70])>{{ $r['risk']['score'] }}%</span>
                    <span class="ds-ai__row-main">
                        <span><b>{{ $b->invoice }}</b> {{ \Illuminate\Support\Str::title((string) $b->invdata?->receiver_name) }}</span>
                        <span>{{ $r['risk']['short'] }}</span>
                        <small>Trip {{ $b->deliverylog?->trip_number }}{{ $b->deliverylog?->truck?->plate_no ? ' · '.$b->deliverylog->truck->plate_no : '' }}{{ $b->is_loaded ? ' · loaded' : '' }}</small>
                    </span>
                    <span class="ds-ai__state is-{{ $r['mark']?->status ?? 'open' }}">{{ ['texted' => 'Texted', 'removed' => 'Taken off', 'ok' => 'OK'][$r['mark']?->status] ?? 'To do' }}</span>
                </button>
            @empty
                <p class="ds-ai__empty">No risky boxes on active trips. 👍</p>
            @endforelse
        </section>

        @if ($cur)
            @php($b = $cur['box'])
            <section class="ds-ai__card ds-ai__detail" wire:key="d-{{ $b->id }}">
                <div class="ds-ai__detail-head"><b>{{ $b->invoice }} · {{ \Illuminate\Support\Str::title((string) $b->invdata?->receiver_name) }}</b><small>{{ $cur['risk']['score'] }}% chance it fails</small></div>
                <p class="ds-board__muted">{{ \Illuminate\Support\Str::title(trim($b->invdata?->receiver_address.', '.$b->invdata?->receiver_barangay.', '.$b->invdata?->receiver_city, ', ')) }} · {{ $b->invdata?->receiver_mobile_no ?: 'no phone' }}</p>
                <ul class="ds-ai__why">@foreach ($cur['risk']['reasons'] as $why)<li>{{ $why }}</li>@endforeach</ul>

                <b class="ds-ai__label">Text for the receiver</b>
                <div class="ds-ai__seg is-small">
                    @foreach (['en' => 'English', 'tl' => 'Tagalog', 'ceb' => 'Bisaya'] as $k => $l)
                        <button type="button" wire:click="$set('lang', '{{ $k }}')" @class(['is-on' => $lang === $k])>{{ $l }}</button>
                    @endforeach
                    <x-filament::button size="sm" color="gray" wire:click="write" wire:loading.attr="disabled" wire:target="write">
                        <span wire:loading.remove wire:target="write">{{ $message ? 'Write again' : 'Write with AI' }}</span><span wire:loading wire:target="write">Writing…</span>
                    </x-filament::button>
                </div>
                <textarea wire:model="message" rows="4" class="ds-ai__text" placeholder="Press “Write with AI”, or type your own text."></textarea>
                @if ($error)<p class="ds-ai__err">{{ $error }}</p>@endif
                @php($phone = preg_replace('/[^\d+]/', '', (string) $b->invdata?->receiver_mobile_no))
                <div class="ds-ai__two">
                    @if ($phone && $message)
                        <a class="ds-ai__btn is-green" href="sms:{{ $phone }}?&body={{ rawurlencode($message) }}" wire:click="markTexted">Open in Messages</a>
                    @endif
                    <x-filament::button color="gray" x-on:click="navigator.clipboard.writeText($wire.message)" wire:click="markTexted" :disabled="! $message">Copy &amp; mark texted</x-filament::button>
                </div>
                <div class="ds-ai__two">
                    <x-filament::button color="gray" outlined wire:click="markOk">It's fine</x-filament::button>
                    @unless ($b->is_loaded)
                        <x-filament::button color="danger" outlined wire:click="removeFromTrip" wire:confirm="Take box {{ $b->invoice }} off trip {{ $b->deliverylog?->trip_number }}?">Take off the trip</x-filament::button>
                    @endunless
                </div>
                <p class="ds-board__muted">The driver also sees a warning on this box in the Driver app.</p>
            </section>
        @endif
    </div>
</div>
</x-filament-panels::page>
