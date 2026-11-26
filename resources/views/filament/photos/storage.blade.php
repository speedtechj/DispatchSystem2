<x-filament-panels::page>
@php
    $pl = \App\Support\Photos\Storage\PhotoStore::PLACES;
    $prov = \App\Support\Photos\Storage\PhotoStore::PROVIDERS;
    $ago = fn ($ts) => $ts ? \Illuminate\Support\Carbon::createFromTimestamp($ts)->diffForHumans() : 'never';
    $checks = [
        ['S3 driver', $driver, $driver ? 'Installed on the server' : 'Run once: composer require league/flysystem-aws-s3-v3'],
        ['Background worker', $worker || $scheduler || $runHere, $worker ? 'Running' : ($scheduler ? 'Scheduler runs (every minute)' : ($runHere ? 'Running in this tab' : 'Not running: see the Workers tab'))],
        ['Bucket tested', $usable['tmp'] || $usable['real'], $usable['tmp'] || $usable['real'] ? ($tmp->bucket ?: $real->bucket).': upload, read, delete ok' : 'Put a bucket and press Test connection'],
        ['Old system found', (bool) ($find['found'] ?? false), ($find['found'] ?? false) ? basename($find['dir'] ?? 'old site').' · read-only' : 'Not found on this server (Copy tab, step 1)'],
    ];
