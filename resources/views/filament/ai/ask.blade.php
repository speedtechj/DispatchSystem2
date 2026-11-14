<x-filament-panels::page>
<div class="ds-ai">
    @include('filament.ai.paused', ['paused' => $paused])
    <section class="ds-ai__card ds-ai__chat">
        <div class="ds-ai__msgs" id="ds-ai-msgs" x-data x-init="$el.scrollTop = $el.scrollHeight" x-effect="$wire.chat; $nextTick(() => $el.scrollTop = $el.scrollHeight)">
            @if (! $chat)
                <div class="ds-ai__hello"><b>What do you want to know?</b><span>Type a question, or pick one below.</span></div>
            @endif
            @foreach ($chat as $i => $m)
                <div wire:key="m-{{ $i }}" @class(['ds-ai__msg', 'is-me' => $m['role'] === 'user'])>{!! nl2br(e($m['text'])) !!}</div>
            @endforeach
            <div wire:loading.flex wire:target="ask" class="ds-ai__typing"><i></i><i></i><i></i><span>Looking it up…</span></div>
        </div>
        @if ($error)<p class="ds-ai__err">{{ $error }}</p>@endif
        <div class="ds-ai__ask">
            <div class="ds-ai__chips">
                @foreach ($examples as $ex)
                    <button type="button" wire:click="ask(@js($ex))" wire:loading.attr="disabled">{{ $ex }}</button>
                @endforeach
                @if ($chat)<button type="button" wire:click="clear" class="is-plain">Clear</button>@endif
            </div>
            <form wire:submit="ask()" class="ds-ai__askrow">
                <input type="text" wire:model="question" placeholder="Ask anything… e.g. boxes for Juan dela Cruz" maxlength="400" aria-label="Your question">
                <x-filament::button type="submit" wire:loading.attr="disabled" wire:target="ask">Ask</x-filament::button>
            </form>
            <small class="ds-board__muted">Answers come from your own data and can be wrong; open the box or trip to be sure. Partner hubs only get answers about their own hub.</small>
        </div>
    </section>
</div>
</x-filament-panels::page>
