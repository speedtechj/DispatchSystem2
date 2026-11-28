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
