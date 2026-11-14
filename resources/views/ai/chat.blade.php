<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="robots" content="noindex">
    <title>Ask about your box · {{ $company }}</title>
    <style>
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; display: flex; flex-direction: column; font-family: Archivo, system-ui, -apple-system, 'Segoe UI', sans-serif; color: #0e2433; background: #f3f5f7; }
        header { padding: calc(env(safe-area-inset-top) + 14px) 18px 14px; background: #0e2433; color: #fff; display: flex; align-items: center; gap: 10px; }
        header b { font-size: 17px; } header small { display: block; color: #9fb0bd; font-size: 13px; }
        .mark { width: 36px; height: 36px; border-radius: 10px; background: #f6be00; color: #0e2433; display: grid; place-items: center; font-weight: 900; font-size: 13px; }
        main { flex: 1; width: 100%; max-width: 34rem; margin: 0 auto; padding: 18px 16px 120px; display: flex; flex-direction: column; gap: 10px; }
        .card { background: #fff; border-radius: 18px; padding: 20px; box-shadow: 0 0 0 1px #e6ebef; display: flex; flex-direction: column; gap: 12px; }
        h1 { margin: 0; font-size: 24px; } p { margin: 0; line-height: 1.5; color: #4a5865; }
        label { display: flex; flex-direction: column; gap: 6px; font-weight: 600; font-size: 14px; }
        input, textarea { font: inherit; font-size: 16px; padding: 12px 14px; border-radius: 12px; border: 0; box-shadow: inset 0 0 0 1px #cfd8df; background: #fff; color: #0e2433; }
        input:focus, textarea:focus { outline: 3px solid #f6be00; }
        button { font: inherit; font-weight: 800; font-size: 16px; height: 50px; border: 0; border-radius: 14px; background: #f6be00; color: #0e2433; cursor: pointer; }
        .err { color: #b3261e; font-size: 14px; }
        .msg { max-width: 85%; padding: 11px 14px; border-radius: 18px; line-height: 1.45; font-size: 15px; white-space: pre-line; }
        .me { align-self: flex-end; background: #1a73e8; color: #fff; border-bottom-right-radius: 4px; }
        .ai { align-self: flex-start; background: #fff; box-shadow: 0 0 0 1px #e6ebef; border-bottom-left-radius: 4px; }
        .meta { align-self: flex-start; font-size: 12px; color: #6b7b88; margin: -4px 0 4px 6px; }
        .meta.staff { color: #b26b00; font-weight: 700; }
        form.ask { position: fixed; left: 0; right: 0; bottom: 0; padding: 10px 14px calc(env(safe-area-inset-bottom) + 12px); background: #fff; box-shadow: 0 -1px 0 #e6ebef; }
        form.ask div { max-width: 34rem; margin: 0 auto; display: flex; gap: 8px; }
        form.ask input { flex: 1; min-width: 0; } form.ask button { padding: 0 18px; }
        .hint { font-size: 13px; color: #6b7b88; text-align: center; }
    </style>
</head>
<body>
<header><span class="mark">{{ \Illuminate\Support\Str::of($company)->explode(' ')->map(fn ($w) => mb_substr($w, 0, 1))->take(2)->join('') }}</span><span><b>{{ $company }}</b><small>Ask about your box</small></span></header>
<main>
@if (! $chat)
    <form class="card" method="post" action="{{ route('ai-chat.start') }}">
        @csrf
        <h1>Where is my box?</h1>
        <p>Type your box number and the last 4 digits of the receiver's phone number. Then ask anything about your box, in English, Tagalog or Bisaya.</p>
        <label>Box number<input name="box" value="{{ old('box') }}" inputmode="text" autocomplete="off" required></label>
        <label>Last 4 digits of the receiver's phone<input name="last4" value="{{ old('last4') }}" inputmode="numeric" maxlength="4" pattern="\d{4}" required></label>
        @error('box')<span class="err">{{ $message }}</span>@enderror
        <button type="submit">Continue</button>
    </form>
@else
    <div class="msg ai">Hi! Ask me anything about box {{ $chat->invoice }}. For example: "Where is my box?" or "Kailan po darating?"</div>
    @foreach ($chat->messages ?? [] as $m)
        <div class="msg {{ $m['role'] === 'user' ? 'me' : 'ai' }}">{{ $m['text'] }}</div>
        @if ($m['role'] !== 'user' && ! empty($m['staff']))<span class="meta staff">Passed to our staff</span>@endif
    @endforeach
    <p class="hint">Answers are written by AI from our tracking. Our staff see anything you report.</p>
    <form class="ask" method="post" action="{{ route('ai-chat.ask', $chat->token) }}">
        @csrf
        @error('q')<p class="err" style="text-align:center;margin-bottom:6px">{{ $message }}</p>@enderror
        <div><input name="q" placeholder="{{ $left ? 'Type your question' : 'This chat is full' }}" autocomplete="off" required @disabled(! $left) autofocus><button type="submit" @disabled(! $left)>Send</button></div>
    </form>
    <script>window.scrollTo(0, document.body.scrollHeight)</script>
@endif
</main>
</body>
</html>
