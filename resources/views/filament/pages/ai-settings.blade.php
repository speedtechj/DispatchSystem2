<x-filament-panels::page>
    <form wire:submit="save" class="ds-ai ds-ai-set">
        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>1 · Your Anthropic API key</h2>
                <span class="ds-ai__pill {{ $hasKey ? 'is-ok' : 'is-off' }}">{{ $hasKey ? 'Key saved · ends with '.$keyEnd : 'No key yet' }}</span>
            </div>
            <ol class="ds-ai-set__steps">
                <li>Go to <a href="https://console.anthropic.com/settings/keys" target="_blank" rel="noopener">console.anthropic.com</a>, sign in, add a payment card under Billing.</li>
                <li>Open <b>API keys</b> → <b>Create key</b>, copy it (it starts with <code>sk-ant-</code>).</li>
                <li>Paste it here and press <b>Save</b>, then <b>Test</b>.</li>
            </ol>
            <div class="ds-ai-set__key">
                <input type="password" wire:model="apiKey" autocomplete="off" placeholder="{{ $hasKey ? 'Paste a new key to replace the saved one' : 'sk-ant-…' }}" aria-label="API key">
                <x-filament::button type="submit">Save</x-filament::button>
                <x-filament::button color="gray" wire:click="test" type="button">Test</x-filament::button>
                @if ($hasKey)
                    <x-filament::button color="danger" outlined wire:click="removeKey" wire:confirm="Remove the AI key? All AI helpers that need it will stop." type="button">Remove key</x-filament::button>
                @endif
            </div>
            @error('apiKey')<p class="ds-ai__err">{{ $message }}</p>@enderror
            @if ($testResult)
                <p class="ds-ai__test {{ $testOk ? 'is-ok' : 'is-bad' }}">{{ $testResult }}</p>
            @endif
            <p class="ds-board__muted">The key is saved encrypted in your database and never shown again. Only the question, photo or file being checked is sent to the AI.</p>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>2 · Which helpers are on</h2><span>this month</span></div>
            @foreach ($features as $key => [$title, $text, $who, $needsKey])
                <label class="ds-ai-set__feat" wire:key="f-{{ $key }}">
                    <input type="checkbox" wire:model="enabled.{{ $key }}">
                    <span>
                        <b>{{ $title }}</b>
                        <small>{{ $text }}</small>
                        <em>{{ $who }}{{ $needsKey ? '' : ' · works without a key' }}</em>
                        @if ($key === 'addresses' && class_exists(\App\Filament\Pages\AddressAi::class))<a href="{{ \App\Filament\Pages\AddressAi::getUrl() }}" class="ds-ad__more">Missing barangay, what it uses, try an address ›</a>@endif
                    </span>
                    <span class="ds-ai-set__use">
                        @php($u = $byFeature[$key] ?? null)
                        <b>${{ number_format((float) ($u->c ?? 0), 2) }}</b>
                        <small>{{ number_format((int) ($u->n ?? 0)) }} uses</small>
                    </span>
                </label>
            @endforeach
            <div class="ds-ai-set__save"><x-filament::button type="submit">Save</x-filament::button></div>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>3 · Spending and models</h2></div>
            @php($pct = $limitNow > 0 ? min(100, round($spent / $limitNow * 100)) : 0)
            <div class="ds-ai-set__spend">
                <span><b>${{ number_format($spent, 2) }}</b> used in {{ now()->format('F') }}{{ $limitNow > 0 ? ' of $'.number_format($limitNow, 2) : '' }}</span>
                <i><s style="width: {{ $pct }}%" class="{{ $pct >= 90 ? 'is-bad' : '' }}"></s></i>
            </div>
            <div class="ds-gm__grid">
                <label class="ds-gm__field"><span>Monthly limit in US$ (AI pauses when reached · 0 = no limit)</span><input type="number" min="0" step="1" wire:model="limit"></label>
                <label class="ds-gm__field"><span>Fast model (photos, short texts)</span><input type="text" wire:model="modelFast"></label>
                <label class="ds-gm__field"><span>Smart model (questions, manifests, reports)</span><input type="text" wire:model="modelSmart"></label>
            </div>
            <p class="ds-board__muted">Costs shown here are estimates from the prices in <code>config/ai.php</code>. Your Anthropic Console shows the real bill. You can also set a spending limit there.</p>
            @foreach ($failures as $e)
                <p class="ds-ai__err">{{ $e->created_at->format('M j g:i A') }} · {{ $e->feature }} · {{ $e->error }}</p>
            @endforeach
            <div class="ds-ai-set__save"><x-filament::button type="submit">Save</x-filament::button></div>
        </section>

        <section class="ds-board__panel">
            <div class="ds-board__panel-head"><h2>Good to know</h2></div>
            <ul class="ds-ai-set__notes">
                <li>Alerts and the photo check backlog run from the scheduler. On your server keep <code>php artisan schedule:work</code> running (or the usual cron line).</li>
                <li>Customer chat page for receivers: <a href="{{ $chatUrl }}" target="_blank" rel="noopener">{{ $chatUrl }}</a> (only works when Customer chat is on).</li>
                <li>The AI only suggests. A person decides on damaged boxes, manifest rows, texts and emails.</li>
            </ul>
        </section>
    </form>
</x-filament-panels::page>
