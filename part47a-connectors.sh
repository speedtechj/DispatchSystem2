#!/usr/bin/env bash
#
# Dispatch System — Part 47a · Consolidator connections and Outbox
# Only the files changed in this step; the rest of your project is left as it is.
#
#   cd ~/Desktop/Project/DispatchSystem
#   bash ~/Desktop/Project/part47a-connectors.sh

set -euo pipefail
[ -f artisan ] || { echo "Run this from inside your DispatchSystem project folder (the one with 'artisan')."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="../DispatchSystem-backup-$STAMP.tar.gz"
echo "▶ Backing up the project to $BACKUP"
tar -czf "$BACKUP" --exclude=vendor --exclude=node_modules --exclude=storage/logs .

echo "▶ Writing 19 files"

# ---------------------------------------------------------------- app/Filament/Pages/ConsolidatorConnections.php
mkdir -p 'app/Filament/Pages'
cat > 'app/Filament/Pages/ConsolidatorConnections.php' <<'DISPATCH_FILE_END_0'
<?php

namespace App\Filament\Pages;

use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\Connectors\ConnectorMapping;
use App\Models\Consolidator;
use App\Support\Connectors\Client;
use App\Support\Connectors\Codes;
use App\Support\Connectors\Recorder;
use App\Support\Connectors\Rules;
use App\Support\Connectors\Sender;
use App\Support\Connectors\Suggest;
use BackedEnum;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Livewire\Attributes\Url;
use Throwable;
use UnitEnum;

/**
 * Admin → Settings → Consolidator connections (Part 47, boards 74, 77 and 79).
 * One card per consolidator. Pair with their connector, map our events to their
 * own statuses, set when to send, and watch the Outbox.
 */
class ConsolidatorConnections extends Page
{
    protected string $view = 'filament.pages.consolidator-connections';

    protected static string|UnitEnum|null $navigationGroup = 'Settings';

    protected static string|BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowsRightLeft;

    protected static ?string $navigationLabel = 'Consolidator connections';

    protected static ?string $title = 'Consolidator connections';

    protected static ?string $slug = 'consolidator-connections';

    protected static ?int $navigationSort = 93;

    #[Url]
    public ?int $con = null;

    /** conn · map · rules · outbox */
    #[Url]
    public string $tab = 'conn';

    public string $url = '';

    public string $mode = 'push';

    public string $code = '';

    public string $testBox = '';

    public ?array $testResult = null;

    /** Mapping being edited: key => ['id' => ?int, 'name' => ?string, 'skip' => bool] */
    public array $draft = [];

    public bool $draftChanged = false;

    public ?string $selKey = null;

    public string $statusSearch = '';

    /** @var array<string, bool> */
    public array $rules = [];

    /** Outbox filter */
    public string $filter = 'all';

    public string $boxSearch = '';

    public static function canAccess(): bool
    {
        return (bool) Auth::user()?->hasRole('super_admin');
    }

    public function getSubheading(): ?string
    {
        return 'Our side. One card per consolidator. Their database password is never here: it stays in the connector on their server.';
    }

    public function mount(): void
    {
        $this->con ??= Consolidator::query()->orderBy('company_name')->value('id');
        $this->rules = Rules::all();
        $this->tab = in_array($this->tab, ['conn', 'map', 'rules', 'outbox'], true) ? $this->tab : 'conn';
        $this->loadCon();
    }

    protected function loadCon(): void
    {
        $link = $this->link();
        $this->url = (string) ($link?->url ?? '');
        $this->mode = $link?->mode ?? 'push';
        $this->code = '';
        $this->testResult = null;
        $this->selKey = null;
        $this->loadDraft();
    }

    public function link(): ?ConnectorLink
    {
        return $this->con ? ConnectorLink::query()->where('consolidator_id', $this->con)->first() : null;
    }

    public function pickCon(int $id): void
    {
        if (! Consolidator::query()->whereKey($id)->exists()) {
            return;
        }
        $this->con = $id;
        $this->loadCon();
    }

    public function setTab(string $tab): void
    {
        $this->tab = in_array($tab, ['conn', 'map', 'rules', 'outbox'], true) ? $tab : 'conn';
    }

    // ---------------------------------------------------------------- Connection

    public function saveConnection(): void
    {
        $this->validate([
            'url' => [$this->mode === 'push' ? 'required' : 'nullable', 'url:https,http', 'max:250'],
            'mode' => ['required', 'in:push,pull'],
        ], [], ['url' => 'connector address']);
        $link = ConnectorLink::query()->firstOrNew(['consolidator_id' => $this->con]);
        $link->fill(['url' => $this->url ? Client::base($this->url) : null, 'mode' => $this->mode])->save();
        $this->url = (string) $link->url;
        Notification::make()->title('Saved')->success()->send();
    }

    public function pair(): void
    {
        $this->validate([
            'url' => ['required', 'url:https,http', 'max:250'],
            'code' => ['required', 'string', 'max:20'],
        ], [], ['url' => 'connector address', 'code' => 'pairing code']);
        $con = Consolidator::query()->findOrFail($this->con);
        try {
            $data = Client::pair($this->url, $this->code);
        } catch (Throwable $e) {
            $this->addError('code', 'Not paired: '.$e->getMessage());

            return;
        }
        $about = $data['connector'] ?? [];
        $link = ConnectorLink::query()->firstOrNew(['consolidator_id' => $con->id]);
        $link->fill([
            'url' => Client::base($this->url),
            'mode' => ($about['mode'] ?? 'push') === 'pull' ? 'pull' : 'push',
            'token' => $data['token'], 'secret' => $data['secret'], 'key_id' => $data['key_id'],
            'connector_name' => $about['name'] ?? null, 'version' => $about['version'] ?? null,
            'location_code' => $about['location_code'] ?? null,
            'state' => 'online', 'last_seen_at' => now(), 'paired_at' => now(), 'paired_by' => Auth::id(),
            'fails' => 0, 'paused_at' => null, 'next_try_at' => null, 'last_error' => null,
        ])->save();
        $this->code = '';
        $this->mode = $link->mode;

        $warn = filled($link->location_code) && (string) $link->location_code !== (string) $con->code
            ? " Their connector says location code {$link->location_code}, but {$con->company_name} is {$con->code} here: fix one of them, or every status is refused."
            : '';
        try {
            Sender::refreshStatuses($link);
            Sender::health($link);
            $this->loadDraft();
            $this->suggestAll(false);
        } catch (Throwable $e) {
            $warn .= ' Their statuses could not be read yet: '.$e->getMessage();
        }
        Notification::make()->title('Paired with '.$con->company_name)
            ->body('Token and secret were exchanged by themselves and kept encrypted.'.$warn.' Next: check the Status mapping and Save.')
            ->{$warn ? 'warning' : 'success'}()->persistent()->send();
        $this->tab = 'map';
    }

    public function revoke(): void
    {
        $link = $this->link();
        if (! $link) {
            return;
        }
        $link->forceFill(['token' => null, 'secret' => null, 'key_id' => null, 'state' => 'setup', 'paired_at' => null])->save();
        ConnectorEvent::query()->where('connector_link_id', $link->id)->whereIn('state', ['hold', 'trip', 'ready', 'retry', 'busy'])
            ->update(['state' => 'cancelled', 'message' => 'Pairing revoked', 'updated_at' => now()]);
        Notification::make()->title('Pairing revoked')->body('Nothing more is sent. Pair again with a new code from their connector.')->warning()->send();
    }

    public function toggleOff(): void
    {
        $link = $this->link();
        if (! $link || ! $link->isPaired()) {
            return;
        }
        $link->forceFill(['state' => $link->state === 'off' ? 'online' : 'off'])->save();
        Notification::make()->title($link->state === 'off' ? 'Sending stopped for this consolidator' : 'Sending again')->success()->send();
    }

    public function checkHealth(): void
    {
        $link = $this->link();
        if (! $link?->isPaired()) {
            return;
        }
        if (! $link->isPush()) {
            Notification::make()->title('Pull mode')->body('Their connector asks us every few minutes. Last time: '.($link->last_seen_at?->diffForHumans() ?? 'never').'.')->info()->send();

            return;
        }
        $h = Sender::health($link);
        $h ? Notification::make()->title('Connector answered')->body('Version '.($h['version'] ?? '?').'.')->success()->send()
            : Notification::make()->title('No answer')->body((string) $link->fresh()->last_error)->danger()->send();
    }

    public function checkBox(): void
    {
        $this->validate(['testBox' => ['required', 'string', 'max:40']], [], ['testBox' => 'box number']);
        $link = $this->link();
        if (! $link?->isPaired() || ! $link->isPush()) {
            $this->addError('testBox', 'Needs a paired connector in push mode.');

            return;
        }
        try {
            $t = (new Client($link))->get('/api/v1/track?'.http_build_query(['invoice' => trim($this->testBox)]));
            $row = $t['rows'][0] ?? null;
            $this->testResult = ($t['found'] ?? false)
                ? ['ok' => true, 'text' => 'Found in their CMS: newest status "'.($row['status'] ?? '—').'" ('.($row['date'] ?? '').'), '.count($t['rows'] ?? []).' rows. Nothing was written.']
                : ['ok' => false, 'text' => 'Box '.trim($this->testBox).' is not in their CMS (yet).'];
        } catch (Throwable $e) {
            $this->testResult = ['ok' => false, 'text' => $e->getMessage()];
        }
    }

    // ---------------------------------------------------------------- Status mapping (board 77)

    protected function loadDraft(): void
    {
        $this->draft = [];
        $this->draftChanged = false;
        $link = $this->link();
        if (! $link) {
            return;
        }
        $names = $this->theirNames();
        foreach ($link->mappings()->get() as $m) {
            $this->draft[$m->key] = ['id' => $m->trackstatus_id ? (int) $m->trackstatus_id : null,
                'name' => $m->trackstatus_id ? ($names[$m->trackstatus_id] ?? $m->status_name) : null, 'skip' => (bool) $m->skip, 'tag' => 'Saved'];
        }
        // what the connector already has (mapped on their side), when nothing is saved here
        foreach ($link->statuses['mapping'] ?? [] as $m) {
            $k = $m['key'] ?? null;
            if ($k && ! isset($this->draft[$k]) && (! empty($m['trackstatus_id']) || ! empty($m['skip']))) {
                $this->draft[$k] = ['id' => ! empty($m['trackstatus_id']) ? (int) $m['trackstatus_id'] : null, 'name' => $names[$m['trackstatus_id'] ?? 0] ?? null,
                    'skip' => (bool) ($m['skip'] ?? false), 'tag' => 'On their side'];
            }
        }
        // Nothing saved yet: show the ✨ suggestions (saved only with Save).
        if (! $link->mappings()->exists() && $this->theirStatuses()) {
            $this->suggestAll(false);
        }
    }

    /** @return list<array{id: int, name: string, code: ?string, branch_id: ?int, active: bool}> */
    public function theirStatuses(): array
    {
        $s = $this->link()?->statuses ?? [];
        $ph = $s['ph_branch_id'] ?? null;

        return collect($s['list'] ?? [])->filter(fn ($x) => ($x['active'] ?? true) && ($ph === null || $x['branch_id'] === null || (int) $x['branch_id'] === (int) $ph))
            ->sortBy('id')->values()->all();
    }

    /** @return array<int, string> */
    protected function theirNames(): array
    {
        return collect($this->link()?->statuses['list'] ?? [])->mapWithKeys(fn ($x) => [(int) $x['id'] => (string) $x['name']])->all();
    }

    public function refreshStatuses(): void
    {
        $link = $this->link();
        if (! $link?->isPaired() || ! $link->isPush()) {
            return;
        }
        try {
            $n = count(Sender::refreshStatuses($link));
            Notification::make()->title("Read $n statuses from their CMS")->success()->send();
        } catch (Throwable $e) {
            Notification::make()->title('Could not read their statuses')->body($e->getMessage())->danger()->send();
        }
    }

    public function selectRow(string $key): void
    {
        $this->selKey = $key;
        $this->statusSearch = '';
    }

    public function pickStatus(int $id): void
    {
        if (! $this->selKey) {
            return;
        }
        $name = $this->theirNames()[$id] ?? null;
        if ($name === null) {
            return;
        }
        $this->draft[$this->selKey] = ['id' => $id, 'name' => $name, 'skip' => false, 'tag' => 'Changed'];
        $this->draftChanged = true;
        $this->selKey = $this->nextEmpty($this->selKey);
    }

    public function skipRow(): void
    {
        if ($this->selKey) {
            $this->draft[$this->selKey] = ['id' => null, 'name' => null, 'skip' => true, 'tag' => 'Changed'];
            $this->draftChanged = true;
        }
    }

    public function clearRow(): void
    {
        if ($this->selKey) {
            unset($this->draft[$this->selKey]);
            $this->draftChanged = true;
        }
    }

    /** ✨ Fill every empty row with its best match (not saved until Save). */
    public function suggestAll(bool $notify = true): void
    {
        $list = $this->theirStatuses();
        $n = 0;
        foreach (Codes::rows() as $r) {
            if (isset($this->draft[$r['key']])) {
                continue;
            }
            $best = Suggest::for($r['code'], $r['place'], $list)[0] ?? null;
            // a place row is only worth its own line when the place name is in their status
            if ($best && ($r['place'] === null || str_contains(Str::lower($best['name']), Str::lower((string) $r['place'])))) {
                $this->draft[$r['key']] = ['id' => $best['id'], 'name' => $best['name'], 'skip' => false, 'tag' => 'Suggested'];
                $n++;
            }
        }
        $this->draftChanged = $this->draftChanged || $n > 0;
        $notify && Notification::make()->title($n ? "$n suggestions: check them, then Save" : 'No new suggestions')->info()->send();
    }

    public function clearAll(): void
    {
        $this->draft = [];
        $this->draftChanged = true;
    }

    public function saveMapping(): void
    {
        $link = $this->link();
        if (! $link) {
            return;
        }
        $known = collect(Codes::rows())->pluck('key')->all();
        DB::transaction(function () use ($link, $known) {
            ConnectorMapping::query()->where('connector_link_id', $link->id)->delete();
            foreach ($this->draft as $key => $d) {
                if (! in_array($key, $known, true) || (! $d['skip'] && ! $d['id'])) {
                    continue;
                }
                ConnectorMapping::query()->create(['connector_link_id' => $link->id, 'key' => $key,
                    'trackstatus_id' => $d['skip'] ? null : $d['id'], 'status_name' => $d['skip'] ? null : $d['name'], 'skip' => (bool) $d['skip']]);
            }
        });
        $text = 'Saved here.';
        if ($link->isPaired() && $link->isPush()) {
            try {
                $r = Sender::pushMapping($link);
                $text = "Saved here and on their connector ({$r['saved']} rows). ".($r['retried'] ? "{$r['retried']} statuses that waited for a mapping were written now." : '');
            } catch (Throwable $e) {
                Notification::make()->title('Saved here, but their connector did not take it')->body($e->getMessage())->danger()->persistent()->send();
                $this->loadDraft();

                return;
            }
        } elseif (! $link->isPush()) {
            $text = 'Saved here. Pull mode: set the same on their connector (Admin → Status mapping), it cannot be sent from here.';
        }
        $this->loadDraft();
        Notification::make()->title('Mapping saved')->body($text)->success()->send();
    }

    protected function nextEmpty(string $after): ?string
    {
        $keys = collect(Codes::rows())->pluck('key')->all();
        $i = array_search($after, $keys, true);
        foreach (array_slice($keys, $i === false ? 0 : $i + 1) as $k) {
            if (! isset($this->draft[$k])) {
                return $k;
            }
        }

        return null;
    }

    // ---------------------------------------------------------------- Rules

    public function toggleRule(string $key): void
    {
        if (array_key_exists($key, Rules::ALL)) {
            $this->rules[$key] = ! ($this->rules[$key] ?? false);
            Rules::save($this->rules);
            $this->rules = Rules::all();
        }
    }

    // ---------------------------------------------------------------- Outbox (board 79)

    public function setFilter(string $f): void
    {
        $this->filter = $f;
    }

    public function sendNow(): void
    {
        $link = $this->link();
        if (! $link?->isPaired()) {
            return;
        }
        $r = Sender::sendNow($link);
        $r['error']
            ? Notification::make()->title('Not sent')->body($r['error'].' · They wait in the Outbox and go by themselves later.')->danger()->send()
            : Notification::make()->title($link->isPush() ? "Sent {$r['sent']} · {$r['saved']} saved in their CMS" : 'Ready for their connector (pull)')->success()->send();
    }

    public function tryNow(): void
    {
        $link = $this->link();
        if (! $link?->isPaired()) {
            return;
        }
        $link->forceFill(['next_try_at' => null])->save();
        if ($link->isPush() && ! Sender::health($link)) {
            Notification::make()->title('Still no answer')->body((string) $link->fresh()->last_error)->danger()->send();

            return;
        }
        $this->sendNow();
    }

    public function resendFailed(): void
    {
        $link = $this->link();
        if ($link) {
            $n = Sender::resendFailed($link);
            Notification::make()->title("$n statuses will be sent again")->success()->send();
            $link->isPush() && $n && $this->sendNow();
        }
    }

    public function rowAction(int $id): void
    {
        $e = ConnectorEvent::query()->where('connector_link_id', $this->link()?->id)->find($id);
        if (! $e) {
            return;
        }
        if (in_array($e->state, ['hold', 'trip', 'ready'], true)) {
            $e->update(['state' => 'cancelled', 'message' => 'Cancelled by '.Auth::user()?->full_name.' before sending']);
            Notification::make()->title('Cancelled before sending: their CMS never sees it')->success()->send();
        } elseif ($e->state === 'needs_mapping') {
            $this->tab = 'map';
            $this->selKey = Codes::key($e->code, $e->place);
            if (! collect(Codes::rows())->contains('key', $this->selKey)) {
                $this->selKey = $e->code;
            }
        } elseif ($e->state === 'saved' && ! $e->corrects && ! $e->undone_by) {
            $u = Recorder::undo($e, Auth::user(), 'Undone in Outbox by '.Auth::user()?->full_name);
            Notification::make()->title($u ? 'Undo made: it goes first' : 'Nothing to undo')->success()->send();
        } elseif (in_array($e->state, ['failed', 'retry', 'busy', 'not_found', 'refused'], true)) {
            $e->update(['state' => 'ready', 'next_try_at' => null]);
            Notification::make()->title('It will be sent again')->success()->send();
        }
    }

    // ---------------------------------------------------------------- view

    protected function getViewData(): array
    {
        $cons = Consolidator::query()->orderBy('company_name')->get(['id', 'company_name', 'code']);
        $links = ConnectorLink::query()->get()->keyBy('consolidator_id');
        $counts = ConnectorEvent::query()->selectRaw("connector_link_id as l,
                sum(case when state = 'saved' and updated_at >= ? then 1 else 0 end) as today,
                sum(case when state = 'hold' then 1 else 0 end) as hold,
                sum(case when state in ('ready','retry','busy','trip') then 1 else 0 end) as waiting,
                sum(case when state = 'needs_mapping' then 1 else 0 end) as map", [today()])
            ->groupBy('connector_link_id')->get()->keyBy('l');

        $link = $this->link();
        $con = $cons->firstWhere('id', $this->con);

        return [
            'cards' => $cons->map(function ($c) use ($links, $counts) {
                $l = $links->get($c->id);
                $n = $l ? $counts->get($l->id) : null;

                return ['id' => $c->id, 'code' => $c->code, 'name' => $c->company_name, 'link' => $l,
                    'state' => $l ? ($l->isPaired() ? $l->stateLabel() : 'Setup') : 'No connector',
                    'sub' => $l ? ($l->isPaired() ? trim(($l->version ? 'Connector '.$l->version.' · ' : '').$l->mode.($l->url ? ' · '.parse_url($l->url, PHP_URL_HOST) : '')) : 'Not paired yet') : 'not connected yet',
                    'nums' => [
                        [(int) ($n->today ?? 0), 'sent today', ''],
                        [(int) ($n->hold ?? 0), 'in hold', ''],
                        [(int) ($n->waiting ?? 0), 'waiting', ($n->waiting ?? 0) > 0 && in_array($l?->state, ['paused', 'offline'], true) ? 'is-warn' : ''],
                        [(int) ($n->map ?? 0), 'need map', ($n->map ?? 0) > 0 ? 'is-bad' : ''],
                    ]];
            }),
            'cur' => $con,
            'link' => $link,
            'needs' => $link ? (int) ($counts->get($link->id)->map ?? 0) : 0,
            'scheduleOk' => (int) \Illuminate\Support\Facades\Cache::get('connectors.schedule.seen', 0) > time() - 600,
        ] + match ($this->tab) {
            'map' => $this->mapView($link),
            'outbox' => $this->outboxView($link),
            default => [],
        };
    }

    protected function mapView(?ConnectorLink $link): array
    {
        $list = $this->theirStatuses();
        $rows = collect(Codes::rows())->map(function ($r) {
            $d = $this->draft[$r['key']] ?? null;

            return $r + ['their' => $d ? ($d['skip'] ? 'Don\'t send' : '#'.$d['id'].' '.$d['name']) : null,
                'tag' => $d['tag'] ?? ($r['place'] ? 'Uses "any place"' : 'Needs mapping'), 'skip' => $d['skip'] ?? false, 'set' => (bool) $d];
        });
        $sel = $this->selKey ? $rows->firstWhere('key', $this->selKey) : null;
        $q = Str::lower(trim($this->statusSearch));

        return [
            'groups' => $rows->groupBy('group'),
            'sel' => $sel,
            'suggest' => $sel ? collect(Suggest::for($sel['code'], $sel['place'], $list))->map(fn ($s) => $s + ['pct' => Suggest::percent($s['score'])]) : collect(),
            'statuses' => collect($list)->filter(fn ($s) => $q === '' || str_contains(Str::lower($s['name']), $q) || (string) $s['id'] === $q),
            'nMapped' => collect($this->draft)->filter(fn ($d) => $d['id'] && ! $d['skip'])->count(),
            'nSkip' => collect($this->draft)->where('skip', true)->count(),
            'nEmpty' => $rows->whereNull('place')->where('set', false)->count(),
        ];
    }

    protected function outboxView(?ConnectorLink $link): array
    {
        if (! $link) {
            return ['rows' => collect(), 'filters' => []];
        }
        $base = ConnectorEvent::query()->where('connector_link_id', $link->id)->where('created_at', '>=', now()->subDays(7));
        $groups = [
            'all' => ['All', null],
            'hold' => ['In hold', ['hold', 'trip']],
            'waiting' => ['Waiting', ['ready', 'not_found', 'sent']],
            'retry' => ['Will retry', ['retry', 'busy', 'failed']],
            'map' => ['Needs mapping', ['needs_mapping']],
            'sent' => ['Saved', ['saved']],
            'skipped' => ['Skipped', ['skipped', 'refused', 'cancelled']],
        ];
        $byState = (clone $base)->selectRaw('state, count(*) as n')->groupBy('state')->pluck('n', 'state');
        $filters = collect($groups)->map(fn ($g, $k) => ['k' => $k, 't' => $g[0], 'n' => $g[1] ? $byState->only($g[1])->sum() : $byState->sum()]);
        $states = $groups[$this->filter][1] ?? null;
        $box = trim($this->boxSearch);
        $rows = (clone $base)
            ->when($states, fn ($q) => $q->whereIn('state', $states))
            ->when($box !== '', fn ($q) => $q->where('invoice', 'like', '%'.$box.'%'))
            ->orderByRaw("case when state in ('hold','trip','ready','retry','busy') then 0 else 1 end")
            ->orderBy('priority')->orderByDesc('id')->limit(150)->get();
        $names = $this->theirNames();

        return [
            'filters' => $filters->values(),
            'rows' => $rows->map(fn (ConnectorEvent $e) => [
                'id' => $e->id, 'at' => $e->created_at, 'box' => $e->invoice, 'ev' => ($e->corrects ? 'Undo → ' : '').$e->label,
                'their' => $e->trackstatus_id ? '#'.$e->trackstatus_id.' '.($names[$e->trackstatus_id] ?? '') : ($e->state === 'needs_mapping' ? '— not mapped —' : ''),
                'who' => implode(' · ', array_filter([$e->payload['by']['name'] ?? null, $e->payload['by']['role'] ?? null, filled($e->payload['trip'] ?? null) ? 'Trip '.$e->payload['trip'] : null, $e->manual ? 'manual' : null])),
                'state' => $e->state, 'sends' => Sender::sendsAt($e), 'msg' => $e->message, 'row' => $e->row_id, 'ms' => $e->took_ms,
                'prio' => $e->priority === 1, 'undone' => (bool) $e->undone_by, 'undo' => (bool) $e->corrects,
            ]),
        ];
    }
}
DISPATCH_FILE_END_0

# ---------------------------------------------------------------- app/Http/Controllers/ConnectorApiController.php
mkdir -p 'app/Http/Controllers'
cat > 'app/Http/Controllers/ConnectorApiController.php' <<'DISPATCH_FILE_END_1'
<?php

namespace App\Http\Controllers;

use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Support\Connectors\Rules;
use App\Support\Connectors\Sender;
use App\Support\Connectors\Signer;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;
use Illuminate\Support\Facades\DB;

/**
 * What a consolidator's connector calls on Dispatch System (Part 47).
 * Pull mode: GET events, POST results. Both modes: GET hello.
 * Every request is signed with the pairing secret (X-Connector-Key / -Time / -Signature);
 * every answer is signed too (METHOD = RESPONSE, the path without the query).
 */
class ConnectorApiController extends Controller
{
    /** GET /api/connector/v1/events?after=CURSOR&limit=100 */
    public function events(Request $request): Response
    {
        $link = $this->check($request);
        if ($link instanceof Response) {
            return $link;
        }
        Sender::releaseHeld();
        Sender::resendLost();
        $limit = max(1, min(Rules::BATCH, (int) $request->query('limit', 100)));
        $rows = Sender::waiting($link)->orderBy('priority')->orderBy('id')->limit($limit + 1)->get();
        $more = $rows->count() > $limit;
        $rows = $rows->take($limit);
        $events = $rows->map(fn (ConnectorEvent $e) => Sender::payload($e))->values()->all();
        if ($rows->isNotEmpty()) {
            ConnectorEvent::query()->whereKey($rows->modelKeys())->update(['state' => 'sent', 'sent_at' => now(), 'tries' => DB::raw('tries + 1'), 'updated_at' => now()]);
        }
        $cursor = max((int) $link->pull_cursor, (int) ($rows->max('id') ?? 0));
        $link->forceFill(['pull_cursor' => $cursor, 'state' => 'online', 'last_seen_at' => now(), 'fails' => 0, 'paused_at' => null])->save();

        return $this->answer($request, ['events' => $events, 'cursor' => (string) $cursor, 'more' => $more]);
    }

    /** POST /api/connector/v1/results  {results: [...]} */
    public function results(Request $request): Response
    {
        $link = $this->check($request);
        if ($link instanceof Response) {
            return $link;
        }
        $results = $request->json('results');
        $n = Sender::applyResults($link, is_array($results) ? $results : []);
        $link->forceFill(['last_seen_at' => now(), 'last_results_at' => now()])->save();

        return $this->answer($request, ['ok' => true, 'applied' => $n]);
    }

    /** GET /api/connector/v1/hello (asked every hour): newest connector version and what we offer. */
    public function hello(Request $request): Response
    {
        $link = $this->check($request);
        if ($link instanceof Response) {
            return $link;
        }
        $link->forceFill(['last_seen_at' => now()] + ($link->state === 'setup' ? ['state' => 'online'] : []))->save();

        return $this->answer($request, [
            'latest_version' => (string) config('connectors.latest_version', '2.5.0'),
            'min_version' => (string) config('connectors.min_version', '2.0.0'),
            'features' => ['explain' => false],
        ]);
    }

    /** The key id, a fresh time and a valid signature, or a refusal. */
    protected function check(Request $request): ConnectorLink|Response
    {
        $key = (string) $request->header(Signer::KEY);
        $link = $key === '' ? null : ConnectorLink::query()->where('key_id', $key)->first();
        if (! $link || blank($link->secret) || $link->state === 'off') {
            return response()->json(['message' => 'Unknown key'], 401);
        }
        $time = (string) $request->header(Signer::TIME);
        if (! ctype_digit($time) || abs(time() - (int) $time) > Signer::WINDOW) {
            return response()->json(['message' => 'Request too old or clock off'], 401);
        }
        if (! Signer::valid((string) $link->secret, $request->header(Signer::SIGN), (int) $time, $request->method(), $request->getRequestUri(), $request->getContent())) {
            return response()->json(['message' => 'Bad signature'], 401);
        }
        if ($link->mode !== 'pull' && $request->is('api/connector/v1/events')) {
            $link->forceFill(['mode' => 'pull'])->save(); // their connector is set to pull: follow it
        }
        $request->attributes->set('connector_link', $link);

        return $link;
    }

    protected function answer(Request $request, array $data): Response
    {
        $link = $request->attributes->get('connector_link');
        $body = json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        $time = time();

        return response($body, 200, [
            'Content-Type' => 'application/json',
            Signer::TIME => (string) $time,
            Signer::SIGN => Signer::make((string) $link->secret, $time, 'RESPONSE', '/'.ltrim($request->path(), '/'), $body),
        ]);
    }
}
DISPATCH_FILE_END_1

# ---------------------------------------------------------------- app/Models/Connectors/ConnectorEvent.php
mkdir -p 'app/Models/Connectors'
cat > 'app/Models/Connectors/ConnectorEvent.php' <<'DISPATCH_FILE_END_2'
<?php

namespace App\Models\Connectors;

use App\Models\Invoice;
use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** One status in the Outbox (Part 47): made here first, then sent to the connector. */
class ConnectorEvent extends Model
{
    protected $guarded = ['id'];

    /** States that are finished: nothing more is sent. */
    public const DONE = ['saved', 'skipped', 'refused', 'cancelled'];

    /** States the connector keeps and retries by itself (we only read the result later). */
    public const AT_CONNECTOR = ['needs_mapping', 'not_found', 'failed', 'sent'];

    protected function casts(): array
    {
        return [
            'payload' => 'array',
            'manual' => 'boolean',
            'send_after' => 'datetime',
            'next_try_at' => 'datetime',
            'sent_at' => 'datetime',
            'happened_at' => 'datetime',
        ];
    }

    public function link(): BelongsTo
    {
        return $this->belongsTo(ConnectorLink::class, 'connector_link_id');
    }

    public function invoiceRow(): BelongsTo
    {
        return $this->belongsTo(Invoice::class, 'invoice_id');
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    public function isUndo(): bool
    {
        return filled($this->corrects);
    }
}
DISPATCH_FILE_END_2

# ---------------------------------------------------------------- app/Models/Connectors/ConnectorLink.php
mkdir -p 'app/Models/Connectors'
cat > 'app/Models/Connectors/ConnectorLink.php' <<'DISPATCH_FILE_END_3'
<?php

namespace App\Models\Connectors;

use App\Models\Consolidator;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * One consolidator's connector (Part 47). The token and secret come from the
 * pairing and are kept encrypted; they are never shown again.
 */
class ConnectorLink extends Model
{
    protected $guarded = ['id'];

    protected $hidden = ['token', 'secret'];

    protected function casts(): array
    {
        return [
            'token' => 'encrypted',
            'secret' => 'encrypted',
            'health' => 'array',
            'statuses' => 'array',
            'statuses_at' => 'datetime',
            'last_seen_at' => 'datetime',
            'last_results_at' => 'datetime',
            'paused_at' => 'datetime',
            'next_try_at' => 'datetime',
            'mailed_at' => 'datetime',
            'paired_at' => 'datetime',
        ];
    }

    protected static function booted(): void
    {
        static::saved(fn () => \App\Support\Connectors\Recorder::forgetLinks());
        static::deleted(fn () => \App\Support\Connectors\Recorder::forgetLinks());
    }

    public function consolidator(): BelongsTo
    {
        return $this->belongsTo(Consolidator::class);
    }

    public function mappings(): HasMany
    {
        return $this->hasMany(ConnectorMapping::class);
    }

    public function events(): HasMany
    {
        return $this->hasMany(ConnectorEvent::class);
    }

    public function isPaired(): bool
    {
        return filled($this->key_id) && filled($this->secret);
    }

    public function isPush(): bool
    {
        return $this->mode !== 'pull';
    }

    /** Shown on the cards: Online, Offline, Paused, Setup, Off. */
    public function stateLabel(): string
    {
        return match ($this->state) {
            'online' => 'Online',
            'offline' => 'Offline',
            'paused' => 'Paused',
            'off' => 'Off',
            default => $this->isPaired() ? 'Paired' : 'Setup',
        };
    }
}
DISPATCH_FILE_END_3

# ---------------------------------------------------------------- app/Models/Connectors/ConnectorMapping.php
mkdir -p 'app/Models/Connectors'
cat > 'app/Models/Connectors/ConnectorMapping.php' <<'DISPATCH_FILE_END_4'
<?php

namespace App\Models\Connectors;

use Illuminate\Database\Eloquent\Model;

/** Our event (code or code@place) → the consolidator's own status (Part 47). */
class ConnectorMapping extends Model
{
    protected $guarded = ['id'];

    protected function casts(): array
    {
        return ['skip' => 'boolean'];
    }
}
DISPATCH_FILE_END_4

# ---------------------------------------------------------------- app/Support/AppHooks.php
mkdir -p 'app/Support'
cat > 'app/Support/AppHooks.php' <<'DISPATCH_FILE_END_5'
<?php

namespace App\Support;

use App\Models\Container;
use App\Models\DeliveryAttempt;
use App\Models\Tripinvoice;
use App\Livewire\HelpDrawer;
use App\Support\Help\Help;
use App\Support\Maps\SortQueue;
use App\Support\Sms\SmsEvents;
use Filament\Support\Facades\FilamentView;
use Filament\View\PanelsRenderHook;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Blade;
use Illuminate\Support\Facades\Schema;
use Livewire\Livewire;

/**
 * App-wide hooks that do not belong to one panel. Registered from
 * DeliveryPanelProvider::boot() so no shared provider file needs changing.
 */
class AppHooks
{
    public static function register(): void
    {
        // Browser tab icon for all four panels (Admin → App icon & favicon).
        FilamentView::registerRenderHook(
            PanelsRenderHook::HEAD_END,
            fn (): string => view('pwa.favicon', ['url' => Pwa::faviconUrl(), 'version' => Pwa::faviconVersion()])->render(),
        );

        // Help guide: the "?" in the top bar (Admin, Warehouse, Partner hub) and the help panel it opens.
        // The Scan app and the Driver app have their own "?" in the screen header.
        Livewire::component('help-drawer', HelpDrawer::class);
        FilamentView::registerRenderHook(
            PanelsRenderHook::USER_MENU_BEFORE,
            fn (): string => in_array(Help::currentApp(), ['admin', 'warehouse', 'company'], true) && Auth::check() && Help::ready()
                ? view('filament.help.topbar-button', ['tl' => Help::lang() === 'tl'])->render() : '',
        );
        FilamentView::registerRenderHook(
            PanelsRenderHook::BODY_END,
            fn (): string => Auth::check() && Help::ready()
                ? Blade::render('@livewire(\'help-drawer\', [\'app\' => $app, \'route\' => $route], key(\'help-drawer\'))', ['app' => Help::currentApp(), 'route' => request()->route()?->getName()])
                : '',
        );

        // Remember when a container is marked unloaded (for the Containers widget).
        Container::saving(function (Container $container): void {
            if ($container->isDirty('is_unloaded') && Schema::hasColumn('containers', 'unloaded_at')) {
                $container->unloaded_at = $container->is_unloaded ? now() : null;
            }
        });

        // Maps & routes: a trip is sorted again when boxes are added to it or taken off it.
        // SMS to receivers: right after the page has answered, so nobody waits for the text.
        $sms = function (callable $job): void {
            if (app()->runningUnitTests()) {
                return; // tests call SmsEvents directly
            }
            app()->terminating(function () use ($job) {
                try {
                    if (Schema::hasTable('sms_messages')) {
                        $job();
                    }
                } catch (\Throwable $e) {
                    report($e);
                }
            });
        };
        Tripinvoice::saved(function (Tripinvoice $box) use ($sms): void {
            if ($box->is_delivered && $box->wasChanged('is_delivered')) {
                $sms(fn () => SmsEvents::delivered($box->fresh()));
            }
            if ($box->logistichub_id && $box->wasChanged('logistichub_id')) {
                $sms(fn () => SmsEvents::hubArrived($box->fresh()));
            }
        });
        DeliveryAttempt::created(fn ($a) => $sms(fn () => SmsEvents::notDelivered($a)));

        // Part 47: what happens here becomes a status in the Outbox for the consolidator's connector.
        \App\Support\Connectors\Hooks::register();

        // Dashboard box counts are kept 60 seconds; forget them when boxes change.
        Tripinvoice::saved(fn () => HubBoxes::forget());
        Tripinvoice::deleted(fn () => HubBoxes::forget());
        DeliveryAttempt::created(fn () => HubBoxes::forget());

        Tripinvoice::saved(function (Tripinvoice $box): void {
            if ($box->wasRecentlyCreated || $box->wasChanged(['deliverylog_id', 'deliveryloghub_id'])) {
                SortQueue::touch($box->deliverylog_id, $box->deliveryloghub_id, $box->getOriginal('deliverylog_id'), $box->getOriginal('deliveryloghub_id'));
            }
        });
        Tripinvoice::deleted(fn (Tripinvoice $box) => SortQueue::touch($box->deliverylog_id, $box->deliveryloghub_id));
    }
}
DISPATCH_FILE_END_5

# ---------------------------------------------------------------- app/Support/Connectors/Client.php
mkdir -p 'app/Support/Connectors'
cat > 'app/Support/Connectors/Client.php' <<'DISPATCH_FILE_END_6'
<?php

namespace App\Support\Connectors;

use App\Models\Connectors\ConnectorLink;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\Http;
use RuntimeException;

/** Calls a consolidator's connector (push mode). Every call is signed. */
class Client
{
    public function __construct(protected ConnectorLink $link) {}

    public static function base(string $url): string
    {
        $url = rtrim(trim($url), '/');

        return preg_replace('#/api/v1$#', '', $url);
    }

    /**
     * Pair with the code shown on their connector. Returns the connector's answer
     * (token, secret, key_id, connector{…}); the caller stores it encrypted.
     *
     * @return array<string, mixed>
     */
    public static function pair(string $url, string $code): array
    {
        try {
            $res = Http::acceptJson()->timeout(20)->post(static::base($url).'/api/v1/pair', [
                'code' => strtoupper(trim($code)),
                'dispatch_url' => rtrim((string) config('app.url'), '/'),
                'dispatch_name' => (string) config('app.name', 'Dispatch System'),
            ]);
        } catch (\Illuminate\Http\Client\ConnectionException $e) {
            throw new RuntimeException(static::short($e->getMessage()), 0, $e);
        }
        if ($res->status() !== 201) {
            throw new RuntimeException($res->json('message') ?: 'The connector answered HTTP '.$res->status());
        }
        $data = $res->json();
        foreach (['token', 'secret', 'key_id'] as $k) {
            if (blank($data[$k] ?? null)) {
                throw new RuntimeException('The connector did not send a '.$k);
            }
        }

        return $data;
    }

    /** @return array<mixed> */
    public function get(string $path, int $timeout = 20): array
    {
        return $this->call('GET', $path, null, $timeout)->json() ?? [];
    }

    /** @return array<mixed> */
    public function send(string $method, string $path, array $data, int $timeout = 30): array
    {
        return $this->call($method, $path, $data, $timeout)->json() ?? [];
    }

    /** The raw answer (Sender reads Retry-After and HTTP 503 itself). */
    public function call(string $method, string $path, ?array $data = null, int $timeout = 30): Response
    {
        if (! $this->link->isPaired() || blank($this->link->token)) {
            throw new RuntimeException('Not paired yet');
        }
        if (blank($this->link->url)) {
            throw new RuntimeException('No connector address (pull mode: their connector asks us)');
        }
        $url = static::base($this->link->url).$path;
        $body = $data === null ? '' : json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        $time = time();
        $req = Http::withToken((string) $this->link->token)->acceptJson()->timeout($timeout)->connectTimeout(8)->withHeaders([
            Signer::TIME => (string) $time,
            Signer::SIGN => Signer::make((string) $this->link->secret, $time, $method, Signer::pathOf($url), $body),
        ]);
        try {
            $res = match ($method) {
                'GET' => $req->get($url),
                default => $req->withBody($body, 'application/json')->send($method, $url),
            };
        } catch (\Illuminate\Http\Client\ConnectionException $e) {
            throw new RuntimeException(static::short($e->getMessage()), 0, $e);
        }
        if ($res->status() === 401) {
            throw new RuntimeException('The connector refused our token or signature: '.($res->json('message') ?: 'HTTP 401'));
        }
        if (! $res->successful() && $res->status() !== 503) {
            throw new RuntimeException($res->json('message') ?: 'The connector answered HTTP '.$res->status());
        }

        return $res;
    }

    /** A cURL error in plain words. */
    public static function short(string $error): string
    {
        return match (true) {
            str_contains($error, 'cURL error 6') => 'The connector address was not found (DNS)',
            str_contains($error, 'cURL error 7') => 'Could not connect to the connector (server down or port closed)',
            str_contains($error, 'cURL error 28') => 'The connector did not answer in time',
            str_contains($error, 'cURL error 35'), str_contains($error, 'cURL error 60') => 'HTTPS problem on the connector (certificate)',
            default => mb_substr($error, 0, 160),
        };
    }
}
DISPATCH_FILE_END_6

# ---------------------------------------------------------------- app/Support/Connectors/Codes.php
mkdir -p 'app/Support/Connectors'
cat > 'app/Support/Connectors/Codes.php' <<'DISPATCH_FILE_END_7'
<?php

namespace App\Support\Connectors;

use App\Models\Logistichub;
use App\Models\Warehouse;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * The events Dispatch System sends (docs/PROTOCOL.md of the connector). The
 * list is ours; each consolidator maps every one to their own status.
 */
class Codes
{
    /**
     * code => [label, group, place kind, when it is sent]
     * place kind: warehouse | hub | partner | island | null (no place)
     * when: hold (10-minute hold) | trip (when the trip leaves) | now
     */
    public const ALL = [
        'ds.unloaded' => ['Unload container', 'Warehouse', 'warehouse', 'hold'],
        'ds.transfer' => ['Transfer to warehouse / hub', 'Warehouse', 'hub', 'hold'],
        'ds.return_to_warehouse' => ['Return to warehouse', 'Warehouse', 'warehouse', 'hold'],
        'ds.to_port' => ['Sea shipment · to port', 'Sea shipment', 'island', 'hold'],
        'ds.sailing' => ['Sea shipment · sailing', 'Sea shipment', 'island', 'now'],
        'ds.arrived_port' => ['Sea shipment · arrived', 'Sea shipment', 'island', 'now'],
        'ds.partner_hub' => ['Arrived at partner hub', 'Partner hub', 'partner', 'hold'],
        'ds.load.1' => ['Load on truck · 1st try', 'Delivery', null, 'trip'],
        'ds.load.2' => ['Load on truck · 2nd try', 'Delivery', null, 'trip'],
        'ds.load.3' => ['Load on truck · 3rd try', 'Delivery', null, 'trip'],
        'ds.back_to_hub.2' => ['Not delivered · back to hub (2nd try next)', 'Delivery', null, 'hold'],
        'ds.back_to_hub.3' => ['Not delivered · back to hub (3rd try next)', 'Delivery', null, 'hold'],
        'ds.waiting_next_try' => ['Waiting at hub for next try', 'Delivery', null, 'hold'],
        'ds.delivered' => ['Delivered', 'Delivery', null, 'hold'],
        'ds.delivered_damaged' => ['Delivered · damaged (signed)', 'Delivery', null, 'hold'],
        'ds.correction' => ['Correction (undo, no earlier status)', 'Other', null, 'now'],
    ];

    public static function label(string $code, ?string $place = null): string
    {
        $l = static::ALL[$code][0] ?? $code;

        return $place ? $l.' · '.$place : $l;
    }

    public static function when(string $code): string
    {
        return static::ALL[$code][3] ?? 'hold';
    }

    /** The mapping key the connector uses: code, or code@place (place in lower case, spaces → _). */
    public static function key(string $code, ?string $place): string
    {
        $slug = $place === null ? '' : Str::slug($place, '_');

        return $slug === '' || $slug === 'any' ? $code : $code.'@'.$slug;
    }

    /** Places for a place kind (the rows of the mapping table). @return list<string> */
    public static function places(?string $kind): array
    {
        static $memo = [];
        if ($kind === null) {
            return [];
        }

        return $memo[$kind] ??= match ($kind) {
            'warehouse' => Warehouse::query()->orderBy('name')->pluck('name')->filter()->values()->all(),
            'hub' => array_values(array_unique(array_merge(
                Warehouse::query()->orderBy('name')->pluck('name')->filter()->all(),
                Logistichub::query()->where('is_company', false)->orderBy('hub_name')->pluck('hub_name')->filter()->all(),
            ))),
            'partner' => Logistichub::query()->where('is_company', true)->orderBy('hub_name')->pluck('hub_name')->filter()->values()->all(),
            'island' => Schema::hasColumn('logistichubs', 'island')
                ? Logistichub::query()->whereNotNull('island')->distinct()->orderBy('island')->pluck('island')->map(fn ($i) => Str::title((string) $i))->filter()->values()->all()
                : [],
            default => [],
        };
    }

    /**
     * Every row of the mapping table: one "any place" row per code, plus one per place.
     *
     * @return list<array{key: string, code: string, place: ?string, label: string, group: string}>
     */
    public static function rows(): array
    {
        $rows = [];
        foreach (static::ALL as $code => [$label, $group, $kind]) {
            foreach (static::places($kind) as $p) {
                $rows[] = ['key' => static::key($code, $p), 'code' => $code, 'place' => $p, 'label' => $label, 'group' => $group];
            }
            $rows[] = ['key' => $code, 'code' => $code, 'place' => null, 'label' => $label, 'group' => $group];
        }

        return $rows;
    }
}
DISPATCH_FILE_END_7

# ---------------------------------------------------------------- app/Support/Connectors/Hooks.php
mkdir -p 'app/Support/Connectors'
cat > 'app/Support/Connectors/Hooks.php' <<'DISPATCH_FILE_END_8'
<?php

namespace App\Support\Connectors;

use App\Models\DeliveryAttempt;
use App\Models\DeliveryReversal;
use App\Models\DeliverySignature;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Shipping\SeaShipment;
use App\Models\Shipping\TruckReceiptScan;
use App\Models\Tripinvoice;
use App\Models\Warehouse;
use App\Models\Whtripinvoice;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;
use Throwable;

/**
 * Part 47: what happens in Dispatch System becomes a status in the Outbox.
 * A hook never stops a scan: any error is only reported.
 */
class Hooks
{
    public static function register(): void
    {
        Invoice::saved(fn (Invoice $i) => static::safe(fn () => static::invoiceSaved($i)));
        Whtripinvoice::saved(fn (Whtripinvoice $w) => static::safe(fn () => static::transferSaved($w)));
        Tripinvoice::saved(fn (Tripinvoice $t) => static::safe(fn () => static::tripBoxSaved($t)));
        Tripinvoice::deleted(fn (Tripinvoice $t) => static::safe(fn () => Recorder::cancelWaiting('load:'.$t->id)));
        DeliveryAttempt::created(fn (DeliveryAttempt $a) => static::safe(fn () => static::notDelivered($a)));
        DeliveryReversal::created(fn (DeliveryReversal $r) => static::safe(fn () => static::undoDelivery($r)));
        Deliverylog::updated(function (Deliverylog $trip): void {
            if ($trip->taken_at && $trip->wasChanged('taken_at') && ! $trip->getOriginal('taken_at')) {
                static::safe(fn () => Recorder::tripLeft($trip));
            }
        });
        if (class_exists(SeaShipment::class)) {
            SeaShipment::updated(fn (SeaShipment $s) => static::safe(fn () => static::seaShipment($s)));
        }
        if (class_exists(TruckReceiptScan::class)) {
            TruckReceiptScan::created(fn (TruckReceiptScan $s) => static::safe(fn () => static::hubReceived($s)));
        }
    }

    protected static function safe(callable $fn): void
    {
        try {
            if (Recorder::ready() && Recorder::links()) {
                $fn();
            }
        } catch (Throwable $e) {
            report($e);
        }
    }

    /** Unload: the box was scanned out of the container. */
    protected static function invoiceSaved(Invoice $i): void
    {
        if (! $i->wasChanged('is_verified') || ! Recorder::linkIdFor($i->location_code)) {
            return;
        }
        if ($i->is_verified && $i->verified_at) {
            $wh = $i->warehouse_id ? Warehouse::query()->whereKey($i->warehouse_id)->value('name') : null;
            $wh ??= $i->container?->warehouse_id ? Warehouse::query()->whereKey($i->container->warehouse_id)->value('name') : null;
            Recorder::record($i, 'ds.unloaded', $wh, [
                'at' => $i->verified_at, 'user' => $i->verified_by ? (int) $i->verified_by : null,
                'source' => 'unload:'.$i->id, 'location' => $wh,
            ]);
        } elseif (! $i->is_verified) {
            Recorder::cancelWaiting('unload:'.$i->id) || Recorder::undoLatest($i->id, ['ds.unloaded'], Auth::user(), 'Unload scan taken back');
        }
    }

    /** Warehouse transfer: the box was unloaded at the other warehouse. */
    protected static function transferSaved(Whtripinvoice $w): void
    {
        if (! $w->wasChanged('is_unloaded') || ! $w->is_unloaded) {
            return;
        }
        $inv = Invoice::query()->find($w->invoice_id);
        if (! $inv || ! Recorder::linkIdFor($inv->location_code)) {
            return;
        }
        $whId = $w->whdeliverylog?->warehouse_id ?? $w->warehouse_id;
        $name = $whId ? Warehouse::query()->whereKey($whId)->value('name') : null;
        Recorder::record($inv, 'ds.transfer', $name, [
            'user' => $w->user_id ? (int) $w->user_id : null, 'source' => 'transfer:'.$w->id,
            'trip' => $w->whdeliverylog?->trip_number, 'location' => $name,
        ]);
    }

    /** Load on truck (sent when the trip leaves) and Delivered. */
    protected static function tripBoxSaved(Tripinvoice $t): void
    {
        $inv = null;
        $get = function () use ($t, &$inv) {
            return $inv ??= Invoice::query()->find($t->invoice_id);
        };

        foreach (['is_loaded' => 'deliverylog_id', 'is_loaded_hub' => 'deliveryloghub_id'] as $col => $tripCol) {
            if (! $t->wasChanged($col)) {
                continue;
            }
            if (! $t->{$col}) {
                Recorder::cancelWaiting('load:'.$t->id);

                continue;
            }
            $i = $get();
            if (! $i || ! Recorder::linkIdFor($i->location_code)) {
                return;
            }
            $trip = $t->{$tripCol} ? Deliverylog::query()->find($t->{$tripCol}) : null;
            $try = min(3, DeliveryAttempt::query()->where('invoice_id', $t->invoice_id)->count() + 1);
            $hub = $trip?->logistichub_id ? Logistichub::query()->whereKey($trip->logistichub_id)->value('hub_name') : null;
            $ev = Recorder::record($i, 'ds.load.'.$try, null, [
                'source' => 'load:'.$t->id, 'trip' => $trip?->trip_number, 'location' => $hub,
            ]);
            if ($ev && $ev->state === 'trip' && $trip?->taken_at) {
                Recorder::tripLeft($trip); // the trip already left (box added on the road)
            }
        }

        if ($t->wasChanged('is_delivered') && $t->is_delivered) {
            $i = $get();
            if (! $i || ! Recorder::linkIdFor($i->location_code)) {
                return;
            }
            $trip = Deliverylog::query()->find($t->deliveryloghub_id ?: $t->deliverylog_id);
            Recorder::record($i, 'ds.delivered', null, [
                'at' => $t->delivered_at, 'user' => $t->delivered_by ? (int) $t->delivered_by : null,
                'source' => 'deliver:'.$t->id, 'trip' => $trip?->trip_number,
                'location' => $trip?->logistichub_id ? Logistichub::query()->whereKey($trip->logistichub_id)->value('hub_name') : null,
            ]);
        }
    }

    protected static function notDelivered(DeliveryAttempt $a): void
    {
        $i = Invoice::query()->find($a->invoice_id);
        if (! $i || ! Recorder::linkIdFor($i->location_code)) {
            return;
        }
        $next = min(3, DeliveryAttempt::query()->where('invoice_id', $a->invoice_id)->count() + 1);
        $trip = $a->deliverylog_id ? Deliverylog::query()->find($a->deliverylog_id) : null;
        Recorder::record($i, 'ds.back_to_hub.'.max(2, $next), null, [
            'at' => $a->created_at, 'user' => (int) $a->user_id, 'source' => 'attempt:'.$a->id,
            'trip' => $trip?->trip_number, 'reason' => $a->reason?->getLabel(),
            'location' => $trip?->logistichub_id ? Logistichub::query()->whereKey($trip->logistichub_id)->value('hub_name') : null,
        ]);
    }

    protected static function undoDelivery(DeliveryReversal $r): void
    {
        $why = is_object($r->reason) && method_exists($r->reason, 'getLabel') ? $r->reason->getLabel() : (string) $r->reason;
        $src = $r->tripinvoice_id ? 'deliver:'.$r->tripinvoice_id : null;
        if ($src && Recorder::cancelWaiting($src)) {
            return; // still in the 10-minute hold: never sent
        }
        Recorder::undoLatest((int) $r->invoice_id, ['ds.delivered', 'ds.delivered_damaged'], $r->user, Str::limit('Undo delivery: '.$why, 200, ''));
    }

    protected static function seaShipment(SeaShipment $s): void
    {
        if (! $s->wasChanged('status')) {
            return;
        }
        $code = ['at_port' => 'ds.to_port', 'sailed' => 'ds.sailing', 'arrived' => 'ds.arrived_port'][$s->status] ?? null;
        if (! $code) {
            return;
        }
        $island = $s->logistichub_id ? Logistichub::query()->whereKey($s->logistichub_id)->value('island') : null;
        $place = $island ? Str::title((string) $island) : null;
        $ids = Tripinvoice::query()->where('deliverylog_id', $s->deliverylog_id)->pluck('invoice_id');
        foreach (Invoice::query()->whereKey($ids)->get() as $i) {
            if (Recorder::linkIdFor($i->location_code)) {
                Recorder::record($i, $code, $place, ['source' => 'sea:'.$s->id.':'.$i->id, 'trip' => $s->code, 'location' => $s->port_to ?: $place]);
            }
        }
    }

    protected static function hubReceived(TruckReceiptScan $s): void
    {
        $i = Invoice::query()->find($s->invoice_id);
        if (! $i || ! Recorder::linkIdFor($i->location_code)) {
            return;
        }
        $hub = Logistichub::query()->find($s->logistichub_id);
        if (! $hub) {
            return;
        }
        $trip = Deliverylog::query()->find($s->deliverylog_id);
        Recorder::record($i, $hub->is_company ? 'ds.partner_hub' : 'ds.transfer', $hub->hub_name, [
            'user' => $s->user_id ? (int) $s->user_id : null, 'source' => 'hub:'.$s->id,
            'trip' => $trip?->trip_number, 'location' => $hub->hub_name,
        ]);
    }

    /** Delivered with a "damaged" signature: sent as Delivered · damaged. */
    public static function isDamaged(?int $tripinvoiceId): bool
    {
        return $tripinvoiceId && class_exists(DeliverySignature::class)
            && DeliverySignature::query()->where('tripinvoice_id', $tripinvoiceId)->where('why', 'damaged')->exists();
    }
}
DISPATCH_FILE_END_8

# ---------------------------------------------------------------- app/Support/Connectors/Recorder.php
mkdir -p 'app/Support/Connectors'
cat > 'app/Support/Connectors/Recorder.php' <<'DISPATCH_FILE_END_9'
<?php

namespace App\Support\Connectors;

use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use Carbon\CarbonInterface;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Puts a status in the Outbox (Part 47). Nothing here talks to a connector:
 * scans stay fast, and Sender sends the Outbox in the background.
 */
class Recorder
{
    /** @var array<string, int>|null location code => link id */
    protected static ?array $links = null;

    protected static ?int $linksApp = null;

    protected static ?bool $ready = null;

    protected static ?int $readyApp = null;

    /** The tables exist (checked once per app). */
    public static function ready(): bool
    {
        if (static::$readyApp !== spl_object_id(app())) {
            static::$readyApp = spl_object_id(app());
            static::$ready = null;
        }

        return static::$ready ??= Schema::hasTable('connector_events');
    }

    /** location code => link id, for paired connectors that are not off. @return array<string, int> */
    public static function links(): array
    {
        if (static::$linksApp !== spl_object_id(app())) {
            static::$linksApp = spl_object_id(app());
            static::$links = null;
        }
        if (! static::ready()) {
            return [];
        }

        return static::$links ??= Cache::remember('connectors.links', 300, fn () => ConnectorLink::query()
            ->join('consolidators', 'consolidators.id', '=', 'connector_links.consolidator_id')
            ->whereNotNull('connector_links.key_id')->where('connector_links.state', '!=', 'off')
            ->pluck('connector_links.id', 'consolidators.code')->map(fn ($v) => (int) $v)->all());
    }

    public static function forgetLinks(): void
    {
        Cache::forget('connectors.links');
        static::$links = null;
    }

    public static function linkIdFor(?string $locationCode): ?int
    {
        return blank($locationCode) ? null : (static::links()[(string) $locationCode] ?? null);
    }

    /**
     * Put one status in the Outbox.
     *
     * @param  array{at?: CarbonInterface|null, user?: User|int|null, trip?: string|null, location?: string|null,
     *               note?: string|null, source?: string|null, manual?: bool, reason?: string|null, corrects?: string|null,
     *               state?: string|null, send_now?: bool, link_id?: int|null}  $o
     */
    public static function record(Invoice $inv, string $code, ?string $place = null, array $o = []): ?ConnectorEvent
    {
        $linkId = $o['link_id'] ?? static::linkIdFor($inv->location_code);
        if (! $linkId || ! isset(Codes::ALL[$code])) {
            return null;
        }

        // The same thing twice (a page saved again): keep the one waiting.
        if (filled($o['source'] ?? null) && empty($o['corrects'])) {
            $same = ConnectorEvent::query()->where('connector_link_id', $linkId)->where('source', $o['source'])
                ->where('code', $code)->whereIn('state', ['hold', 'trip', 'ready'])->first();
            if ($same) {
                return $same;
            }
        }

        $user = $o['user'] ?? Auth::user();
        $user = is_int($user) ? User::find($user) : $user;
        $at = $o['at'] ?? now();
        $rules = Rules::all();

        $when = $o['state'] ?? Codes::when($code);
        $sendNow = ($o['send_now'] ?? false) || filled($o['corrects'] ?? null);
        [$state, $after] = match (true) {
            $sendNow, $when === 'ready' => ['ready', now()],
            $when === 'trip' => ['trip', null],
            $when === 'now', ! $rules['hold'] => ['ready', now()],
            default => ['hold', now()->addMinutes(Rules::HOLD_MINUTES)],
        };
        $first = filled($o['corrects'] ?? null) || str_starts_with($code, 'ds.delivered');

        $uid = (string) Str::ulid();
        $label = Codes::label($code, $place);
        $payload = array_filter([
            'id' => $uid,
            'code' => $code,
            'place' => $place,
            'label' => $label,
            'invoice' => (string) $inv->invoice,
            'location_code' => (string) $inv->location_code,
            'at' => $at->toIso8601String(),
            'by' => $user ? array_filter(['name' => Str::limit((string) $user->full_name, 100, ''), 'role' => static::role($user)]) : null,
            'location' => filled($o['location'] ?? $place) ? Str::upper(Str::limit((string) ($o['location'] ?? $place), 180, '')) : null,
            'trip' => $o['trip'] ?? null,
            'note' => filled($o['note'] ?? null) ? Str::limit((string) $o['note'], 500, '') : null,
            'corrects' => $o['corrects'] ?? null,
            'reason' => filled($o['reason'] ?? null) ? Str::limit((string) $o['reason'], 200, '') : null,
        ], fn ($v) => $v !== null && $v !== []);

        return ConnectorEvent::query()->create([
            'uid' => $uid,
            'connector_link_id' => $linkId,
            'invoice_id' => $inv->getKey(),
            'invoice' => (string) $inv->invoice,
            'code' => $code,
            'place' => $place,
            'label' => $label,
            'payload' => $payload,
            'state' => $state,
            'priority' => $first && $rules['prio'] ? 1 : 5,
            'send_after' => $after,
            'source' => $o['source'] ?? null,
            'corrects' => $o['corrects'] ?? null,
            'user_id' => $user?->getKey(),
            'manual' => (bool) ($o['manual'] ?? false),
            'happened_at' => $at,
        ]);
    }

    /** Role shown with the name: "driver", "office", … */
    public static function role(User $u): ?string
    {
        try {
            $r = $u->getRoleNames()->first();
        } catch (\Throwable) {
            $r = null;
        }

        return $r ? Str::limit(str_replace(['_', '-'], ' ', (string) $r), 50, '') : null;
    }

    /** Statuses of this source that have not gone yet are cancelled. Returns how many. */
    public static function cancelWaiting(string $source, ?array $codes = null): int
    {
        if (! static::ready() || ! static::links()) {
            return 0;
        }

        return ConnectorEvent::query()->where('source', $source)->whereIn('state', ['hold', 'trip', 'ready'])
            ->when($codes, fn ($q) => $q->whereIn('code', $codes))
            ->update(['state' => 'cancelled', 'message' => 'Cancelled before sending', 'updated_at' => now()]);
    }

    /**
     * Undo a status. Not sent yet: it is cancelled (their CMS never sees it).
     * Already sent: an undo event (the right status, with "corrects") goes first.
     */
    public static function undo(ConnectorEvent $wrong, ?User $by = null, ?string $reason = null): ?ConnectorEvent
    {
        if (in_array($wrong->state, ['hold', 'trip', 'ready', 'busy', 'retry'], true) && ! $wrong->sent_at) {
            $wrong->update(['state' => 'cancelled', 'message' => 'Undone before sending: never reached their CMS']);

            return null;
        }
        if (in_array($wrong->state, ['cancelled', 'refused', 'skipped'], true) || filled($wrong->undone_by)) {
            return null;
        }

        // The box goes back to the status before the wrong one.
        $prev = ConnectorEvent::query()->where('connector_link_id', $wrong->connector_link_id)->where('invoice_id', $wrong->invoice_id)
            ->where('id', '<', $wrong->id)->whereNull('corrects')->whereNull('undone_by')
            ->whereIn('state', ['saved', 'sent'])->latest('id')->first();
        $inv = $wrong->invoiceRow ?? Invoice::query()->where('invoice', $wrong->invoice)->first();
        if (! $inv) {
            return null;
        }
        $undo = static::record($inv, $prev->code ?? static::nowCode($inv, $wrong->code), $prev->place ?? null, [
            'user' => $by, 'reason' => $reason ?: 'Undone in Dispatch System', 'corrects' => $wrong->uid,
            'link_id' => $wrong->connector_link_id, 'trip' => $prev?->payload['trip'] ?? null,
            'location' => $prev?->payload['location'] ?? null, 'source' => 'undo:'.$wrong->id,
        ]);
        if ($undo) {
            $wrong->update(['undone_by' => $undo->uid]);
        }

        return $undo;
    }

    /**
     * Where the box is in Dispatch System now (for an undo when no earlier status
     * was sent), leaving out the status being undone.
     */
    public static function nowCode(Invoice $inv, ?string $wrong = null): string
    {
        $wrongDelivered = $wrong !== null && str_starts_with($wrong, 'ds.delivered');
        $row = Tripinvoice::query()->where('invoice_id', $inv->id)->latest('id')->first();
        $tries = \App\Models\DeliveryAttempt::query()->where('invoice_id', $inv->id)->count();
        if ($row && $row->is_delivered && ! $wrongDelivered) {
            return 'ds.delivered';
        }
        if ($row && ($row->is_loaded || $row->is_loaded_hub) && ! str_starts_with((string) $wrong, 'ds.load')) {
            return 'ds.load.'.min(3, $tries + 1);
        }
        if ($tries > 0 && ! str_starts_with((string) $wrong, 'ds.back_to_hub')) {
            return 'ds.back_to_hub.'.min(3, $tries + 1);
        }
        if ($inv->is_verified && $wrong !== 'ds.unloaded') {
            return 'ds.unloaded';
        }

        return 'ds.correction';
    }

    /** Undo the newest status of these codes for a box (Undo delivery, unscan). */
    public static function undoLatest(int $invoiceId, array $codes, ?User $by = null, ?string $reason = null): ?ConnectorEvent
    {
        if (! static::ready() || ! static::links()) {
            return null;
        }
        $wrong = ConnectorEvent::query()->where('invoice_id', $invoiceId)->whereIn('code', $codes)
            ->whereNull('corrects')->whereNull('undone_by')->whereNotIn('state', ['cancelled'])->latest('id')->first();

        return $wrong ? static::undo($wrong, $by, $reason) : null;
    }

    /** The trip left (driver took it): its "Load on truck" statuses go now, dated when it left. */
    public static function tripLeft(Deliverylog $trip): int
    {
        if (! static::ready() || ! static::links()) {
            return 0;
        }
        $ids = Tripinvoice::query()->where(fn ($q) => $q->where('deliverylog_id', $trip->id)->orWhere('deliveryloghub_id', $trip->id))->pluck('id');
        $n = 0;
        foreach ($ids->chunk(500) as $chunk) {
            $sources = $chunk->map(fn ($id) => 'load:'.$id)->all();
            foreach (ConnectorEvent::query()->whereIn('source', $sources)->where('state', 'trip')->get() as $ev) {
                $at = $trip->taken_at ?? now();
                $ev->update(['state' => 'ready', 'send_after' => now(), 'happened_at' => $at,
                    'payload' => ['at' => $at->toIso8601String()] + $ev->payload]);
                $n++;
            }
        }

        return $n;
    }
}
DISPATCH_FILE_END_9

# ---------------------------------------------------------------- app/Support/Connectors/Rules.php
mkdir -p 'app/Support/Connectors'
cat > 'app/Support/Connectors/Rules.php' <<'DISPATCH_FILE_END_10'
<?php

namespace App\Support\Connectors;

use App\Models\AppSetting;

/**
 * Settings → Consolidator connections → Rules (all consolidators).
 * Saved as one JSON value in app_settings.
 */
class Rules
{
    public const KEY = 'connectors.rules';

    /** key => [title, text, default] */
    public const ALL = [
        'prio' => ['Delivered and undo first', 'They jump ahead of a big unload in the line.', true],
        'hold' => ['10-minute hold (Delivered, Unload, Transfer)', 'An undo inside 10 minutes is never sent. Load goes when the trip leaves.', true],
        'pause' => ['Pause a connector after 5 failed tries', 'Then try every 10 minutes; nothing is lost.', true],
        'mail' => ['Email the admins when a connector is paused or 500+ wait', 'Also shown on this page.', true],
        'night' => ['Send backfill only at night (10 PM – 5 AM)', 'For a big history, to keep their server free in the day.', false],
    ];

    public const HOLD_MINUTES = 10;

    public const BATCH = 200;

    public const PAUSE_AFTER = 5;

    public const RETRY_MINUTES = 10;

    public const MAIL_WAITING = 500;

    /** @return array<string, bool> */
    public static function all(): array
    {
        $saved = json_decode((string) AppSetting::get(static::KEY, '{}'), true);
        $saved = is_array($saved) ? $saved : [];
        $out = [];
        foreach (static::ALL as $k => [, , $default]) {
            $out[$k] = (bool) ($saved[$k] ?? $default);
        }

        return $out;
    }

    public static function on(string $key): bool
    {
        return static::all()[$key] ?? false;
    }

    /** @param array<string, mixed> $rules */
    public static function save(array $rules): void
    {
        $clean = [];
        foreach (array_keys(static::ALL) as $k) {
            $clean[$k] = (bool) ($rules[$k] ?? false);
        }
        AppSetting::put(static::KEY, json_encode($clean));
    }
}
DISPATCH_FILE_END_10

# ---------------------------------------------------------------- app/Support/Connectors/Sender.php
mkdir -p 'app/Support/Connectors'
cat > 'app/Support/Connectors/Sender.php' <<'DISPATCH_FILE_END_11'
<?php

namespace App\Support\Connectors;

use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\User;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Mail;
use Throwable;

/**
 * Sends the Outbox (Part 47): one batch at a time per connector (up to 200),
 * Delivered and undo first, then oldest first. A busy or offline connector is
 * tried again later; after 5 failed tries in a row it is paused and tried every
 * 10 minutes. Nothing is ever lost: the statuses wait here.
 */
class Sender
{
    /** Minutes to wait after the 1st, 2nd, 3rd… failed try. */
    public const BACKOFF = [1, 2, 5, 10];

    /** Run for up to $seconds (the scheduler calls this every minute). @return array<string, int> */
    public static function run(int $seconds = 50): array
    {
        $stop = microtime(true) + $seconds;
        $out = ['released' => static::releaseHeld(), 'sent' => 0, 'saved' => 0, 'links' => 0, 'results' => 0];
        static::resendLost();

        $links = ConnectorLink::query()->whereNotNull('key_id')->where('state', '!=', 'off')->orderBy('id')->get();
        foreach ($links as $link) {
            if (microtime(true) > $stop) {
                break;
            }
            $out['links']++;
            if (! $link->isPush()) {
                continue; // pull: their connector asks us
            }
            try {
                if (static::due($link)) {
                    do {
                        $r = static::sendBatch($link);
                        $out['sent'] += $r['sent'];
                        $out['saved'] += $r['saved'];
                    } while ($r['sent'] === Rules::BATCH && ! $r['stop'] && microtime(true) < $stop);
                }
                if (! $link->last_results_at || $link->last_results_at->lt(now()->subMinutes(5))) {
                    $out['results'] += static::pollResults($link);
                }
                if (! $link->last_seen_at || $link->last_seen_at->lt(now()->subMinutes(10))) {
                    static::health($link);
                }
            } catch (Throwable $e) {
                report($e);
            }
            static::maybeMail($link->fresh());
        }

        return $out;
    }

    /** Statuses whose 10-minute hold is over are ready. */
    public static function releaseHeld(): int
    {
        return ConnectorEvent::query()->where('state', 'hold')->where('send_after', '<=', now())
            ->update(['state' => 'ready', 'updated_at' => now()]);
    }

    /** Sent but no answer for 30 minutes (lost on the way): send again (the connector writes an id once). */
    public static function resendLost(): int
    {
        return ConnectorEvent::query()->where('state', 'sent')->where('sent_at', '<', now()->subMinutes(30))
            ->update(['state' => 'ready', 'next_try_at' => null, 'updated_at' => now()]);
    }

    public static function due(ConnectorLink $link, bool $force = false): bool
    {
        if ($force) {
            return true;
        }

        return ! in_array($link->state, ['paused', 'offline'], true) || ! $link->next_try_at || $link->next_try_at->lte(now());
    }

    /** @return \Illuminate\Database\Eloquent\Builder<ConnectorEvent> */
    public static function waiting(ConnectorLink $link)
    {
        return ConnectorEvent::query()->where('connector_link_id', $link->id)->whereIn('state', ['ready', 'busy', 'retry'])
            ->where(fn ($q) => $q->whereNull('next_try_at')->orWhere('next_try_at', '<=', now()));
    }

    /**
     * Send one batch. @return array{sent: int, saved: int, stop: bool, error: ?string}
     */
    public static function sendBatch(ConnectorLink $link): array
    {
        $batch = static::waiting($link)->orderBy('priority')->orderBy('id')->limit(Rules::BATCH)->get();
        if ($batch->isEmpty()) {
            return ['sent' => 0, 'saved' => 0, 'stop' => true, 'error' => null];
        }

        $events = $batch->map(fn (ConnectorEvent $e) => static::payload($e))->values()->all();
        $start = microtime(true);
        try {
            $res = (new Client($link))->call('POST', '/api/v1/events', ['events' => $events], 40);
        } catch (Throwable $e) {
            static::failed($link, $batch, $e->getMessage());

            return ['sent' => 0, 'saved' => 0, 'stop' => true, 'error' => $e->getMessage()];
        }
        $ms = (int) round((microtime(true) - $start) * 1000);

        if ($res->status() === 503) { // busy with another batch: come back, not a failure
            $wait = max(5, (int) ($res->header('Retry-After') ?: 15));
            ConnectorEvent::query()->whereKey($batch->modelKeys())->update(['next_try_at' => now()->addSeconds($wait), 'message' => 'Connector busy: sends again in '.$wait.' s', 'updated_at' => now()]);
            static::seen($link);

            return ['sent' => 0, 'saved' => 0, 'stop' => true, 'error' => null];
        }

        $by = collect($res->json('results') ?? [])->filter(fn ($r) => is_array($r) && filled($r['id'] ?? null))->keyBy('id');
        $wait = max(5, (int) ($res->header('Retry-After') ?: 10));
        $saved = 0;
        foreach ($batch as $e) {
            $r = $by->get($e->uid);
            if (! $r) {
                $e->update(['state' => 'busy', 'next_try_at' => now()->addSeconds($wait), 'message' => 'No answer for this one: sends again']);

                continue;
            }
            $saved += static::apply($e, $r, $ms) === 'saved' ? 1 : 0;
        }
        static::seen($link);

        return ['sent' => $batch->count(), 'saved' => $saved, 'stop' => $by->contains(fn ($r) => ($r['result'] ?? '') === 'busy'), 'error' => null];
    }

    /** The event as it goes: Delivered becomes "Delivered · damaged" when the receiver signed for a damaged box. @return array<string, mixed> */
    public static function payload(ConnectorEvent $e): array
    {
        $p = $e->payload;
        if ($e->code === 'ds.delivered' && str_starts_with((string) $e->source, 'deliver:')
            && Hooks::isDamaged((int) substr((string) $e->source, 8))) {
            $p['code'] = 'ds.delivered_damaged';
            $p['label'] = Codes::label('ds.delivered_damaged');
            $e->forceFill(['code' => $p['code'], 'label' => $p['label'], 'payload' => $p])->save();
        }

        return $p;
    }

    /** One result from the connector (push answer, /results, or pull). Returns the new state. */
    public static function apply(ConnectorEvent $e, array $r, ?int $ms = null): string
    {
        $result = (string) ($r['result'] ?? '');
        $state = in_array($result, ['saved', 'skipped', 'refused', 'needs_mapping', 'not_found', 'failed', 'busy'], true) ? $result : 'failed';
        $fields = [
            'state' => $state,
            'message' => mb_substr((string) ($r['message'] ?? ''), 0, 250) ?: null,
            'trackstatus_id' => $r['trackstatus_id'] ?? $e->trackstatus_id,
            'row_id' => $state === 'saved' ? ($r['row_id'] ?? $e->row_id) : $e->row_id,
            'sent_at' => $e->sent_at ?? now(),
            'tries' => $ms !== null ? $e->tries + 1 : $e->tries,
            'next_try_at' => $state === 'busy' ? now()->addSeconds(10) : null,
        ];
        if ($ms !== null) {
            $fields['took_ms'] = $ms;
        }
        $e->update($fields);

        return $state;
    }

    protected static function failed(ConnectorLink $link, $batch, string $why): void
    {
        $fails = $link->fails + 1;
        $wait = static::BACKOFF[min($fails, count(static::BACKOFF)) - 1];
        $pause = Rules::on('pause') && $fails >= Rules::PAUSE_AFTER;
        $next = now()->addMinutes($pause ? Rules::RETRY_MINUTES : $wait);
        foreach ($batch as $e) {
            $e->update(['state' => 'retry', 'tries' => $e->tries + 1, 'next_try_at' => $next, 'message' => mb_substr('Not sent: '.$why, 0, 250)]);
        }
        $link->forceFill([
            'fails' => $fails, 'last_error' => mb_substr(now()->format('M j g:i A').': '.$why, 0, 300),
            'state' => $pause ? 'paused' : 'offline', 'paused_at' => $pause ? ($link->paused_at ?? now()) : null,
            'next_try_at' => $next,
        ])->save();
    }

    protected static function seen(ConnectorLink $link): void
    {
        $link->forceFill(['fails' => 0, 'state' => 'online', 'last_seen_at' => now(), 'paused_at' => null, 'next_try_at' => null, 'mailed_at' => null])->save();
    }

    /** Results that changed at the connector (it retried a "not found", or a mapping was saved). */
    public static function pollResults(ConnectorLink $link): int
    {
        $since = ($link->last_results_at ?? now()->subDay())->copy()->subMinute()->utc()->format('Y-m-d\TH:i:s\Z');
        $data = (new Client($link))->get('/api/v1/results?'.http_build_query(['since' => $since]));
        $n = static::applyResults($link, $data['results'] ?? []);
        $link->forceFill(['last_results_at' => now()])->save();

        return $n;
    }

    /** @param  array<mixed>  $results */
    public static function applyResults(ConnectorLink $link, array $results): int
    {
        $rows = collect($results)->filter(fn ($r) => is_array($r) && filled($r['id'] ?? null))->keyBy('id');
        if ($rows->isEmpty()) {
            return 0;
        }
        $n = 0;
        foreach ($rows->keys()->chunk(200) as $ids) {
            foreach (ConnectorEvent::query()->where('connector_link_id', $link->id)->whereIn('uid', $ids->all())->get() as $e) {
                if (in_array($e->state, ['cancelled'], true)) {
                    continue;
                }
                static::apply($e, $rows->get($e->uid));
                $n++;
            }
        }

        return $n;
    }

    /** GET /health: version, their database, warnings. Marks the connector online or offline. */
    public static function health(ConnectorLink $link): ?array
    {
        try {
            $h = (new Client($link))->get('/api/v1/health', 15);
            $link->forceFill([
                'health' => $h, 'version' => $h['version'] ?? $link->version,
                'state' => $link->state === 'paused' ? 'paused' : 'online', 'last_seen_at' => now(),
            ])->save();
            if ($link->state === 'paused') {
                static::seen($link); // answered again: go on sending
            }

            return $h;
        } catch (Throwable $e) {
            $link->forceFill(['last_error' => mb_substr(now()->format('M j g:i A').': '.$e->getMessage(), 0, 300),
                'state' => $link->state === 'paused' ? 'paused' : 'offline'])->save();

            return null;
        }
    }

    /** GET /statuses: their own status list and the mapping the connector has. */
    public static function refreshStatuses(ConnectorLink $link): array
    {
        $data = (new Client($link))->get('/api/v1/statuses', 20);
        $list = collect($data['statuses'] ?? [])->filter(fn ($s) => is_array($s) && isset($s['id']))
            ->map(fn ($s) => ['id' => (int) $s['id'], 'name' => (string) ($s['description'] ?? $s['name'] ?? ''), 'code' => $s['code'] ?? null,
                'branch_id' => isset($s['branch_id']) ? (int) $s['branch_id'] : null, 'active' => (bool) ($s['is_active'] ?? true)])
            ->values()->all();
        $link->forceFill(['statuses' => ['ph_branch_id' => $data['ph_branch_id'] ?? null, 'list' => $list, 'mapping' => $data['mapping'] ?? []],
            'statuses_at' => now(), 'last_seen_at' => now()])->save();

        return $list;
    }

    /** PUT /mapping: the connector gets the whole mapping. Returns [saved, retried]. @return array{saved: int, retried: int} */
    public static function pushMapping(ConnectorLink $link): array
    {
        $rows = $link->mappings()->get()->filter(fn ($m) => $m->skip || $m->trackstatus_id)
            ->map(fn ($m) => ['key' => $m->key, 'trackstatus_id' => $m->skip ? null : (int) $m->trackstatus_id, 'skip' => (bool) $m->skip])
            ->values()->all();
        $res = (new Client($link))->send('PUT', '/api/v1/mapping', ['rows' => $rows]);
        // statuses that waited for this mapping are tried again at the connector: read their results soon
        $link->forceFill(['last_results_at' => now()->subMinutes(10)])->save();

        return ['saved' => (int) ($res['saved'] ?? 0), 'retried' => (int) ($res['retried'] ?? 0)];
    }

    /** Email the admins once when a connector is paused, or 500+ statuses wait. */
    public static function maybeMail(?ConnectorLink $link): void
    {
        if (! $link || ! Rules::on('mail') || $link->mailed_at) {
            return;
        }
        $waiting = ConnectorEvent::query()->where('connector_link_id', $link->id)->whereIn('state', ['ready', 'retry', 'busy', 'hold'])->count();
        if ($link->state !== 'paused' && $waiting < Rules::MAIL_WAITING) {
            return;
        }
        $name = $link->consolidator?->company_name ?? 'A consolidator';
        $text = $link->state === 'paused'
            ? "$name's connector is not answering ({$link->last_error}). It is paused and tried every 10 minutes. $waiting statuses wait in the Outbox; nothing is lost."
            : "$waiting statuses wait in the Outbox for $name's connector.";
        try {
            $to = User::role('super_admin')->whereNotNull('email')->pluck('email')->filter()->unique()->values()->all();
            if ($to) {
                Mail::raw($text."\n\nSettings → Consolidator connections → Outbox", fn ($m) => $m->to($to)->subject('Connector: '.$name.($link->state === 'paused' ? ' is paused' : ' has '.$waiting.' waiting')));
            }
        } catch (Throwable $e) {
            report($e);
        }
        $link->forceFill(['mailed_at' => now()])->save();
    }

    /** Send right now (the button): the held ones too. @return array{sent: int, saved: int, error: ?string} */
    public static function sendNow(ConnectorLink $link): array
    {
        ConnectorEvent::query()->where('connector_link_id', $link->id)->where('state', 'hold')
            ->update(['state' => 'ready', 'send_after' => now(), 'updated_at' => now()]);
        ConnectorEvent::query()->where('connector_link_id', $link->id)->whereIn('state', ['retry', 'busy'])
            ->update(['next_try_at' => null, 'updated_at' => now()]);
        if (! $link->isPush()) {
            return ['sent' => 0, 'saved' => 0, 'error' => null]; // pull: ready for their next ask
        }
        $sent = $saved = 0;
        $error = null;
        for ($i = 0; $i < 10; $i++) {
            $r = static::sendBatch($link->fresh());
            $sent += $r['sent'];
            $saved += $r['saved'];
            $error ??= $r['error'];
            if ($r['stop'] || $r['sent'] < Rules::BATCH) {
                break;
            }
        }

        return compact('sent', 'saved', 'error');
    }

    /** "Resend failed": statuses the connector could not write go again. */
    public static function resendFailed(ConnectorLink $link): int
    {
        return ConnectorEvent::query()->where('connector_link_id', $link->id)->whereIn('state', ['failed', 'retry', 'busy'])
            ->update(['state' => 'ready', 'next_try_at' => null, 'updated_at' => now()]);
    }

    /** When it really goes: "sends 4:08 PM". */
    public static function sendsAt(ConnectorEvent $e): ?Carbon
    {
        return match ($e->state) {
            'hold' => $e->send_after,
            'retry', 'busy' => $e->next_try_at,
            default => null,
        };
    }
}
DISPATCH_FILE_END_11

# ---------------------------------------------------------------- app/Support/Connectors/Signer.php
mkdir -p 'app/Support/Connectors'
cat > 'app/Support/Connectors/Signer.php' <<'DISPATCH_FILE_END_12'
<?php

namespace App\Support\Connectors;

/**
 * The signature between Dispatch System and a connector (same as the connector's Signature):
 *   X-Connector-Signature: sha256=HMAC_SHA256(secret, time \n METHOD \n /path?query \n sha256(body))
 */
class Signer
{
    public const TIME = 'X-Connector-Time';

    public const SIGN = 'X-Connector-Signature';

    public const KEY = 'X-Connector-Key';

    public const WINDOW = 300;

    public static function make(string $secret, int $time, string $method, string $path, string $body): string
    {
        $path = '/'.ltrim($path, '/');

        return 'sha256='.hash_hmac('sha256', $time."\n".strtoupper($method)."\n".$path."\n".hash('sha256', $body), $secret);
    }

    public static function valid(string $secret, ?string $given, int $time, string $method, string $path, string $body): bool
    {
        return is_string($given) && hash_equals(static::make($secret, $time, $method, $path, $body), $given);
    }

    /** /path?query of a full URL. */
    public static function pathOf(string $url): string
    {
        $q = parse_url($url, PHP_URL_QUERY);

        return (parse_url($url, PHP_URL_PATH) ?: '/').($q ? '?'.$q : '');
    }
}
DISPATCH_FILE_END_12

# ---------------------------------------------------------------- app/Support/Connectors/Suggest.php
mkdir -p 'app/Support/Connectors'
cat > 'app/Support/Connectors/Suggest.php' <<'DISPATCH_FILE_END_13'
<?php

namespace App\Support\Connectors;

use Illuminate\Support\Str;

/** ✨ Suggestions for the mapping: their status names that match our event (by words). */
class Suggest
{
    /** code => [words that should be there, words that must not] */
    public const WORDS = [
        'ds.unloaded' => [['unload', 'unloaded', 'warehouse', 'philippine', 'ph'], ['2nd', '3rd', 'transfer', 'return']],
        'ds.transfer' => [['transfer', 'transferred', 'hub', 'warehouse'], ['shipping', 'port', 'inter', 'island']],
        'ds.return_to_warehouse' => [['return', 'returned', 'warehouse'], ['hub', 'unloaded', 'unload', 'philippine']],
        'ds.to_port' => [['shipping', 'line', 'port', 'transfer'], ['arrived']],
        'ds.sailing' => [['transit', 'sailing', 'vessel', 'shipped'], ['arrived']],
        'ds.arrived_port' => [['arrived', 'port'], ['philippine', 'warehouse']],
        'ds.partner_hub' => [['inter', 'island', 'transferred', 'hub', 'arrived'], ['shipping', 'port', 'return']],
        'ds.load.1' => [['loaded', 'load', 'truck', 'delivery', 'out'], ['2nd', '3rd', 'second', 'third', 'attempt']],
        'ds.load.2' => [['loaded', 'truck', '2nd', 'second', 'attempt', 're'], ['3rd', 'third']],
        'ds.load.3' => [['loaded', 'truck', '3rd', 'third', 'attempt'], ['2nd', 'second']],
        'ds.back_to_hub.2' => [['return', 'returned', 'back', 'hub', '2nd', 'second'], ['3rd', 'loaded', 'warehouse', 'delivered']],
        'ds.back_to_hub.3' => [['return', 'returned', 'back', 'hub', '3rd', 'third'], ['2nd', 'loaded', 'warehouse', 'delivered']],
        'ds.waiting_next_try' => [['waiting', 'next', 'redelivery', 'hold', 'hub'], ['loaded']],
        'ds.delivered' => [['delivered'], ['not', 'damaged', 'undelivered']],
        'ds.delivered_damaged' => [['delivered', 'damaged', 'damage'], ['not', 'undelivered']],
        'ds.correction' => [['correction', 'update', 'remarks'], []],
    ];

    /** A 2nd or 3rd try is only matched by a status that says so. */
    public const MUST = [
        'ds.load.2' => ['2nd', 'second'], 'ds.load.3' => ['3rd', 'third'],
        'ds.back_to_hub.2' => ['2nd', 'second'], 'ds.back_to_hub.3' => ['3rd', 'third'],
    ];

    /**
     * @param  list<array{id: int, name: string}>  $statuses
     * @return list<array{id: int, name: string, score: int}> best first, at most 3
     */
    public static function for(string $code, ?string $place, array $statuses): array
    {
        [$want, $not] = static::WORDS[$code] ?? [[], []];
        $placeWords = $place ? static::words($place) : [];
        $out = [];
        foreach ($statuses as $s) {
            $w = static::words($s['name']);
            if (isset(static::MUST[$code]) && ! array_intersect(static::MUST[$code], $w)) {
                continue;
            }
            $score = 0;
            foreach ($want as $k) {
                $score += in_array($k, $w, true) ? 2 : 0;
            }
            foreach ($not as $k) {
                $score -= in_array($k, $w, true) ? 4 : 0;
            }
            foreach ($placeWords as $p) {
                $score += in_array($p, $w, true) ? 5 : 0;
            }
            if ($w && ! array_diff($w, $want)) {
                $score += 2; // the whole name is what we look for ("Delivered")
            }
            if ($place === null && static::hasPlaceName($w)) {
                $score -= 1; // "any place" fits a general status better
            }
            if ($score >= 3) {
                $out[] = ['id' => (int) $s['id'], 'name' => $s['name'], 'score' => $score];
            }
        }
        usort($out, fn ($a, $b) => $b['score'] <=> $a['score'] ?: $a['id'] <=> $b['id']);

        return array_slice($out, 0, 3);
    }

    /** @return list<string> */
    public static function words(string $text): array
    {
        $t = Str::lower(Str::ascii($text));
        $t = preg_replace('/(\d)(st|nd|rd|th)\b/', '$1$2 ', $t);

        return array_values(array_filter(preg_split('/[^a-z0-9]+/', $t)));
    }

    protected static function hasPlaceName(array $w): bool
    {
        return (bool) array_intersect($w, ['tarlac', 'isabela', 'benguet', 'visayas', 'mindanao', 'masbate', 'palawan', 'mindoro', 'cavite', 'manila']);
    }

    /** Percent shown next to a suggestion. */
    public static function percent(int $score): int
    {
        return min(99, 40 + $score * 6);
    }
}
DISPATCH_FILE_END_13

# ---------------------------------------------------------------- database/migrations/2026_11_28_000053_create_connector_tables.php
mkdir -p 'database/migrations'
cat > 'database/migrations/2026_11_28_000053_create_connector_tables.php' <<'DISPATCH_FILE_END_14'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Part 47: Dispatch System sends box statuses to each consolidator's connector.
 *
 *  connector_links     one per consolidator: address, push or pull, the pairing (token and secret encrypted)
 *  connector_mappings  our event (code or code@place) → their status id, per consolidator
 *  connector_events    the Outbox: every status we send, with its hold, tries and the connector's answer
 */
return new class extends Migration
{
    public function up(): void
    {
        if (! Schema::hasTable('connector_links')) {
            Schema::create('connector_links', function (Blueprint $t) {
                $t->id();
                $t->foreignId('consolidator_id')->unique();
                $t->string('url', 250)->nullable();              // push: the connector's HTTPS address
                $t->string('mode', 8)->default('push');           // push | pull
                $t->text('token')->nullable();                    // encrypted
                $t->text('secret')->nullable();                   // encrypted
                $t->string('key_id', 64)->nullable()->index();    // pull: the connector signs with this key id
                $t->string('state', 12)->default('setup');        // setup | online | offline | paused | off
                $t->string('connector_name', 150)->nullable();
                $t->string('version', 20)->nullable();
                $t->string('location_code', 20)->nullable();      // what the connector says it is
                $t->json('health')->nullable();                   // last /health answer
                $t->json('statuses')->nullable();                 // their status list (branch PH, active)
                $t->timestamp('statuses_at')->nullable();
                $t->timestamp('last_seen_at')->nullable();
                $t->timestamp('last_results_at')->nullable();     // /results?since=
                $t->string('last_error', 300)->nullable();
                $t->unsignedSmallInteger('fails')->default(0);     // failed tries in a row
                $t->timestamp('paused_at')->nullable();
                $t->timestamp('next_try_at')->nullable();
                $t->timestamp('mailed_at')->nullable();
                $t->timestamp('paired_at')->nullable();
                $t->foreignId('paired_by')->nullable();
                $t->unsignedBigInteger('pull_cursor')->default(0);
                $t->timestamps();
            });
        }

        if (! Schema::hasTable('connector_mappings')) {
            Schema::create('connector_mappings', function (Blueprint $t) {
                $t->id();
                $t->foreignId('connector_link_id');
                $t->string('key', 140);                          // ds.transfer@tarlac
                $t->unsignedBigInteger('trackstatus_id')->nullable();
                $t->string('status_name', 191)->nullable();
                $t->boolean('skip')->default(false);              // Don't send this one
                $t->timestamps();
                $t->unique(['connector_link_id', 'key']);
            });
        }

        if (! Schema::hasTable('connector_events')) {
            Schema::create('connector_events', function (Blueprint $t) {
                $t->id();
                $t->string('uid', 40)->unique();                  // the event id the connector sees
                $t->foreignId('connector_link_id');
                $t->foreignId('invoice_id')->nullable()->index();
                $t->string('invoice', 40);
                $t->string('code', 80);
                $t->string('place', 60)->nullable();
                $t->string('label', 150)->nullable();
                $t->json('payload');                              // the event as it is sent
                $t->string('state', 16)->default('hold')->index();
                // hold | trip (waits for the trip to leave) | ready | sent | saved | skipped | refused
                // | needs_mapping | not_found | failed | busy | retry | cancelled
                $t->unsignedTinyInteger('priority')->default(5);  // 1 = first (delivered, undo)
                $t->timestamp('send_after')->nullable();
                $t->unsignedSmallInteger('tries')->default(0);
                $t->timestamp('next_try_at')->nullable();
                $t->timestamp('sent_at')->nullable();
                $t->unsignedInteger('took_ms')->nullable();
                $t->string('message', 250)->nullable();
                $t->unsignedBigInteger('trackstatus_id')->nullable();
                $t->unsignedBigInteger('row_id')->nullable();
                $t->string('source', 40)->nullable()->index();    // tripinvoice:12, invoice:5, manual, backfill
                $t->string('corrects', 40)->nullable()->index();  // uid of the event this one undoes
                $t->string('undone_by', 40)->nullable();
                $t->foreignId('user_id')->nullable();             // who did it in Dispatch System
                $t->boolean('manual')->default(false);
                $t->timestamp('happened_at');
                $t->timestamps();
                $t->index(['connector_link_id', 'state', 'priority', 'id']);
                $t->index(['connector_link_id', 'created_at']);
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('connector_events');
        Schema::dropIfExists('connector_mappings');
        Schema::dropIfExists('connector_links');
    }
};
DISPATCH_FILE_END_14

# ---------------------------------------------------------------- resources/views/filament/pages/consolidator-connections.blade.php
mkdir -p 'resources/views/filament/pages'
cat > 'resources/views/filament/pages/consolidator-connections.blade.php' <<'DISPATCH_FILE_END_15'
@php
    $stCls = fn ($s) => match ($s) {
        'Online', 'Paired' => 'bg-[#17895e]/12 text-[#17895e]',
        'Paused', 'Offline' => 'bg-[#d64236]/12 text-[#d64236]',
        'Off' => 'bg-slate-200 text-slate-600',
        default => 'bg-slate-100 text-slate-500',
    };
    $evCls = [
        'hold' => ['In 10-min hold', 'bg-[#e8f1fb] text-[#2f6fb0]'], 'trip' => ['Waits for the trip to leave', 'bg-[#e8f1fb] text-[#2f6fb0]'],
        'ready' => ['Ready', 'bg-[#e8f1fb] text-[#2f6fb0]'], 'sent' => ['Sent · no answer yet', 'bg-[#fff6d6] text-[#8a6400]'],
        'saved' => ['Saved', 'bg-[#17895e]/12 text-[#17895e]'], 'skipped' => ['Skipped', 'bg-slate-100 text-slate-500'],
        'refused' => ['Refused', 'bg-[#d64236]/12 text-[#d64236]'], 'needs_mapping' => ['Needs mapping', 'bg-[#d64236]/12 text-[#d64236]'],
        'not_found' => ['Waiting · box not in their CMS', 'bg-[#fff6d6] text-[#8a6400]'], 'failed' => ['Will retry (their side)', 'bg-[#fff6d6] text-[#8a6400]'],
        'busy' => ['Will retry', 'bg-[#fff6d6] text-[#8a6400]'], 'retry' => ['Will retry', 'bg-[#fff6d6] text-[#8a6400]'],
        'cancelled' => ['Cancelled', 'bg-slate-100 text-slate-500'],
    ];
    $paired = $link?->isPaired();
@endphp
<x-filament-panels::page>
<div class="grid items-start gap-6 text-[#0e2433] xl:grid-cols-[360px_minmax(0,1fr)]">

    {{-- A · every consolidator --}}
    <section class="flex flex-col gap-3">
        <b class="text-base">A · Consolidators</b>
        @foreach ($cards as $c)
            <button type="button" wire:click="pickCon({{ $c['id'] }})" wire:key="card-{{ $c['id'] }}"
                @class(['flex flex-col gap-2 rounded-2xl bg-white p-4 text-left ring-1 dark:bg-white/5', 'ring-2 ring-[#f6be00]' => $c['id'] === $cur?->id, 'ring-slate-200 dark:ring-white/10' => $c['id'] !== $cur?->id])>
                <span class="flex items-center gap-3">
                    <span @class(['grid size-10 shrink-0 place-items-center rounded-xl text-[14px] font-black', 'bg-[#0e2433] text-white' => $c['link']?->isPaired(), 'bg-slate-100 text-slate-500' => ! $c['link']?->isPaired()])>{{ $c['code'] }}</span>
                    <span class="flex min-w-0 flex-1 flex-col"><b class="truncate text-[15px] dark:text-white">{{ $c['name'] }}</b><small class="truncate text-[12.5px] text-slate-500">{{ $c['sub'] }}</small></span>
                    <span class="shrink-0 rounded-full px-2.5 py-0.5 text-[11.5px] font-extrabold {{ $stCls($c['state']) }}">{{ $c['state'] }}</span>
                </span>
                @if ($c['link']?->isPaired())
                    <span class="grid grid-cols-4 gap-2 text-center">
                        @foreach ($c['nums'] as [$v, $t, $cls])
                            <span class="flex flex-col rounded-lg bg-[#f6f8fa] py-1.5 dark:bg-white/5"><b @class(['text-[16px] dark:text-white', 'text-[#b97412]' => $cls === 'is-warn', 'text-[#d64236]' => $cls === 'is-bad'])>{{ number_format($v) }}</b><small class="text-[11px] text-slate-500">{{ $t }}</small></span>
                        @endforeach
                    </span>
                @endif
            </button>
        @endforeach
        @if ($cards->isEmpty())
            <p class="rounded-2xl bg-white p-4 text-[13.5px] text-slate-500 ring-1 ring-slate-200">No consolidators yet. Add them in Consolidators first.</p>
        @endif

        <div class="flex flex-col gap-2 rounded-2xl bg-white p-4 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            <b class="text-[14px] dark:text-white">Rules (all consolidators)</b>
            @foreach (\App\Support\Connectors\Rules::ALL as $k => [$t, $d])
                <button type="button" wire:click="toggleRule('{{ $k }}')" wire:key="rule-{{ $k }}" role="switch" aria-checked="{{ ($rules[$k] ?? false) ? 'true' : 'false' }}"
                    class="flex items-center gap-3 rounded-xl bg-[#f6f8fa] px-3.5 py-2.5 text-left ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
                    <span class="flex flex-1 flex-col"><b class="text-[13.5px] dark:text-white">{{ $t }}</b><small class="text-[12px] text-slate-500">{{ $d }}</small></span>
                    <span @class(['relative h-6 w-11 shrink-0 rounded-full', 'bg-[#17895e]' => $rules[$k] ?? false, 'bg-slate-300' => ! ($rules[$k] ?? false)])><span @class(['absolute top-0.5 size-5 rounded-full bg-white shadow', 'left-[22px]' => $rules[$k] ?? false, 'left-0.5' => ! ($rules[$k] ?? false)])></span></span>
                </button>
            @endforeach
            <small class="text-[12px] text-slate-500">Load on truck goes when the trip leaves (the driver takes the trip), not at each scan. Remarks on their tracking page stay plain: only a note for the customer. Names, trips and reasons are kept for staff.</small>
            @unless ($scheduleOk)
                <small class="rounded-lg bg-[#fff6d6] px-3 py-2 text-[12px] text-[#8a6400]">The scheduler has not run in the last 10 minutes, so the Outbox is not sent by itself. Check the cron job (php artisan schedule:run every minute).</small>
            @endunless
        </div>
    </section>

    {{-- B · one consolidator --}}
    <section class="flex min-w-0 flex-col gap-3">
        @if ($cur)
        <b class="text-base">B · {{ $cur->company_name }} <span class="font-normal text-slate-500">· location code {{ $cur->code }}</span></b>
        <div class="flex flex-col gap-5 rounded-2xl bg-white p-6 shadow-[0_30px_60px_-34px_rgb(14_36_51/.45)] ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
            <nav class="flex flex-wrap gap-2" aria-label="Connection tabs">
                @foreach (['conn' => ['Connection', null], 'map' => ['Status mapping', $needs ?: null], 'outbox' => ['Outbox', null]] as $k => [$label, $badge])
                    <button type="button" wire:click="setTab('{{ $k }}')" @class(['flex h-10 items-center gap-2 rounded-xl px-4 text-[14px] font-bold', 'bg-[#0e2433] text-white' => $tab === $k, 'bg-[#f6f8fa] text-[#0e2433] ring-1 ring-slate-200' => $tab !== $k])>
                        {{ $label }}@if ($badge)<span class="rounded-full bg-[#d64236] px-2 text-[11.5px] font-extrabold text-white">{{ $badge }}</span>@endif
                    </button>
                @endforeach
            </nav>

            {{-- ============================================================ Connection --}}
            @if ($tab === 'conn')
                <div class="grid gap-5 lg:grid-cols-2">
                    <div class="flex flex-col gap-4">
                        <label class="flex flex-col gap-1.5"><b class="text-[13.5px]">Connector address (on their server)</b>
                            <input type="url" wire:model="url" placeholder="https://connector.theircompany.com" class="h-11 rounded-xl border-0 bg-[#f6f8fa] px-3.5 font-mono text-[14px] ring-1 ring-slate-200 focus:ring-2 focus:ring-[#f6be00] dark:bg-white/5">
                            @error('url')<small class="text-[12.5px] text-[#d64236]">{{ $message }}</small>@enderror
                        </label>
                        <div class="flex flex-col gap-1.5"><b class="text-[13.5px]">How the statuses go</b>
                            <div class="grid gap-2 sm:grid-cols-2">
                                @foreach (['push' => ['Push (webhook)', 'We send at once · their connector has an HTTPS address'], 'pull' => ['Pull', 'Their connector asks every few minutes · nothing open on their server']] as $k => [$t, $d])
                                    <button type="button" wire:click="$set('mode', '{{ $k }}')" @class(['flex flex-col rounded-xl px-4 py-3 text-left ring-1', 'bg-[#fff6d6] ring-2 ring-[#f6be00]' => $mode === $k, 'bg-white ring-slate-200 dark:bg-white/5' => $mode !== $k])>
                                        <b class="text-[14px]">{{ $t }}</b><small class="text-[12px] text-slate-500">{{ $d }}</small>
                                    </button>
                                @endforeach
                            </div>
                            <small class="text-[12px] text-slate-500">The connector's own setting (CONNECTOR_MODE) decides; pairing reads it from there.</small>
                        </div>
                        <div><x-filament::button color="gray" wire:click="saveConnection">Save address</x-filament::button></div>
                    </div>

                    <div class="flex flex-col gap-3 rounded-xl bg-[#f6f8fa] p-4 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10">
                        <b class="text-[14px]">Pairing</b>
                        @if (! $paired)
                            <small class="text-[13px] text-slate-600">On their server: <code class="rounded bg-white px-1.5 py-0.5 dark:bg-black/30">php artisan connector:install</code>, or in the connector's Admin → Pairing and tokens → New pairing code. It shows a code, valid 10 minutes.</small>
                            <div class="flex gap-2">
                                <input type="text" wire:model="code" placeholder="K7Q-29M" maxlength="20" aria-label="Pairing code" class="h-11 w-40 rounded-xl border-0 bg-white px-3.5 font-mono text-[18px] font-black tracking-[0.2em] uppercase ring-1 ring-slate-300 focus:ring-2 focus:ring-[#f6be00] dark:bg-white/5">
                                <x-filament::button wire:click="pair" wire:loading.attr="disabled">Pair</x-filament::button>
                            </div>
                            @error('code')<small class="text-[12.5px] text-[#d64236]">{{ $message }}</small>@enderror
                        @else
                            <p class="flex items-center gap-2 text-[14px]"><span class="grid size-6 place-items-center rounded-full bg-[#17895e] text-[13px] font-black text-white">✓</span><b>Paired</b><span class="text-slate-500">· {{ $link->paired_at?->format('M j, Y g:i A') }} · token and secret exchanged by themselves (never shown)</span></p>
                            <div class="flex flex-wrap gap-2">
                                <x-filament::button color="gray" size="sm" wire:click="checkHealth">Check now</x-filament::button>
                                <x-filament::button color="gray" size="sm" wire:click="toggleOff">{{ $link->state === 'off' ? 'Start sending again' : 'Stop sending' }}</x-filament::button>
                                <x-filament::button color="danger" outlined size="sm" wire:click="revoke" wire:confirm="Revoke the pairing? Nothing more is sent until you pair again with a new code.">Revoke</x-filament::button>
                            </div>
                            <small class="text-[12px] text-slate-500">New token: make a new pairing code on their connector and press Revoke, then Pair again.</small>
                        @endif
                    </div>
                </div>

                @if ($paired)
                    @php($h = $link->health ?? [])
                    <div @class(['flex flex-col gap-3 rounded-xl p-4 ring-1', 'bg-[#fff6d6] ring-[#e7c766]' => in_array($link->state, ['offline', 'paused'], true), 'bg-[#17895e]/6 ring-[#17895e]/25' => ! in_array($link->state, ['offline', 'paused'], true)])>
                        <b class="text-[14px]">
                            @if (in_array($link->state, ['offline', 'paused'], true))
                                ⚠ {{ $link->stateLabel() }} · {{ $link->last_error }}
                            @elseif ($link->state === 'off')
                                Sending stopped by you
                            @else
                                ● Online · last seen {{ $link->last_seen_at?->diffForHumans() ?? 'never' }}
                            @endif
                        </b>
                        <div class="grid gap-3 text-[13px] sm:grid-cols-2 xl:grid-cols-4">
                            <span class="flex flex-col"><small class="text-slate-500">Connector</small><b>{{ $link->connector_name ?: '—' }} · {{ $link->version ?: '?' }}</b></span>
                            <span class="flex flex-col"><small class="text-slate-500">Their database</small><b>{{ ($h['cms']['ok'] ?? null) === true ? '✓ connected'.(filled($h['cms']['dispatch_user'] ?? null) ? ' · user "'.$h['cms']['dispatch_user'].'"' : '') : (($h['cms']['ok'] ?? null) === false ? '✗ '.($h['cms']['problem'] ?? 'not connected') : '—') }}</b></span>
                            <span class="flex flex-col"><small class="text-slate-500">Location code on their side</small><b @class(['text-[#d64236]' => filled($link->location_code) && $link->location_code !== $cur->code])>{{ $link->location_code ?: '—' }}{{ filled($link->location_code) && $link->location_code !== $cur->code ? ' ≠ '.$cur->code.' (fix it)' : '' }}</b></span>
                            <span class="flex flex-col"><small class="text-slate-500">Their statuses (Philippines, active)</small><b>{{ count($this->theirStatuses()) }} · read {{ $link->statuses_at?->diffForHumans() ?? 'never' }}</b></span>
                        </div>
                        @foreach (array_slice((array) ($h['warnings'] ?? []), 0, 4) as $w)
                            <small class="text-[12.5px] text-[#8a6400]">⚠ {{ is_array($w) ? ($w['text'] ?? json_encode($w)) : $w }}</small>
                        @endforeach
                    </div>

                    <div class="flex flex-col gap-2">
                        <b class="text-[14px]">Check one box in their CMS (reads only, writes nothing)</b>
                        <div class="flex gap-2">
                            <input type="text" wire:model="testBox" wire:keydown.enter="checkBox" placeholder="0110457" aria-label="Box number" class="h-11 w-48 rounded-xl border-0 bg-[#f6f8fa] px-3.5 font-mono text-[15px] ring-1 ring-slate-200 dark:bg-white/5">
                            <x-filament::button color="gray" wire:click="checkBox">Check</x-filament::button>
                        </div>
                        @error('testBox')<small class="text-[12.5px] text-[#d64236]">{{ $message }}</small>@enderror
                        @if ($testResult)
                            <span @class(['rounded-lg px-3 py-2 text-[13px]', 'bg-[#17895e]/10 text-[#0f6e4a]' => $testResult['ok'], 'bg-[#fff6d6] text-[#8a6400]' => ! $testResult['ok']])>{{ $testResult['ok'] ? '✓ ' : '' }}{{ $testResult['text'] }}</span>
                        @endif
                    </div>
                @endif
            @endif

            {{-- ============================================================ Status mapping (board 77) --}}
            @if ($tab === 'map')
                @if (! $link?->statuses)
                    <p class="rounded-xl bg-[#f6f8fa] p-4 text-[14px] text-slate-600">Pair first: the connector reads their own status list, then you map ours to theirs here.</p>
                @else
                    <div class="flex flex-wrap items-center gap-2">
                        <span class="rounded-full bg-[#17895e]/12 px-3 py-1 text-[12.5px] font-extrabold text-[#17895e]">{{ $nMapped }} mapped</span>
                        <span class="rounded-full bg-[#d64236]/12 px-3 py-1 text-[12.5px] font-extrabold text-[#d64236]">{{ $nEmpty }} need mapping</span>
                        <span class="rounded-full bg-slate-100 px-3 py-1 text-[12.5px] font-extrabold text-slate-500">{{ $nSkip }} not sent</span>
                        <span class="ml-auto flex flex-wrap gap-2">
                            <x-filament::button color="gray" size="sm" wire:click="refreshStatuses">↻ Read their statuses</x-filament::button>
                            <x-filament::button color="gray" size="sm" wire:click="suggestAll">✨ Suggest all empty</x-filament::button>
                            <x-filament::button color="gray" size="sm" wire:click="clearAll" wire:confirm="Clear the whole mapping? Nothing is saved until you press Save.">Clear all</x-filament::button>
                            <x-filament::button size="sm" wire:click="saveMapping">Save mapping{{ $draftChanged ? ' •' : '' }}</x-filament::button>
                        </span>
                    </div>
                    <small class="text-[12.5px] text-slate-500">1) Tap a row on the left. 2) Tap their status on the right, or a ✨ suggestion. A place row left empty uses the "any place" row. "Needs mapping": those statuses wait at the connector and nothing is lost; they go when you save.</small>

                    <div class="grid items-start gap-5 2xl:grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)]">
                        <div class="overflow-hidden rounded-xl ring-1 ring-slate-200 dark:ring-white/10">
                            <div class="grid grid-cols-[1.25fr_0.8fr_1.55fr_104px] bg-[#f6f8fa] px-4 py-2.5 text-[12px] font-bold text-slate-500 dark:bg-white/5"><span>In Dispatch System</span><span>Place</span><span>Their status</span><span></span></div>
                            <div class="max-h-[720px] overflow-y-auto">
                                @foreach ($groups as $g => $rows)
                                    <div class="border-t border-slate-100 bg-white px-4 pt-3 pb-1 text-[11.5px] font-extrabold tracking-wide text-slate-400 dark:bg-transparent">{{ $g }}</div>
                                    @foreach ($rows as $r)
                                        <button type="button" wire:click="selectRow('{{ $r['key'] }}')" wire:key="m-{{ $r['key'] }}"
                                            @class(['grid w-full grid-cols-[1.25fr_0.8fr_1.55fr_104px] items-center gap-2 border-t border-slate-100 px-4 py-2 text-left text-[13px] dark:border-white/5',
                                                'bg-[#fff6d6] ring-2 ring-inset ring-[#f6be00]' => $sel && $sel['key'] === $r['key'],
                                                'bg-[#d64236]/4' => ! ($sel && $sel['key'] === $r['key']) && ! $r['set'] && ! $r['place']])>
                                            <b>{{ $r['label'] }}</b>
                                            <span class="text-slate-500">{{ $r['place'] ?? 'any' }}</span>
                                            <span @class(['truncate', 'text-[#d64236]' => ! $r['set'] && ! $r['place'], 'text-slate-400' => ! $r['set'] && $r['place'], 'text-slate-500 line-through' => $r['skip']])>{{ $r['their'] ?? ($r['place'] ? '(same as any place)' : '— choose their status —') }}</span>
                                            <span class="flex justify-end">@if ($r['set'] || ! $r['place'])<span @class(['whitespace-nowrap rounded-full px-2 py-0.5 text-[11px] font-extrabold',
                                                'bg-[#fff6d6] text-[#8a6400]' => $r['tag'] === 'Suggested',
                                                'bg-[#17895e]/12 text-[#17895e]' => $r['tag'] === 'Saved' || $r['tag'] === 'On their side',
                                                'bg-[#e8f1fb] text-[#2f6fb0]' => $r['tag'] === 'Changed',
                                                'bg-[#d64236]/12 text-[#d64236]' => $r['tag'] === 'Needs mapping',
                                                ])>{{ $r['tag'] }}</span>@endif</span>
                                        </button>
                                    @endforeach
                                @endforeach
                            </div>
                        </div>

                        <div class="flex flex-col gap-3 rounded-xl bg-[#f6f8fa] p-4 ring-1 ring-slate-200 dark:bg-white/5 dark:ring-white/10 2xl:sticky 2xl:top-20">
                            @if (! $sel)
                                <b class="text-[14px]">Their statuses</b>
                                <p class="text-[13px] text-slate-500">Tap a row on the left to choose their status for it.</p>
                            @else
                                <b class="text-[14px]">Choosing for: <span class="text-[#2f6fb0]">{{ $sel['label'] }}{{ $sel['place'] ? ' · '.$sel['place'] : '' }}</span></b>
                                @if ($suggest->isNotEmpty())
                                    <div class="flex flex-col gap-1.5">
                                        <small class="text-[12px] font-bold text-slate-500">✨ Suggested (names that match)</small>
                                        @foreach ($suggest as $s)
                                            <button type="button" wire:click="pickStatus({{ $s['id'] }})" class="flex items-center gap-2 rounded-lg bg-[#fff6d6] px-3 py-2 text-left text-[13px] ring-1 ring-[#e7c766]">
                                                <b class="flex-1">#{{ $s['id'] }} {{ $s['name'] }}</b><small class="font-bold text-[#8a6400]">{{ $s['pct'] }}%</small>
                                            </button>
                                        @endforeach
                                    </div>
                                @endif
                                <input type="search" wire:model.live.debounce.250ms="statusSearch" placeholder="Search their statuses" aria-label="Search their statuses" class="h-10 rounded-lg border-0 bg-white px-3 text-[13.5px] ring-1 ring-slate-200 dark:bg-white/5">
                                <div class="flex max-h-[430px] flex-col gap-1 overflow-y-auto">
                                    @foreach ($statuses as $s)
                                        @php($on = ($draft[$sel['key']]['id'] ?? null) === $s['id'])
                                        <button type="button" wire:click="pickStatus({{ $s['id'] }})" wire:key="s-{{ $s['id'] }}" @class(['flex items-center gap-2 rounded-lg px-3 py-1.5 text-left text-[13px]', 'bg-[#0e2433] text-white' => $on, 'bg-white hover:bg-[#e8f1fb] dark:bg-white/5' => ! $on])>
                                            <span class="w-10 shrink-0 font-mono text-[12px] opacity-70">#{{ $s['id'] }}</span><span class="flex-1">{{ $s['name'] }}</span>@if ($s['code'])<small class="font-mono text-[11px] opacity-60">{{ $s['code'] }}</small>@endif
                                        </button>
                                    @endforeach
                                </div>
                                <div class="flex gap-2">
                                    <x-filament::button color="gray" size="sm" wire:click="skipRow">Don't send this one</x-filament::button>
                                    <x-filament::button color="gray" size="sm" wire:click="clearRow">Clear</x-filament::button>
                                </div>
                                <small class="text-[12px] text-slate-500">Only their Philippines statuses that are on are listed. Abroad and customs stay theirs.</small>
                            @endif
                        </div>
                    </div>
                @endif
            @endif

            {{-- ============================================================ Outbox (board 79) --}}
            @if ($tab === 'outbox')
                @if (! $paired)
                    <p class="rounded-xl bg-[#f6f8fa] p-4 text-[14px] text-slate-600">Not paired yet. Statuses of {{ $cur->company_name }} are not kept until the connector is paired.</p>
                @else
                    @if ($link->state === 'paused')
                        <div class="flex flex-wrap items-center gap-3 rounded-xl bg-[#d64236]/8 px-4 py-3 ring-1 ring-[#d64236]/25">
                            <b class="text-[#a5281f]">⏸ Paused by itself</b>
                            <span class="flex-1 text-[13.5px] text-[#a5281f]">{{ \App\Support\Connectors\Rules::PAUSE_AFTER }} tries in a row failed ({{ $link->last_error }}). Nothing is lost: the statuses wait here. It tries again every {{ \App\Support\Connectors\Rules::RETRY_MINUTES }} minutes{{ $link->mailed_at ? '; the admins were emailed' : '' }}.</span>
                            <button type="button" wire:click="tryNow" class="h-9 rounded-lg bg-white px-3 text-[13px] font-bold ring-1 ring-[#d64236]/30">↻ Try now</button>
                        </div>
                    @endif
                    <div class="flex flex-wrap items-center gap-2">
                        @foreach ($filters as $f)
                            <button type="button" wire:click="setFilter('{{ $f['k'] }}')" @class(['h-9 rounded-full px-3.5 text-[13px] font-bold', 'bg-[#0e2433] text-white' => $filter === $f['k'], 'bg-[#f6f8fa] text-[#0e2433] ring-1 ring-slate-200' => $filter !== $f['k']])>{{ $f['t'] }} <span class="ml-1 opacity-70">{{ $f['n'] }}</span></button>
                        @endforeach
                        <span class="ml-auto flex flex-wrap gap-2">
                            <input type="search" wire:model.live.debounce.400ms="boxSearch" placeholder="Box number" aria-label="Find a box" class="h-9 w-36 rounded-lg border-0 bg-[#f6f8fa] px-3 text-[13px] ring-1 ring-slate-200 dark:bg-white/5">
                            <button type="button" wire:click="sendNow" wire:loading.attr="disabled" class="h-9 rounded-lg bg-[#f6be00] px-3.5 text-[13px] font-extrabold text-[#0a1219]">▶ Send now</button>
                            <button type="button" wire:click="resendFailed" class="h-9 rounded-lg bg-white px-3.5 text-[13px] font-bold ring-1 ring-slate-200 dark:bg-white/5">↻ Resend failed</button>
                        </span>
                    </div>
                    <div class="overflow-x-auto rounded-xl ring-1 ring-slate-200 dark:ring-white/10">
                        <div class="min-w-[820px]">
                            <div class="grid grid-cols-[70px_82px_1.5fr_1.15fr_1fr_1.3fr_78px] bg-[#f6f8fa] px-4 py-2.5 text-[12px] font-bold text-slate-500 dark:bg-white/5"><span>Made</span><span>Box</span><span>Status → their status</span><span>Who · where</span><span>State</span><span>Answer from the connector</span><span></span></div>
                            @forelse ($rows as $r)
                                @php([$stT, $stC] = $evCls[$r['state']] ?? [$r['state'], 'bg-slate-100 text-slate-500'])
                                @php($act = match (true) {
                                    in_array($r['state'], ['hold', 'trip', 'ready'], true) => ['Cancel', 'bg-white ring-1 ring-slate-200'],
                                    $r['state'] === 'needs_mapping' => ['Map it', 'bg-[#d64236] text-white'],
                                    $r['state'] === 'saved' && ! $r['undo'] && ! $r['undone'] => ['Undo', 'bg-white ring-1 ring-slate-200'],
                                    in_array($r['state'], ['failed', 'retry', 'busy', 'not_found', 'refused'], true) => ['Resend', 'bg-white ring-1 ring-slate-200'],
                                    default => null,
                                })
                                <div class="grid grid-cols-[70px_82px_1.5fr_1.15fr_1fr_1.3fr_78px] items-center gap-2 border-t border-slate-100 px-4 py-2.5 text-[13px] dark:border-white/5" wire:key="ev-{{ $r['id'] }}">
                                    <span class="text-slate-500">{{ $r['at']->isToday() ? $r['at']->format('g:i A') : $r['at']->format('M j g:i A') }}</span>
                                    <b class="font-mono">{{ $r['box'] }}</b>
                                    <span class="flex flex-col"><b>{{ $r['prio'] ? '⚡ ' : '' }}{{ $r['ev'] }}</b><small class="text-[12px] text-slate-500">{{ $r['their'] }}</small></span>
                                    <span class="text-slate-600">{{ $r['who'] ?: '—' }}</span>
                                    <span class="flex flex-col gap-0.5"><span class="w-fit rounded-full px-2.5 py-0.5 text-[11.5px] font-extrabold {{ $stC }}">{{ $r['undone'] ? 'Undone' : $stT }}</span>
                                        @if ($r['sends'])<small class="text-[11.5px] text-slate-500">sends {{ $r['sends']->format('g:i A') }}</small>@endif</span>
                                    <span class="line-clamp-2 text-[12.5px] text-slate-600" title="{{ $r['msg'] }}">{{ $r['msg'] ?: ($r['row'] ? 'row '.$r['row'] : '—') }}{{ $r['ms'] ? ' · '.number_format($r['ms'] / 1000, 1).' s' : '' }}</span>
                                    <span class="flex justify-end">@if ($act)<button type="button" wire:click="rowAction({{ $r['id'] }})" @if ($act[0] === 'Undo') wire:confirm="Undo this status in their CMS? The connector removes its own row and the box goes back to its last status." @endif class="h-8 rounded-lg px-2.5 text-[12px] font-bold {{ $act[1] }}">{{ $act[0] }}</button>@endif</span>
                                </div>
                            @empty
                                <p class="border-t border-slate-100 px-4 py-6 text-[13.5px] text-slate-500">Nothing here in the last 7 days.</p>
                            @endforelse
                        </div>
                    </div>
                    <small class="text-[12.5px] text-slate-500">Each status has its own ID, so sending it twice never makes two rows. Order: oldest first; with "Delivered and undo first" on, those (⚡) jump the line. Last 7 days, at most 150 rows.</small>
                @endif
            @endif
        </div>
        @endif
    </section>
</div>
</x-filament-panels::page>
DISPATCH_FILE_END_15

# ---------------------------------------------------------------- routes/console.php
mkdir -p 'routes'
cat > 'routes/console.php' <<'DISPATCH_FILE_END_16'
<?php

use App\Support\Photos\BoxPhotos;
use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

Artisan::command('photos:prune', function () {
    $this->info(BoxPhotos::prune().' old box photos deleted.');
})->purpose('Delete box photos older than the keep time in Settings → Box photos');

Artisan::command('photos:work {--seconds=50}', function () {
    \Illuminate\Support\Facades\Cache::put('photos.schedule.seen', time(), 3600);
    $n = \App\Support\Photos\Storage\PhotoWork::work((int) $this->option('seconds'));
    $n && $this->info($n.' photos moved or copied.');
})->purpose('Settings → Photo storage: go on with moves and copies (the scheduler runs it every minute)');

Artisan::command('connectors:send {--seconds=50}', function () {
    if (! \App\Support\Connectors\Recorder::ready()) {
        return;
    }
    \Illuminate\Support\Facades\Cache::put('connectors.schedule.seen', time(), 3600);
    $r = \App\Support\Connectors\Sender::run((int) $this->option('seconds'));
    ($r['sent'] || $r['released']) && $this->info("{$r['sent']} statuses sent ({$r['saved']} saved), {$r['released']} out of the hold.");
})->purpose('Settings → Consolidator connections: send the Outbox to the connectors (the scheduler runs it every minute)');

Schedule::command('photos:prune')->dailyAt('02:30');
Schedule::command('photos:work')->everyMinute()->withoutOverlapping(10);
Schedule::command('ai:work')->everyFifteenMinutes()->withoutOverlapping();
Schedule::command('aging:summary')->hourly()->withoutOverlapping();
Schedule::command('track:check')->everyFiveMinutes()->withoutOverlapping();
Schedule::command('sms:work')->everyFiveMinutes()->withoutOverlapping();
Schedule::command('track:summary')->dailyAt('18:00');
Schedule::command('photos:shrink')->everyTenMinutes()->withoutOverlapping();
Schedule::command('connectors:send')->everyMinute()->withoutOverlapping(10);
DISPATCH_FILE_END_16

# ---------------------------------------------------------------- routes/web.php
mkdir -p 'routes'
cat > 'routes/web.php' <<'DISPATCH_FILE_END_17'
<?php

use App\Http\Controllers\AiChatController;
use App\Http\Controllers\BoxPhotoController;
use App\Http\Controllers\DriverOfflineController;
use App\Http\Controllers\FuelController;
use App\Http\Controllers\InstallQrController;
use App\Http\Controllers\InvoiceController;
use App\Http\Controllers\LoadingListController;
use App\Http\Controllers\PwaController;
use App\Http\Controllers\TrackController;
use Illuminate\Foundation\Http\Middleware\ValidateCsrfToken;
use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken;
use Illuminate\Support\Facades\Route;

// Printable delivery receipt. Only signed-in users (any panel) may print.
Route::get('/tripinv/{invoice}/printpdf', [InvoiceController::class, 'tripinvoice'])
    ->middleware('auth')
    ->whereNumber('invoice')
    ->name('invoicepdf');

// Several receipts at once (at most 15), one per page: /tripinv/print?ids=1,2,3
Route::get('/tripinv/print', [InvoiceController::class, 'bulk'])
    ->middleware('auth')
    ->name('invoicepdf.bulk');

// Install the Delivery panel as an app (PWA): manifest, icons, service worker and offline page.
Route::controller(PwaController::class)->group(function () {
    Route::get('/sw.js', 'serviceWorker')->name('pwa.sw');
    Route::get('/pwa/offline', 'offline')->name('pwa.offline');
    Route::get('/pwa/{panel}/manifest.webmanifest', 'manifest')->whereIn('panel', ['delivery', 'scan'])->name('pwa.manifest');
    Route::get('/pwa/{panel}/icon-{size}.png', 'icon')->whereIn('panel', ['delivery', 'scan'])->whereNumber('size')->name('pwa.icon');
    // Same files without a file ending: Plesk's nginx serves .js / .png / .webmanifest from disk
    // and never asks Laravel, so phones get a 404 and Android does not offer to install.
    Route::get('/pwa/sw', 'serviceWorker')->name('pwa.sw.plain');
    Route::get('/pwa/{panel}/manifest', 'manifest')->whereIn('panel', ['delivery', 'scan'])->name('pwa.manifest.plain');
    Route::get('/pwa/{panel}/icon/{size}', 'icon')->whereIn('panel', ['delivery', 'scan'])->whereNumber('size')->name('pwa.icon.plain');
});

Route::middleware('web')->group(function () {
    Route::get('/box-photos/{photo}.jpg', [BoxPhotoController::class, 'show'])->whereNumber('photo')->name('box-photos.show');
    Route::get('/box-photos/{photo}/download', [BoxPhotoController::class, 'download'])->whereNumber('photo')->name('box-photos.download');
});

// Driver app without signal: today's boxes for the phone, sending what was saved offline, and the offline page.
Route::middleware('web')->group(function () {
    Route::get('/delivery-offline/trip', [DriverOfflineController::class, 'trip'])->name('driver-offline.trip');
    Route::post('/delivery-offline/sync', [DriverOfflineController::class, 'sync'])->name('driver-offline.sync');
    Route::get('/delivery-offline', [DriverOfflineController::class, 'shell'])->name('driver-offline.shell');
});

// Customer chat: receivers ask about their own box (only while "Customer chat" is on in Admin → Settings → AI).
Route::middleware(['web', 'throttle:30,60'])->controller(AiChatController::class)->group(function () {
    Route::get('/ask-box', 'show')->name('ai-chat.show');
    Route::post('/ask-box', 'start')->name('ai-chat.start');
    Route::get('/ask-box/{token}', 'chat')->name('ai-chat.chat');
    Route::post('/ask-box/{token}', 'ask')->name('ai-chat.ask');
});

// Install QR codes for the phone apps (signed-in staff only): download, poster, stickers.
Route::middleware(['web', 'auth'])->controller(InstallQrController::class)->group(function () {
    Route::get('/install-qr/{app}.png', 'png')->whereIn('app', ['scan', 'driver'])->name('install-qr.png');
    Route::get('/install-qr/{app}/poster', 'poster')->whereIn('app', ['scan', 'driver'])->name('install-qr.poster');
    Route::get('/install-qr/{app}/stickers', 'stickers')->whereIn('app', ['scan', 'driver'])->name('install-qr.stickers');
});

// Maps & routes: printed loading list of a trip (FRONT → MIDDLE → BACK).
Route::middleware(['web', 'auth'])->get('/trip-loading/{trip}', [LoadingListController::class, 'show'])
    ->whereNumber('trip')->name('trip.loading-list');

// Truck tracking: the Driver app sends locations during a trip; GPS trackers send to a secret link.
Route::middleware(['web', 'auth', 'throttle:240,1'])->post('/scan/box-photo', [App\Http\Controllers\ScanPhotoController::class, 'store'])->name('scan.box-photo');
Route::middleware(['web', 'auth', 'throttle:120,1'])->post('/delivery-track', [TrackController::class, 'driver'])->name('track.driver');
Route::middleware(['throttle:600,1'])->match(['get', 'post'], '/track/in/{token}', [TrackController::class, 'tracker'])
    ->withoutMiddleware([ValidateCsrfToken::class, VerifyCsrfToken::class, 'Illuminate\Foundation\Http\Middleware\PreventRequestForgery'])
    ->name('track.tracker');

// Part 47 · consolidator connectors call us (pull mode, hello). Signed with the pairing secret, no session.
Route::middleware(['throttle:240,1'])->prefix('api/connector/v1')->controller(App\Http\Controllers\ConnectorApiController::class)
    ->withoutMiddleware([ValidateCsrfToken::class, VerifyCsrfToken::class, 'Illuminate\Foundation\Http\Middleware\PreventRequestForgery'])
    ->group(function () {
        Route::get('/events', 'events')->name('connector-api.events');
        Route::post('/results', 'results')->name('connector-api.results');
        Route::get('/hello', 'hello')->name('connector-api.hello');
    });

// Fuel › VAT: the month's fuel receipts for the accountant (signed-in staff, their own hub).
Route::get('/fuel/vat-export', [FuelController::class, 'vatExport'])->middleware(['web', 'auth'])->name('fuel.vat-export');

// Printable QR labels for the warehouse sections.
Route::get('/sections/labels', App\Http\Controllers\SectionLabelsController::class)->middleware(['web', 'auth'])->name('sections.labels');

// Settings → Photo storage: open a copied photo (a temporary link to the bucket, or the file on this server).
Route::get('/photo-storage/open/{item}', function (int $item) {
    abort_unless(\Illuminate\Support\Facades\Auth::user()?->is_admin, 403);
    $i = \App\Models\Photos\PhotoTaskItem::findOrFail($item);
    $disk = str_starts_with($i->path, 'wms-v1/') ? 'old' : 'public';
    $key = $i->new_path ?: $i->path;
    $place = \App\Support\Photos\Storage\PhotoStore::placeOf($disk, $key);
    if ($place !== 'server') {
        return redirect()->away(\App\Support\Photos\Storage\PhotoStore::link($place, $key, 1));
    }

    return $i->source && is_file($i->source) ? response()->file($i->source) : abort(404);
})->name('photo-storage.open');

// Local only (PHOTOS_FAKE_BUCKETS=1): show a photo from a bucket that is a folder.
if (app()->environment('local') && env('PHOTOS_FAKE_BUCKETS')) {
    Route::get('/photo-storage/fake/{slot}/{key}', function (string $slot, string $key) {
        return response(\App\Support\Photos\Storage\PhotoStore::fs($slot)->get($key) ?? abort(404), 200, ['Content-Type' => 'image/jpeg']);
    })->where('key', '.*');
}

// Part 44: the signed delivery receipt, from the link in the receiver's SMS (no sign-in; the 10-letter code is the key).
Route::get('/r/{token}', function (string $token) {
    $s = \App\Models\DeliverySignature::where('token', strtolower($token))->firstOrFail();
    if (! $s->receipt_pdf || ! \Illuminate\Support\Facades\Storage::disk('public')->exists($s->receipt_pdf)) {
        \App\Support\Deliveries\SignedReceipt::make($s);
        $s->refresh();
    }
    if ($s->receipt_pdf && \Illuminate\Support\Facades\Storage::disk('public')->exists($s->receipt_pdf)) {
        return response(\Illuminate\Support\Facades\Storage::disk('public')->get($s->receipt_pdf), 200, [
            'Content-Type' => 'application/pdf',
            'Content-Disposition' => 'inline; filename="receipt-'.($s->tripinvoice?->invoice ?? $s->invoice_id).'.pdf"',
            'Cache-Control' => 'private, max-age=600',
            'X-Robots-Tag' => 'noindex',
        ]);
    }

    return response(\App\Support\Deliveries\SignedReceipt::html($s))->header('X-Robots-Tag', 'noindex');
})->where('token', '[A-Za-z0-9]{10}')->middleware('throttle:30,1')->name('signed-receipt');
DISPATCH_FILE_END_17

# ---------------------------------------------------------------- tests/Feature/ConnectorOutboxTest.php
mkdir -p 'tests/Feature'
cat > 'tests/Feature/ConnectorOutboxTest.php' <<'DISPATCH_FILE_END_18'
<?php

use App\Enums\UndoDeliveryReason;
use App\Filament\Pages\ConsolidatorConnections;
use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\Consolidator;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Services\TripAssignment;
use App\Support\Connectors\Recorder;
use App\Support\Connectors\Rules;
use App\Support\Connectors\Sender;
use App\Support\Connectors\Signer;
use App\Support\TripFlow;
use Database\Seeders\DemoSeeder;
use Filament\Facades\Filament;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Storage;
use Livewire\Livewire;

uses(RefreshDatabase::class);

beforeEach(function () {
    $this->seed(DemoSeeder::class);
    Storage::fake('public');
    $this->driver = User::where('email', 'driver@example.com')->firstOrFail();
    $this->admin = User::where('email', 'admin@example.com')->firstOrFail();
    $this->trip = Deliverylog::firstOrFail();
    $this->box = Tripinvoice::where('deliverylog_id', $this->trip->id)->firstOrFail();
    $this->con = Consolidator::where('code', Invoice::find($this->box->invoice_id)->location_code)->firstOrFail();
});

function pairLink(array $extra = []): ConnectorLink
{
    $l = ConnectorLink::create(array_merge([
        'consolidator_id' => test()->con->id, 'url' => 'https://conn.test', 'mode' => 'push',
        'token' => 'tok-123', 'secret' => 'sec-456', 'key_id' => 'key-1', 'state' => 'online', 'paired_at' => now(),
    ], $extra));
    Recorder::forgetLinks();

    return $l;
}

/** A fake connector: answers every event "saved" with a new row id. */
function fakeConnector(array &$got = []): void
{
    Http::fake(function (Request $r) use (&$got) {
        if (str_ends_with(parse_url($r->url(), PHP_URL_PATH), '/api/v1/events')) {
            $got[] = $r;
            $res = collect($r['events'])->values()->map(fn ($e, $i) => ['id' => $e['id'], 'result' => 'saved', 'row_id' => 900 + $i, 'trackstatus_id' => 15])->all();

            return Http::response(['results' => $res]);
        }
        if (str_contains($r->url(), '/api/v1/results')) {
            return Http::response(['results' => []]);
        }
        if (str_contains($r->url(), '/api/v1/health')) {
            return Http::response(['version' => '2.5.0', 'cms' => ['ok' => true]]);
        }

        return Http::response([], 404);
    });
}

it('keeps nothing while the consolidator has no paired connector', function () {
    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    expect(ConnectorEvent::count())->toBe(0);
});

it('holds Delivered 10 minutes, then sends it signed and stores their row', function () {
    pairLink();
    $got = [];
    fakeConnector($got);

    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    $e = ConnectorEvent::sole();
    expect($e->code)->toBe('ds.delivered')->and($e->state)->toBe('hold')->and($e->priority)->toBe(1)
        ->and($e->payload['by']['name'])->toBe($this->driver->full_name)
        ->and($e->payload['location_code'])->toBe($this->con->code);

    Sender::run(5);
    expect($got)->toBe([]); // still in the hold

    $this->travel(11)->minutes();
    Sender::run(5);
    expect($got)->toHaveCount(1);
    $req = $got[0];
    $path = Signer::pathOf($req->url());
    expect($req->header('Authorization')[0])->toBe('Bearer tok-123')
        ->and(Signer::valid('sec-456', $req->header(Signer::SIGN)[0], (int) $req->header(Signer::TIME)[0], 'POST', $path, $req->body()))->toBeTrue()
        ->and($e->fresh()->state)->toBe('saved')->and($e->fresh()->row_id)->toBe(900);
});

it('never sends a delivery undone inside the hold', function () {
    pairLink();
    $got = [];
    fakeConnector($got);
    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    app(TripAssignment::class)->undoDelivery($this->box->fresh(), $this->driver, UndoDeliveryReason::TappedByMistake, null);

    expect(ConnectorEvent::sole()->state)->toBe('cancelled');
    $this->travel(11)->minutes();
    Sender::run(5);
    expect($got)->toBe([]);
});

it('sends an undo first, back to the status before, when the delivery was already sent', function () {
    pairLink();
    $got = [];
    fakeConnector($got);
    $inv = Invoice::find($this->box->invoice_id);
    $load = Recorder::record($inv, 'ds.load.1', null, ['send_now' => true, 'state' => 'ready', 'source' => 'x']);
    Sender::run(5);
    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    $this->travel(11)->minutes();
    Sender::run(5);
    $delivered = ConnectorEvent::where('code', 'ds.delivered')->sole();
    expect($delivered->state)->toBe('saved');

    app(TripAssignment::class)->undoDelivery($this->box->fresh(), $this->admin, UndoDeliveryReason::TappedByMistake, null, true);
    $undo = ConnectorEvent::whereNotNull('corrects')->sole();
    expect($undo->corrects)->toBe($delivered->uid)->and($undo->code)->toBe('ds.load.1')
        ->and($undo->state)->toBe('ready')->and($undo->priority)->toBe(1)
        ->and($delivered->fresh()->undone_by)->toBe($undo->uid);
    Sender::run(5);
    expect(end($got)['events'][0]['corrects'])->toBe($delivered->uid);
});

it('sends Load on truck only when the trip leaves', function () {
    pairLink();
    $this->box->forceFill(['is_loaded' => false])->save();
    app(TripAssignment::class)->markLoaded($this->box->fresh());
    $e = ConnectorEvent::where('code', 'ds.load.1')->sole();
    expect($e->state)->toBe('trip');

    $this->trip->forceFill(['taken_at' => null])->save();
    TripFlow::take($this->trip->fresh(), $this->driver);
    expect($e->fresh()->state)->toBe('ready');
});

it('pauses a connector after 5 failed tries and emails the admins once', function () {
    Mail::fake();
    pairLink();
    Http::fake(fn () => Http::response(['message' => 'down'], 500));
    Recorder::record(Invoice::find($this->box->invoice_id), 'ds.delivered', null, ['send_now' => true]);

    for ($i = 0; $i < 5; $i++) {
        ConnectorLink::query()->update(['next_try_at' => null]);
        ConnectorEvent::query()->update(['next_try_at' => null]);
        Sender::run(5);
    }
    $l = ConnectorLink::sole();
    expect($l->state)->toBe('paused')->and($l->fails)->toBe(5)->and($l->mailed_at)->not->toBeNull()
        ->and(ConnectorEvent::sole()->state)->toBe('retry');
});

it('waits without counting a failure when the connector is busy (503)', function () {
    pairLink();
    Http::fake(['*/api/v1/events' => Http::response(['message' => 'Busy'], 503, ['Retry-After' => '15']), '*' => Http::response(['results' => []])]);
    Recorder::record(Invoice::find($this->box->invoice_id), 'ds.delivered', null, ['send_now' => true]);
    Sender::run(5);
    $e = ConnectorEvent::sole();
    expect($e->state)->toBe('ready')->and($e->next_try_at)->not->toBeNull()
        ->and(ConnectorLink::sole()->fails)->toBe(0);
});

it('gives pull connectors their events, signed, and takes their results', function () {
    $l = pairLink(['mode' => 'pull', 'url' => null]);
    $e = Recorder::record(Invoice::find($this->box->invoice_id), 'ds.delivered', null, ['send_now' => true]);

    $sign = function (string $method, string $uri, string $body = '') {
        $t = time();

        return ['X-Connector-Key' => 'key-1', 'X-Connector-Time' => (string) $t, 'X-Connector-Signature' => Signer::make('sec-456', $t, $method, $uri, $body)];
    };

    $this->get('/api/connector/v1/events?after=0&limit=100', ['X-Connector-Key' => 'key-1', 'X-Connector-Time' => (string) time(), 'X-Connector-Signature' => 'sha256=bad'])->assertStatus(401);

    $res = $this->get('/api/connector/v1/events?after=0&limit=100', $sign('GET', '/api/connector/v1/events?after=0&limit=100'));
    $res->assertOk();
    expect($res->json('events.0.id'))->toBe($e->uid)
        ->and(Signer::valid('sec-456', $res->headers->get(Signer::SIGN), (int) $res->headers->get(Signer::TIME), 'RESPONSE', '/api/connector/v1/events', $res->getContent()))->toBeTrue()
        ->and($e->fresh()->state)->toBe('sent');

    $body = json_encode(['results' => [['id' => $e->uid, 'result' => 'saved', 'row_id' => 77]]]);
    $this->call('POST', '/api/connector/v1/results', [], [], [], array_merge(['CONTENT_TYPE' => 'application/json'],
        collect($sign('POST', '/api/connector/v1/results', $body))->mapWithKeys(fn ($v, $k) => ['HTTP_'.strtoupper(str_replace('-', '_', $k)) => $v])->all()), $body)->assertOk();
    expect($e->fresh()->state)->toBe('saved')->and($e->fresh()->row_id)->toBe(77);
});

it('pairs from the page, reads their statuses and suggests a mapping', function () {
    Http::fake([
        '*/api/v1/pair' => Http::response(['token' => 't', 'secret' => 's', 'key_id' => 'k', 'connector' => ['name' => 'Forex connector', 'version' => '2.5.0', 'mode' => 'push', 'location_code' => test()->con->code]], 201),
        '*/api/v1/statuses' => Http::response(['ph_branch_id' => 2, 'statuses' => [
            ['id' => 6, 'description' => 'Unloaded in Philippine Warehouse', 'branch_id' => 2, 'is_active' => 1],
            ['id' => 7, 'description' => 'Loaded to Truck for Delivery', 'branch_id' => 2, 'is_active' => 1],
            ['id' => 51, 'description' => 'Loaded to truck - 2nd attempt', 'branch_id' => 2, 'is_active' => 1],
            ['id' => 15, 'description' => 'Delivered', 'branch_id' => 2, 'is_active' => 1],
            ['id' => 3, 'description' => 'ETA Manila', 'branch_id' => 1, 'is_active' => 1],
        ], 'mapping' => []]),
        '*/api/v1/health' => Http::response(['version' => '2.5.0', 'cms' => ['ok' => true]]),
        '*/api/v1/mapping' => Http::response(['saved' => 4, 'retried' => 0]),
    ]);
    Filament::setCurrentPanel(Filament::getPanel('admin'));
    $this->actingAs($this->admin);

    $page = Livewire::test(ConsolidatorConnections::class, ['con' => $this->con->id])
        ->set('url', 'https://conn.test')->set('code', 'k7q-29m')->call('pair')
        ->assertHasNoErrors()->assertSet('tab', 'map');
    $draft = $page->get('draft');
    expect($draft['ds.delivered']['id'])->toBe(15)->and($draft['ds.load.1']['id'])->toBe(7)
        ->and($draft['ds.load.2']['id'])->toBe(51)->and($draft['ds.unloaded']['id'])->toBe(6);

    $page->call('saveMapping');
    expect(ConnectorLink::sole()->mappings()->count())->toBeGreaterThanOrEqual(4);
    Http::assertSent(fn (Request $r) => $r->method() === 'PUT' && collect($r['rows'])->contains('key', 'ds.delivered'));

    $page->call('setTab', 'outbox')->assertSee('Send now');
    $page->call('setTab', 'conn')->assertSee('Paired');
});

it('turns the hold off with its rule', function () {
    pairLink();
    Rules::save(['hold' => false] + Rules::all());
    app(TripAssignment::class)->markDelivered($this->box, ['d.jpg'], $this->driver);
    expect(ConnectorEvent::sole()->state)->toBe('ready');
});
DISPATCH_FILE_END_18

echo "▶ Updating the database (keeps your data)"
php artisan migrate --force

echo "▶ Rebuilding the design"
npm run build

echo "▶ Clearing caches"
php artisan optimize:clear

echo "▶ Running the tests"
php artisan test --filter=Connector || echo "Some tests failed — send the red text for help."

echo
echo "✓ Done. Backup: $BACKUP"
echo "  Start the app with:  PHP_CLI_SERVER_WORKERS=4 php artisan serve   (or open https://dispatchsystem.test in Herd)"
