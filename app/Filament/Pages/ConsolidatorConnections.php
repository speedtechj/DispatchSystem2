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
