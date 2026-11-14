<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#0e2433">
    <title>No signal · {{ $company }}</title>
    <style>
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; display: flex; flex-direction: column; font-family: Archivo, system-ui, -apple-system, 'Segoe UI', sans-serif; color: #0e2433; background: #f3f5f7; }
        header { height: 64px; padding: 0 18px; padding-top: env(safe-area-inset-top); display: flex; align-items: center; gap: 10px; background: #0e2433; color: #fff; font-weight: 800; }
        .mark { width: 32px; height: 32px; border-radius: 8px; background: #f6be00; color: #0e2433; display: flex; align-items: center; justify-content: center; font-weight: 900; font-size: 13px; overflow: hidden; }
        .mark img { width: 100%; height: 100%; object-fit: contain; background: #fff; }
        main { flex: 1; width: 100%; max-width: 30rem; margin: 0 auto; padding: 0 28px; display: flex; flex-direction: column; justify-content: center; gap: 18px; }
        .icon { width: 72px; height: 72px; border-radius: 22px; background: #fff1dc; color: #e08a00; display: flex; align-items: center; justify-content: center; }
        h1 { margin: 0; font-size: 28px; line-height: 1.15; }
        p { margin: 0; font-size: 16px; line-height: 1.5; color: #4a5865; }
        ul { margin: 0; padding: 14px 16px; list-style: none; border-radius: 14px; background: #fff; box-shadow: 0 0 0 1px rgba(14,36,51,.06); display: flex; flex-direction: column; gap: 10px; font-size: 15px; }
        li { display: flex; gap: 10px; }
        .ok { color: #17895e; font-weight: 800; }
        .warn { color: #e08a00; font-weight: 800; }
        footer { width: 100%; max-width: 30rem; margin: 0 auto; padding: 0 22px calc(34px + env(safe-area-inset-bottom)); }
        button { width: 100%; height: 56px; border: 0; border-radius: 14px; background: #f6be00; color: #0e2433; font: inherit; font-size: 17px; font-weight: 800; cursor: pointer; }
        button[disabled] { background: #d5dde3; color: #4a5865; }
        button:focus-visible { outline: 3px solid #0e2433; outline-offset: 3px; }
    </style>
</head>
<body>
    <header>
        <span class="mark">@if ($logo)<img src="{{ $logo }}" alt="" onerror="this.replaceWith('{{ $initials }}')">@else{{ $initials }}@endif</span>
        <span>{{ $company }}</span>
    </header>
    <main>
        <span class="icon" aria-hidden="true">
            <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 8.8a15 15 0 0 1 4.2-2.6M10.5 5.1A15 15 0 0 1 22 8.8M5 12.9a10 10 0 0 1 3.4-2M15.5 11a10 10 0 0 1 3.5 1.9M8.5 16.4a5 5 0 0 1 7 0M12 20h.01M3 3l18 18"/></svg>
        </span>
        <h1>No signal right now</h1>
        <p>The app will reload by itself when your phone is back online.</p>
        <ul>
            <li><span class="ok" aria-hidden="true">✓</span> Boxes you already marked are saved</li>
            <li><span class="ok" aria-hidden="true">✓</span> Nothing is lost while you wait</li>
            <li><span class="warn" aria-hidden="true">!</span> Marking a box delivered needs a signal</li>
        </ul>
    </main>
    <footer>
        <button type="button" id="retry">Try again</button>
    </footer>
    <script>
        const retry = document.getElementById('retry');
        const reload = () => location.reload();
        addEventListener('online', reload);
        // Phones sometimes miss the "online" event: check every few seconds too.
        setInterval(() => fetch('/pwa/offline', { cache: 'no-store' }).then((r) => r.ok && reload()).catch(() => {}), 5000);
        retry.addEventListener('click', () => {
            retry.disabled = true;
            retry.textContent = 'Checking connection…';
            fetch('/pwa/offline', { cache: 'no-store' }).then(reload).catch(() => {
                setTimeout(() => { retry.disabled = false; retry.textContent = 'Try again'; }, 800);
            });
        });
    </script>
</body>
</html>
