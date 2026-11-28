<?php

namespace App\Support\Connectors;

use App\Models\Connectors\ConnectorEvent;
use App\Models\Container;
use App\Models\Consolidator;
use App\Models\Deliverylog;
use App\Models\Invoice;
use App\Models\Logistichub;
use App\Models\Tripinvoice;
use App\Models\User;
use App\Models\Whdeliverylog;
use App\Models\Whtripinvoice;
use App\Support\People\People;
use Carbon\CarbonInterface;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Schema;

/**
 * Part 47b · Send status manually (board 80): for a missed scan (broken phone, no
 * signal, forgot). It goes through the same Outbox and 10-minute hold.
 */
class ManualSend
{
    /** Over this many boxes, the page asks "Are you sure?". */
    public const CONFIRM_OVER = 50;

    public const MAX_BOXES = 500;

    /** Admins always may; drivers never; others when "Send status manually" is on for them. */
    public static function allowed(?User $u): bool
    {
        if (! $u || ! Recorder::ready()) {
            return false;
        }
        if (People::panelCode((int) $u->panelcategory_id) === 'drv') {
            return false; // drivers never, whatever their role
        }
        if ($u->is_admin || $u->hasRole('super_admin')) {
            return true;
        }

        return Schema::hasColumn('users', 'can_send_status') && (bool) $u->can_send_status;
    }

    /**
     * Which boxes this user may send for: null = all; otherwise a query limit.
     * Partner hub (company): boxes that were sent to their hub. Warehouse: boxes in their warehouse.
     *
     * @return array{type: string, id: int}|null
     */
    public static function scope(User $u, string $panel): ?array
    {
        $hub = $u->logistichub_id ? Logistichub::query()->find($u->logistichub_id) : null;
        if ($panel === 'company' || $hub?->is_company) {
            return ['type' => 'hub', 'id' => (int) ($hub?->id ?? -1)];
        }
        if ($panel === 'warehouse' && $u->warehouse_id) {
            return ['type' => 'warehouse', 'id' => (int) $u->warehouse_id];
        }

        return null;
    }

    public static function scopeName(?array $scope): string
    {
        return match ($scope['type'] ?? null) {
            'hub' => Logistichub::query()->whereKey($scope['id'])->value('hub_name') ?? 'your hub',
            'warehouse' => \App\Models\Warehouse::query()->whereKey($scope['id'])->value('name') ?? 'your warehouse',
            default => 'all boxes',
        };
    }

    /** @param  Collection<int, int>|array<int>  $ids  @return Collection<int, int> the ones in scope */
    public static function allowedIds($ids, ?array $scope): Collection
    {
        $ids = collect($ids)->map(fn ($i) => (int) $i)->unique()->values();
        if ($scope === null || $ids->isEmpty()) {
            return $ids;
        }

        return match ($scope['type']) {
            'hub' => $ids->intersect(Tripinvoice::query()->whereIn('invoice_id', $ids)
                ->where(fn ($q) => $q->where('logistichub_id', $scope['id'])->orWhereIn('deliveryloghub_id', Deliverylog::query()->where('logistichub_id', $scope['id'])->select('id')))
                ->pluck('invoice_id'))->values(),
            'warehouse' => Invoice::query()->whereIn('id', $ids)->where('warehouse_id', $scope['id'])->pluck('id'),
            default => collect(),
        };
    }

    /** A box number (leading 0 optional). */
    public static function findBox(string $no): ?Invoice
    {
        $no = trim($no);
        if ($no === '') {
            return null;
        }

        return Invoice::query()->where('invoice', $no)->first()
            ?? Invoice::query()->where('invoice', ltrim($no, '0'))->first()
            ?? Invoice::query()->where('invoice', '0'.$no)->first();
    }

    /** Boxes of a delivery trip or a warehouse transfer trip. @return Collection<int, int> */
    public static function tripBoxes(string $no): Collection
    {
        $no = trim($no);
        $ids = Tripinvoice::query()->where(fn ($q) => $q->whereIn('deliverylog_id', Deliverylog::query()->where('trip_number', $no)->select('id'))
            ->orWhereIn('deliveryloghub_id', Deliverylog::query()->where('trip_number', $no)->select('id')))->pluck('invoice_id');

        return $ids->merge(Whtripinvoice::query()->whereIn('whdeliverylog_id', Whdeliverylog::query()->where('trip_number', $no)->select('id'))->pluck('invoice_id'))->unique()->values();
    }

    /** @return Collection<int, int> */
    public static function containerBoxes(string $no): Collection
    {
        $no = preg_replace('/\s+/', '', $no);
        $c = Container::query()->whereRaw("REPLACE(container_no, ' ', '') = ?", [$no])->first()
            ?? Container::query()->whereRaw("REPLACE(container_no, ' ', '') like ?", ['%'.$no.'%'])->first();

        return $c ? Invoice::query()->where('container_id', $c->id)->pluck('id') : collect();
    }

    /** The newest status sent (or waiting) for each box: invoice id => label. @return array<int, string> */
    public static function lastSent(array $ids): array
    {
        if (! $ids) {
            return [];
        }

        return ConnectorEvent::query()->whereIn('invoice_id', $ids)->whereNotIn('state', ['cancelled', 'refused'])->whereNull('undone_by')
            ->orderBy('id')->get(['invoice_id', 'label', 'happened_at'])
            ->keyBy('invoice_id')->map(fn ($e) => $e->label.' · '.$e->happened_at?->format('M j g:i A'))->all();
    }

    /**
     * Put the status in the Outbox for every box whose consolidator has a connector.
     *
     * @param  list<int>  $ids
     * @return array{made: int, skipped: int, until: ?CarbonInterface}
     */
    public static function send(array $ids, string $code, ?string $place, CarbonInterface $at, ?string $note, string $reason, User $by): array
    {
        $made = 0;
        $skipped = 0;
        $until = null;
        foreach (Invoice::query()->whereIn('id', $ids)->get() as $inv) {
            $ev = Recorder::record($inv, $code, $place ?: null, [
                'at' => $at, 'user' => $by, 'note' => $note, 'reason' => 'Manual · '.$reason, 'manual' => true,
                'state' => 'hold', 'source' => 'manual:'.$inv->id.':'.now()->format('YmdHis'), 'location' => $place,
            ]);
            if ($ev) {
                $made++;
                $until = $ev->send_after;
            } else {
                $skipped++;
            }
        }

        return ['made' => $made, 'skipped' => $skipped, 'until' => $until];
    }

    /** Consolidators of these boxes: code => [name, connected, n]. @return array<string, array{name: string, connected: bool, n: int}> */
    public static function groups(array $ids): array
    {
        if (! $ids) {
            return [];
        }
        $links = Recorder::links();

        return Invoice::query()->whereIn('id', $ids)->selectRaw('location_code, count(*) as n')->groupBy('location_code')->get()
            ->mapWithKeys(fn ($r) => [(string) $r->location_code => [
                'name' => Consolidator::nameForCode($r->location_code) ?? 'Location '.$r->location_code,
                'connected' => isset($links[(string) $r->location_code]), 'n' => (int) $r->n,
            ]])->all();
    }
}
