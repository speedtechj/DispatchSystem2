<?php

namespace App\Support\Connectors;

use App\Models\Connectors\ConnectorEvent;
use App\Models\Connectors\ConnectorLink;
use App\Models\Container;
use App\Models\Invoice;
use Illuminate\Support\Facades\Cache;
use Throwable;

/**
 * Part 47c · Consolidator tracking (board 83): a box the way the consolidator's own
 * tracking shows it, read from their connector (read only, signed), next to ours.
 */
class TheirTracking
{
    public static function linkFor(Invoice $i): ?ConnectorLink
    {
        $id = Recorder::linkIdFor($i->location_code);

        return $id ? ConnectorLink::query()->find($id) : null;
    }

    /**
     * @return array{ok: bool, offline: bool, read_at: ?string, message: ?string, found: bool, rows: list<array>}
     */
    public static function box(Invoice $i, bool $fresh = false): array
    {
        $link = static::linkFor($i);
        if (! $link) {
            return ['ok' => false, 'offline' => false, 'read_at' => null, 'message' => 'This consolidator has no connector yet.', 'found' => false, 'rows' => []];
        }
        if (! $link->isPush()) {
            return ['ok' => false, 'offline' => false, 'read_at' => null, 'message' => 'Their connector is in pull mode: Dispatch System cannot ask it (tracking needs push).', 'found' => false, 'rows' => []];
        }
        $key = 'conn.track.'.$link->id.'.'.$i->invoice;
        if (! $fresh && ($c = Cache::get($key)) && ($c['at'] ?? 0) > time() - 120) {
            return $c['data'];
        }
        try {
            $t = (new Client($link))->get('/api/v1/track?'.http_build_query(['invoice' => (string) $i->invoice]), 15);
            $data = ['ok' => true, 'offline' => false, 'read_at' => now()->format('g:i A'), 'message' => null,
                'found' => (bool) ($t['found'] ?? false), 'rows' => array_values($t['rows'] ?? [])];
            Cache::put($key, ['at' => time(), 'data' => $data], now()->addDays(2));

            return $data;
        } catch (Throwable $e) {
            $old = Cache::get($key)['data'] ?? null;

            return $old
                ? ['offline' => true, 'message' => $e->getMessage()] + $old
                : ['ok' => false, 'offline' => true, 'read_at' => null, 'message' => $e->getMessage(), 'found' => false, 'rows' => []];
        }
    }

    /** What Dispatch System sent for this box, newest first. */
    public static function ours(Invoice $i): array
    {
        return ConnectorEvent::query()->where('invoice_id', $i->id)->latest('id')->limit(30)->get()->map(fn (ConnectorEvent $e) => [
            't' => ($e->corrects ? 'Undo → ' : '').$e->label, 'at' => $e->happened_at?->format('M j g:i A'),
            'who' => implode(' · ', array_filter([$e->payload['by']['name'] ?? null, $e->payload['by']['role'] ?? null, $e->manual ? 'manual' : null, $e->priority === Backfill::PRIORITY ? 'backfill' : null])),
            'state' => $e->undone_by ? 'undone' : $e->state, 'msg' => $e->message, 'row' => $e->row_id,
        ])->all();
    }

    /**
     * Every box of a container: their newest status (one request per 500 boxes), and
     * whether it matches what Dispatch System last saved there.
     *
     * @return array{ok: bool, message: ?string, total: int, took: float, groups: list<array{t: string, n: int, kind: string, boxes: list<string>}>}
     */
    public static function container(Container $c): array
    {
        $start = microtime(true);
        $boxes = Invoice::query()->where('container_id', $c->id)->get(['id', 'invoice', 'location_code']);
        $groups = [];
        $put = function (string $t, string $kind, string $box) use (&$groups) {
            $groups[$kind.'|'.$t] ??= ['t' => $t, 'kind' => $kind, 'n' => 0, 'boxes' => []];
            $groups[$kind.'|'.$t]['n']++;
            $groups[$kind.'|'.$t]['boxes'][] = $box;
        };
        $message = null;
        foreach ($boxes->groupBy('location_code') as $loc => $list) {
            $id = Recorder::linkIdFor((string) $loc);
            $link = $id ? ConnectorLink::query()->find($id) : null;
            if (! $link || ! $link->isPush()) {
                foreach ($list as $b) {
                    $put('No connector for this consolidator', 'none', $b->invoice);
                }

                continue;
            }
            $ours = ConnectorEvent::query()->whereIn('invoice_id', $list->pluck('id'))->where('state', 'saved')->whereNull('undone_by')
                ->orderBy('id')->get(['invoice_id', 'trackstatus_id', 'row_id'])->keyBy('invoice_id');
            foreach ($list->chunk(500) as $chunk) {
                try {
                    $res = (new Client($link))->send('POST', '/api/v1/track', ['invoices' => $chunk->pluck('invoice')->values()->all()], 30);
                } catch (Throwable $e) {
                    $message = $e->getMessage();
                    foreach ($chunk as $b) {
                        $put('Their connector did not answer', 'off', $b->invoice);
                    }

                    continue;
                }
                foreach ($chunk as $b) {
                    $r = $res['boxes'][$b->invoice] ?? null;
                    if (! ($r['found'] ?? false)) {
                        $put('Not in their CMS', 'missing', $b->invoice);

                        continue;
                    }
                    $latest = $r['latest'];
                    $put((string) ($latest['status'] ?? '#'.$latest['status_id']), 'status', $b->invoice);
                    $mine = $ours->get($b->id);
                    if ($mine && (int) $mine->row_id !== (int) $latest['row_id'] && ($latest['by'] ?? '') === 'staff') {
                        $put('Their staff changed it after us', 'mismatch', $b->invoice);
                    }
                }
            }
        }
        $order = ['status' => 0, 'mismatch' => 1, 'missing' => 2, 'off' => 3, 'none' => 4];
        $groups = array_values($groups);
        usort($groups, fn ($a, $b) => [$order[$a['kind']], -$a['n']] <=> [$order[$b['kind']], -$b['n']]);

        return ['ok' => $message === null, 'message' => $message, 'total' => $boxes->count(), 'took' => round(microtime(true) - $start, 1), 'groups' => $groups];
    }
}
