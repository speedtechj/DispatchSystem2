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