@endphp
<div class="ds-pst" @if ($runHere) wire:poll.4s="tick" @elseif ($active) wire:poll.10s @endif>
    <span class="ds-pst__title"><h1>Photo storage</h1><small>Where every photo is saved: box photos, unload, POD, pick-up, from the scan app, the driver app and the panels. Put your bucket here: nothing to set in the server files.</small></span>

    <section class="ds-pst__card">
        <span class="ds-pst__row"><b class="ds-pst__h">Setup checklist</b><small class="ds-pst__mute">Everything needs a ✓ before photos go to the bucket.</small></span>
        <span class="ds-pst__grid4">
            @foreach ($checks as [$name, $ok, $text])
                <span @class(['ds-pst__chk', 'is-ok' => $ok])><b>{{ $ok ? '✓' : '✗' }} {{ $name }}</b><small>{{ $text }}</small></span>
            @endforeach
        </span>
    </section>

    <span class="ds-pst__tabs">
        @foreach (['old' => 'Copy from the old system', 'bucket' => 'Bucket', 'work' => 'Workers'] as $id => $name)
            <button type="button" wire:click="setTab('{{ $id }}')" @class(['is-on' => $tab === $id])>{{ $name }}</button>
        @endforeach
    </span>

    {{-- ─────────────── Bucket ─────────────── --}}
    @if ($tab === 'bucket')
        @if ($usable['real'] && ($target !== 'real' || ($switch && $switch->status !== 'done') || ($switch && $switch->finished_at?->gt(now()->subDay()))))
            @php $sw = $switch && in_array($switch->status, ['running', 'paused', 'done']) && $switch->created_at->gt(now()->subDays(3)) ? $switch : null; @endphp
            <section class="ds-pst__switch">
                <span class="ds-pst__row">
                    <span class="ds-pst__col"><b>{{ $sw?->status === 'done' ? '✓ Switched to the real bucket' : ($sw ? 'Switching to the real bucket…' : 'Switch to the real bucket') }}</b>
                        <small>{{ $sw?->status === 'done' ? 'All photos are in '.$real->bucket.'. '.($sw->opt('auto_off') ? 'Temporary was turned off by itself; its files stay as a backup.' : 'Press Turn off on the Temporary card when you are ready.') : ($sw ? 'Runs in the background, you can close this page. Every photo keeps opening while it moves.' : 'One press: new photos go to Real, the photos in Temporary move there, it is checked, then Temporary turns off.') }}</small></span>
                    @if (! $sw)
                        <button type="button" class="ds-pst__go is-yellow" wire:click="startSwitch">Switch to Real bucket</button>
                    @elseif ($sw->status === 'paused')
                        <button type="button" class="ds-pst__go is-yellow" wire:click="resume({{ $sw->id }})">Go on</button>
                    @elseif ($sw->status === 'running')
                        <button type="button" class="ds-pst__go" wire:click="pause({{ $sw->id }})">Pause</button>
                    @endif
                </span>
                <span class="ds-pst__grid4">
                    @foreach ([['New photos → Real', 'right away', (bool) $sw], ['Move Temporary → Real', $sw ? number_format($sw->done + $sw->skipped).' of '.number_format($sw->total) : number_format($inTmp).' photos', $sw?->status === 'done' ? true : ($sw ? 'on' : false)], ['Check', '0 left, same size', $sw?->status === 'done'], ['Turn off Temporary', $autoOff ? 'by itself' : 'you press it', $sw?->status === 'done' && $tmp->is_off]] as [$n, $t, $st])
                        <span class="ds-pst__sstep"><b @class(['is-ok' => $st === true, 'is-on' => $st === 'on'])>{{ $st === true ? '✓' : ($st === 'on' ? '…' : '○') }} {{ $n }}</b><small>{{ $t }}</small></span>
                    @endforeach
                </span>
                <span class="ds-pst__bar is-dark"><i style="width: {{ $sw ? $sw->pct() : 0 }}%"></i></span>
                @unless ($sw)
                    <label class="ds-pst__tog is-dark"><input type="checkbox" wire:model.live="autoOff"><span><b>Turn off Temporary by itself when it is empty</b><small>Off: you press Turn off on the Temporary card yourself.</small></span></label>
                @endunless
            </section>
        @endif

        <section class="ds-pst__card">
            <b class="ds-pst__h">New photos go to</b>
            <span class="ds-pst__where">
                @foreach ($pl as $id => $name)
                    <button type="button" wire:click="setTarget('{{ $id }}')" @class(['is-on' => $target === $id]) @disabled(! $usable[$id])>
                        <b>{{ $name }}</b><small>{{ $id === 'server' ? 'Like before (this server\'s disk)' : (${$id}->is_off ? 'Turned off' : ($usable[$id] ? ${$id}->bucket : 'Put and test it first')) }}</small>
                    </button>
                @endforeach
            </span>
            <small class="ds-pst__mute">Old photos keep working: each photo remembers where it is saved (server, temporary or real) until you move it. Logos and app icons always stay on the server.</small>
        </section>

        <div class="ds-pst__two">
            @foreach (['tmp' => $tmp, 'real' => $real] as $slot => $b)
                @php $f = $form[$slot]; $set = $b->exists && $b->isSet(); @endphp
                <section @class(['ds-pst__card', 'is-off' => $b->is_off]) wire:key="slot-{{ $slot }}">
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h">{{ $slot === 'tmp' ? 'Temporary bucket' : 'Real bucket' }}</b><small class="ds-pst__mute">{{ $slot === 'tmp' ? 'Now: used on production for a while' : 'Later: your real bucket' }}</small></span>
                        <span @class(['ds-pst__pill', 'is-ok' => $set && $b->test_ok && ! $b->is_off, 'is-warn' => $set && ! $b->test_ok])>{{ $b->is_off ? 'Turned off' : (! $set ? 'Not set' : ($b->test_ok ? 'Connected' : 'Not tested')) }}</span></span>
                    <span class="ds-pst__chips"><small class="ds-pst__lbl">Provider</small>
                        @foreach ($prov as $id => $name)
                            <button type="button" wire:click="setProvider('{{ $slot }}', '{{ $id }}')" @class(['is-on' => $f['provider'] === $id])>{{ $name }}</button>
                        @endforeach
                    </span>
                    @if ($editing[$slot])
                        <span class="ds-pst__fields">
                            @if ($f['provider'] === 'r2')
                                <label><small class="ds-pst__lbl">Account ID</small><input wire:model="form.{{ $slot }}.account_id" placeholder="from the S3 API link"></label>
                            @elseif ($f['provider'] === 's3')
                                <label><small class="ds-pst__lbl">Region</small><input wire:model="form.{{ $slot }}.region" placeholder="ap-southeast-1"></label>
                            @else
                                <label><small class="ds-pst__lbl">Endpoint URL</small><input wire:model="form.{{ $slot }}.endpoint" placeholder="https://…"></label>
                                <label><small class="ds-pst__lbl">Region</small><input wire:model="form.{{ $slot }}.region" placeholder="us-east-1"></label>
                            @endif
                            <label><small class="ds-pst__lbl">Bucket name</small><input wire:model="form.{{ $slot }}.bucket"></label>
                            <label><small class="ds-pst__lbl">Access key ID</small><input wire:model="form.{{ $slot }}.access_key" autocomplete="off"></label>
                            <label><small class="ds-pst__lbl">Secret access key</small><input type="password" wire:model="form.{{ $slot }}.secret" autocomplete="new-password" placeholder="{{ $b->secret ? '•••••••• saved (leave empty to keep)' : '' }}"></label>
                        </span>
                    @else
                        <span class="ds-pst__fields is-read">
                            @foreach (array_filter([
                                $b->provider === 'r2' ? ['Account ID', $b->account_id] : null,
                                $b->provider !== 'r2' && $b->provider !== 's3' ? ['Endpoint URL', $b->endpoint] : null,
                                $b->provider !== 'r2' ? ['Region', $b->region] : null,
                                ['Bucket name', $b->bucket], ['Access key ID', $b->access_key ? Str::mask($b->access_key, '•', 4, max(0, strlen($b->access_key) - 8)) : '—'], ['Secret access key', $b->secret ? '••••••••  saved' : '—'],
                            ]) as [$l, $v])
                                <span><small class="ds-pst__lbl">{{ $l }}</small><span class="ds-pst__in">{{ $v ?: '—' }}</span></span>
                            @endforeach
                        </span>
                    @endif
                    <small @class(['ds-pst__mute', 'is-warn' => $f['provider'] === 's3'])>{{ match ($f['provider']) { 'r2' => 'Endpoint made from the Account ID'.($b->endpointUrl() ? ': '.$b->endpointUrl() : '').' · region auto · downloads free', 's3' => 'No endpoint needed (made from the region). Amazon charges for downloads (about $0.09 per GB opened), R2 does not.', default => 'Wasabi, DigitalOcean Spaces, Backblaze B2 and others: put the endpoint from the provider.' } }}</small>
                    <span class="ds-pst__acts">
                        @if ($editing[$slot])
                            <button type="button" class="ds-pst__go" wire:click="saveBucket('{{ $slot }}')">Save and test</button>
                        @else
                            <button type="button" class="ds-pst__go" wire:click="testBucket('{{ $slot }}')" @disabled(! $set)><span wire:loading.remove wire:target="testBucket('{{ $slot }}')">Test connection</span><span wire:loading wire:target="testBucket('{{ $slot }}')">Testing…</span></button>
                            <button type="button" class="ds-pst__btn" wire:click="editBucket('{{ $slot }}')">{{ $set ? 'Edit' : 'Put a bucket' }}</button>
                        @endif
                        @if ($slot === 'tmp' && $b->exists)
                            @if ($b->is_off)
                                <button type="button" class="ds-pst__btn" wire:click="turnOn('tmp')">Turn on again</button>
                            @else
                                <button type="button" class="ds-pst__btn is-red" wire:click="turnOff('tmp')">Turn off</button>
                            @endif
                        @endif
                    </span>
                    @php $m = $msg[$slot] ?? ($b->test_message ? (($b->test_ok ? '✓ ' : '✗ ').$b->test_message) : ''); @endphp
                    @if ($m)<small @class(['ds-pst__res', 'is-ok' => str_starts_with($m, '✓'), 'is-bad' => str_starts_with($m, '✗') || str_starts_with($m, 'Not yet')])>{{ $m }}</small>@endif
                </section>
            @endforeach
        </div>

        <div class="ds-pst__two">
            <section class="ds-pst__card">
                <b class="ds-pst__h">Last 7 days</b>
                <span class="ds-pst__grid3">
                    <span class="ds-pst__stat is-ok"><b>{{ number_format($stats['bucket']) }}</b><small>saved to a bucket</small></span>
                    <span class="ds-pst__stat is-warn"><b>{{ number_format($stats['server']) }}</b><small>stayed on the server (bucket did not answer)</small></span>
                    <span class="ds-pst__stat"><b>{{ number_format($inTmp) }}</b><small>in the Temporary bucket now</small></span>
                </span>
                <small class="ds-pst__mute">Photos from every app: scan app, driver app and the panels. When a bucket does not answer, the photo is saved on the server: nothing is lost.</small>
            </section>
            <section class="ds-pst__card">
                <span class="ds-pst__row"><b class="ds-pst__h">Move photos</b><small class="ds-pst__mute">Copies each photo, checks it, then deletes the old copy. Runs in the background.</small></span>
                <span class="ds-pst__mv">
                    <b>Server → {{ $target === 'server' ? 'a bucket' : $pl[$target] }}</b>
                    <span class="ds-pst__col"><small>{{ number_format($serverCount) }} photos still on this server</small></span>
                    <button type="button" class="ds-pst__go" wire:click="startMove" @disabled($target === 'server' || $active || ! $serverCount)>Start</button>
                </span>
                @foreach ($moves as $m)
                    <span class="ds-pst__mv" wire:key="mv-{{ $m->id }}">
                        <b>{{ $pl[$m->from_place] ?? $m->from_place }} → {{ $pl[$m->to_place] ?? $m->to_place }}</b>
                        <span class="ds-pst__col"><small>{{ $m->status === 'done' ? '✓ Done · '.number_format($m->done).' moved' : number_format($m->done + $m->skipped).' of '.number_format($m->total).($m->failed ? ' · '.$m->failed.' failed' : '') }} · {{ $m->created_at->diffForHumans() }}</small><span class="ds-pst__bar"><i style="width: {{ $m->pct() }}%"></i></span></span>
                        @if ($m->status === 'running')
                            <button type="button" class="ds-pst__btn" wire:click="pause({{ $m->id }})">Pause</button>
                        @elseif ($m->status === 'paused')
                            <button type="button" class="ds-pst__go" wire:click="resume({{ $m->id }})">Go on</button>
                        @else
                            <span class="ds-pst__pill is-ok">Done</span>
                        @endif
                    </span>
                @endforeach
            </section>
        </div>
    @endif

    {{-- ─────────────── Workers ─────────────── --}}
    @if ($tab === 'work')
        @foreach ([['Background worker (Supervisor)', $worker, 'sudo bash setup-worker.sh', 'Last job '.$ago($queueSeen).' · copy and move run here even with the page closed', 'Run this once on the server as root (SSH, or Plesk → SSH Terminal), in the wmsv2 folder:'], ['Scheduler (cron)', $scheduler, 'Plesk → wmsv2 → Laravel → Scheduled Tasks → On', 'Ran '.$ago($scheduleSeen).' · goes on with moves every minute', 'Turn it on once in Plesk:']] as [$name, $on, $how, $okText, $offText])
            <section class="ds-pst__card ds-pst__runner">
                <span @class(['ds-pst__dot', 'is-ok' => $on])></span>
                <span class="ds-pst__col"><b class="ds-pst__h">{{ $name }}: {{ $on ? 'running' : 'not running' }}</b><small class="ds-pst__mute">{{ $on ? $okText : $offText }}</small></span>
                @unless ($on)<code class="ds-pst__in">{{ $how }}</code>@endunless
            </section>
        @endforeach
        <section class="ds-pst__card">
            <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h">No worker? Run here</b><small class="ds-pst__mute">This page does the work itself, a few photos every few seconds, while the tab stays open. Slower than the worker, nothing to set up. Close the tab and it stops; press again and it goes on.</small></span>
                <button type="button" @class(['ds-pst__go', 'is-purple' => ! $runHere, 'is-redbg' => $runHere]) wire:click="toggleRunHere">{{ $runHere ? 'Stop' : 'Run here' }}</button></span>
            <span class="ds-pst__bar is-purple"><i style="width: {{ $active ? $active->pct() : 0 }}%"></i></span>
            <small class="ds-pst__mute">{{ $active ? ($runHere ? 'Running in this tab · ' : 'Waiting for a worker · ').number_format($active->done + $active->skipped).' of '.number_format($active->total) : 'Nothing to move or copy right now.' }}</small>
        </section>
        <small class="ds-pst__mute">Supervisor and cron are set on the server, not from this page: the website does not run as root, on purpose. Use one worker way, not both Supervisor and the Plesk queue.</small>
    @endif

    {{-- ─────────────── Copy from the old system ─────────────── --}}
    @if ($tab === 'old')
        @php
            $copyDone = $task && $task->status === 'done';
            $stepNames = [['Find the old system', 'its folder · same database?'], ['Scan', 'folders + database paths'], ['Review', 'where each file is'], ['Try 50', 'look before you copy'], ['Copy', 'new only, smaller'], ['Check', 'everything is there'], ['New photos', 'wmsv2 to the bucket'], ['Clean the old server', 'checklist, by you']];
            $doneTo = ! ($find['found'] ?? false) ? 0 : (! $task ? 1 : ($copyDone ? 6 : ($task->done ? 4 : 3)));
        @endphp
        <div class="ds-pst__steps">
            <section class="ds-pst__card ds-pst__nav">
                <small class="ds-pst__lbl">Old system → bucket</small>
                @foreach ($stepNames as $i => [$n, $s])
                    @php $k = $i + 1; @endphp
                    <button type="button" wire:click="setStep({{ $k }})" @class(['is-on' => $step === $k])><span @class(['ds-pst__num', 'is-ok' => $k <= $doneTo && $step !== $k, 'is-on' => $step === $k])>{{ $k <= $doneTo && $step !== $k ? '✓' : $k }}</span><span class="ds-pst__col"><b>{{ $n }}</b><small>{{ $s }}</small></span></button>
                @endforeach
                <small class="ds-pst__mute">Nothing on the old site is ever changed or deleted from here. Any step can be pressed again: it only does what is missing.</small>
            </section>

            <section class="ds-pst__card ds-pst__body">
                @if ($step === 1)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">1 · Find the old system</b><small class="ds-pst__mute">Looks for the old site's folder on this server and checks if it uses the same database.</small></span><span @class(['ds-pst__pill', 'is-ok' => $find['found'] ?? false])>{{ ($find['found'] ?? false) ? (($find['same'] ?? false) ? '✓ Same database' : '✓ Found') : 'Not found' }}</span></span>
                    <span class="ds-pst__acts"><input class="ds-pst__inp" wire:model="oldFolder" aria-label="Old site folder"><button type="button" class="ds-pst__btn" wire:click="saveFolder">Find</button></span>
                    @if ($find['found'] ?? false)
                        <span class="ds-pst__grid3">
                            <span class="ds-pst__chk is-ok"><b>✓ Found {{ basename($find['dir']) }}</b><small>{{ $find['laravel'] ? 'Laravel site' : 'a folder' }} · {{ $find['storage'] ? 'storage/app/public' : 'no storage folder' }}{{ $find['uploads'] ? ' + public/uploads' : '' }}</small></span>
                            <span @class(['ds-pst__chk', 'is-ok' => $find['same']])><b>{{ $find['same'] ? '✓ Same database as wmsv2' : 'Another database' }}</b><small>{{ $find['same'] ? 'one list of photos: no matching needed' : 'the files are copied under wms-v1/ (not linked to boxes)' }}</small></span>
                            <span class="ds-pst__chk is-ok"><b>✓ {{ number_format(collect($columns)->sum('n')) }} photo paths</b><small>in {{ count($columns) }} columns</small></span>
                        </span>
                        @if ($columns)
                            <small class="ds-pst__lbl">Columns that hold photo paths (found by themselves)</small>
                            @foreach ($columns as $c)
                                <span class="ds-pst__tr4"><b class="ds-pst__mono">{{ $c['table'] }}.{{ $c['column'] }}</b><span>{{ number_format($c['n']) }} paths</span><span class="ds-pst__mono ds-pst__mute ds-pst__cut">{{ $c['example'] }}</span><b class="ds-pst__ok">✓ Use</b></span>
                            @endforeach
                        @endif
                    @else
                        <small class="ds-pst__res is-bad">No old site at {{ $find['dir'] ?? 'the usual place' }}. Put the folder of wms.icargoxpress.net above and press Find.</small>
                    @endif
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__go" wire:click="scan" @disabled(! ($find['found'] ?? false))><span wire:loading.remove wire:target="scan">Next: Scan</span><span wire:loading wire:target="scan">Scanning…</span></button></span>

                @elseif ($step === 2)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">2 · Scan old + new</b><small class="ds-pst__mute">Every folder with photos in both sites, and where the file of each path really is.</small></span><span class="ds-pst__pill">{{ $task?->opt('scanned_at') ? 'Scanned '.\Illuminate\Support\Carbon::parse($task->opt('scanned_at'))->diffForHumans() : 'Not scanned yet' }}</span></span>
                    @php $folders = $task?->opt('folders', []) ?? []; $same = collect($folders)->filter(fn ($f) => isset($f['old'], $f['new']))->count(); @endphp
                    @if ($folders)
                        <span class="ds-pst__row"><small class="ds-pst__lbl">Folder structure: old vs new</small><span class="ds-pst__pill is-blue">{{ $same }} of {{ count($folders) }} folders are in both</span></span>
                        <span class="ds-pst__tr4 is-head"><span>Folder</span><span>wms (old)</span><span>wmsv2 (new)</span><span></span></span>
                        @foreach (array_slice($folders, 0, 14, true) as $path => $f)
                            <span class="ds-pst__tr4"><span class="ds-pst__mono">{{ $path }}</span><span>{{ isset($f['old']) ? number_format($f['old'][0]).' · '.$mb($f['old'][1]) : '—' }}</span><span>{{ isset($f['new']) ? number_format($f['new'][0]).' · '.$mb($f['new'][1]) : '—' }}</span>
                                <b @class(['ds-pst__pill', 'is-ok' => isset($f['old'], $f['new']), 'is-blue' => ! isset($f['old']), 'is-warn' => ! isset($f['new'])])>{{ isset($f['old'], $f['new']) ? '✓ Same in both' : (isset($f['new']) ? 'Only in the new' : '⚠ Only in the old') }}</b></span>
                        @endforeach
                    @endif
                    <small class="ds-pst__lbl">The database paths against the files</small>
                    <span class="ds-pst__grid4">
                        @foreach (['wmsv2' => ['✓ In the wmsv2 folder', 'Copied from wmsv2', 'is-ok'], 'wms' => ['✓ In the wms folder', 'Copied from the old site', 'is-ok'], 'both' => ['⚠ Different file in both', 'Same path, two photos: pick one', 'is-warn'], 'missing' => ['✗ Missing', 'In the database, no file anywhere', 'is-bad']] as $g => [$n, $t, $c])
                            <span class="ds-pst__stat {{ $c }}"><b>{{ number_format($groups[$g] ?? 0) }}</b><b class="ds-pst__sm">{{ $n }}</b><small>{{ $t }}</small></span>
                        @endforeach
                    </span>
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__btn" wire:click="scan"><span wire:loading.remove wire:target="scan">Scan old + new again</span><span wire:loading wire:target="scan">Scanning…</span></button><button type="button" class="ds-pst__go" wire:click="setStep(3)" @disabled(! $task)>Next: Review</button></span>

                @elseif ($step === 3)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">3 · Review</b><small class="ds-pst__mute">Each path from the database, which folder has the file, and a link to open it.</small></span><span class="ds-pst__pill">{{ number_format($groups->sum()) }} paths</span></span>
                    <span class="ds-pst__acts">
                        @foreach (['wmsv2' => '✓ wmsv2 folder', 'wms' => '✓ wms folder', 'both' => '⚠ Different in both', 'missing' => '✗ Missing'] as $g => $n)
                            <button type="button" wire:click="$set('rt', '{{ $g }}')" @class(['ds-pst__chip', 'is-on' => $rt === $g])>{{ $n }} {{ number_format($groups[$g] ?? 0) }}</button>
                        @endforeach
                        <input class="ds-pst__inp is-short" wire:model.live.debounce.400ms="search" placeholder="Search path or record…">
                        <button type="button" class="ds-pst__btn" wire:click="csv('report')">Download report (CSV)</button>
                    </span>
                    <span class="ds-pst__tr4 is-head"><span>Path in the database</span><span>Record</span><span>File found in</span><span></span></span>
                    @forelse ($rows as $r)
                        <span class="ds-pst__tr4" wire:key="r-{{ $r->id }}"><span class="ds-pst__mono ds-pst__cut">{{ $r->path }}</span><span class="ds-pst__mute ds-pst__cut">{{ $r->ref }}</span>
                            <span @class(['ds-pst__cut', 'ds-pst__bad' => $r->found === 'missing', 'ds-pst__warn' => $r->found === 'both'])>{{ match ($r->found) { 'wmsv2' => 'wmsv2 folder', 'wms' => 'wms folder', 'both' => 'both · '.$mb((int) $r->size_before).' used, other kept', default => 'no file in either folder' } }}</span>
                            <span>@if ($r->found === 'both')<button type="button" class="ds-pst__link" wire:click="pick({{ $r->id }})">Pick the other</button>@elseif ($r->found !== 'missing')<a class="ds-pst__link" href="{{ $openUrl($r) }}" target="_blank" rel="noopener">Open</a>@endif</span></span>
                    @empty
                        <small class="ds-pst__mute">Nothing here.</small>
                    @endforelse
                    <small class="ds-pst__mute">{{ ['wmsv2' => 'Copied from the wmsv2 folder, same path.', 'wms' => 'Copied from the old site\'s folder, same path: opens in wmsv2 right after.', 'both' => 'The newest file is used, the other is kept in the bucket under _other/. Pick the other to swap.', 'missing' => 'Nothing to copy: these records have no photo in either site.'][$rt] }}</small>
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__go" wire:click="setStep(4)">Next: Try 50</button></span>

                @elseif ($step === 4)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">4 · Try 50 first</b><small class="ds-pst__mute">Copies 50 photos (the biggest first), made smaller. Open the old and the new side by side.</small></span><span class="ds-pst__pill">{{ (int) ($triedSum->n ?? 0) }} tried</span></span>
                    @if ($tried->isNotEmpty())
                        <span class="ds-pst__grid3">
                            @foreach ($tried->take(6) as $t)
                                <span class="ds-pst__pair" wire:key="t-{{ $t->id }}">
                                    <span class="ds-pst__two is-tight"><a href="{{ $oldUrl($t) }}" target="_blank" rel="noopener"><img src="{{ $oldUrl($t) }}" alt="Old" loading="lazy"><em>Old · {{ $mb((int) $t->size_before) }}</em></a><a href="{{ $openUrl($t) }}" target="_blank" rel="noopener"><img src="{{ $openUrl($t) }}" alt="New" loading="lazy"><em class="is-ok">New · {{ $mb((int) $t->size_after) }}</em></a></span>
                                    <small class="ds-pst__cut">{{ $t->ref ?: $t->path }}</small>
                                </span>
                            @endforeach
                        </span>
                        <span class="ds-pst__res is-ok"><b>{{ (int) $triedSum->n }} tried:</b> {{ $mb((int) $triedSum->b) }} → {{ $mb((int) $triedSum->a) }} ({{ $triedSum->b ? round(100 - $triedSum->a * 100 / $triedSum->b) : 0 }}% smaller). Invoice numbers and signatures still clear? Look before you copy all.</span>
                    @endif
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__btn" wire:click="tryFifty" @disabled(! $task)><span wire:loading.remove wire:target="tryFifty">{{ $tried->isEmpty() ? 'Try 50 first' : 'Try 50 others' }}</span><span wire:loading wire:target="tryFifty">Copying 50…</span></button><button type="button" class="ds-pst__go" wire:click="setStep(5)">Looks good: Next</button></span>

                @elseif ($step === 5)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">5 · Copy to the bucket</b><small class="ds-pst__mute">Runs in the background. Press it again any time: only what is missing is copied.</small></span><span @class(['ds-pst__pill', 'is-ok' => $copyDone])>{{ $copyDone ? '✓ Done' : ($task && in_array($task->status, ['running', 'checking']) ? 'Copying' : 'Ready') }}</span></span>
                    @if ($task)
                        <span class="ds-pst__two">
                            @foreach (['small' => ['Make photos smaller (max 200 KB)', '1600 px, clear enough to read the invoice. Signatures and other files stay as they are.', true], 'keep' => ['Also keep the originals in the bucket', 'Full size under _original/ · a few cents a month · safe to delete the old server later', false]] as $k => [$n, $t, $def])
                                <button type="button" class="ds-pst__tog" wire:click="setOpt('{{ $k }}')"><span @class(['ds-pst__sw', 'is-on' => $task->opt($k, $def)])><i></i></span><span class="ds-pst__col"><b>{{ $n }}</b><small>{{ $t }}</small></span></button>
                            @endforeach
                        </span>
                        @php $all = max(1, $task->total); @endphp
                        <span class="ds-pst__col"><span class="ds-pst__row"><small>{{ $copyDone ? '✓ Done · '.number_format($task->done).' copied · '.number_format($task->skipped).' already there · '.$task->failed.' failed' : number_format($task->done + $task->skipped).' of '.number_format($task->total).' photos'.($task->failed ? ' · '.$task->failed.' failed' : '') }}</small><small class="ds-pst__mute">{{ $mb((int) $task->bytes_before) }} → {{ $mb((int) $task->bytes_after) }}</small></span><span class="ds-pst__bar is-blue"><i style="width: {{ $task->pct() }}%"></i></span></span>
                        @if ($task->last_error && $task->failed)<small class="ds-pst__res is-bad">Last problem: {{ $task->last_error }}</small>@endif
                        <span class="ds-pst__acts">
                            @if (in_array($task->status, ['running', 'checking']))
                                <button type="button" class="ds-pst__btn" wire:click="pause({{ $task->id }})">Pause</button>
                            @else
                                <button type="button" class="ds-pst__go is-blue" wire:click="copyNew" @disabled(! ($worker || $scheduler || $runHere))>{{ $task->done ? 'Copy new only' : 'Copy to the bucket' }}</button>
                            @endif
                            <button type="button" class="ds-pst__btn" wire:click="checkBucket">Check bucket</button>
                            <button type="button" class="ds-pst__btn is-red" wire:click="copyAgain">{{ $sureAgain ? 'Press again to replace all' : 'Copy all again…' }}</button>
                            @unless ($worker || $scheduler || $runHere)<small class="ds-pst__warn">No worker runs: start one, or press Run here on the Workers tab.</small>@endunless
                        </span>
                        <small class="ds-pst__lbl">Last copied: old link → new link</small>
                        @foreach ($last as $i)
                            <span class="ds-pst__tr5" wire:key="l-{{ $i->id }}"><a class="ds-pst__mono ds-pst__cut ds-pst__link" href="{{ $oldUrl($i) }}" target="_blank" rel="noopener">{{ $oldUrl($i) }}</a><span class="ds-pst__mute">→</span><a class="ds-pst__mono ds-pst__cut ds-pst__link" href="{{ $openUrl($i) }}" target="_blank" rel="noopener">{{ ($tmp->bucket && $target !== 'real' ? $tmp->bucket : $real->bucket).'/'.$i->path }}</a><span class="ds-pst__mute">{{ $i->size_after && $i->size_after !== $i->size_before ? $mb((int) $i->size_before).' → '.$mb((int) $i->size_after) : $mb((int) $i->size_before) }}</span><b @class(['ds-pst__ok' => $i->status === 'done', 'ds-pst__bad' => $i->status === 'failed'])>{{ ['done' => '✓ Copied', 'skipped' => 'Already there', 'failed' => '✗ '.Str::limit((string) $i->note, 40)][$i->status] ?? $i->status }}</b></span>
                        @endforeach
                        <small class="ds-pst__mute">Same path in the bucket as in the database, so every photo opens in wmsv2 right after. Copy new only: photos already in the bucket are skipped. A photo that changed on the old site is copied again after a new Scan.</small>
                    @else
                        <small class="ds-pst__res is-bad">Scan first (step 2).</small>
                    @endif

                @elseif ($step === 6)
                    <span class="ds-pst__row"><span class="ds-pst__col"><b class="ds-pst__h2">6 · Check</b><small class="ds-pst__mute">Reads the bucket and compares with the list. A missing photo is copied again.</small></span><span @class(['ds-pst__pill', 'is-ok' => $copyDone])>{{ $task?->status === 'checking' ? 'Checking…' : ($task?->checked_at ? '✓ Checked '.$task->checked_at->diffForHumans() : 'Not checked yet') }}</span></span>
                    <span class="ds-pst__grid3">
                        <span class="ds-pst__stat is-ok"><b>{{ number_format($checkedN) }}</b><small>in the bucket and checked</small></span>
                        <span class="ds-pst__stat"><b>{{ number_format(max(0, ($task?->done ?? 0) - $checkedN)) }}</b><small>copied, not checked yet</small></span>
                        <span class="ds-pst__stat is-warn"><b>{{ number_format($missingN) }}</b><small>had no file on either site (Review → Missing)</small></span>
                    </span>
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__btn" wire:click="checkBucket" @disabled(! $task)>Check again</button><button type="button" class="ds-pst__btn" wire:click="csv('list')" @disabled(! $task)>Download old → new list (CSV)</button><button type="button" class="ds-pst__go" wire:click="setStep(7)">Next</button></span>

                @elseif ($step === 7)
                    <b class="ds-pst__h2">7 · New photos of wmsv2</b>
                    <span>Choose where <b>new</b> photos of wmsv2 go (Bucket tab), and move wmsv2's own photos from the server. The photos keep opening: each one remembers where it is.</span>
                    <span class="ds-pst__acts"><button type="button" class="ds-pst__go" wire:click="setTab('bucket')">Open the Bucket tab</button><button type="button" class="ds-pst__btn" wire:click="setStep(8)">Next</button></span>

                @else
                    @php $days = $task?->finished_at ? (int) $task->finished_at->diffInDays(now()) : 0; @endphp
                    <b class="ds-pst__h2">8 · Clean the old server</b>
                    <span>When all of these have a ✓, you can delete the photos on the old server yourself. This page never deletes them.</span>
                    @foreach ([[$copyDone && $task->checked_at, 'Copied and checked: 0 missing in the bucket', 'Step 6'], [(bool) $csvAt, 'Old → new list downloaded (CSV)', $csvAt ? 'on '.$csvAt : 'Step 6'], [($task?->opt('keep') ?? false) || $backup, 'Originals kept in the bucket, or a backup downloaded', $backup ? 'backup on '.$backup : 'Step 5, or the box below'], [$days >= 14, '14 days of using the new storage', $task?->finished_at ? $days.' days so far' : 'after the copy']] as [$ok, $t, $n])
                        <span class="ds-pst__tr2"><b @class(['ds-pst__ok' => $ok])>{{ $ok ? '✓' : '○' }}</b><span>{{ $t }}</span><small class="ds-pst__mute">{{ $n }}</small></span>
                    @endforeach
                    <label class="ds-pst__tog"><input type="checkbox" @checked($backup) wire:click="markBackup"><span><b>I downloaded a backup of the old photos</b><small>For example with: tar -czf ~/wms-photos-original.tar.gz -C {{ $find['dir'] ?? '…' }}/storage/app public</small></span></label>
                @endif
            </section>
        </div>
    @endif
</div>
</x-filament-panels::page>
