<?php

namespace App\Support\Deliveries;

use App\Enums\FailedDeliveryReason as R;
use App\Models\DeliveryAttempt;
use Carbon\Carbon;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;

/**
 * Part 44 (board 69): when a box that could not be delivered is tried again.
 * The reason sets the date; after 3 tries, or when only the office can fix it, the office decides.
 */
class NextTry
{
    public const MAX_TRIES = 3;

    /** Reasons the driver cannot fix by coming back: the office calls or fixes the address first. */
    public const OFFICE = [R::AddressNotFound, R::PhoneUnreachable, R::Refused, R::BoxDamaged];

    /** The next working day (no Sundays). */
    public static function workday(?Carbon $from = null, int $days = 1): Carbon
    {
        $d = ($from ?? today())->copy()->startOfDay();
        for ($i = 0; $i < $days; $i++) {
            $d->addDay();
            if ($d->isSunday()) {
                $d->addDay();
            }
        }

        return $d;
    }

    /**
     * @return array{on: ?Carbon, office: bool, text: string}
     */
    public static function plan(R $reason, int $tryNumber, ?string $picked = null): array
    {
        if ($tryNumber >= self::MAX_TRIES) {
            return ['on' => null, 'office' => true, 'text' => "Try {$tryNumber} of ".self::MAX_TRIES.': the office takes over'];
        }
        if (in_array($reason, self::OFFICE, true)) {
            return ['on' => null, 'office' => true, 'text' => match ($reason) {
                R::AddressNotFound => 'The office fixes the address first',
                R::PhoneUnreachable => 'The office calls the receiver first',
                R::Refused => 'The office calls the sender first',
                default => 'The office decides',
            }];
        }
        $on = match ($reason) {
            R::Rescheduled => $picked ? Carbon::parse($picked)->startOfDay() : static::workday(),
            R::AreaInaccessible => static::workday(null, 2),
            default => static::workday(),
        };
        if ($on->lte(today())) {
            $on = static::workday();
        }

        return ['on' => $on, 'office' => false, 'text' => 'Next try: '.$on->format('D M j')];
    }

    /** Days the receiver can pick when they ask for another day. */
    public static function choices(): array
    {
        return collect([1, 2, 3, 5])->mapWithKeys(fn ($n) => [static::workday(null, $n)->toDateString() => $n === 1 ? 'Tomorrow · '.static::workday()->format('D') : static::workday(null, $n)->format('D M j')])->all();
    }

    /** The latest try of each box that is still not delivered. */
    public static function open(): Builder
    {
        return DeliveryAttempt::query()
            ->whereIn('id', DeliveryAttempt::selectRaw('MAX(id)')->groupBy('invoice_id'))
            ->whereNull('handled_at')
            ->whereHas('invoice', fn ($q) => $q->where('is_delivered', false));
    }

    /** Due today / Overdue / On hold (a later day) / Needs office. */
    public static function tab(DeliveryAttempt $a): string
    {
        return match (true) {
            $a->needs_office || ! $a->next_try_on => 'office',
            Carbon::parse($a->next_try_on)->lt(today()) => 'overdue',
            Carbon::parse($a->next_try_on)->isToday() => 'today',
            default => 'hold',
        };
    }

    /** @return Collection<string, int> */
    public static function counts(Collection $rows): Collection
    {
        return collect(['today' => 0, 'overdue' => 0, 'hold' => 0, 'office' => 0])->merge($rows->countBy(fn ($a) => static::tab($a)));
    }
}
