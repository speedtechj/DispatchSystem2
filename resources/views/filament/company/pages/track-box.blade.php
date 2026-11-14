<x-filament-panels::page>
    <div class="ds-co">
        @if ($code !== '')
            <p class="ds-board__muted">Showing <strong>{{ $code }}</strong>. Scan or type another number below.</p>
        @endif
        <x-barcode-scanner method="scanCode" />

        @if ($code !== '' && ! $result)
            <div class="ds-co__empty">
                <x-filament::icon icon="heroicon-o-question-mark-circle" class="h-8 w-8" />
                <strong>{{ $code }} is not one of your hub's boxes</strong>
                <span>Check the number, or ask the main hub where it is.</span>
            </div>
        @elseif ($result)
            <div class="ds-co__track">
                <section class="ds-board__panel">
                    <h2 class="ds-co__h2">What happened</h2>
                    <ol class="ds-co__timeline">
                        @foreach ($result['events'] as $event)
                            <li @class(['is-'.$event['tone'] => $event['tone']])>
                                <span class="ds-co__dot" aria-hidden="true"></span>
                                <span class="ds-co__event">
                                    <strong>{{ $event['title'] }}</strong>
                                    @if ($event['detail']) <span>{{ $event['detail'] }}</span> @endif
                                    @if ($event['photo'] ?? null)
                                        <a href="{{ $event['photo'] }}" target="_blank" rel="noopener"><img src="{{ $event['photo'] }}" alt="Photo: {{ $event['title'] }}" loading="lazy"></a>
                                    @endif
                                </span>
                                <time class="ds-board__muted">
                                    @if ($event['at'])
                                        {{ \Illuminate\Support\Carbon::parse($event['at'])->format(($event['dateOnly'] ?? false) ? 'M j' : 'M j, g:i A') }}
                                    @endif
                                </time>
                            </li>
                        @endforeach
                    </ol>
                </section>
                <aside class="ds-board__panel ds-co__boxcard">
                    <span @class(['ds-co__status', 'is-ok' => $result['status'] === 'Delivered'])>{{ $result['status'] }}</span>
                    <strong class="ds-co__boxno">{{ $result['box']?->invoice ?? $result['row']->invoice }}</strong>
                    @if ($result['box']?->boxtype) <span class="ds-board__muted">{{ $result['box']->boxtype }}</span> @endif
                    <dl>
                        <dt>Receiver</dt><dd>{{ $result['box']?->receiver_name }}</dd>
                        <dt>Address</dt><dd>{{ collect([$result['box']?->receiver_address, $result['box']?->receiver_barangay, $result['box']?->receiver_city, $result['box']?->receiver_province])->filter()->join(', ') }}</dd>
                        @if ($result['box']?->receiver_mobile_no)
                            <dt>Phone</dt><dd>{{ $result['box']->receiver_mobile_no }} <a href="tel:{{ preg_replace('/[^0-9+]/', '', $result['box']->receiver_mobile_no) }}">Call</a></dd>
                        @endif
                        <dt>Sender</dt><dd>{{ $result['box']?->sender_name }}</dd>
                    </dl>
                </aside>
            </div>
            <section class="ds-board__panel">
                <div class="ds-board__panel-head"><h2>Box photos</h2></div>
                @include('filament.partials.invoice-photos', ['items' => (new \App\Support\Photos\BoxAlbum(auth()->user()))->forInvoice($result['row']->invoice_id)])
            </section>
        @endif
    </div>
</x-filament-panels::page>
