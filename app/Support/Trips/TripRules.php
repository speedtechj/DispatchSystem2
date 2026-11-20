<?php

namespace App\Support\Trips;

use App\Models\AppSetting;
use App\Models\Boxes\SetSplit;
use App\Models\Invoice;
use App\Models\TripOverride;
use App\Models\User;
use Filament\Notifications\Notification;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

/**
 * Trip rules and who can bypass them: off (no reason needed), anyone with a reason, or office only.
 * The office = Admin and Super admin. Every bypass is saved with who and why.
 */
class TripRules
{
    /** key => [title, what it stops, default level] */
    public const RULES = [
        'topup_other' => ['Top up with other cities', 'Add boxes of a city not on the trip', 'reason'],
        'truck_full' => ['Truck full', 'Load more than the truck space', 'reason'],
        'split_set' => ['Split a customer', 'A customer’s boxes on two trips', 'office'],
        'wrong_hub' => ['Wrong hub or warehouse', 'Box for another partner hub or warehouse', 'office'],
        'change_plan' => ['Change the AI plan', 'Switch off a trip or change its truck before Create', 'reason'],
        'load_order' => ['Load out of order', 'Too early for its stop', 'off'],
        'direct_hub' => ['Deliver direct instead of a hub', 'A hub’s boxes on our own trip, or the reverse', 'reason'],
    ];

    public const LEVELS = ['off' => 'Off', 'reason' => 'Anyone with a reason', 'office' => 'Office only'];

    public const DEFAULT_REASONS = ['Customer called', 'Road closed', 'It still fits (small box)', 'Truck problem', 'Other'];

    public static function ready(): bool
    {
        return Schema::hasTable('trip_overrides');
    }

    public static function level(string $rule): string
    {
        $l = (string) AppSetting::get('rules.'.$rule, self::RULES[$rule][2] ?? 'reason');

        return isset(self::LEVELS[$l]) ? $l : 'reason';
    }

    public static function setLevel(string $rule, string $level): void
    {
        if (isset(self::RULES[$rule], self::LEVELS[$level])) {
            AppSetting::put('rules.'.$rule, $level);
        }
    }

    /** @return list<string> */
    public static function reasons(): array
    {
        $r = json_decode((string) AppSetting::get('rules.reasons', ''), true);

        return is_array($r) && $r ? array_values($r) : self::DEFAULT_REASONS;
    }

    public static function setReasons(array $reasons): void
    {
        AppSetting::put('rules.reasons', json_encode(array_values(array_unique(array_filter(array_map(fn ($r) => Str::limit(trim((string) $r), 60, ''), $reasons))))));
    }

    /** The office: Admin and Super admin. */
    public static function isOffice(?User $u): bool
    {
        return (bool) ($u && ($u->is_admin || $u->hasRole('super_admin')));
    }

    /** What this person needs to bypass the rule: free, reason, or office (ask the office). */
    public static function need(string $rule, ?User $u, ?int $tripId = null, ?int $invoiceId = null): string
    {
        if (! static::ready()) {
            return 'free';
        }
        if ($tripId && $invoiceId && static::isApproved($rule, $tripId, $invoiceId)) {
            return 'free';
        }

        return match (static::level($rule)) {
            'off' => 'free',
            'office' => static::isOffice($u) ? 'reason' : 'office',
            default => 'reason',
        };
    }

    public static function isApproved(string $rule, ?int $tripId, ?int $invoiceId): bool
    {
        return static::ready() && $tripId && $invoiceId
            && TripOverride::where('rule', $rule)->where('trip_id', $tripId)->where('invoice_id', $invoiceId)->where('status', 'approved')->exists();
    }

    /** A bypass with a reason (allowed now). */
    public static function record(string $rule, ?User $u, ?string $reason, array $ctx = [], string $status = 'allowed'): ?TripOverride
    {
        if (! static::ready()) {
            return null;
        }

        return TripOverride::create([
            'rule' => $rule, 'trip_kind' => $ctx['kind'] ?? 'delivery', 'trip_id' => $ctx['trip_id'] ?? null, 'trip_number' => $ctx['trip_number'] ?? null,
            'invoice_id' => $ctx['invoice_id'] ?? null, 'box' => $ctx['box'] ?? null, 'user_id' => $u?->id,
            'reason' => $reason ? Str::limit($reason, 115, '') : null, 'note' => isset($ctx['note']) ? Str::limit($ctx['note'], 195, '') : null,
            'data' => $ctx['data'] ?? null, 'status' => $status,
        ]);
    }

    /** Office only: the request waits; the office gets it in the bell. */
    public static function ask(string $rule, ?User $u, ?string $reason, array $ctx = []): ?TripOverride
    {
        $existing = static::ready() && ($ctx['trip_id'] ?? null) && ($ctx['invoice_id'] ?? null)
            ? TripOverride::where('rule', $rule)->where('trip_id', $ctx['trip_id'])->where('invoice_id', $ctx['invoice_id'])->where('status', 'pending')->first() : null;
        $o = $existing ?? static::record($rule, $u, $reason, $ctx, 'pending');
        if ($o && ! $existing) {
            try {
                $office = User::where('is_admin', true)->get()->merge(User::role('super_admin')->get())->unique('id');
                Notification::make()->title('Approve: '.self::RULES[$rule][0])
                    ->body(collect([$o->box, $o->trip_number ? 'trip '.$o->trip_number : null, $u?->first_name, $reason])->filter()->join(' · '))
                    ->warning()->sendToDatabase($office);
            } catch (\Throwable $e) {
                report($e);
            }
        }

        return $o;
    }

    public static function decide(TripOverride $o, bool $yes, ?User $by): void
    {
        $o->update(['status' => $yes ? 'approved' : 'refused', 'decided_by' => $by?->id, 'decided_at' => now()]);
        // an approved split is written as the reason the box stays behind
        if ($yes && $o->rule === 'split_set' && $o->invoice_id && $o->trip_id) {
            $key = $o->data['split'] ?? null;
            SetSplit::updateOrCreate(['invoice_id' => $o->invoice_id, 'deliverylog_id' => $o->trip_id],
                ['reason' => array_key_exists((string) $key, SetSplit::REASONS) ? $key : 'held', 'user_id' => $o->user_id, 'set_key' => Invoice::whereKey($o->invoice_id)->value('set_key')]);
        }
        if ($o->user) {
            try {
                Notification::make()->title(self::RULES[$o->rule][0].': '.($yes ? 'approved' : 'refused'))
                    ->body(($o->box ? $o->box.' · ' : '').($yes ? 'Scan it again to load it.' : 'Keep it off the truck.'))
                    ->{$yes ? 'success' : 'danger'}()->sendToDatabase($o->user);
            } catch (\Throwable $e) {
                report($e);
            }
        }
    }

    /** The rule behind a "load it anyway" warning. */
    public static function ruleOf(?array $early, ?array $wrongHub): string
    {
        if ($early) {
            return 'load_order';
        }

        return match ($wrongHub['kind'] ?? null) {
            'city' => 'topup_other',
            'full' => 'truck_full',
            'hub' => 'direct_hub',
            default => 'wrong_hub',
        };
    }

    public static function pendingCount(): int
    {
        return static::ready() ? TripOverride::where('status', 'pending')->count() : 0;
    }
}
