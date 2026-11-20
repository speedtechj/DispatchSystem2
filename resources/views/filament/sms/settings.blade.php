<x-filament-panels::page>
<div class="ds-mp">
    <div class="ds-mp__badges">
        <span @class(['is-ok' => $ready, 'is-warn' => ! $ready])>● {{ $ready ? 'Sending · '.$providers[$provider][0] : 'Not sending: no SMS key yet' }}</span>
        <span><b>{{ number_format($used) }}</b> texts this month · limit {{ number_format((int) $limit) }}</span>
        @if ($badNumbers)<span class="is-warn">{{ $badNumbers }} bad numbers this week · see the SMS log</span>@endif
    </div>

    <form wire:submit="saveSetup" class="ds-board__panel">
        <div class="ds-board__panel-head"><h2>SMS provider</h2></div>
        <div class="ds-mp__providers ds-sms__providers">
            @foreach ($providers as $k => [$name, $text, $works])
                <button type="button" wire:click="pick('{{ $k }}')" @class(['ds-mp__provider', 'is-picked' => $provider === $k])>
                    <span class="ds-mp__provhead"><b>{{ $name }}</b><em @class(['is-on' => $provider === $k && $ready])>{{ ! $works ? 'Ask to connect' : ($provider === $k ? ($ready ? 'In use' : 'Chosen') : (\App\Support\Sms\SmsSettings::masked($k) ? 'Key saved' : 'No key')) }}</em></span>
                    <small>{{ $text }}</small>
                </button>
            @endforeach
        </div>
        <div class="ds-sms__fields">
            <label><span>{{ $provider === 'twilio' ? 'Account SID:Auth Token' : 'API key' }} @if ($masked)<small class="is-ok">saved ✓ {{ $masked }}</small>@endif</span><input type="password" wire:model="key" autocomplete="off" placeholder="{{ $masked ? 'Paste to replace' : 'Paste the key' }}"></label>
            <label><span>Sender name {{ $provider === 'twilio' ? '(Twilio number or MG… SID)' : '' }}</span><input type="text" wire:model="sender" placeholder="e.g. DISPATCHPH (approved by the provider)"></label>
            <label><span>Monthly limit (texts)</span><input type="number" min="0" wire:model="limit"></label>
            <label><span>Office phone in texts {hub_phone}</span><input type="text" wire:model="officePhone" placeholder="0917 555 0101"></label>
            <label><span>Language of the texts</span><select wire:model="language"><option value="auto">By province (Bisaya · Tagalog · English)</option><option value="en">Always English</option><option value="tl">Always Tagalog</option><option value="ceb">Always Bisaya</option></select></label>
        </div>
        @error('key')<p class="ds-ai__err">{{ $message }}</p>@enderror
        <div class="ds-mp__keyrow">
            <x-filament::button type="submit">Save</x-filament::button>
            @if ($masked)<x-filament::button type="button" color="danger" outlined wire:click="removeKey" wire:confirm="Remove the key? No texts will be sent.">Remove key</x-filament::button>@endif
            <span class="ds-sms__test"><input type="text" wire:model="testNumber" placeholder="Your number, 0917…"><x-filament::button type="button" color="gray" wire:click="test">Send a test text</x-filament::button></span>
        </div>
        @if ($testResult)<p @class(['ds-mp__result', 'is-ok' => $testOk])>{{ $testResult }}</p>@endif
        <p class="ds-board__muted">Semaphore: sign up at semaphore.co, buy credits, copy the API key, and ask for your Sender Name (it takes a few days; until then texts come from "SEMAPHORE"). A receiver with 10 boxes gets one text, not 10. Bad numbers are skipped and listed in the SMS log.</p>
    </form>

    <div class="ds-sms__grid">
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Messages</h2><span class="ds-board__muted">switch each on or off · click to edit</span></div>
            @foreach ($kinds as $k => [$title, $when])
                <div wire:key="k-{{ $k }}" @class(['ds-sms__kind', 'is-sel' => $kind === $k])>
                    <button type="button" wire:click="toggle('{{ $k }}')" @class(['ds-sms__switch', 'is-on' => $enabled[$k] ?? false]) aria-label="Switch {{ $title }}"><i></i></button>
                    <button type="button" class="ds-sms__kindtext" wire:click="edit('{{ $k }}')"><b>{{ $title }}</b><small>{{ $when }}</small></button>
                    <small>{{ ($enabled[$k] ?? false) ? number_format($counts[$k] ?? 0).' this month' : 'off' }}</small>
                </div>
                @if ($k === 'out_for_delivery')
                    <small class="ds-sms__follow">Plan trips follows this switch: {{ ($enabled[$k] ?? false) ? '“SMS to receivers when the trip is locked”' : '“No SMS (off in SMS settings)”' }}. One trip only: “Send SMS for this trip” on its card.</small>
                @endif
            @endforeach
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Edit · {{ $kinds[$kind][0] }}</h2>
                <span class="ds-tm__tabs">@foreach ($langs as $l => $ln)<button type="button" wire:click="edit('{{ $kind }}', '{{ $l }}')" @class(['is-on' => $lang === $l])>{{ $ln }}</button>@endforeach</span></div>
            <textarea wire:model.live.debounce.400ms="text" rows="4" class="ds-sms__text"></textarea>
            @error('text')<p class="ds-ai__err">{{ $message }}</p>@enderror
            <span class="ds-sms__blanks">@foreach ($blanks as $b)<em>{{ $b }}</em>@endforeach</span>

            @if ($aiOn)
                <span class="ds-sms__ai">
                    <button type="button" wire:click="ai('short')" wire:loading.attr="disabled">✨ Make it 1 text</button>
                    <button type="button" wire:click="ai('friendly')" wire:loading.attr="disabled">✨ Friendlier</button>
                    @foreach ($langs as $l => $ln)@if ($l !== $lang)<button type="button" wire:click="ai('{{ $l }}')" wire:loading.attr="disabled">✨ Translate to {{ $ln }}</button>@endif @endforeach
                    <small wire:loading wire:target="ai">The AI is writing…</small>
                </span>
            @else
                <p class="ds-board__muted">✨ AI writer: {{ $aiSwitched ? 'add the AI key in Settings → AI' : 'switch on "SMS writer" in Settings → AI' }} to shorten, make friendlier and translate texts.</p>
            @endif
            @if ($aiNote)
                <div class="ds-sms__ainote"><span>✨ {{ $aiNote }}</span><button type="button" wire:click="undoAi">Back to mine</button></div>
            @endif
            @if ($aiError)<p class="ds-ai__err">{{ $aiError }}</p>@endif

            <div class="ds-sms__checks">
                <span @class(['is-ok' => $parts === 1, 'is-warn' => $parts > 1])>{{ $parts === 1 ? '✓ 1 text per receiver' : '⚠ '.$parts.' texts per receiver ('.$chars.' characters)'.($aiOn ? ': press "Make it 1 text" to save money' : '') }}</span>
                <span @class(['is-ok' => ! $unknown, 'is-warn' => (bool) $unknown])>{{ $unknown ? '⚠ Unknown blank: '.implode(', ', $unknown) : '✓ All blanks are known' }}</span>
                <span @class(['is-ok' => ! $emoji, 'is-warn' => $emoji])>{{ $emoji ? '⚠ Emojis make texts cost more' : '✓ No emojis' }}</span>
            </div>

            <b class="ds-sms__label">Preview</b>
            <div class="ds-sms__phone"><small>{{ \App\Support\Sms\SmsSettings::sender() ?: 'SEMAPHORE' }} · now</small><span>{{ $preview }}</span></div>

            <span class="ds-mp__keyrow"><x-filament::button wire:click="saveText">Save message</x-filament::button><x-filament::button color="gray" wire:click="resetText">Back to default</x-filament::button></span>

            <b class="ds-sms__label">Other languages</b>
            @foreach ($others as $l => $t)
                <button type="button" class="ds-sms__other" wire:click="edit('{{ $kind }}', '{{ $l }}')"><b>{{ $langs[$l] }}</b><span>{{ $t }}</span></button>
            @endforeach
        </section>
    </div>
</div>
</x-filament-panels::page>
